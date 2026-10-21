// El canal de control del enlace sobre Network.framework (IOS-11, ADR 0023 §3).
//
// Solo control (TCP, tramas separadas por su `length`): los medios por UDP y el
// `hello` autenticado llegan con IOS-16 e IOS-12. Escucha el izquierdo —anuncia
// `_footballai-rig._tcp` con el lado y la huella del secreto en la TXT— y conecta el
// derecho con NWBrowser, en cualquier orden de arranque. La reconexión espera
// creciente con tope de 2 s (decisión 3): en la cancha, «se soltó el cable» tiene que
// curarse solo y rápido.
//
// Para los tests de macOS el transporte también sabe escuchar en un puerto del
// loopback y conectar a él directamente, sin Bonjour ni Ethernet: la lógica de
// tramas, estados y reconexión es la misma.
//
// Cómo se anuncia y se busca cada canal lo dice la cita (LinkRendezvous, IOS-14):
// Bonjour por la interfaz pedida, o Wi-Fi Aware entre dispositivos emparejados. Por Wi-Fi
// Aware, además, la cita caduca a los ~2 min y nada avisa si el datapath muere: un vigía
// de silencio tira el enlace entero (control y medios) cuando el otro calla, y la cita
// se vuelve a abrir entonces, no mientras la conexión sigue (IOS-14c).

import Foundation
import Network
import os
import RigCore

public final class NWLinkTransport: LinkTransport {
    /// Cómo se llega al otro móvil.
    public enum Mode {
        /// El izquierdo: anuncia el servicio con la TXT {side, huella}.
        case advertise(name: String, txt: [String: String])
        /// El derecho: busca el servicio y conecta.
        case browse
        /// Tests: escuchar en un puerto del loopback (0 = efímero).
        case listen(port: UInt16)
        /// Tests: conectar a un host y puerto concretos.
        case connect(host: String, port: UInt16)
    }

    /// Un hueco entre llegadas de medios mayor que esto es un parón (ADR 0023 §6).
    static let mediaStallMs: Double = 100

    /// Segundos sin un datagrama de medios, con el control conectado, tras los que el
    /// lado que busca prueba otro anuncio de medios: el primero puede ser uno viejo de la
    /// caché de Bonjour (un proceso anterior) y por UDP nada avisa de que no hay nadie.
    static let mediaWatchdogS: Double = 3

    /// Segundos que se espera a que el control quede listo antes de darlo por perdido y
    /// probar otro anuncio, por Bonjour: una conexión a un anuncio muerto se queda en
    /// `.waiting` sin fallar nunca. Wi-Fi Aware pide más (`connectTimeoutS` de la cita).
    static let controlConnectTimeoutS: Double = 4

    /// Espera creciente de la reconexión, con el tope de 2 s de la decisión 3.
    static let reconnectDelaysS: [Double] = [0.25, 0.5, 1.0, 2.0]

    /// Segundos hasta volver a publicar, con la conexión arriba, una cita que FALLÓ (no
    /// que caducó): por Bonjour, un listener que se cae se cambia por otro sin tocar la
    /// conexión. La espera evita un bucle si el nuevo fallara enseguida. La que caduca
    /// (Wi-Fi Aware) no se renueva hasta que cae la conexión (IOS-14c).
    static let rendezvousRenewS: Double = 5

    /// Segundos hasta abrir otra cita cuando la anterior caduca sin conexión: el otro
    /// todavía no ha aparecido y hay que seguir publicando o buscando.
    static let rendezvousRetryS: Double = 0.5

    /// Segundos que la cita nueva de un canal espera a que la vieja diga `.cancelled` antes
    /// de publicarse igual (Bug B, 2026-10-21). Por Wi-Fi Aware dos publicaciones del mismo
    /// servicio no conviven: la nueva cae con `serviceAlreadyPublishing`. Cancelar un
    /// listener tarda milisegundos; el tope es por si el `.cancelled` no llegara nunca.
    static let listenerCancelWaitS: Double = 2

    /// Cuántas veces por plazo de silencio mira el vigía: con 4, un enlace muerto se tira
    /// entre 1 y 1,25 plazos después de lo último que llegó.
    static let silenceChecksPerTimeout: Double = 4

    /// Cuántas veces por plazo mira el vigía de la suscripción: con 4, una suscripción que
    /// no da con nadie se cambia entre 1 y 1,25 plazos después de abrirse.
    static let subscriptionChecksPerTimeout: Double = 4

    /// Sucesos que guarda la línea de tiempo del banco: los últimos `maxEvents` y, aparte,
    /// los `maxStartEvents` primeros, que son el arranque (2026-10-11).
    static let maxEvents = 80
    static let maxStartEvents = 40

    /// Qué se hace cuando una cita (listener o browser) se acaba (IOS-14).
    enum RendezvousEndAction: Equatable {
        /// Con la conexión arriba: la cita se guarda sin cancelar y se abre otra cuando la
        /// conexión caiga. El que busca, siempre; los dos, si caducó (Wi-Fi Aware). No es
        /// un fallo del transporte.
        case keepUntilDrop
        /// El que anuncia, con la conexión arriba y un fallo que no es caducidad: se
        /// vuelve a publicar al rato, sin tocar la conexión.
        case renewLater
        /// Sin conexión y la cita caducó: se abre otra enseguida, sin pasar por `.failed`.
        case reopen
        /// Sin conexión y un error de verdad: `.failed` y se abre otra con espera.
        case fail
    }

    /// La decisión ante el fin de una cita. Con la conexión arriba nada es un fallo del
    /// transporte: por Wi-Fi Aware las conexiones sobreviven a la cita que las creó, y
    /// Apple pide soltar el listener y el browser en cuanto están las conexiones («stop
    /// the listener and browser once all the required connections have been made», WWDC25
    /// 228). Por eso la que caduca ya no se vuelve a publicar con la conexión arriba
    /// (95f756e lo hacía cada ~2 min): si el enlace muere, el vigía de silencio lo tira en
    /// los dos lados y es entonces cuando se abre una cita nueva (IOS-14c).
    static func rendezvousEndAction(publishing: Bool, connected: Bool, expired: Bool) -> RendezvousEndAction {
        if connected { return publishing && !expired ? .renewLater : .keepUntilDrop }
        return expired ? .reopen : .fail
    }

    /// Si el vigía de silencio tira el enlace: arriba, con vigía (la cita da plazo), con
    /// medios del otro desde que subió el control (sin ellos no hay latidos que echar de
    /// menos: el apretón de manos o un conflicto de roles) y callado más que el plazo.
    static func linkIsDead(connected: Bool, peerMediaSinceConnect: Bool, silentS: Double, limitS: Double?) -> Bool {
        guard connected, peerMediaSinceConnect, let limitS else { return false }
        return silentS > limitS
    }

    /// Si el vigía de la suscripción rehace la de un canal del que busca (2026-10-15): la
    /// cita da plazo, el canal sigue buscando, no hay un intento en marcha (cada intento
    /// que falla ya abre una suscripción nueva) y esta lleva el plazo sin dar con nadie.
    /// Una suscripción de Wi-Fi Aware en espera («Network is down») o que no ve nada no
    /// falla, y no tiene por qué caducar: sin esto, se quedaba así toda la pasada.
    static func subscriptionIsStuck(searching: Bool, attemptInFlight: Bool, ageS: Double?, limitS: Double?) -> Bool {
        guard searching, !attemptInFlight, let ageS, let limitS else { return false }
        return ageS >= limitS
    }

    /// Si el vigía de la publicación rehace la cita de un canal del que publica (2026-10-15):
    /// la cita da plazo, el canal no está en uso (una conexión de control en marcha o
    /// arriba; medios del otro con el control arriba), no ha llegado nadie a ella desde que
    /// se abrió o desde la última caída, y lleva así el plazo. Un listener de Wi-Fi Aware en
    /// espera no falla ni caduca, y uno publicado al que nadie llega solo se renovaba al
    /// caducar (~2 min).
    static func publicationIsStuck(inUse: Bool, arrived: Bool, ageS: Double?, limitS: Double?) -> Bool {
        guard !inUse, !arrived, let ageS, let limitS else { return false }
        return ageS >= limitS
    }

    /// La ruta de una conexión en palabras, para la línea de tiempo (Bug B): estado, por qué
    /// interfaces y las dos direcciones. «satisfied» sin dirección local es la firma de un
    /// datapath de Wi-Fi Aware sin IPv6 en `nan0` (FB22904826: wifip2pd sin descriptores; la
    /// conexión se queda en `preparing` y solo se cura reiniciando el móvil).
    static func describePath(status: String, interfaces: [String], local: String?, remote: String?) -> String {
        let por = interfaces.isEmpty ? "sin interfaz" : "por " + interfaces.joined(separator: ",")
        var texto = "\(status) \(por), local \(local ?? "ninguna"), remoto \(remote ?? "ninguno")"
        if status == "satisfied", local == nil {
            texto += " (sin dirección local: ¿datapath sin IPv6? FB22904826)"
        }
        return texto
    }

    static func describe(path: NWPath) -> String {
        let estado = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requiresConnection"
        @unknown default: "desconocido"
        }
        return describePath(status: estado, interfaces: path.availableInterfaces.map(\.name),
                            local: path.localEndpoint.map { "\($0)" }, remote: path.remoteEndpoint.map { "\($0)" })
    }

    /// Si el que busca hace borrón tras un intento de control que no subió (Bug B,
    /// 2026-10-21): la cita da tope y van ya ese número de intentos seguidos sin subir.
    static func searchNeedsReset(failedAttempts: Int, limit: Int?) -> Bool {
        guard let limit, limit > 0 else { return false }
        return failedAttempts >= limit
    }

    /// La pausa del borrón que hace `previous + 1` seguido por intentos fallidos: la de su
    /// turno en el calendario de la cita, y la última para los que pasen de ahí.
    static func resetQuietS(previous: Int, schedule: [Double]) -> Double {
        guard let ultima = schedule.last else { return 0 }
        return previous < schedule.count ? schedule[max(previous, 0)] : ultima
    }

    public var onFrame: ((LinkFrame, LinkChannel) -> Void)?
    public var onState: ((LinkTransportState) -> Void)?
    public var onPath: ((String) -> Void)?

    public private(set) var state: LinkTransportState = .idle {
        didSet { if oldValue != state { onState?(state) } }
    }
    public private(set) var stats = LinkTransportStats()

    /// Los contadores leídos en la cola del transporte, para un informe desde otro hilo.
    /// Nunca desde la propia cola: se bloquearía.
    public var statsSnapshot: LinkTransportStats {
        queue.sync { stats }
    }

    /// El puerto real al escuchar (para los tests, con puerto efímero).
    public private(set) var localPort: UInt16 = 0
    public var onReady: ((UInt16) -> Void)?

    private let mode: Mode
    /// Cómo se encuentran los dos móviles: Bonjour por una interfaz o Wi-Fi Aware.
    public let rendezvous: LinkRendezvous
    private let queue = DispatchQueue(label: "io.footballai.zero.link.control")
    private let log = Logger(subsystem: "io.footballai.zero", category: "link")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pathMonitor: NWPathMonitor?
    /// Las tramas del stream de control: guarda como mucho una a medias (2026-10-10).
    private var controlReader = LinkStreamReader()
    private var reconnectAttempt = 0
    private var stopped = false

    // IOS-16: el canal de medios (UDP, sin reintentos).
    private var mediaListener: NWListener?
    private var mediaBrowser: NWBrowser?
    private var mediaConnection: NWConnection?
    // El lado que busca: los anuncios de medios vistos, el que se prueba y desde cuándo.
    private var controlCandidates: [NWEndpoint] = []
    private var controlCandidateIndex = 0
    private var mediaCandidates: [NWEndpoint] = []
    private var mediaCandidateIndex = 0
    private var mediaOpenedAt: Date?
    private var mediaWatchdog: DispatchSourceTimer?
    public private(set) var mediaRotations = 0
    private var reassembler = Reassembler()
    private var mediaSeq: UInt32 = 0
    private var lastMediaSeq: UInt32?
    private var lastMediaArrival: Date?
    public private(set) var mediaLocalPort: UInt16 = 0

    // IOS-52: el espaciado de los fragmentos de las tramas grandes (las partes).
    private var paced: [Data] = []
    private var pacing = false

    /// El ritmo del espaciado; los bancos lo cambian para medir (SPK-02).
    public var pacingBurstDatagrams = LinkConstants.pacingBurstDatagrams
    public var pacingIntervalUs = LinkConstants.pacingIntervalMs * 1000

    /// La IP del otro móvil por la conexión de control, o nil sin conexión. La lleva el
    /// QR Mando como alternativa, para que el mando siga tras un relevo (IOS-63).
    public var peerHost: String? {
        queue.sync {
            guard case let .hostPort(host, _)? = connection?.currentPath?.remoteEndpoint else {
                return nil
            }
            switch host {
            case let .ipv4(ip):
                return "\(ip)"
            case let .ipv6(ip):
                return "[\("\(ip)".split(separator: "%").first ?? "")]"
            case let .name(nombre, _):
                return nombre
            @unknown default:
                return nil
            }
        }
    }

    /// `interfaceType` por defecto: Ethernet por el hub (ADR 0023). `.wifi` para el
    /// banco sin cables y `nil` para el loopback de los tests.
    public convenience init(mode: Mode, interfaceType: NWInterface.InterfaceType? = .wiredEthernet) {
        self.init(mode: mode, rendezvous: BonjourRendezvous(interfaceType: interfaceType))
    }

    public init(mode: Mode, rendezvous: LinkRendezvous) {
        self.mode = mode
        self.rendezvous = rendezvous
    }

    /// La ruta de la conexión de control, o nil sin conexión: el banco lee de ella el
    /// informe de Wi-Fi Aware (señal, capacidad y latencia de emisión).
    public var controlPath: NWPath? {
        queue.sync { connection?.currentPath }
    }

    /// Por qué espera el listener o el browser de control, si espera: Wi-Fi Aware sin
    /// nadie emparejado o sin entitlement no falla, se queda esperando. Para el banco.
    public var waitingReason: String? {
        queue.sync { esperaPor }
    }
    private var esperaPor: String?

    /// Por qué se acabó la última cita que no era un fallo (Wi-Fi Aware:
    /// `publisherTimeout`), o nil. Para el banco.
    public var lastRendezvousEnd: String? {
        queue.sync { finDeCita }
    }
    private var finDeCita: String?

    /// Los canales cuya cita se acabó y espera a que la cambien por otra (IOS-14): la del
    /// que busca, hasta que caiga la conexión; la del que anuncia, `rendezvousRenewS`.
    private var endedRendezvous: Set<LinkChannel> = []
    /// Listeners acabados que se guardan mientras siga la conexión que salió de ellos.
    private var retiredListeners: [NWListener] = []
    /// Bug B (2026-10-21): listeners cancelados que aún no han dicho `.cancelled`, por canal,
    /// y el turno de la cita nueva de cada canal que espera a que acaben.
    private var cancellingListeners: [LinkChannel: [NWListener]] = [:]
    private var pendingPublication: [LinkChannel: Int] = [:]
    private var publicationTurn = 0

    // IOS-14c: el vigía de silencio. Cuándo llegó lo último del otro por medios (ns de
    // uptime, monótono) y si llegó algo desde que subió el control.
    private var lastPeerMediaNs: UInt64 = 0
    private var peerMediaSinceConnect = false
    private var linkWatchdog: DispatchSourceTimer?

    // 2026-10-15: el vigía de la suscripción del que busca. Cuándo se abrió el browser de
    // cada canal (ns de uptime).
    private var browserOpenedNs: UInt64?
    private var mediaBrowserOpenedNs: UInt64?
    private var subscriptionWatchdog: DispatchSourceTimer?

    // 2026-10-15: el vigía de la publicación del que publica. Desde cuándo cuenta la cita de
    // cada canal (se abrió o cayó la conexión que salió de ella; ns de uptime) y si ha
    // llegado alguien desde entonces.
    private var listenerQuietSinceNs: UInt64?
    private var controlArrived = false
    // Bug B (2026-10-21): el borrón del que busca. Intentos de control seguidos sin subir,
    // borrones seguidos por ellos desde que el control subió por última vez, y la pausa en
    // curso (hasta cuándo, en ns de uptime; y su turno, para que un fin de pausa viejo no
    // abra nada).
    private var failedAttempts = 0
    private var failedResets = 0
    /// El último intento de control (a quién, o de quién si llega) y su ruta al caer.
    private var ultimoIntento: String?
    private var quietUntilNs: UInt64?
    private var quietTurn = 0
    private var quiet: Bool { quietUntilNs != nil }
    private var mediaListenerQuietSinceNs: UInt64?
    private var mediaArrived = false
    private var publicationWatchdog: DispatchSourceTimer?

    // 2026-10-15: lo que dice `diagnosis`. Citas de control abiertas, si la actual está
    // lista, intentos de control (los que salen o los que llegan), la última caída y desde
    // cuándo no hay control arriba (ns de uptime; nil, arriba).
    private var citasAbiertas = 0
    private var citaLista = false
    private var intentosControl = 0
    private var ultimaCaida: String?
    private var sinEnlaceDesdeNs: UInt64? = DispatchTime.now().uptimeNanoseconds

    /// Por qué no hay enlace, o que lo hay: para el latido y el informe del programa.
    /// Nunca desde la propia cola: se bloquearía.
    public var diagnosis: LinkDiagnosis {
        queue.sync {
            let ahora = DispatchTime.now().uptimeNanoseconds
            let rol: LinkDiagnosis.Role = switch mode {
            case .advertise, .listen: .publishes
            case .browse, .connect: .searches
            }
            return LinkDiagnosis(
                role: rol, medium: rendezvous.label, state: state, waiting: esperaPor,
                lastRendezvousEnd: finDeCita, lastDrop: ultimaCaida, rendezvousReady: citaLista,
                announcements: controlCandidates.count, mediaAnnouncements: mediaCandidates.count,
                rendezvousOpened: citasAbiertas, resubscribes: stats.resubscribes, republishes: stats.republishes,
                controlAttempts: intentosControl,
                withoutLinkS: state == .connected ? nil : sinEnlaceDesdeNs.map { Double(ahora &- $0) / 1e9 },
                failedAttempts: failedAttempts, searchResets: stats.searchResets,
                quietS: quietUntilNs.map { Double($0 > ahora ? $0 - ahora : 0) / 1e9 },
                lastAttempt: ultimoIntento,
                liveConnections: (connection == nil ? 0 : 1) + (mediaConnection == nil ? 0 : 1),
                retiredListeners: retiredListeners.count,
                cancellingListeners: cancellingListeners.values.reduce(0) { $0 + $1.count },
                subscriptions: (browser == nil ? 0 : 1) + (mediaBrowser == nil ? 0 : 1)
            )
        }
    }

    /// Lo que le ha pasado al enlace, «segundos desde que se creó el transporte: qué»: el
    /// arranque y los últimos `maxEvents`. Para el banco: dice si cada caída coincide con
    /// una cita que caduca y con qué error cae cada conexión (IOS-14c), y cuándo sube
    /// cada canal al arrancar (2026-10-11).
    public var events: [String] {
        queue.sync { eventos.lines }
    }
    private var eventos = LinkEventLog(headCount: maxStartEvents, tailCount: maxEvents)
    /// Cuándo se creó el transporte, en ns de uptime: el cero de `events`.
    public let createdNs = DispatchTime.now().uptimeNanoseconds

    /// Apunta un suceso en la línea de tiempo, con la huella del proceso en ese momento
    /// (2026-10-14: una caída y su vuelta dicen si dejaron memoria retenida). En la cola
    /// del transporte.
    private func note(_ texto: String) {
        let s = Double(DispatchTime.now().uptimeNanoseconds &- createdNs) / 1e9
        let huella = ProcessFootprint.megabytes().map { String(format: " [%.0f MB]", $0) } ?? ""
        eventos.append(String(format: "%.1f", s) + huella + " " + texto)
    }

    /// Los anuncios que ve un browser: cuántos hay y cuántos acaban de aparecer o irse
    /// (al arrancar, la caché de Bonjour puede traer el de un proceso anterior).
    private func noteResults(_ canal: String, total: Int, cambios: Set<NWBrowser.Result.Change>) {
        var altas = 0, bajas = 0
        for cambio in cambios {
            switch cambio {
            case .added: altas += 1
            case .removed: bajas += 1
            default: break
            }
        }
        guard altas + bajas > 0 else { return }
        note("\(canal): \(total) anuncios (+\(altas) −\(bajas))")
    }

    private var publishes: Bool {
        if case .advertise = mode { return true }
        return false
    }

    // MARK: - Ciclo de vida

    public func start() {
        queue.async { [self] in
            stopped = false
            startPathMonitor()
            open()
            openMedia()
            startMediaWatchdog()
            startLinkWatchdog()
            startSubscriptionWatchdog()
            startPublicationWatchdog()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
            mediaConnection?.cancel()
            mediaConnection = nil
            mediaListener?.cancel()
            mediaListener = nil
            mediaBrowser?.cancel()
            mediaBrowser = nil
            mediaWatchdog?.cancel()
            mediaWatchdog = nil
            linkWatchdog?.cancel()
            linkWatchdog = nil
            subscriptionWatchdog?.cancel()
            subscriptionWatchdog = nil
            publicationWatchdog?.cancel()
            publicationWatchdog = nil
            mediaCandidates = []
            endedRendezvous = []
            cancelRetiredListeners()
            cancellingListeners = [:]
            pendingPublication = [:]
            quietUntilNs = nil
            quietTurn += 1
            pathMonitor?.cancel()
            pathMonitor = nil
            state = .idle
        }
    }

    public func send(_ frame: LinkFrame, on channel: LinkChannel) {
        queue.async { [self] in
            switch channel {
            case .control:
                guard let connection, state == .connected else { return }
                connection.send(content: frame.encode(), completion: .contentProcessed { [weak self] error in
                    if error == nil {
                        self?.stats.framesSent += 1
                    }
                })
            case .media:
                guard let mediaConnection else { return }
                mediaSeq &+= 1
                let datagramas = Fragmenter.fragment(
                    frame: frame.encode(), session: frame.session, seq: mediaSeq
                )
                if datagramas.count == 1 {
                    // Latidos, reloj y vistas: un datagrama, sin esperar detrás de un IDR.
                    mediaConnection.send(content: datagramas[0], completion: .contentProcessed { _ in })
                } else {
                    guard paced.count + datagramas.count <= LinkConstants.pacingMaxQueuedDatagrams else {
                        stats.mediaPacerDrops += 1
                        return
                    }
                    paced.append(contentsOf: datagramas)
                    if !pacing { drainPaced() }
                }
                stats.framesSent += 1
            }
        }
    }

    /// Suelta un golpe de datagramas y, si quedan, vuelve en `pacingIntervalMs`. En la
    /// cola del transporte.
    private func drainPaced() {
        guard let mediaConnection, !stopped else {
            paced.removeAll()
            pacing = false
            return
        }
        let n = min(pacingBurstDatagrams, paced.count)
        for datagrama in paced.prefix(n) {
            mediaConnection.send(content: datagrama, completion: .contentProcessed { _ in })
        }
        paced.removeFirst(n)
        pacing = !paced.isEmpty
        if pacing {
            queue.asyncAfter(deadline: .now() + .microseconds(pacingIntervalUs)) { [weak self] in
                self?.drainPaced()
            }
        }
    }

    // MARK: - Abrir según el modo

    private func open() {
        guard !stopped else { return }
        switch mode {
        case let .advertise(name, txt):
            openListener { try self.rendezvous.makeListener(for: .control, name: name, txt: txt) }
        case let .listen(port):
            openListener { try Self.plainListener(self.parameters(), port: port) }
        case .browse:
            openBrowser()
        case let .connect(host, port):
            openConnection(to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            ))
        }
    }

    private func parameters() -> NWParameters {
        rendezvous.parameters(for: .control)
    }

    /// Un listener sin anuncio en un puerto (0 = efímero): el de los tests.
    private static func plainListener(_ params: NWParameters, port: UInt16) throws -> NWListener {
        if port > 0, let nwPort = NWEndpoint.Port(rawValue: port) {
            return try NWListener(using: params, on: nwPort)
        }
        return try NWListener(using: params)
    }

    /// Un error en palabras del medio: con Wi-Fi Aware, si falta el entitlement o el
    /// emparejado.
    private func describe(_ error: Error) -> String {
        (error as? NWError).map(rendezvous.explain) ?? "\(error)"
    }

    private func openListener(_ make: () throws -> NWListener) {
        do {
            let listener = try make()
            listener.newConnectionHandler = { [weak self] nueva in
                guard let self else { return }
                // Un soporte son dos móviles: la conexión nueva sustituye a la vieja,
                // que Network puede tardar en dar por muerta (el patrón de RigLink).
                self.intentosControl += 1
                self.controlArrived = true
                self.ultimoIntento = "de " + self.rendezvous.describe(nueva.endpoint)
                self.note((self.connection == nil ? "control: llega una conexión"
                    : "control: llega otra y sustituye a la de antes") + " (\(self.ultimoIntento ?? ""))")
                self.connection?.cancel()
                // Si la vieja seguía arriba, la sesión tiene que verlo para darse la mano
                // otra vez por la nueva; si no, se queda con la clave de la vieja.
                let estabaArriba = self.state == .connected
                if estabaArriba { self.state = .listening }
                self.adopt(connection: nueva)
                // Con vigía de silencio, el otro viene de cero (soltó su enlace entero) y se
                // va a suscribir otra vez a los medios: la cita de medios caducada se
                // cambia ya por otra, o no encontraría a nadie. La conexión de medios
                // vieja la sustituye la nueva al llegar.
                if estabaArriba, self.rendezvous.silenceTimeoutS != nil {
                    self.cancelRetiredListeners()
                    self.renewEndedRendezvous()
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] estado in
                guard let self, let listener else { return }
                // Uno sustituido solo cuenta para decir que ya acabó (Bug B): la cita nueva
                // del canal puede estar esperándolo.
                if case .cancelled = estado {
                    self.listenerCancelled(listener, .control)
                    return
                }
                guard listener === self.listener else { return }
                switch estado {
                case .ready:
                    self.esperaPor = nil
                    self.citaLista = true
                    self.localPort = listener.port?.rawValue ?? 0
                    self.note("cita de control publicada")
                    // Una cita renovada con la conexión arriba no la tumba.
                    if self.state != .connected { self.state = .listening }
                    self.onReady?(self.localPort)
                case let .failed(error):
                    self.citaLista = false
                    self.rendezvousEnded(.control, error)
                case let .waiting(error):
                    // Wi-Fi Aware sin nadie emparejado no falla: espera. Que se lea.
                    self.citaLista = false
                    if self.esperaPor != self.describe(error) { self.note("listener en espera: \(self.describe(error))") }
                    self.esperaPor = self.describe(error)
                    self.log.info("listener en espera: \(self.describe(error))")
                default:
                    break
                }
            }
            self.listener = listener
            listenerQuietSinceNs = DispatchTime.now().uptimeNanoseconds
            controlArrived = false
            citasAbiertas += 1
            citaLista = false
            listener.start(queue: queue)
        } catch {
            state = .failed(describe(error))
            scheduleReopen()
        }
    }

    private func openBrowser() {
        let browser: NWBrowser
        do {
            browser = try rendezvous.makeBrowser(for: .control)
        } catch {
            state = .failed(describe(error))
            scheduleReopen()
            return
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, cambios in
            // Lo que vea una suscripción ya soltada no cuenta (Bug B).
            guard let self, let browser, browser === self.browser else { return }
            // En un orden fijo (los resultados son un conjunto): rotar tiene que avanzar.
            self.controlCandidates = results.map(\.endpoint).sorted { "\($0)" < "\($1)" }
            self.noteResults("control", total: results.count, cambios: cambios)
            guard self.state != .connected else { return }
            // Un anuncio que acaba de aparecer manda sobre la conexión a medias: al
            // arrancar, la caché de Bonjour trae el anuncio del izquierdo de antes, ya
            // muerto, y esperar a que esa conexión falle (con su espera creciente)
            // costaba hasta 2 s de más cuando el izquierdo de verdad aparecía.
            let nuevo = cambios.compactMap { cambio -> NWEndpoint? in
                if case let .added(resultado) = cambio { return resultado.endpoint }
                return nil
            }.last
            if let nuevo {
                if let previo = self.connection {
                    self.note("control: se deja el intento en marcha por un anuncio nuevo")
                    previo.cancel()
                }
                self.openConnection(to: nuevo)
            } else if self.connection == nil, !self.controlCandidates.isEmpty {
                // Tras una caída, el siguiente anuncio: el que falló puede ser el muerto.
                let i = self.controlCandidateIndex % self.controlCandidates.count
                self.openConnection(to: self.controlCandidates[i])
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] estado in
            guard let self, let browser, browser === self.browser else { return }
            switch estado {
            case let .failed(error):
                self.citaLista = false
                self.rendezvousEnded(.control, error)
            case let .waiting(error):
                // Wi-Fi Aware sin emparejado o sin entitlement no falla: espera. Se dice.
                self.citaLista = false
                if self.esperaPor != self.describe(error) { self.note("browser en espera: \(self.describe(error))") }
                self.esperaPor = self.describe(error)
                self.log.info("browser en espera: \(self.describe(error))")
            case .ready:
                // Lista y sin anuncios no es lo mismo que en espera: que se lea cuál.
                self.note("suscripción de control lista")
                self.esperaPor = nil
                self.citaLista = true
            default:
                break
            }
        }
        self.browser = browser
        browserOpenedNs = DispatchTime.now().uptimeNanoseconds
        citasAbiertas += 1
        citaLista = false
        // Los anuncios son los de la suscripción nueva (el diagnóstico los cuenta).
        controlCandidates = []
        state = .connecting
        browser.start(queue: queue)
    }

    private func openConnection(to endpoint: NWEndpoint) {
        state = .connecting
        intentosControl += 1
        ultimoIntento = "a " + rendezvous.describe(endpoint)
        note("control: se conecta \(ultimoIntento ?? "")")
        let conexion = NWConnection(to: endpoint, using: parameters())
        adopt(connection: conexion)
        // Por Wi-Fi Aware la conexión monta antes un datapath: se le da más plazo.
        let plazo = rendezvous.connectTimeoutS
        queue.asyncAfter(deadline: .now() + plazo) { [weak self, weak conexion] in
            guard let self, let conexion, conexion === self.connection, self.state != .connected else { return }
            self.log.info("control sin respuesta en \(plazo) s: otro anuncio")
            self.dropConnection("sin respuesta en \(Int(plazo)) s")
        }
    }

    private func adopt(connection nueva: NWConnection) {
        connection = nueva
        controlReader.reset()
        nueva.stateUpdateHandler = { [weak self, weak nueva] estado in
            // Lo que diga una conexión ya sustituida no cuenta: si no, cancelarla al
            // cambiar a otra dispararía una reconexión de la que nadie quiere saber.
            guard let self, let nueva, nueva === self.connection else { return }
            switch estado {
            case .ready:
                self.reconnectAttempt = 0
                self.failedAttempts = 0
                self.failedResets = 0
                // El vigía de silencio se arma con los primeros medios de esta conexión.
                self.peerMediaSinceConnect = false
                self.sinEnlaceDesdeNs = nil
                self.note("control arriba")
                // Por qué ruta sube (Bug B): la interfaz y las dos direcciones del datapath.
                if let ruta = nueva.currentPath { self.note("control: ruta " + Self.describe(path: ruta)) }
                if self.publishes, !self.mediaArrived {
                    // El que busca conecta los medios con el control arriba (Bug B): el vigía
                    // de la cita de medios le da su plazo entero desde aquí.
                    self.mediaListenerQuietSinceNs = DispatchTime.now().uptimeNanoseconds
                }
                if self.stats.firstControlUpNs == nil {
                    self.stats.firstControlUpNs = DispatchTime.now().uptimeNanoseconds
                }
                self.state = .connected
                self.receive(on: nueva)
                if case .browse = self.mode, self.rendezvous.mediaAfterControl, self.mediaConnection == nil,
                   let primero = self.mediaCandidates.first {
                    self.mediaCandidateIndex = 0
                    self.openMediaConnection(to: primero, why: "el control subió")
                }
            case let .failed(error):
                self.log.info("control caído: \(String(describing: error))")
                self.dropConnection("falló: \(self.describe(error))")
            case let .waiting(error):
                // Rechazada o sin ruta: Network reintentaría el mismo anuncio para
                // siempre. Se suelta y se prueba otro.
                self.log.info("control en espera: \(String(describing: error))")
                self.dropConnection("en espera: \(self.describe(error))")
            case .cancelled:
                self.dropConnection("cancelada")
            default:
                break
            }
        }
        nueva.start(queue: queue)
    }

    private func dropConnection(_ motivo: String) {
        guard !stopped else { return }
        let estabaArriba = state == .connected
        // Con la ruta de la conexión que se tira: dice si llegó a tener datapath y dirección.
        let ruta = connection?.currentPath.map(Self.describe(path:))
        note("control caído (\(motivo))" + (ruta.map { " · ruta \($0)" } ?? ""))
        if let ruta, !estabaArriba { ultimoIntento = (ultimoIntento ?? "?") + " · ruta \(ruta)" }
        ultimaCaida = motivo
        if estabaArriba || sinEnlaceDesdeNs == nil { sinEnlaceDesdeNs = DispatchTime.now().uptimeNanoseconds }
        connection?.cancel()
        connection = nil
        stats.reconnects += 1
        // El que escucha sigue escuchando; el que conecta lo reintenta con espera.
        switch mode {
        case .advertise, .listen:
            state = .listening
            // El vigía de la publicación cuenta desde aquí: el otro tiene que volver a
            // llegar, a esta cita o a la que la sustituya. Los medios, si estaban arriba: los
            // que había son de un enlace que ya no está.
            listenerQuietSinceNs = DispatchTime.now().uptimeNanoseconds
            controlArrived = false
            if estabaArriba {
                mediaListenerQuietSinceNs = listenerQuietSinceNs
                mediaArrived = false
            }
        case .browse, .connect:
            state = .connecting
            controlCandidateIndex += 1
            // El browser del control lo abre nuevo scheduleReopen.
            endedRendezvous.remove(.control)
            // Bug B (2026-10-21): por Wi-Fi Aware, perder un control que estaba arriba o
            // encadenar intentos que no suben suelta TODO lo del par anterior y deja un rato
            // sin nada abierto antes de volver a suscribirse (resetSearch).
            if estabaArriba, let pausa = rendezvous.settleAfterDropS {
                failedAttempts = 0
                resetSearch("el control cayó: \(motivo)", quietS: pausa)
                return
            }
            if !estabaArriba { failedAttempts += 1 }
            if Self.searchNeedsReset(failedAttempts: failedAttempts, limit: rendezvous.failedAttemptsBeforeReset) {
                let pausa = Self.resetQuietS(previous: failedResets, schedule: rendezvous.resetQuietS)
                let n = failedAttempts
                failedResets += 1
                failedAttempts = 0
                resetSearch("\(n) intentos seguidos sin subir; el último: \(motivo)", quietS: pausa)
                return
            }
            scheduleReopen()
        }
        // Con vigía de silencio (Wi-Fi Aware) el enlace es uno: si cae el control que
        // estaba arriba, el que busca suelta también los medios y se vuelve a suscribir,
        // en vez de seguir hablando a un anuncio de un datapath muerto. Un intento que no
        // llegó a subir no los toca.
        if estabaArriba, rendezvous.silenceTimeoutS != nil {
            dropMedia()
        }
        // Las citas que se acabaron con la conexión viva se cambian ya por otras: sin
        // ellas, por Wi-Fi Aware, los dos no podrían volver a encontrarse.
        cancelRetiredListeners()
        if estabaArriba, rendezvous.silenceTimeoutS != nil, case .advertise = mode {
            // Bug B (2026-10-21): el otro montó su datapath con estas citas y se fue (murió,
            // se cerró su app o calló la radio). Lo que lo espere tiene que ser nuevo: las
            // dos citas se cambian, sin que convivan con las viejas.
            note("el enlace cayó: citas nuevas, nada del par anterior")
            for canal in [LinkChannel.control, .media] {
                let acabada = endedRendezvous.contains(canal)
                endedRendezvous.remove(canal)
                publishAnew(canal, oldEnded: acabada)
            }
        }
        renewEndedRendezvous()
    }

    /// El lado que busca suelta su conexión de medios y se suscribe de nuevo; el que
    /// conecta (los tests) la vuelve a abrir. El que anuncia también suelta la suya (Bug B,
    /// 2026-10-21): antes la guardaba hasta que llegara otra, y con el otro muerto quedaba
    /// una conexión al par anterior reteniendo su datapath. La nueva no puede adelantarse:
    /// el que busca conecta los medios cuando sube el control nuevo, después de esta caída.
    /// El que escucha en los tests (`.listen`) sigue sin tocarla.
    private func dropMedia() {
        switch mode {
        case .browse:
            mediaConnection?.cancel()
            mediaConnection = nil
            mediaOpenedAt = nil
            mediaBrowser?.cancel()
            mediaBrowser = nil
            mediaCandidates = []
            endedRendezvous.remove(.media)
            openMediaBrowser()
        case .connect:
            mediaConnection?.cancel()
            mediaConnection = nil
            mediaOpenedAt = nil
            openMedia()
        case .advertise:
            discardMedia("el enlace cayó")
        case .listen:
            break
        }
    }

    /// Suelta la conexión de medios y dice por qué (Bug B: cada conexión que se tira, con
    /// su motivo, en la línea de tiempo).
    private func discardMedia(_ motivo: String) {
        guard let vieja = mediaConnection else { return }
        note("medios: se descarta la conexión (\(motivo))")
        vieja.cancel()
        mediaConnection = nil
    }

    // MARK: - El borrón del que busca (Bug B, 2026-10-21)

    /// El que busca suelta todo lo del par anterior —el intento o la conexión de control, la
    /// de medios, las dos suscripciones y sus anuncios— y no abre nada en `quietS`; después
    /// se suscribe de cero. Con el maestro cerrado y vuelto a abrir, el esclavo seguía viendo
    /// su anuncio y cada intento se quedaba «sin respuesta en 10 s», diez seguidos, con una
    /// conexión de medios lista 85 s sobre un datapath que el maestro nuevo no veía (16 Pro,
    /// 21-oct 09:45). Solo lo curaba matar la app y esperar: esto hace lo mismo con el
    /// transporte, sin tocar la cámara ni la emisión.
    private func resetSearch(_ motivo: String, quietS: Double) {
        stats.searchResets += 1
        note(String(format: "borrón (%@): se suelta todo y %.0f s sin buscar", motivo, quietS))
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        browserOpenedNs = nil
        discardMedia("borrón")
        mediaOpenedAt = nil
        mediaBrowser?.cancel()
        mediaBrowser = nil
        mediaBrowserOpenedNs = nil
        controlCandidates = []
        mediaCandidates = []
        endedRendezvous = []
        citaLista = false
        state = .connecting
        quietTurn += 1
        let turno = quietTurn
        quietUntilNs = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(quietS, 0) * 1e9)
        queue.asyncAfter(deadline: .now() + max(quietS, 0)) { [weak self] in self?.endQuiet(turno) }
    }

    private func endQuiet(_ turno: Int) {
        guard !stopped, turno == quietTurn, quiet else { return }
        quietUntilNs = nil
        note("fin de la pausa: se busca de cero")
        switch mode {
        case .browse:
            openBrowser()
            openMediaBrowser()
        case .connect:
            open()
            openMedia()
        case .advertise, .listen:
            break
        }
    }

    // MARK: - El vigía de silencio (IOS-14c)

    /// Por Wi-Fi Aware, si el datapath muere nada avisa: el TCP tarda decenas de segundos
    /// en rendirse y, mientras, el otro no puede volver a montar el suyo (bancos del
    /// 2026-10-08: 20-90 s fuera). Los latidos van por medios a 10 Hz en los dos
    /// sentidos; si callan `silenceTimeoutS`, se tira el enlace y se vuelve a buscar.
    private func startLinkWatchdog() {
        guard let limite = rendezvous.silenceTimeoutS, linkWatchdog == nil else { return }
        let paso = limite / Self.silenceChecksPerTimeout
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + paso, repeating: paso)
        t.setEventHandler { [weak self] in self?.checkLink() }
        linkWatchdog = t
        t.resume()
    }

    private func checkLink() {
        guard !stopped else { return }
        let mudoS = Double(DispatchTime.now().uptimeNanoseconds &- lastPeerMediaNs) / 1e9
        guard Self.linkIsDead(
            connected: state == .connected, peerMediaSinceConnect: peerMediaSinceConnect,
            silentS: mudoS, limitS: rendezvous.silenceTimeoutS
        ) else { return }
        stats.silenceDrops += 1
        log.info("enlace mudo \(mudoS) s: se tira y se vuelve a buscar")
        dropConnection(String(format: "silencio de %.1f s", mudoS))
    }

    // MARK: - El vigía de la suscripción (2026-10-15)

    /// El que busca cambia por otra la suscripción que en `resubscribeAfterS` no ha dado
    /// con nadie. Hasta ahora solo se rehacía al fallar un intento de conexión o al caducar;
    /// por Wi-Fi Aware una en espera o sin anuncios no hace ninguna de las dos cosas, y en
    /// el plan B del 2026-10-15 el esclavo pasó así los 10 min.
    private func startSubscriptionWatchdog() {
        guard case .browse = mode, let limite = rendezvous.resubscribeAfterS, subscriptionWatchdog == nil else {
            return
        }
        let paso = limite / Self.subscriptionChecksPerTimeout
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + paso, repeating: paso)
        t.setEventHandler { [weak self] in self?.checkSubscriptions() }
        subscriptionWatchdog = t
        t.resume()
    }

    private func checkSubscriptions() {
        guard !stopped, !quiet, let limite = rendezvous.resubscribeAfterS else { return }
        let ahora = DispatchTime.now().uptimeNanoseconds
        let edad = { (ns: UInt64?) in ns.map { Double(ahora &- $0) / 1e9 } }
        // El control: sin enlace y sin un intento en marcha.
        if let s = edad(browserOpenedNs), Self.subscriptionIsStuck(
            searching: state != .connected, attemptInFlight: connection != nil, ageS: s, limitS: limite
        ) {
            resubscribe(.control, afterS: s)
        }
        // Los medios: sin nada del otro y sin ningún anuncio que probar (con anuncios, ya los
        // rota el vigía de medios).
        if let s = edad(mediaBrowserOpenedNs), Self.subscriptionIsStuck(
            searching: !(state == .connected && peerMediaSinceConnect), attemptInFlight: !mediaCandidates.isEmpty,
            ageS: s, limitS: limite
        ) {
            resubscribe(.media, afterS: s)
        }
    }

    private func resubscribe(_ canal: LinkChannel, afterS edad: Double) {
        stats.resubscribes += 1
        endedRendezvous.remove(canal)
        switch canal {
        case .control:
            note(String(format: "control: la suscripción no ha dado con nadie en %.0f s: otra", edad))
            browser?.cancel()
            browser = nil
            openBrowser()
        case .media:
            note(String(format: "medios: la suscripción no ha dado con nadie en %.0f s: otra", edad))
            mediaBrowser?.cancel()
            mediaBrowser = nil
            mediaCandidates = []
            openMediaBrowser()
        }
    }

    // MARK: - El vigía de la publicación (2026-10-15)

    /// El que publica cambia por otra la cita a la que en `republishAfterS` no ha llegado
    /// nadie, sin enlace. Lo mismo que el vigía de la suscripción en el otro lado: un listener
    /// de Wi-Fi Aware en espera no falla ni caduca, y uno publicado solo se renovaba al
    /// caducar (~2 min). En el EMITIR del 2026-10-15 (11:36), los dos 5 min buscando.
    private func startPublicationWatchdog() {
        guard case .advertise = mode, let limite = rendezvous.republishAfterS, publicationWatchdog == nil else {
            return
        }
        let paso = limite / Self.subscriptionChecksPerTimeout
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + paso, repeating: paso)
        t.setEventHandler { [weak self] in self?.checkPublications() }
        publicationWatchdog = t
        t.resume()
    }

    private func checkPublications() {
        guard !stopped, let limite = rendezvous.republishAfterS else { return }
        let ahora = DispatchTime.now().uptimeNanoseconds
        let edad = { (ns: UInt64?) in ns.map { Double(ahora &- $0) / 1e9 } }
        if let s = edad(listenerQuietSinceNs), Self.publicationIsStuck(
            inUse: connection != nil, arrived: controlArrived, ageS: s, limitS: limite
        ) {
            republish(.control, afterS: s)
        }
        // Los medios, en uso también con una conexión de control a medio montar (Bug B): el
        // que busca conecta los medios cuando el control sube, y cambiarle la cita entonces
        // es tirarle el intento.
        let controlAMedias = connection != nil && state != .connected
        if let s = edad(mediaListenerQuietSinceNs), Self.publicationIsStuck(
            inUse: controlAMedias || (state == .connected && peerMediaSinceConnect), arrived: mediaArrived,
            ageS: s, limitS: limite
        ) {
            republish(.media, afterS: s)
        }
    }

    private func republish(_ canal: LinkChannel, afterS edad: Double) {
        stats.republishes += 1
        let acabada = endedRendezvous.contains(canal)
        endedRendezvous.remove(canal)
        let espera = (canal == .control ? esperaPor : nil).map { " (en espera: \($0))" } ?? ""
        note(String(format: "%@: no ha llegado nadie a la cita en %.0f s%@: otra",
                    canal == .control ? "control" : "medios", edad, espera))
        publishAnew(canal, oldEnded: acabada)
    }

    // MARK: - Una cita nueva sin que convivan dos (Bug B, 2026-10-21)

    /// Cambia la cita de un canal del que anuncia por otra sin que convivan dos
    /// publicaciones del mismo servicio. Antes, con el control arriba, la vieja se guardaba
    /// sin cancelar (`retire`) aunque siguiera publicada, y por Wi-Fi Aware la nueva caía con
    /// `serviceAlreadyPublishing` cada 5 s (16 Pro, 20-oct, 20:59). Ahora la vieja que sigue
    /// viva (publicada o en espera) se cancela y la nueva sale cuando la vieja dice
    /// `.cancelled`. La que ya acabó (caducó o falló) no publica nada: se retira como antes
    /// (con la conexión arriba se guarda, de ella pudo salir) y la nueva sale ya.
    private func publishAnew(_ canal: LinkChannel, oldEnded: Bool) {
        let viejo = canal == .control ? listener : mediaListener
        if canal == .control {
            listener = nil
            citaLista = false
        } else {
            mediaListener = nil
        }
        if let viejo, !oldEnded {
            cancellingListeners[canal, default: []].append(viejo)
            viejo.cancel()
        } else {
            retire(viejo)
        }
        publicationTurn += 1
        let turno = publicationTurn
        pendingPublication[canal] = turno
        guard cancellingListeners[canal]?.isEmpty == false else {
            publishPending(canal, turn: turno, forced: false)
            return
        }
        note("\(Self.channelName(canal)): la cita vieja se cancela y la nueva espera a que acabe")
        queue.asyncAfter(deadline: .now() + Self.listenerCancelWaitS) { [weak self] in
            self?.publishPending(canal, turn: turno, forced: true)
        }
    }

    /// Publica la cita nueva del canal si sigue pendiente con ese turno. `forced`: la vieja
    /// no dijo `.cancelled` a tiempo.
    private func publishPending(_ canal: LinkChannel, turn turno: Int, forced: Bool) {
        guard !stopped, pendingPublication[canal] == turno else { return }
        pendingPublication[canal] = nil
        if forced, cancellingListeners[canal]?.isEmpty == false {
            note(String(format: "%@: la cita vieja no acabó en %.0f s; se publica la nueva igual",
                        Self.channelName(canal), Self.listenerCancelWaitS))
            cancellingListeners[canal] = nil
        }
        switch canal {
        case .control: open()
        case .media: openMedia()
        }
    }

    /// Un listener cancelado ya acabó: si era el último del canal, sale la cita nueva.
    private func listenerCancelled(_ viejo: NWListener, _ canal: LinkChannel) {
        guard var quedan = cancellingListeners[canal], let i = quedan.firstIndex(where: { $0 === viejo }) else {
            return
        }
        quedan.remove(at: i)
        cancellingListeners[canal] = quedan.isEmpty ? nil : quedan
        guard quedan.isEmpty, let turno = pendingPublication[canal] else { return }
        publishPending(canal, turn: turno, forced: false)
    }

    static func channelName(_ canal: LinkChannel) -> String {
        canal == .control ? "control" : "medios"
    }

    // MARK: - El fin de una cita (IOS-14)

    /// Un listener o un browser se acabó. Con la conexión arriba no es un fallo del
    /// transporte: por Wi-Fi Aware, la cita caduca a los ~2 min y la conexión sigue.
    private func rendezvousEnded(_ channel: LinkChannel, _ error: NWError) {
        let motivo = describe(error)
        let accion = Self.rendezvousEndAction(
            publishing: publishes, connected: state == .connected, expired: rendezvous.isExpiry(error)
        )
        if accion != .fail {
            stats.rendezvousEnds += 1
            finDeCita = motivo
        }
        note("cita de \(channel == .control ? "control" : "medios") acabada (\(motivo)): \(accion)")
        log.info("cita de \(String(describing: channel)) acabada (\(motivo)): \(String(describing: accion))")
        switch accion {
        case .keepUntilDrop:
            // Sin cancelarla: de ella salió la conexión que sigue.
            endedRendezvous.insert(channel)
        case .renewLater:
            endedRendezvous.insert(channel)
            queue.asyncAfter(deadline: .now() + Self.rendezvousRenewS) { [weak self] in
                self?.renewEndedRendezvous()
            }
        case .reopen:
            endedRendezvous.insert(channel)
            queue.asyncAfter(deadline: .now() + Self.rendezvousRetryS) { [weak self] in
                self?.renewEndedRendezvous()
            }
        case .fail where channel == .control:
            state = .failed(motivo)
            // Si no se suelta, scheduleReopen no cambia nunca el listener por otro.
            listener?.cancel()
            listener = nil
            scheduleReopen()
        case .fail:
            // Los medios no cambian el estado del transporte: se dice y se reintenta.
            log.error("medios sin cita: \(motivo)")
            endedRendezvous.insert(channel)
            queue.asyncAfter(deadline: .now() + Self.reconnectDelaysS[Self.reconnectDelaysS.count - 1]) {
                [weak self] in self?.renewEndedRendezvous()
            }
        }
    }

    /// Cambia por otras nuevas las citas que se acabaron. El browser del control no se
    /// abre con una conexión en marcha: abrirlo pasa el estado a `.connecting`.
    private func renewEndedRendezvous() {
        guard !stopped else { return }
        if quiet, case .browse = mode { return }
        for canal in endedRendezvous {
            switch (mode, canal) {
            case (.advertise, _):
                // La cita acabada ya no publica: la nueva sale ya, salvo que otra del canal
                // esté todavía cancelándose (publishAnew espera a que acabe).
                publishAnew(canal, oldEnded: true)
            case (.browse, .control):
                guard connection == nil else { continue }
                browser?.cancel()
                browser = nil
                openBrowser()
            case (.browse, .media):
                mediaBrowser?.cancel()
                mediaBrowser = nil
                openMediaBrowser()
            default:
                break
            }
            endedRendezvous.remove(canal)
        }
    }

    /// Un listener acabado del que anuncia. Con la conexión arriba se guarda sin
    /// cancelar hasta que caiga: de él salió la conexión, y no se sabe si cancelarlo la
    /// arrastra (la caducidad sola no lo hizo). Sin conexión se cancela ya.
    private func retire(_ viejo: NWListener?) {
        guard let viejo else { return }
        if state == .connected {
            retiredListeners.append(viejo)
        } else {
            viejo.cancel()
        }
    }

    private func cancelRetiredListeners() {
        retiredListeners.forEach { $0.cancel() }
        retiredListeners.removeAll()
    }

    private func scheduleReopen() {
        guard !stopped else { return }
        let delay = Self.reconnectDelaysS[min(reconnectAttempt, Self.reconnectDelaysS.count - 1)]
        reconnectAttempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, !self.quiet, self.connection == nil else { return }
            switch self.mode {
            case .browse:
                self.browser?.cancel()
                self.openBrowser()
            case .connect:
                self.open()
            case .advertise, .listen:
                if self.listener == nil, self.pendingPublication[.control] == nil { self.open() }
            }
        }
    }

    // MARK: - Lectura del stream

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LinkConstants.controlReadChunkB) {
            [weak self] data, _, terminado, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.readControl(data)
            }
            if terminado || error != nil {
                // La lectura que acaba de una conexión ya descartada (la cancelamos al tirarla)
                // no es otra caída: antes contaba dos y abría dos suscripciones (Bug B).
                guard connection === self.connection else { return }
                self.dropConnection(error.map { "al recibir: \(self.describe($0))" } ?? "cerrada por el otro")
                return
            }
            self.receive(on: connection)
        }
    }

    /// Un trozo del stream de control: las tramas que completa, a la sesión. Antes se
    /// recortaba un Data con `removeFirst`, que guardaba todo lo leído (LinkStreamReader).
    private func readControl(_ data: Data) {
        stats.controlBytesReceived += data.count
        let salida = controlReader.push(data)
        stats.controlBufferPeakBytes = max(stats.controlBufferPeakBytes, controlReader.retainedBytes)
        for frame in salida.frames {
            stats.framesReceived += 1
            onFrame?(frame, .control)
        }
        if let campo = salida.invalid {
            // Basura por control: se tira y se cierra (ADR 0023 §2).
            stats.invalidFrames += 1
            log.error("trama inválida por control (\(campo)): se cierra")
            dropConnection("trama inválida (\(campo))")
        }
    }

    // MARK: - Medios por UDP (IOS-16)

    private func mediaParameters() -> NWParameters {
        rendezvous.parameters(for: .media)
    }

    private func openMedia() {
        guard !stopped else { return }
        switch mode {
        case let .advertise(name, txt):
            openMediaListener { try self.rendezvous.makeListener(for: .media, name: name, txt: txt) }
        case let .listen(port):
            // En los tests el puerto UDP es el TCP + 1. Con puerto 0, el TCP sale
            // efímero: se espera a conocerlo antes de atar el UDP al suyo + 1.
            let base = port > 0 ? port : localPort
            if base > 0 {
                openMediaListener { try Self.plainListener(self.mediaParameters(), port: base + 1) }
            } else {
                queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.openMedia()
                }
            }
        case .browse:
            openMediaBrowser()
        case let .connect(host, port):
            openMediaConnection(to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port + 1)!
            ), why: "puerto fijo de los tests")
        }
    }


    private func openMediaListener(_ make: () throws -> NWListener) {
        // Antes de crearlo: si falla, el vigía de la publicación cuenta desde aquí.
        mediaListenerQuietSinceNs = DispatchTime.now().uptimeNanoseconds
        mediaArrived = false
        do {
            let listener = try make()
            listener.newConnectionHandler = { [weak self] nueva in
                guard let self else { return }
                self.mediaArrived = true
                // La de quién se lee en la de control (el mismo par).
                self.note(self.mediaConnection == nil ? "medios: llega una conexión"
                    : "medios: llega otra y sustituye a la de antes")
                self.mediaConnection?.cancel()
                self.mediaConnection = nueva
                nueva.start(queue: self.queue)
                self.receiveMedia(on: nueva)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] estado in
                guard let self, let listener else { return }
                if case .cancelled = estado {
                    self.listenerCancelled(listener, .media)
                    return
                }
                guard listener === self.mediaListener else { return }
                switch estado {
                case .ready:
                    self.mediaLocalPort = listener.port?.rawValue ?? 0
                    self.note("cita de medios publicada")
                case let .failed(error):
                    self.rendezvousEnded(.media, error)
                case let .waiting(error):
                    self.note("listener de medios en espera: \(self.describe(error))")
                default:
                    break
                }
            }
            mediaListener = listener
            listener.start(queue: queue)
        } catch {
            // Un listener de medios que no se pudo crear se reintenta, como uno que falla.
            log.error("medios sin listener: \(self.describe(error))")
            note("medios sin listener: \(describe(error))")
            guard case .advertise = mode else { return }
            endedRendezvous.insert(.media)
            queue.asyncAfter(deadline: .now() + Self.reconnectDelaysS[Self.reconnectDelaysS.count - 1]) {
                [weak self] in self?.renewEndedRendezvous()
            }
        }
    }

    private func openMediaBrowser() {
        // Antes de crearlo: si falla, el vigía de la suscripción lo vuelve a intentar.
        mediaBrowserOpenedNs = DispatchTime.now().uptimeNanoseconds
        let browser: NWBrowser
        do {
            browser = try rendezvous.makeBrowser(for: .media)
        } catch {
            log.error("medios sin browser: \(self.describe(error))")
            note("medios sin browser: \(describe(error))")
            return
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, cambios in
            guard let self, let browser, browser === self.mediaBrowser else { return }
            // Lo recién aparecido primero: el anuncio viejo de la caché suele ser el que
            // ya estaba.
            let nuevos = cambios.compactMap { cambio -> NWEndpoint? in
                if case let .added(r) = cambio { return r.endpoint }
                return nil
            }
            let resto = results.map(\.endpoint).filter { e in !nuevos.contains(where: { $0 == e }) }
            self.mediaCandidates = nuevos.reversed() + resto
            self.noteResults("medios", total: results.count, cambios: cambios)
            // Bug B: por Wi-Fi Aware los medios esperan al control (adopt los conecta al subir).
            if self.rendezvous.mediaAfterControl, self.state != .connected {
                self.discardMedia("los medios esperan a que suba el control")
                return
            }
            if self.mediaConnection == nil || !nuevos.isEmpty, !self.mediaCandidates.isEmpty {
                self.mediaCandidateIndex = 0
                self.openMediaConnection(to: self.mediaCandidates[0],
                                         why: nuevos.isEmpty ? "sin conexión de medios" : "anuncio nuevo")
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] estado in
            guard let self, let browser, browser === self.mediaBrowser else { return }
            switch estado {
            case let .failed(error):
                self.rendezvousEnded(.media, error)
            case let .waiting(error):
                self.note("browser de medios en espera: \(self.describe(error))")
            case .ready:
                self.note("suscripción de medios lista")
            default:
                break
            }
        }
        mediaBrowser = browser
        browser.start(queue: queue)
    }

    private func openMediaConnection(to endpoint: NWEndpoint, why motivo: String) {
        discardMedia("otra en su lugar: \(motivo)")
        note("medios: se conecta a \(rendezvous.describe(endpoint)) (\(motivo))")
        let conexion = NWConnection(to: endpoint, using: mediaParameters())
        mediaConnection = conexion
        mediaOpenedAt = Date()
        conexion.stateUpdateHandler = { [weak self, weak conexion] estado in
            // Lo que diga una conexión ya descartada no cuenta (Bug B).
            guard let self, let conexion, conexion === self.mediaConnection else { return }
            switch estado {
            case .ready:
                self.note("medios: conexión lista")
                self.receiveMedia(on: conexion)
                // Un sondeo: por UDP, el que escucha solo conoce al otro cuando le llega
                // algo. El reensamblador del otro lo cuenta como basura y lo tira.
                conexion.send(content: Data([0]), completion: .contentProcessed { _ in })
            case let .failed(error), let .waiting(error):
                // Se suelta (Bug B): una conexión caída o en espera sin cancelar retiene lo
                // suyo, y la siguiente la abren un anuncio nuevo o el vigía de medios.
                self.note("medios: conexión en espera o caída (\(self.describe(error)))")
                self.discardMedia("en espera o caída")
            default:
                break
            }
        }
        conexion.start(queue: queue)
    }

    /// El lado que busca (o conecta) vigila que por medios llegue algo; si no, prueba el
    /// siguiente anuncio.
    private func startMediaWatchdog() {
        switch mode {
        case .browse, .connect: break
        default: return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.mediaWatchdogS, repeating: Self.mediaWatchdogS / 2)
        t.setEventHandler { [weak self] in self?.checkMedia() }
        mediaWatchdog = t
        t.resume()
    }

    private func checkMedia() {
        guard !stopped, state == .connected, let abierta = mediaOpenedAt else { return }
        // Con el vigía de silencio armado, unos medios mudos son un enlace muerto: lo tira
        // entero checkLink, sin probar otro anuncio sobre el mismo datapath.
        if rendezvous.silenceTimeoutS != nil, peerMediaSinceConnect { return }
        let ultima = max(lastMediaArrival ?? .distantPast, abierta)
        guard Date().timeIntervalSince(ultima) > Self.mediaWatchdogS else { return }
        mediaRotations += 1
        switch mode {
        case .browse:
            guard !mediaCandidates.isEmpty else { return }
            mediaCandidateIndex = (mediaCandidateIndex + 1) % mediaCandidates.count
            log.info("medios mudos: se prueba el anuncio \(self.mediaCandidateIndex)")
            note("medios mudos: se prueba el anuncio \(mediaCandidateIndex + 1) de \(mediaCandidates.count)")
            openMediaConnection(to: mediaCandidates[mediaCandidateIndex], why: "medios mudos")
        case let .connect(host, port):
            openMediaConnection(to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port + 1)!
            ), why: "medios mudos")
        default:
            break
        }
    }

    private func receiveMedia(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleMediaDatagram(data)
            }
            if error == nil {
                self.receiveMedia(on: connection)
            }
        }
    }

    private func handleMediaDatagram(_ datagram: Data) {
        guard let trama = reassembler.push(datagram) else { return }
        guard case let .frame(frame, _) = LinkFrame.decode(from: trama) else {
            // Por medios la basura se cuenta y se sigue: cerrar aquí sería dejar que
            // un datagrama roto tire el canal entero (ADR 0023 §2 solo cierra control).
            stats.invalidFrames += 1
            return
        }
        lastPeerMediaNs = DispatchTime.now().uptimeNanoseconds
        // Una vez por subida del control (y una antes, si los medios se adelantan): el
        // canal de medios, arriba de verdad.
        if !peerMediaSinceConnect { note("medios: primera trama del otro") }
        if stats.firstPeerMediaNs == nil { stats.firstPeerMediaNs = lastPeerMediaNs }
        peerMediaSinceConnect = true
        let ahora = Date()
        if let anterior = lastMediaArrival,
           ahora.timeIntervalSince(anterior) * 1000 > Self.mediaStallMs {
            stats.mediaStallsOver100Ms += 1
        }
        lastMediaArrival = ahora
        if let previo = lastMediaSeq, frame.seq > previo + 1 {
            stats.mediaLossGaps += Int(frame.seq - previo - 1)
        }
        if lastMediaSeq == nil || frame.seq > lastMediaSeq! {
            lastMediaSeq = frame.seq
        }
        stats.mediaFramesReceived += 1
        stats.framesReceived += 1
        onFrame?(frame, .media)
    }

    // MARK: - La ruta a internet

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaz = path.availableInterfaces.first.map(\.name) ?? "ninguna"
            self?.onPath?(interfaz)
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }
}
