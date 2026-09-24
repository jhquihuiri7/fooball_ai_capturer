// El enlace entre los dos móviles del soporte (ADR 0012, decisión 2; TASK A3 y A4).
//
// Los dos iPhone están a centímetros y se hablan por Multipeer Connectivity, sin pasar
// por el servidor ni por internet: es donde el enlace es bueno (pocos milisegundos) y
// donde medir el desfase entre sus relojes sale barato. El izquierdo es el maestro: se
// anuncia y contesta. El derecho lo busca, se conecta y le pregunta la hora.
//
// Dos cosas que este fichero cuida y que un chat entre móviles no cuidaría:
//
//   1. **Los sellos se toman aquí, en nativo, con el reloj de los frames**
//      (`CMClockGetHostTimeClock`). Si se tomaran en Dart llevarían encima el salto por
//      el canal de plataforma, que es justo del orden de lo que se quiere medir.
//   2. **Las preguntas de hora van por el canal no fiable.** Un paquete reenviado llega
//      tarde y falsea la ida y vuelta; mejor perderlo, que hay otro en un momento.
//
// Lo que NO hace: despejar el desfase. Entrega los cuatro sellos y la cuenta la hace
// Dart (`solveClockSample`, `RigClock`), que es donde está probada.

import CoreMedia
import Foundation
import MultipeerConnectivity
import UIKit

/// Lo que viaja por el enlace. Binario, big-endian y de tamaño fijo salvo la lista de PTS.
enum RigMessage: Equatable {
    /// Pregunta de hora. `t1` es cuándo salió, en el reloj del que pregunta.
    case ping(seq: UInt32, t1: Int64)
    /// Respuesta. Devuelve `t1` y añade cuándo llegó (`t2`) y cuándo sale (`t3`), en el
    /// reloj del maestro.
    case pong(seq: UInt32, t1: Int64, t2: Int64, t3: Int64)
    /// El derecho pide los PTS recientes del maestro para medir la fase (TASK A4).
    case ptsRequest(seq: UInt32)
    case ptsReply(seq: UInt32, pts: [Int64])
    /// El derecho pregunta cómo ve el maestro (exposición y balance de blancos)...
    case lookRequest(seq: UInt32)
    /// ...y el maestro contesta; también lo manda por su cuenta cuando los cambia.
    case look(seq: UInt32, look: CameraLook)

    private enum Kind: UInt8 {
        case ping = 1, pong, ptsRequest, ptsReply, lookRequest, look
    }

    func encode() -> Data {
        var data = Data()
        switch self {
        case let .ping(seq, t1):
            data.append(Kind.ping.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(t1)
        case let .pong(seq, t1, t2, t3):
            data.append(Kind.pong.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(t1)
            data.appendBigEndian(t2)
            data.appendBigEndian(t3)
        case let .ptsRequest(seq):
            data.append(Kind.ptsRequest.rawValue)
            data.appendBigEndian(seq)
        case let .ptsReply(seq, pts):
            data.append(Kind.ptsReply.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(UInt16(clamping: pts.count))
            pts.prefix(Int(UInt16.max)).forEach { data.appendBigEndian($0) }
        case let .lookRequest(seq):
            data.append(Kind.lookRequest.rawValue)
            data.appendBigEndian(seq)
        case let .look(seq, look):
            data.append(Kind.look.rawValue)
            data.appendBigEndian(seq)
            data.appendBigEndian(look.exposureNs)
            // Los decimales viajan con sus bits tal cual: sin redondeos ni escalas que acordar.
            [look.iso, look.aperture, look.kelvin, look.tint].forEach { data.appendBigEndian($0.bitPattern) }
        }
        return data
    }

    /// `nil` si el paquete está truncado o no es nuestro: se ignora, no se revienta.
    static func decode(_ data: Data) -> RigMessage? {
        var reader = Reader(data: data)
        guard let raw = reader.read(UInt8.self), let kind = Kind(rawValue: raw),
              let seq = reader.read(UInt32.self)
        else {
            return nil
        }
        switch kind {
        case .ping:
            guard let t1 = reader.read(Int64.self) else { return nil }
            return .ping(seq: seq, t1: t1)
        case .pong:
            guard let t1 = reader.read(Int64.self), let t2 = reader.read(Int64.self),
                  let t3 = reader.read(Int64.self)
            else {
                return nil
            }
            return .pong(seq: seq, t1: t1, t2: t2, t3: t3)
        case .ptsRequest:
            return .ptsRequest(seq: seq)
        case .ptsReply:
            guard let count = reader.read(UInt16.self) else { return nil }
            var pts: [Int64] = []
            for _ in 0..<count {
                guard let value = reader.read(Int64.self) else { return nil }
                pts.append(value)
            }
            return .ptsReply(seq: seq, pts: pts)
        case .lookRequest:
            return .lookRequest(seq: seq)
        case .look:
            guard let exposureNs = reader.read(Int64.self), let iso = reader.read(UInt32.self),
                  let aperture = reader.read(UInt32.self), let kelvin = reader.read(UInt32.self),
                  let tint = reader.read(UInt32.self)
            else {
                return nil
            }
            let look = CameraLook(
                exposureNs: exposureNs,
                iso: Float(bitPattern: iso),
                aperture: Float(bitPattern: aperture),
                kelvin: Float(bitPattern: kelvin),
                tint: Float(bitPattern: tint)
            )
            // Un paquete corrupto no debe llegar a la cámara como un ISO infinito.
            guard exposureNs > 0, [look.iso, look.aperture, look.kelvin, look.tint].allSatisfy(\.isFinite),
                  look.iso > 0
            else {
                return nil
            }
            return .look(seq: seq, look: look)
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            let start = data.startIndex + offset
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: start..<(start + size)) }
            offset += size
            return T(bigEndian: value)
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        // `Swift.`: dentro de una extensión de `Data`, el nombre a secas es el método de `Data`.
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

final class RigLink: NSObject {
    /// Tipo de servicio Multipeer. Máximo 15 caracteres; está en `NSBonjourServices`
    /// del Info.plist como `_footballai-rig._tcp` y `._udp`.
    static let serviceType = "footballai-rig"

    /// Al conectar se pregunta la hora en ráfaga, para tener reloj en un par de segundos
    /// (`RigClock` pide tres muestras), y después a ritmo lento para seguir la deriva.
    private static let burstCount = 10
    private static let burstInterval: TimeInterval = 0.25
    private static let steadyInterval: TimeInterval = 5

    /// Segundos que se espera la respuesta del maestro con sus PTS antes de dar vacío.
    private static let ptsTimeout: TimeInterval = 1.5

    /// Segundos que se deja a la invitación antes de volver a intentarlo.
    private static let inviteTimeout: TimeInterval = 10

    /// Cada cuántos segundos, mientras no haya enlace, el derecho vuelve a buscar. Sin esto
    /// había que encender los dos casi a la vez: la invitación se mandaba una sola vez, al
    /// descubrir al otro, y si caducaba nadie la repetía, porque iOS no vuelve a avisar de
    /// un par que ya vio (bug 3 del 22-09).
    private static let retryInterval: TimeInterval = 5

    /// Donde se guarda la identidad de este móvil entre arranques (ver `stablePeerID`).
    private static let peerIDKey = "rigPeerID"

    /// Bytes que admite el nombre de un par: 63 en UTF-8. Se corta por caracteres a
    /// 40 para no partir uno de varios bytes justo en el límite.
    private static let maxDisplayNameCharacters = 40

    var onState: ((LinkState, String) -> Void)?
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)?

    /// De dónde saca el maestro sus PTS recientes cuando el derecho se los pide.
    var recentPts: (() -> [Int64])?

    /// De dónde saca el maestro cómo ve su cámara, y qué hace el derecho cuando le llega.
    var currentLook: (() -> CameraLook?)?
    var onLook: ((CameraLook) -> Void)?

    private let role: CameraRole
    private let peerID: MCPeerID
    private let session: MCSession
    private let queue = DispatchQueue(label: "io.footballai.riglink")
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var seq: UInt32 = 0
    private var pingGeneration = 0
    private var sentPings = 0
    private var pendingPts: [UInt32: CheckedContinuation<[Int64], Never>] = [:]

    /// Si en esta conexión ya llegó cómo ve el maestro. Mientras no, se vuelve a pedir
    /// con cada respuesta de hora: el maestro puede estar todavía midiendo la luz.
    private var lookReceived = false

    /// Todo lo de aquí abajo se toca solo desde el hilo principal, que es donde Pigeon
    /// llama a `start` y `stop`: así no hace falta cerrojo.
    ///
    /// `stopped` corta lo que llegue tarde de este enlace cuando ya hay otro. Al invertir
    /// los lados se para uno y se crea otro, y la sesión vieja todavía avisaba de
    /// «desconectado» después: la pantalla pasaba a «buscando» con el nuevo ya conectado,
    /// y el derecho viejo volvía a buscar y a invitar desde una sesión muerta (bug 2).
    private var stopped = false
    private var retryTimer: Timer?
    private var invitedAt: Date?
    private var foregroundObserver: NSObjectProtocol?

    init(role: CameraRole) {
        self.role = role
        peerID = Self.stablePeerID()
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// La identidad de este móvil en el enlace: la misma en cada arranque y en los dos lados.
    ///
    /// Antes el nombre llevaba el lado —«iPhone (izquierda)»—, así que cambiar de rol
    /// fabricaba una identidad nueva para el mismo teléfono y el otro seguía con la vieja
    /// en caché: se cruzaban los roles hasta reiniciar la app (bug 2 del 22-09). Apple pide
    /// que el `MCPeerID` sea estable; el lado ya viaja en `discoveryInfo`, que es su sitio.
    /// Solo se hace otro si cambia el nombre del teléfono.
    static func stablePeerID() -> MCPeerID {
        let name = String(UIDevice.current.name.prefix(maxDisplayNameCharacters))
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: peerIDKey),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           saved.displayName == name {
            return saved
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            defaults.set(data, forKey: peerIDKey)
        }
        return fresh
    }

    /// El instante actual en el reloj de los frames, en nanosegundos.
    static func hostNowNs() -> Int64 {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value
    }

    // MARK: - Ciclo de vida

    func start() {
        onState?(.searching, "")
        rearm()
        // Mientras no haya enlace, el derecho vuelve a buscar cada poco: el izquierdo puede
        // encenderse minutos después, o la invitación caducar, y nadie más lo reintentaría.
        // El izquierdo no: su anuncio sigue vivo solo, y rehacerlo cortaría una invitación
        // que esté llegando.
        if role == .right {
            let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
                guard let self, !self.stopped, self.session.connectedPeers.isEmpty,
                      !self.invitationInFlight
                else {
                    return
                }
                self.startBrowsing()
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        }
        // Con la pantalla apagada iOS suspende el anuncio y la búsqueda, y al volver no los
        // reanuda: el izquierdo que llevaba rato apagado ya no se dejaba encontrar.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopped, self.session.connectedPeers.isEmpty,
                  !self.invitationInFlight
            else {
                return
            }
            NSLog("[enlace] de vuelta en primer plano, se rearma")
            self.rearm()
        }
    }

    func stop() {
        stopped = true
        retryTimer?.invalidate()
        retryTimer = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        queue.sync {
            pingGeneration += 1
            pendingPts.values.forEach { $0.resume(returning: []) }
            pendingPts.removeAll()
        }
        // Sin delegados antes de desconectar: lo que la sesión vieja avise a partir de
        // aquí ya no es de nadie, y no puede tocar la pantalla ni volver a invitar.
        session.delegate = nil
        advertiser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.delegate = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        onState?(.off, "")
    }

    /// Vuelve a anunciarse (el izquierdo) o a buscar (el derecho) desde cero.
    ///
    /// Parar y volver a empezar es lo que hace que iOS avise otra vez de un par que ya
    /// había visto, y así se puede volver a invitar.
    private func rearm() {
        guard !stopped else { return }
        if role == .left {
            advertiser?.delegate = nil
            advertiser?.stopAdvertisingPeer()
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID,
                discoveryInfo: ["role": "left"],
                serviceType: Self.serviceType
            )
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        } else {
            startBrowsing()
        }
    }

    private func startBrowsing() {
        guard !stopped else { return }
        browser?.delegate = nil
        browser?.stopBrowsingForPeers()
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    /// Si hay una invitación mandada que todavía no ha caducado.
    private var invitationInFlight: Bool {
        guard let invitedAt else { return false }
        return Date().timeIntervalSince(invitedAt) < Self.inviteTimeout
    }

    /// Invita al izquierdo, salvo que ya haya enlace o una invitación en vuelo.
    private func invite(_ peer: MCPeerID) {
        guard !stopped, session.connectedPeers.isEmpty, !invitationInFlight, let browser else {
            return
        }
        invitedAt = Date()
        NSLog("[enlace] encontrado %@, invitando", peer.displayName)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: Self.inviteTimeout)
    }

    // MARK: - Reloj (solo el derecho pregunta)

    private func startPinging() {
        queue.async {
            self.pingGeneration += 1
            self.sentPings = 0
            self.schedulePing(generation: self.pingGeneration, after: 0)
        }
    }

    private func schedulePing(generation: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.pingGeneration else { return }
            guard let peer = self.session.connectedPeers.first else {
                // Multipeer avisa de «conectado» un instante antes de listar al par: se
                // reintenta en vez de dejar morir la cadena de preguntas.
                self.schedulePing(generation: generation, after: Self.burstInterval)
                return
            }
            self.seq &+= 1
            // El sello se toma lo más pegado posible al envío.
            let message = RigMessage.ping(seq: self.seq, t1: Self.hostNowNs())
            do {
                try self.session.send(message.encode(), toPeers: [peer], with: .unreliable)
            } catch {
                if self.sentPings == 0 {
                    NSLog("[enlace] no se pudo preguntar la hora: %@", error.localizedDescription)
                }
            }
            self.sentPings += 1
            let next = self.sentPings < Self.burstCount ? Self.burstInterval : Self.steadyInterval
            self.schedulePing(generation: generation, after: next)
        }
    }

    /// Deja en el log las primeras medidas y luego una de cada veinte. La cuenta de verdad
    /// la hace Dart; esto es para ver desde Xcode, en la cancha, que el reloj está vivo.
    private var loggedPongs = 0

    private func logClock(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
        loggedPongs += 1
        guard loggedPongs <= 3 || loggedPongs % 20 == 0 else { return }
        let roundTripMs = Double((t4 - t1) - (t3 - t2)) / 1_000_000
        let offsetMs = Double((t2 - t1) + (t3 - t4)) / 2_000_000
        NSLog("[enlace] hora %d: ida y vuelta %.2f ms, desfase %.2f ms", loggedPongs, roundTripMs, offsetMs)
    }

    // MARK: - Mismo color en los dos móviles

    /// El maestro avisa de que ha vuelto a congelar exposición y balance.
    func publish(look: CameraLook) {
        guard role == .left, !session.connectedPeers.isEmpty else { return }
        queue.async {
            self.seq &+= 1
            let message = RigMessage.look(seq: self.seq, look: look)
            try? self.session.send(message.encode(), toPeers: self.session.connectedPeers, with: .reliable)
        }
    }

    private func requestLookIfNeeded(from peer: MCPeerID) {
        queue.async {
            guard !self.lookReceived else { return }
            self.seq &+= 1
            try? self.session.send(RigMessage.lookRequest(seq: self.seq).encode(), toPeers: [peer], with: .reliable)
        }
    }

    // MARK: - PTS del maestro (TASK A4)

    /// Los PTS recientes del maestro, o vacío si no hay enlace o no contesta a tiempo.
    func masterRecentPts() async -> [Int64] {
        guard let peer = session.connectedPeers.first else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                self.seq &+= 1
                let id = self.seq
                self.pendingPts[id] = continuation
                try? self.session.send(RigMessage.ptsRequest(seq: id).encode(), toPeers: [peer], with: .reliable)
                self.queue.asyncAfter(deadline: .now() + Self.ptsTimeout) {
                    self.pendingPts.removeValue(forKey: id)?.resume(returning: [])
                }
            }
        }
    }
}

// MARK: - Sesión

extension RigLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            NSLog("[enlace] conectado con %@", peerID.displayName)
            DispatchQueue.main.async { self.invitedAt = nil }
            onState?(.connected, peerID.displayName)
            if role == .right { startPinging() }
        case .notConnected:
            NSLog("[enlace] se perdió %@", peerID.displayName)
            queue.async {
                self.pingGeneration += 1
                self.lookReceived = false
            }
            onState?(.searching, "")
            // El buscador no vuelve a avisar de un par que ya vio: se reinicia. Si este
            // enlace ya se paró, `startBrowsing` no hace nada.
            if role == .right {
                DispatchQueue.main.async {
                    self.invitedAt = nil
                    self.startBrowsing()
                }
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Lo primero, antes de decodificar nada: cuándo llegó.
        let arrival = Self.hostNowNs()
        guard let message = RigMessage.decode(data) else { return }
        switch message {
        case let .ping(seq, t1):
            let reply = RigMessage.pong(seq: seq, t1: t1, t2: arrival, t3: Self.hostNowNs())
            try? session.send(reply.encode(), toPeers: [peerID], with: .unreliable)
        case let .pong(_, t1, t2, t3):
            logClock(t1: t1, t2: t2, t3: t3, t4: arrival)
            onStamps?(t1, t2, t3, arrival)
            // Una respuesta de hora es la prueba de que el enlace va: buen momento para pedir.
            requestLookIfNeeded(from: peerID)
        case let .ptsRequest(seq):
            let reply = RigMessage.ptsReply(seq: seq, pts: recentPts?() ?? [])
            try? session.send(reply.encode(), toPeers: [peerID], with: .reliable)
        case let .ptsReply(seq, pts):
            queue.async { self.pendingPts.removeValue(forKey: seq)?.resume(returning: pts) }
        case let .lookRequest(seq):
            // Sin ajustes todavía no se contesta: el derecho vuelve a preguntar.
            guard role == .left, let look = currentLook?() else { return }
            try? session.send(RigMessage.look(seq: seq, look: look).encode(), toPeers: [peerID], with: .reliable)
        case let .look(_, look):
            guard role == .right else { return }
            queue.async { self.lookReceived = true }
            NSLog("[enlace] ajustes del maestro: ISO %.0f, %.0f K", Double(look.iso), Double(look.kelvin))
            onLook?(look)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Izquierdo: se anuncia y acepta al derecho

extension RigLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Un soporte son dos móviles: con el derecho ya dentro, no entra nadie más. Salvo
        // que quien invita sea ese mismo derecho: con la identidad estable, si vuelve a
        // invitar es que reinició su enlace, y la conexión que se ve aquí es la vieja, que
        // Multipeer tarda en dar por perdida. Rechazarlo lo dejaba fuera ese rato.
        let connected = session.connectedPeers
        let free = connected.isEmpty || connected.contains(peerID)
        NSLog("[enlace] invitación de %@: %@", peerID.displayName, free ? "aceptada" : "rechazada")
        invitationHandler(free, free ? session : nil)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("[enlace] no se pudo anunciar: %@", error.localizedDescription)
    }
}

// MARK: - Derecho: busca al izquierdo y lo invita

extension RigLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "left" else { return }
        // Al hilo principal, que es donde vive el estado de la invitación en vuelo.
        DispatchQueue.main.async { self.invite(peerID) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // No se hace nada más: si no vuelve, el rearme periódico lo vuelve a buscar.
        NSLog("[enlace] dejó de verse %@", peerID.displayName)
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("[enlace] no se pudo buscar: %@", error.localizedDescription)
    }
}
