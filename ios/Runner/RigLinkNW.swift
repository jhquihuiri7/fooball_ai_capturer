// El enlace nuevo sobre Network.framework (IOS-12, ADR 0023), detrás del interruptor
// RIG_LINK_MULTIPEER.
//
// El Multipeer de hoy (RigLink) sigue siendo el predeterminado hasta que haya hubs
// Ethernet con los que pasar la aceptación de campo. Con RIG_LINK_MULTIPEER=0 en el
// entorno del proceso, startLink levanta en su lugar RigLinkSession sobre
// NWLinkTransport: mismo contrato hacia Dart, otro cable por debajo.
//
// El secreto del soporte llega por la variable RIG_LINK_SECRET (base64) hasta que
// IOS-97 lo provisione en el Keychain; con `devicectl … launch --environment-variables`
// se inyecta en banco. Sin secreto no hay enlace: se falla claro en vez de inventar uno.

import CoreMedia
import CoreML
import Foundation
import Network
import RigCore
import RigMedia
import RigNet
import UIKit
import Vision

/// Lo que `CaptureHostApiImpl` necesita de un enlace. Lo cumplen el Multipeer de hoy y
/// el nuevo sobre Network, para que el interruptor sea elegir una clase y nada más.
protocol PeerLinking: AnyObject {
    var onState: ((LinkState, String) -> Void)? { get set }
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)? { get set }
    var recentPts: (() -> [Int64])? { get set }
    var currentLook: (() -> CameraLook?)? { get set }
    var onLook: ((CameraLook) -> Void)? { get set }
    var onCommand: ((RigCommand) -> Void)? { get set }
    func start()
    func stop()
    func publish(look: CameraLook)
    func send(command: RigCommand)
    func masterRecentPts() async -> [Int64]
}

extension RigLink: PeerLinking {}

final class RigLinkNW: PeerLinking {
    var onState: ((LinkState, String) -> Void)?
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)?
    var recentPts: (() -> [Int64])?
    var currentLook: (() -> CameraLook?)?
    var onLook: ((CameraLook) -> Void)?
    var onCommand: ((RigCommand) -> Void)?

    /// La sesión, para los bancos que hablan el render repartido (program-split).
    let session: RigLinkSession
    private let transport: NWLinkTransport

    /// La IP del otro móvil, o nil sin enlace (IOS-63).
    var peerHost: String? { transport.peerHost }

    /// Los contadores del transporte, para el informe del banco program-split.
    var transportStats: LinkTransportStats { transport.statsSnapshot }

    /// La línea de tiempo del transporte y su cero (ns de uptime), para el banco
    /// program-split (2026-10-11).
    var transportTimeline: (createdNs: UInt64, events: [String]) { (transport.createdNs, transport.events) }

    /// Por qué no hay enlace, o que lo hay, para el latido y el informe (2026-10-15).
    var transportDiagnosis: LinkDiagnosis { transport.diagnosis }

    /// El diagnóstico del enlace en `Documents/bench/link-diag-<lado>-<t>.json` desde que se
    /// abre hasta que enlaza, y la frase para la fila Enlace mientras busca (2026-10-15). En
    /// el EMITIR de las 11:36 no llegó a haber pasada del programa, y sin ella nada lo decía.
    private var diagRecorder: LinkDiagnosisRecorder?
    private let sideLabel: String
    /// La última frase del diagnóstico, que acompaña al estado «buscando» hacia Dart.
    private let summaryLock = NSLock()
    private var lastSummary = ""

    /// El partido que dirige este móvil: va en el hello de las siguientes conexiones.
    var matchId: String? {
        get { session.matchId }
        set { session.matchId = newValue }
    }

    /// El reloj nativo de la sesión (IOS-13): CaptureEngine lo lee por fotograma.
    var clock: RigClock { session.clock }

    /// Cada estimación nueva del reloj, para la pantalla. Solo la emite el esclavo.
    var onClockEstimate: ((RigClockEstimate) -> Void)? {
        get { session.onClockEstimate }
        set { session.onClockEstimate = newValue }
    }

    /// El medio del enlace: Ethernet por el hub (ADR 0023) salvo RIG_LINK_INTERFACE=wifi,
    /// el banco sin cables, o =aware, Wi-Fi Aware sin router (IOS-14). nil si no se
    /// entiende el valor.
    static func medium(_ valor: String? = ProcessInfo.processInfo.environment["RIG_LINK_INTERFACE"])
        -> LinkMedium?
    {
        LinkMedium.parse(valor)
    }

    /// El transporte del lado por el medio: escucha el izquierdo y conecta el derecho
    /// (ADR 0023). Por Bonjour, el anuncio lleva el lado y la huella del secreto en la
    /// TXT, para no invitar a un soporte ajeno; Wi-Fi Aware no tiene TXT y solo ve a los
    /// emparejados.
    static func makeTransport(side: RigLinkSession.Side, secret: Data, medium: LinkMedium) -> NWLinkTransport {
        let cita: LinkRendezvous = switch medium {
        case .ethernet: BonjourRendezvous(interfaceType: .wiredEthernet)
        case .wifi: BonjourRendezvous(interfaceType: .wifi)
        case .aware: WiFiAwareRendezvous(activeDuration: awareActiveDuration())
        }
        guard side == .left else { return NWLinkTransport(mode: .browse, rendezvous: cita) }
        return NWLinkTransport(mode: .advertise(
            name: UIDevice.current.name,
            txt: ["side": "left", "fp": LinkAuth.fingerprint(secret: secret)]
        ), rendezvous: cita)
    }

    /// IOS-14: con `RIG_LINK_AWARE_ACTIVE_S=<s>`, cuánto se pide que dure la publicación
    /// y la suscripción por Wi-Fi Aware; sin ella, lo que decida el sistema (~2 min).
    static func awareActiveDuration(
        _ valor: String? = ProcessInfo.processInfo.environment["RIG_LINK_AWARE_ACTIVE_S"]
    ) -> Duration? {
        valor.flatMap(Int64.init).flatMap { $0 > 0 ? Duration.seconds($0) : nil }
    }

    /// El secreto del soporte hasta que IOS-97 lo provisione con su QR: RIG_LINK_SECRET
    /// manda y se guarda en el Keychain; sin él, el guardado (IOS-58: así la app abre el
    /// enlace desde el icono, sin el Mac). Ni el valor ni su longitud salen al log.
    static func benchSecret() -> Data? {
        let guardado: String?
        do {
            guardado = try KeychainText.linkSecret.read()
        } catch {
            NSLog("[enlace] no se pudo leer el secreto del soporte del Keychain")
            guardado = nil
        }
        return RigSecretSource.resolve(
            environment: ProcessInfo.processInfo.environment["RIG_LINK_SECRET"], stored: guardado
        ) { nuevo in
            do { try KeychainText.linkSecret.write(nuevo) } catch {
                NSLog("[enlace] no se pudo guardar el secreto del soporte en el Keychain")
            }
        }
    }

    /// El secreto del mando del partido (ADR 0023 §3), derivado aquí para que S no salga
    /// de nativo. nil sin secreto del soporte.
    static func controlSecret(matchId: String) -> String? {
        guard let secreto = benchSecret() else { return nil }
        return LinkAuth.controlSecret(secret: secreto, matchId: matchId)
    }

    /// El rol que negoció el enlace (IOS-80), con su term y su partido.
    var onRigRole: ((RigCore.RigRole, Int, String?) -> Void)?

    init(role: CameraRole, secret: Data, prefersMaster: Bool, medium: LinkMedium) {
        let side: RigLinkSession.Side = role == .left ? .left : .right
        sideLabel = side.rawValue
        let transport = Self.makeTransport(side: side, secret: secret, medium: medium)
        self.transport = transport
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        session = RigLinkSession(
            transport: transport,
            secret: secret,
            side: side,
            deviceId: UIDevice.current.name,
            appVersion: version ?? "0"
        )
        session.hostNowNs = { RigLink.hostNowNs() }
        // Sin partido todavía, nadie trae rol: decide la preferencia (ADR 0023 §7). El
        // partido y el term llegan con la pizarra (IOS-82).
        session.claimedRole = .slave
        session.prefersMaster = prefersMaster
        session.onRole = { [weak self] rol, term, partido in self?.onRigRole?(rol, term, partido) }
        session.recentPts = { [weak self] in self?.recentPts?() ?? [] }
        session.currentLook = { [weak self] in self?.currentLook?() }
        session.onLook = { [weak self] look in self?.onLook?(look) }
        session.onCommand = { [weak self] wire in
            guard let command = RigCommand(rawValue: Int(wire.rawValue)) else { return }
            self?.onCommand?(command)
        }
        session.onStamps = { [weak self] t1, t2, t3, t4 in
            self?.onStamps?(t1, t2, t3, t4)
        }
        session.onState = { [weak self] estado in
            switch estado {
            case .searching, .authenticating:
                // Con la frase del diagnóstico, si ya la hay: la fila Enlace la enseña.
                self?.onState?(.searching, self?.currentSummary ?? "")
            case let .connected(peer):
                self?.onState?(.connected, peer)
            case let .rejected(motivo):
                // La pantalla de hoy no tiene estado «rechazado»: queda sin enlace y el
                // motivo en el log hasta que la UI lo estrene.
                NSLog("[enlace] rechazado: %@", motivo)
                self?.onState?(.off, "")
            case .conflict:
                self?.onState?(.conflict, "")
            case .off:
                self?.onState?(.off, "")
            }
        }
    }

    func start() {
        session.start()
        startDiagnosisFile()
    }

    func stop() {
        diagRecorder?.stop()
        diagRecorder = nil
        session.stop()
    }

    private var currentSummary: String {
        summaryLock.lock(); defer { summaryLock.unlock() }
        return lastSummary
    }

    private func startDiagnosisFile() {
        guard diagRecorder == nil else { return }
        let arranqueMs = Int64(Date().timeIntervalSince1970 * 1000)
        let destino = (try? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { docs -> URL in
                let base = docs.appendingPathComponent("bench", isDirectory: true)
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                return base.appendingPathComponent(
                    LinkDiagnosisRecorder.fileName(side: sideLabel, startUnixS: Int(arranqueMs / 1000))
                )
            }
        let transporte = transport
        let sesion = session
        let r = LinkDiagnosisRecorder(
            side: sideLabel, startUnixMs: arranqueMs,
            sample: {
                .init(diagnosis: transporte.diagnosis, session: sesion.state, events: transporte.events,
                      stats: transporte.statsSnapshot)
            },
            write: { datos in
                guard let destino else { return }
                // Lo que no se pueda escribir no para el enlace.
                try? datos.write(to: destino, options: .atomic)
            }
        )
        r.onSummary = { [weak self] frase in
            guard let self else { return }
            summaryLock.lock()
            let cambia = lastSummary != frase
            lastSummary = frase
            summaryLock.unlock()
            // Solo mientras busca: apagado, en conflicto o rechazado lo dice su estado.
            switch sesion.state {
            case .searching, .authenticating:
                if cambia { onState?(.searching, frase) }
            default:
                break
            }
            NSLog("[enlace] %@", frase)
        }
        diagRecorder = r
        r.start()
    }

    func publish(look: CameraLook) {
        session.publish(look: look)
    }

    func send(command: RigCommand) {
        guard let wire = RigWireCommand(rawValue: UInt8(command.rawValue)) else { return }
        session.send(command: wire)
    }

    func masterRecentPts() async -> [Int64] {
        await withCheckedContinuation { continuation in
            session.masterRecentPts { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - «Una cámara (sin pareja)» (2026-10-15)

/// El «enlace» de «Una cámara»: ninguno. Ni Bonjour, ni Wi-Fi Aware, ni secreto. Lleva una
/// RigLinkSession que dirige sola (`RigLinkSession.alone`) para que EMITIR sea la misma pasada
/// del programa que con dos, con su reloj de host como reloj del soporte. A Dart le dice que
/// el enlace está apagado y que este móvil dirige; lo que haría falta mandar al otro se pierde.
final class RigSoloLink: PeerLinking {
    var onState: ((LinkState, String) -> Void)?
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)?
    var recentPts: (() -> [Int64])?
    var currentLook: (() -> CameraLook?)?
    var onLook: ((CameraLook) -> Void)?
    var onCommand: ((RigCommand) -> Void)?

    let session: RigLinkSession
    /// El rol (siempre maestro), con su term y su partido, como el de RigLinkNW.
    var onRigRole: ((RigCore.RigRole, Int, String?) -> Void)?

    var clock: RigClock { session.clock }

    var matchId: String? {
        get { session.matchId }
        set { session.matchId = newValue }
    }

    init(role: CameraRole) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        session = .alone(side: role == .left ? .left : .right, deviceId: UIDevice.current.name,
                         appVersion: version ?? "0")
        session.hostNowNs = { RigLink.hostNowNs() }
        session.onRole = { [weak self] rol, term, partido in self?.onRigRole?(rol, term, partido) }
    }

    func start() {
        session.startAlone()
        onState?(.off, "")
    }

    func stop() {
        session.stop()
    }

    func publish(look _: CameraLook) {}
    func send(command _: RigCommand) {}
    func masterRecentPts() async -> [Int64] { [] }
}

// MARK: - El banco del enlace

// El banco del enlace entre los dos móviles (IOS-11/16/12, aceptación de campo).
//
// Vive en el Runner y no en ZeroKit porque junta RigNet (el enlace) con el informe de
// RigMedia, y el contrato de capas no deja que RigMedia importe RigNet. Se lanza en
// cada móvil con `--dart-define=BENCH=link-bench` y estas variables de entorno, que
// `devicectl … process launch --environment-variables` inyecta:
//
//   RIG_LINK_SIDE       left | right (escucha el izquierdo, conecta el derecho)
//   RIG_LINK_SECRET     el secreto del soporte, base64 (el mismo en los dos)
//   RIG_LINK_INTERFACE  ethernet (por defecto, el hub) | wifi (banco sin cables) |
//                       aware (Wi-Fi Aware sin router, IOS-14; emparejados antes)
//   RIG_LINK_BENCH_S    segundos que dura (por defecto 60)
//   RIG_LINK_CUT_AT_S   segundo en que el izquierdo corta el enlace 1 s, como quien
//                       desenchufa el cable (0 = no corta; por defecto 20)
//   RIG_LINK_PREFERS_MASTER  1/0: «este móvil dirige» (IOS-80); por defecto el izquierdo
//
// Mide lo que pide la aceptación: cuánto tarda en quedar autenticado desde el arranque
// (en cualquier orden), cuánto tarda en volver tras el corte, el RTT de cada ping del
// reloj, que las órdenes del maestro y los PTS lleguen (IOS-12) y qué interfaz lleva
// internet, y lo deja en Documents/bench como los demás bancos.

enum LinkBench {
    static let defaultDurationS = 60.0
    static let defaultCutAtS = 20
    /// Lo que dura el corte simulado.
    static let cutLengthS = 1.0
    /// Cada cuánto manda el maestro una orden y pide el esclavo los PTS.
    static let probeEveryS = 2
    /// Cada cuánto deja el banco un informe parcial (se sobrescribe).
    static let partialReportEveryS = 300

    static func run(progress: BenchRunner.Progress?) throws -> URL {
        let entorno = ProcessInfo.processInfo.environment
        guard let lado = entorno["RIG_LINK_SIDE"].flatMap(RigLinkSession.Side.init(rawValue:)) else {
            throw BenchError.unknownBench("link-bench: falta RIG_LINK_SIDE=left|right")
        }
        guard let secreto = RigLinkNW.benchSecret() else {
            throw BenchError.unknownBench("link-bench: falta RIG_LINK_SECRET (base64)")
        }
        guard let medio = RigLinkNW.medium(entorno["RIG_LINK_INTERFACE"]) else {
            throw BenchError.unknownBench("link-bench: RIG_LINK_INTERFACE no es ethernet, wifi ni aware")
        }
        let duracion = entorno["RIG_LINK_BENCH_S"].flatMap(Double.init) ?? defaultDurationS
        let corteEn = entorno["RIG_LINK_CUT_AT_S"].flatMap(Int.init) ?? defaultCutAtS

        let transporte = RigLinkNW.makeTransport(side: lado, secret: secreto, medium: medio)
        // SPK-02: el ritmo del espaciado, para medirlo sin recompilar.
        if let golpe = entorno["RIG_LINK_PACING_BURST"].flatMap(Int.init) {
            transporte.pacingBurstDatagrams = max(1, golpe)
        }
        if let us = entorno["RIG_LINK_PACING_US"].flatMap(Int.init) {
            transporte.pacingIntervalUs = max(100, us)
        }
        let sesion = RigLinkSession(
            transport: transporte, secret: secreto, side: lado,
            deviceId: UIDevice.current.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        )
        sesion.hostNowNs = { RigLink.hostNowNs() }
        // IOS-80: sin partido, nadie trae rol; decide la preferencia.
        sesion.claimedRole = .slave
        sesion.prefersMaster = entorno["RIG_LINK_PREFERS_MASTER"].map { $0 == "1" } ?? (lado == .left)

        let cerrojo = NSLock()
        var rolNegociado = ""
        var termNegociado = 0
        var conectadoMs: Double?
        var conexiones = 0
        var rechazos: [String] = []
        var rtts: [Double] = []
        var estimaciones = 0
        var incertidumbreNs: Int64 = 0
        var ruta = ""
        var par = ""
        var conectado = false
        var caidaNs: UInt64?
        var vueltasMs: [Double] = []
        var ordenesRecibidas = 0
        var ordenesEnviadas = 0
        var ptsPedidos = 0
        var ptsRespondidos = 0
        var ptsMs: [Double] = []
        let inicio = DispatchTime.now().uptimeNanoseconds
        // El desglose de la conexión: transporte escuchando/conectando, TCP arriba
        // (la sesión pasa a autenticar) y auth hecho. Se encadena al de la sesión.
        var hitos: [String: Double] = [:]
        var fallosTransporte: [String] = []
        var ultimaRadio: [String: String] = [:]
        func hito(_ nombre: String) {
            if hitos[nombre] == nil {
                hitos[nombre] = Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6
            }
        }
        let deLaSesion = transporte.onState
        transporte.onState = { estado in
            cerrojo.lock()
            switch estado {
            case .listening: hito("t_listening_ms")
            case .connecting: hito("t_connecting_ms")
            case .connected: hito("t_tcp_ms")
            // Por Wi-Fi Aware, lo que falla antes de conectar (sin emparejado, sin
            // entitlement) solo se ve aquí.
            case let .failed(motivo) where !fallosTransporte.contains(motivo): fallosTransporte.append(motivo)
            default: break
            }
            cerrojo.unlock()
            deLaSesion?(estado)
        }
        // El maestro contesta con unos PTS sintéticos: aquí no hay cámara.
        sesion.recentPts = { [1_000_000, 34_333_333, 67_666_666] }
        sesion.onRole = { rol, term, _ in
            cerrojo.lock(); defer { cerrojo.unlock() }
            rolNegociado = rol.rawValue
            termNegociado = term
        }
        sesion.onCommand = { _ in
            cerrojo.lock(); defer { cerrojo.unlock() }
            ordenesRecibidas += 1
        }

        sesion.onState = { estado in
            cerrojo.lock(); defer { cerrojo.unlock() }
            switch estado {
            case .authenticating:
                hito("t_hello_ms")
            case let .connected(peer):
                let ahora = DispatchTime.now().uptimeNanoseconds
                hito("t_auth_ms")
                conexiones += 1
                conectado = true
                par = peer
                if conectadoMs == nil {
                    conectadoMs = Double(ahora - inicio) / 1e6
                }
                if let caida = caidaNs {
                    vueltasMs.append(Double(ahora - caida) / 1e6)
                    caidaNs = nil
                }
            case let .rejected(motivo):
                rechazos.append(motivo)
                conectado = false
            default:
                // Se pierde la sesión: desde aquí cuenta lo que tarda en volver.
                if conectado { caidaNs = DispatchTime.now().uptimeNanoseconds }
                conectado = false
            }
        }
        sesion.onStamps = { t1, t2, t3, t4 in
            cerrojo.lock(); defer { cerrojo.unlock() }
            rtts.append(Double((t4 - t1) - (t3 - t2)) / 1e6)
        }
        sesion.onClockEstimate = { e in
            cerrojo.lock(); defer { cerrojo.unlock() }
            estimaciones += 1
            incertidumbreNs = e.uncertaintyNs
        }
        transporte.onPath = { interfaz in
            cerrojo.lock(); defer { cerrojo.unlock() }
            ruta = interfaz
        }

        // SPK-02: con RIG_LINK_PARTS=1, partes sintéticas por el camino de las de verdad.
        let carga = entorno["RIG_LINK_PARTS"] == "1" ? LinkPartsLoad(session: sesion, environment: entorno) : nil

        /// El informe: al terminar y, en las pasadas largas, uno parcial cada
        /// `partialReportEveryS` (se sobrescribe), para no perderlo todo si se corta.
        func escribe(duracion: Double, sufijo: String) throws -> URL {
            let stats = transporte.stats
            let deLaCarga = carga?.counters() ?? [:]
            // Al final la sesión ya está parada: vale la última lectura de la radio.
            let leida = medio == .aware ? Self.awareReport(transporte) : [:]
            if !leida.isEmpty { ultimaRadio = leida }
            let radio = ultimaRadio
            // Antes del cerrojo: lo lee en la cola del transporte, que también lo toma.
            let espera = transporte.waitingReason ?? ""
            // IOS-14: la cita que caducó con la conexión viva no es un fallo del transporte.
            let finCita = transporte.lastRendezvousEnd ?? ""
            // IOS-14c: la línea de tiempo del transporte (citas, caídas con su motivo y
            // vueltas), para ver si cada caída coincide con una cita que caduca.
            let sucesos = transporte.events.joined(separator: " | ")
            cerrojo.lock(); defer { cerrojo.unlock() }
            let orden = rtts.sorted()
            func p(_ q: Double) -> Double {
                orden.isEmpty ? 0 : orden[min(orden.count - 1, Int(q * Double(orden.count)))]
            }
            var informe = BenchReport(
                name: "link-bench",
                device: BenchRunner.machine(),
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                startedEpochS: Int64(Date().timeIntervalSince1970),
                durationS: duracion,
                params: [
                    "side": lado.rawValue,
                    "interface": medio.rawValue,
                    "rendezvous": transporte.rendezvous.label,
                    "aware_requested_active_s": RigLinkNW.awareActiveDuration().map { "\($0.components.seconds)" } ?? "sistema",
                    "transport_failures": fallosTransporte.joined(separator: " | "),
                    "transport_waiting": espera,
                    "rendezvous_end": finCita,
                    "transport_events": sucesos,
                    "silence_timeout_s": transporte.rendezvous.silenceTimeoutS.map { "\($0)" } ?? "no",
                    "peer": par,
                    "internet_path": ruta,
                    "rejections": rechazos.joined(separator: " | "),
                    "rig_role": rolNegociado,
                    "prefers_master": sesion.prefersMaster ? "1" : "0",
                    "parts_profile": carga?.profileDescription ?? "",
                    "pacing": "\(transporte.pacingBurstDatagrams) cada \(transporte.pacingIntervalUs) us",
                ].merging(radio) { a, _ in a },
                thermal: [],
                stagesMs: [:],
                counters: [
                    "connected": conexiones > 0 ? 1 : 0,
                    "connections": conexiones,
                    "connect_ms": Int((conectadoMs ?? -1).rounded()),
                    "rtt_samples": rtts.count,
                    "rig_term": termNegociado,
                    "reconnect_ms": vueltasMs.isEmpty ? -1 : Int(vueltasMs.max()!.rounded()),
                    "outages": vueltasMs.count,
                    "t_listening_ms": Int(hitos["t_listening_ms"] ?? -1),
                    "t_connecting_ms": Int(hitos["t_connecting_ms"] ?? -1),
                    "t_tcp_ms": Int(hitos["t_tcp_ms"] ?? -1),
                    "t_hello_ms": Int(hitos["t_hello_ms"] ?? -1),
                    "t_auth_ms": Int(hitos["t_auth_ms"] ?? -1),
                    "commands_sent": ordenesEnviadas,
                    "commands_received": ordenesRecibidas,
                    "pts_requests": ptsPedidos,
                    "pts_answered": ptsRespondidos,
                    "clock_estimates": estimaciones,
                    "clock_uncertainty_us": Int(incertidumbreNs / 1000),
                    "reconnects": stats.reconnects,
                    "frames_sent": stats.framesSent,
                    "frames_received": stats.framesReceived,
                    "invalid_frames": stats.invalidFrames,
                    "media_frames_received": stats.mediaFramesReceived,
                    "media_loss_gaps": stats.mediaLossGaps,
                    "media_stalls_over_100ms": stats.mediaStallsOver100Ms,
                    "media_pacer_drops": stats.mediaPacerDrops,
                    "rendezvous_ends": stats.rendezvousEnds,
                    "silence_drops": stats.silenceDrops,
                    "resubscribes": stats.resubscribes,
                    // 2026-10-10: lo recibido por control y lo más que guardó su búfer.
                    "control_rx_bytes": stats.controlBytesReceived,
                    "control_buffer_peak_bytes": stats.controlBufferPeakBytes,
                ].merging(deLaCarga) { a, _ in a }
            )
            if !rtts.isEmpty {
                informe.stagesMs["link/rtt"] = BenchReport.StageSummary(p50Ms: p(0.5), p90Ms: p(0.9), p99Ms: p(0.99))
            }
            if !ptsMs.isEmpty {
                let o = ptsMs.sorted()
                informe.stagesMs["link/pts_roundtrip"] = BenchReport.StageSummary(
                    p50Ms: o[o.count / 2], p90Ms: o[min(o.count - 1, o.count * 9 / 10)], p99Ms: o[o.count - 1]
                )
            }
            let base = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("bench", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let destino = base.appendingPathComponent("link-bench-\(lado.rawValue)-\(sufijo).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(informe).write(to: destino, options: .atomic)
            return destino
        }

        sesion.start()
        carga?.run()
        let pasos = max(1, Int(duracion))
        for s in 0..<pasos {
            Thread.sleep(forTimeInterval: 1)
            if lado == .left && corteEn > 0 && s + 1 == corteEn {
                // El cable fuera: la sesión entera se cae y vuelve a levantarse.
                sesion.stop()
                Thread.sleep(forTimeInterval: cutLengthS)
                cerrojo.lock(); caidaNs = caidaNs ?? DispatchTime.now().uptimeNanoseconds; cerrojo.unlock()
                sesion.start()
            }
            if (s + 1) % probeEveryS == 0 {
                // Manda órdenes el maestro negociado; pide los PTS el esclavo (IOS-80).
                if sesion.isMaster {
                    sesion.send(command: .stop)
                    cerrojo.lock(); if conectado { ordenesEnviadas += 1 }; cerrojo.unlock()
                } else {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    cerrojo.lock(); ptsPedidos += 1; cerrojo.unlock()
                    sesion.masterRecentPts { pts in
                        cerrojo.lock(); defer { cerrojo.unlock() }
                        if !pts.isEmpty {
                            ptsRespondidos += 1
                            ptsMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                        }
                    }
                }
            }
            if (s + 1) % Self.partialReportEveryS == 0, s + 1 < pasos {
                _ = try? escribe(duracion: Double(s + 1), sufijo: "parcial")
            }
            progress?(Double(s + 1) / Double(pasos), "enlace \(lado.rawValue): \(conexiones > 0 ? "conectado" : "buscando")")
        }
        if medio == .aware {
            let leida = Self.awareReport(transporte)
            if !leida.isEmpty { ultimaRadio = leida }
        }
        carga?.stop()
        sesion.stop()
        return try escribe(duracion: duracion, sufijo: "\(Int64(Date().timeIntervalSince1970))")
    }

    /// Lo que dice la radio de Wi-Fi Aware de la conexión de control (SPK-08): señal,
    /// capacidad y latencia de emisión de vídeo; vacío sin conexión. Espera como mucho
    /// `awareReportTimeoutS`: el informe no puede colgarse por la radio.
    static func awareReport(_ transporte: NWLinkTransport) -> [String: String] {
        guard let ruta = transporte.controlPath else { return [:] }
        let caja = ReportBox()
        let listo = DispatchSemaphore(value: 0)
        Task.detached {
            caja.value = await WiFiAwareRendezvous.report(of: ruta)
            listo.signal()
        }
        _ = listo.wait(timeout: .now() + awareReportTimeoutS)
        return caja.value
    }

    static let awareReportTimeoutS = 1.0
}

/// El informe de la radio, de la tarea que lo lee al hilo del banco.
private final class ReportBox: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var leido: [String: String] = [:]

    var value: [String: String] {
        get { cerrojo.lock(); defer { cerrojo.unlock() }; return leido }
        set { cerrojo.lock(); leido = newValue; cerrojo.unlock() }
    }
}

// MARK: - La carga de partes del banco (SPK-02)

// La carga de partes sintéticas del banco del enlace (SPK-02, IOS-52).
//
// Con RIG_LINK_PARTS=1, el link-bench deja de ser solo apretón y reloj: el esclavo manda
// partes de vídeo falsas a 30 fps con un perfil de Mbit/s que cambia cada
// RIG_LINK_PARTS_STEP_S (por defecto 0, 10 y 30 cada 5 min, como pide SPK-02), por el
// mismo camino que las de verdad (PartPacket → medios → espaciado → reensamblado). El
// maestro las pasa por PartReceiver, pide IDR ante un hueco y cuenta lo que decide
// SPK-02: pérdidas, parones de más de 100 y 150 ms, jitter y Mbit/s. Con 0 Mbit/s el
// esclavo manda `no_part`, que también cuenta como señal de vida para los parones.


final class LinkPartsLoad {
    /// Perfil por defecto, en Mbit/s, y lo que dura cada escalón (SPK-02).
    static let defaultProfileMbps: [Double] = [0, 10, 30]
    static let defaultStepS = 300.0
    static let fps = 30.0
    /// Cada cuántos fotogramas va un IDR sin que nadie lo pida (2 s, el GOP del programa).
    static let gopFrames = 60
    /// Cuánto pesa un IDR frente a una P (sin unidad): lo que se ve en VideoToolbox.
    static let idrWeight = 4.0
    /// Umbrales de parón que pide SPK-02, en ms.
    static let stallMs: [Double] = [100, 150]

    private let session: RigLinkSession
    private let profile: [Double]
    private let stepS: Double
    private let queue = DispatchQueue(label: "io.footballai.zero.bench.parts", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds

    // Esclavo
    private var frame = 0
    private var partSeq: UInt32 = 0
    private var idrPending = false
    private(set) var partsSent = 0
    private(set) var bytesSent = 0

    // Maestro
    private let receiver = PartReceiver()
    private var lastArrivalMs: Double?
    private(set) var stalls = [0, 0]
    private(set) var worstGapMs = 0.0
    private(set) var noParts = 0
    private var maxMbps = 0.0

    private let batteryStart: Float

    init(session: RigLinkSession, environment: [String: String]) {
        self.session = session
        profile = environment["RIG_LINK_PARTS_PROFILE"]
            .map { $0.split(separator: ",").compactMap { Double($0) } }
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultProfileMbps
        stepS = environment["RIG_LINK_PARTS_STEP_S"].flatMap(Double.init) ?? Self.defaultStepS
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryStart = UIDevice.current.batteryLevel

        session.onIdrRequest = { [weak self] _ in
            self?.lock.lock(); self?.idrPending = true; self?.lock.unlock()
        }
        session.onPart = { [weak self] parte, llegadaNs in self?.received(parte, arrivalNs: llegadaNs) }
        session.onNoPart = { [weak self] _ in
            guard let self else { return }
            lock.lock(); defer { lock.unlock() }
            noParts += 1
            beat(Double(DispatchTime.now().uptimeNanoseconds) / 1e6)
        }
    }

    func run() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Self.fps, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private var elapsedS: Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }

    private func currentMbps() -> Double {
        profile[Int(elapsedS / stepS) % profile.count]
    }

    /// Un fotograma del esclavo: una parte del tamaño del escalón, o `no_part`.
    private func tick() {
        guard !session.isMaster, case .connected = session.state else { return }
        let ms = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        let mbps = currentMbps()
        lock.lock()
        frame += 1
        if mbps <= 0 {
            lock.unlock()
            session.send(noPart: NoPartPacket(frameRigMs: ms, viewId: UInt32(truncatingIfNeeded: frame)))
            return
        }
        let esIdr = idrPending || frame % Self.gopFrames == 1
        idrPending = false
        let base = mbps * 1_000_000 / 8 / Self.fps
        let bytes = Int(esIdr ? base * Self.idrWeight : base)
        let parte = PartPacket(
            partSeq: partSeq, frameRigMs: ms, view: Self.view, extrapolated: false, isKey: esIdr,
            accessUnit: Data(count: min(bytes, LinkConstants.maxFrameB / 2))
        )
        partSeq &+= 1
        partsSent += 1
        bytesSent += parte.accessUnit.count
        lock.unlock()
        session.send(part: parte)
    }

    private func received(_ parte: PartPacket, arrivalNs: Int64) {
        let ahoraMs = Double(DispatchTime.now().uptimeNanoseconds) / 1e6
        lock.lock()
        let decision = receiver.receive(parte, arrivalMs: Int64(ahoraMs))
        beat(ahoraMs)
        maxMbps = max(maxMbps, receiver.mbps(nowMs: Int64(ahoraMs)))
        lock.unlock()
        if case let .awaitingIdr(seq) = decision {
            session.requestIdr(partSeq: seq)
        }
    }

    /// Una señal de vida del esclavo: mide el hueco con la anterior.
    private func beat(_ ms: Double) {
        if let previo = lastArrivalMs {
            let hueco = ms - previo
            worstGapMs = max(worstGapMs, hueco)
            for (i, umbral) in Self.stallMs.enumerated() where hueco > umbral {
                stalls[i] += 1
            }
        }
        lastArrivalMs = ms
    }

    /// Lo que va al informe del link-bench.
    func counters() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let recibidas = receiver.received
        let perdidas = receiver.lost
        let total = recibidas + perdidas
        return [
            "parts_sent": partsSent,
            "parts_bytes_sent": bytesSent,
            "parts_received": recibidas,
            "parts_decodable": receiver.decoded,
            "parts_lost": perdidas,
            // En partes por millón: 0,01 % son 100.
            "parts_loss_ppm": total == 0 ? 0 : perdidas * 1_000_000 / total,
            "parts_idr_requests": receiver.idrRequests,
            "no_parts": noParts,
            "stalls_over_100ms": stalls[0],
            "stalls_over_150ms": stalls[1],
            "worst_gap_ms": Int(worstGapMs.rounded()),
            "parts_jitter_us": Int((receiver.jitterMs * 1000).rounded()),
            "parts_max_mbps_x10": Int((maxMbps * 10).rounded()),
            "battery_start_pct": Int((batteryStart * 100).rounded()),
            "battery_end_pct": Int((UIDevice.current.batteryLevel * 100).rounded()),
            "battery_charging": UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full ? 1 : 0,
        ]
    }

    var profileDescription: String {
        profile.map { String(format: "%.0f", $0) }.joined(separator: ",") + " Mbit/s cada \(Int(stepS)) s"
    }

    private static let view = ViewWire.quantized(ViewCommand(
        targetRigMs: 0, viewId: 0, yawRad: 0, pitchRad: 0, hfovRad: 1, sides: [.left, .right],
        seamYawRad: 0, featherRad: 0.02, gains: .unity
    ))
}

// MARK: - El banco program-split (IOS-43, IOS-44)

// El cosido entre los dos móviles con las cámaras de verdad. Con RIG_SPLIT=1 en el
// entorno del lanzamiento (y el enlace de Network: RIG_LINK_MULTIPEER=0), la pantalla de
// captura normal además:
// - en el ESCLAVO, por cada fotograma del pipeline pinta su parte con la vista que manda
//   el maestro, la codifica y la manda (SlavePartStage);
// - en el MAESTRO, genera a 30 Hz un barrido de guion que cruza la costura (no hay
//   director todavía), lo manda como `view`, compone el programa con la parte en
//   T + PART_MAX_WAIT_MS (MasterProgramStage), lo codifica y lo graba en
//   Documents/bench/program-split-<t>.ts, con un informe JSON al terminar.
//
//   RIG_SPLIT_S             lo que dura (600 por defecto: los 10 min de IOS-44)
//   RIG_SPLIT_PART_MBPS     bitrate de la parte; sin él, LinkConstants según la interfaz
//                           (8 por Wi-Fi, medido el 6-oct; 12 por Ethernet)
//   RIG_SPLIT_SWEEP_DEG     amplitud del barrido en yaw (30)
//   RIG_SPLIT_SWEEP_S       periodo del barrido (20)
//   RIG_SPLIT_HFOV_DEG      el encuadre (60)
//   RIG_SPLIT_DIRECTOR      1: dirige el DirectorService (IOS-73) con las detecciones
//   RIG_SPLIT_SCRIPT        spk04: el director de guion de SPK-04 (Spk04Script: barrido que
//                           cruza la costura cada 20 s y zoom de 40° a 83°, en el reloj del
//                           soporte); manda sobre RIG_SPLIT_DIRECTOR y el barrido de siempre
//   RIG_SPLIT_RECORD_4K     1: graba además la 4K HEVC local de cada móvil (IOS-57) en
//                           Documents/bench4k/<t>/, con la reserva de la pasada y no la del
//                           partido (RecordingPolicy.benchReserveBytes)
//   RIG_SPLIT_PUBLISH       1: el maestro publica además el programa por SRT (IOS-56) al
//                           destino del emparejado con el VPS (el QR Soporte del Keychain,
//                           IOS-68), o al de RIG_SRT_HOST, RIG_SRT_PORT (8890), RIG_SRT_USER,
//                           RIG_SRT_PASS y RIG_SRT_PASSPHRASE si se dan (pruebas). Ninguno de
//                           esos valores sale en el log ni en el informe: solo host y puerto.
//   RIG_LADDER_FORCE        L0..L4: fuerza el objetivo de la escalera de degradación (IOS-06)
//                           en el banco, con RIG_LADDER_FORCE_AT_S (desde, 0),
//                           RIG_LADDER_FORCE_UNTIL_S (hasta; sin él, al final) y
//                           RIG_LADDER_FORCE_SIDE (left o right; sin él, los dos). Ver
//                           LadderForce; EMITIR no lo mira
//   RIG_NOMINAL_YAW_DEG     sin Documents/rig.json, la apertura de cada cámara (DEFAULT_RIG_YAW_DEG)
//   RIG_NOMINAL_HFOV_DEG    y su HFOV (106, la ultra gran angular)
//   RIG_NOMINAL_PITCH_DEG   y su pitch (DEFAULT_RIG_PITCH_DEG)
//
// Para separar de dónde crece la memoria del maestro (2026-10-07 a 2026-10-10):
//   RIG_SPLIT_NO_MOV / RIG_SPLIT_NO_TS   sin la copia .mov / sin el .ts
//   RIG_SPLIT_NO_VIEWS      1: el maestro no manda `view` (sin las vistas a 30 Hz; el
//                           esclavo no pinta ni manda partes)
//   RIG_SPLIT_NO_THUMBS     1: el esclavo no manda su miniatura por control (ThumbHub)
//
// El spike de la duración de fotograma (2026-10-15; la propuesta del ADR 0024 de football-ai:
// mantener la fase entre las cámaras alargando un ~0,1 % los fotogramas del que adelanta).
// Con RIG_SPIKE_FRAME_US el CaptureEngine de un lado alarga su duración de fotograma en
// ventanas del reloj del soporte (FrameDurationSpikePlan):
//   RIG_SPIKE_FRAME_US      la duración alargada: µs (33367) o valor/escala de CMTime
//                           (1001/30000); varias con comas, una por ventana y por turnos
//   RIG_SPIKE_FRAME_SIDE    left | right | alternate (obligatorio)
//   RIG_SPIKE_FRAME_ON_S    lo que dura cada ventana (20)
//   RIG_SPIKE_FRAME_EVERY_S cada cuánto empieza una, en múltiplos del reloj del soporte (120)
//   RIG_SPIKE_FRAME_AFTER_S ninguna antes de estos s de pasada (60)
// El informe de cada lado trae `frame_duration_spike`: la cadencia de su cámara cada 10 s
// (`cadence_by_10s`) y cada cambio pedido con lo que dio la cámara y cuánto tardó
// (`transitions`); el del maestro, además, las ventanas con el movimiento de fase previsto y
// el medido (`windows`) y `halves_phase_by_10s`, la fase en cubos de 10 s de la misma rejilla.
//
// IOS-58: la misma clase es EMITIR en la arquitectura B, con `ProgramRunConfig.production`:
// la arranca startProgram y la para stopProgram, sin fin propio, con el director, el
// detector (si su paquete está en Documents/bench-resources) y el SRT; la copia del programa
// va a Documents/program-<partido>-<t>.mov (IOS-57) y sin el .ts ni las vistas. Lo de medir
// sigue leyéndose del entorno y sin él no hace nada.
//
// «Una cámara (sin pareja)» (2026-10-15, `ProgramRunConfig.single`): la misma pasada de EMITIR
// con un solo móvil, sobre la sesión sola (`RigSoloLink`). Sin parte (ni su codificador ni su
// render), el maestro no espera ninguna, y el director va con el lienzo de su lente desde el
// primer instante (`DirectorLoop.singleCamera`): recorre su lente entera, el plano abierto es el
// más abierto que cabe en ella (en la franja del campo, como con dos) y no pide vistas de la otra
// lente, así que no hay retrocesos que contar. El informe y el latido lo dicen con `single_camera`.
//
// IOS-06 (2026-10-15): la escalera de degradación ACTÚA en el banco y en EMITIR
// (LadderGovernor). Una vez por segundo avanza con los sensores del CaptureEngine y su nivel
// va en el latido. La IA de los dos sigue la peor de las dos escaleras: el maestro la manda
// con la orden `cadence` y cada uno detecta en los instantes k/hz del soporte (DetectionGate);
// con la IA apagada (L2), sin detecciones y el director al plano abierto. L3 baja el bitrate
// del programa ×0,6 (el techo del publicador o, sin él, el codificador). En L4 el esclavo deja
// de pintar su parte y el maestro sigue con una lente. El informe trae `ladder_by_minute`,
// `ladder_ai_by_minute`, `detect_runs_by_minute` y `ladder` (cambios y acciones en vigor).
//
// SPK-04: el maestro escribe además Documents/bench/program-views-<t>.jsonl, una línea por
// instante del programa con la vista de verdad, los fotogramas de cada móvil y la GPU (lo
// que necesita la referencia de REF-41 para el PSNR), y el informe trae en `files` las
// rutas (relativas a Documents) de todo lo grabado en la pasada, para que el banco del Mac
// las recoja sin traer vídeos viejos.

final class SplitBench {
    static func enabled(_ entorno: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        entorno["RIG_SPLIT"] == "1"
    }

    static let fps = 30.0
    static let programWidth = 1920
    static let programHeight = 1080
    static let programBitrateBps = 6_000_000
    /// Cuánto se adelanta la vista que manda el maestro al instante que pinta: el
    /// esclavo tiene que tenerla antes de procesar su fotograma (2 fotogramas).
    static let viewLeadMs: Int64 = 67
    /// Distancia máxima entre el instante pedido y el fotograma propio que se usa.
    static let frameMatchMs: Int64 = 20
    /// El pitch del lienzo del director, en rad: de 0,5 por debajo del horizonte a 0,1 por
    /// encima (el campo, sin cielo). El mismo con dos lentes y con una.
    static let directorPitchLimitsRad = (low: -0.5, high: 0.1)

    private let session: RigLinkSession
    private let side: CameraSide
    private let pipelineProvider: () -> RigPipeline?
    private let env: [String: String]
    /// El banco (del entorno) o EMITIR (IOS-58).
    private let config: ProgramRunConfig
    private let queue = DispatchQueue(label: "io.footballai.zero.split", qos: .userInteractive)
    /// El disco va aparte: escribir el .ts en la cola del tic retrasaba el programa
    /// (IOS-44: tic p5 29,43 fps). En serie, así el orden de los paquetes se conserva.
    private let writerQueue = DispatchQueue(label: "io.footballai.zero.split.writer", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let startNs = DispatchTime.now().uptimeNanoseconds
    /// 2026-10-11: cuándo sube cada pieza del enlace, en ms desde el arranque del banco
    /// (en `…-20261010-1106` el maestro no vio al esclavo hasta los 102 s y no se sabía
    /// por qué), y el arranque en la hora Unix y en el reloj del soporte, para casar los
    /// informes de los dos móviles.
    private let linkTimeline = LinkStartupTimeline()
    private let startHostNs = RigLink.hostNowNs()
    private let startUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
    /// La línea de tiempo del transporte y su cero, para el informe.
    var linkEvents: () -> (createdNs: UInt64, events: [String])? = { nil }
    private let durationS: Double

    // Montado al haber pipeline (sabe el tamaño de la cámara).
    private var rig: RigModel?
    private var rigSource = ""
    private var context: MetalContext?
    private var slave: SlavePartStage?
    private var slaveEncoder: VideoEncoder?
    private var master: MasterProgramStage?
    private var programEncoder: VideoEncoder?
    private let history = ViewHistory()
    /// IOS-73: con RIG_SPLIT_DIRECTOR=1 dirige el director de verdad y no el barrido.
    private var director: DirectorService?
    /// IOS-75: el registro N0 del maestro (Documents/n0/<partido>-<lado>.jsonl).
    private var e0: E0Logger?
    private var e0URL: URL?
    /// SPK-04: el director de guion (RIG_SPLIT_SCRIPT=spk04).
    private var spk04: Spk04Script?
    /// SPK-04: una línea por instante del programa (program-views-<t>.jsonl).
    private var viewsFile: FileHandle?
    private var viewsURL: URL?
    private var viewsPending = Data()
    private var viewsLines = 0
    /// Las líneas que se juntan antes de pasarlas al disco (1 s a 30 fps).
    private static let viewsFlushEvery = 30
    /// SPK-04: la 4K local de este móvil (RIG_SPLIT_RECORD_4K=1). Las abre y cierra el
    /// CaptureEngine; el banco solo sabe la carpeta.
    var startLocal4K: ((String, Int64) -> String)?
    var stopLocal4K: (() -> Void)?
    var local4KFrames: () -> Int64 = { 0 }
    /// Lo que el reloj del soporte hizo con la 4K: fotogramas esperando y segmentos por salto.
    var local4KClock: () -> [String: Any] = { [:] }
    private var rec4kDir: URL?
    private var rec4kStarted = false
    private var rec4kPath = ""
    private var diskFreeStartGb: Double?
    /// La aceptación de SPK-04, para el informe: latencia añadida p95 (ms) y GPU (ms).
    private static let spk04LatencyP95Ms = 120.0
    private static let spk04GpuMs = 3.0
    private static let bytesPerGb = 1e9
    private var e0Ticks = 0
    /// Los cambios de salud del esclavo, para el informe (IOS-81).
    private var peerStates: [String] = []
    /// Una vista de cada 4 tics del programa: los 7,5 Hz del registro.
    static let e0ViewEvery = 4
    // IOS-38: el igualado de color, medido cada `colorEveryMs`.
    private var overlap: OverlapMeans?
    private let matcher = ColorMatcher()
    private var lastColorMs: Int64 = 0
    private var slaveMeans: [Double]?
    private var colorObservations = 0
    static let colorEveryMs: Int64 = 2000
    private var lastProgramT: Int64?
    /// 2026-10-14: el tic en fase con la rejilla, rearmado en cada disparo
    /// (ProgramTickPhase). Con un intervalo repetido la fase se iba 0,075 ms/min.
    private let tickPhase = ProgramTickPhase(framesPerSecond: Int(SplitBench.fps),
                                             marginMs: SplitBench.tickPhaseMarginMs)
    /// La fase de cada tic del maestro frente a la rejilla, en ms: tiene que quedarse en
    /// el margen (2 ms más lo que tarde en despertar).
    private var tickPhaseHist = LatencyHistogram(boundsMs: SplitBench.tickPhaseBoundsMs)
    /// Instantes del programa que no se compusieron porque el tic llegó más de un
    /// fotograma tarde (el ensayo del 2026-10-14 llegó a 570 por minuto).
    private var programSkippedInstants = 0
    /// Instantes del programa sin vista del director: se pintan con la anterior, no con el
    /// barrido de guion (que salía como un salto de plano de un fotograma).
    private var missingDirectorViews = 0
    /// El último instante al que se le pidió vista al director.
    private var lastDirectorT: Int64?
    /// La latencia añadida de cada minuto, [p50, p95] en ms: con la fase a la deriva subía
    /// un fotograma entero al final de la pasada.
    private var latencyByMinute: [[Double]] = []
    private var latencyMinuteFrom = 0
    /// Los saltos de la huella, mirada cada `footprintCheckEveryS`, con lo que pasaba.
    private var footprintJumps = FootprintJumps()
    private var footprintJumpContexts: [[String: Any]] = []
    private var nextFootprintCheckS = 0.0
    /// Lo más que tuvo dentro el codificador del programa (búferes del pool retenidos).
    private var programEncoderInFlightPeak = 0
    /// La huella en cada cambio de salud del esclavo, en paralelo a `peerStates`.
    private var peerStatesFootprintMb: [Double] = []
    /// Lo que le pasa a la app (avisos de memoria, primer plano y fondo), con su segundo y
    /// la huella: el salto del ensayo coincidió con alguien junto al soporte.
    private var appEvents: [String] = []
    private var appObservers: [NSObjectProtocol] = []
    /// El AAC del programa es estéreo (el micro mono va a los dos canales, IOS-54) y el
    /// PMT lo declara desde el primer paquete.
    private static let programAudio = CaptureEngine.audioEnabled
        ? TsMuxer.AudioConfig(sampleRate: AudioConstants.sampleRate, channels: AudioConstants.programChannels)
        : nil
    private let muxer = TsMuxer(audio: SplitBench.programAudio)
    /// IOS-56: el programa por SRT al VPS (RIG_SPLIT_PUBLISH=1), solo mientras se es maestro.
    private var publisher: ProgramPublisher?
    /// De dónde salió el destino («keychain» o «env») y su host:puerto, para el informe.
    private var publishTarget: [String: Any] = [:]
    /// Las estadísticas de cada tramo de maestro que publicó (un relevo abre otro).
    private var publishSessions: [ProgramPublisher.Stats] = []
    /// El puerto SRT de MediaMTX en el VPS (ADR 0022 §1), si RIG_SRT_PORT no dice otro.
    static let srtDefaultPort: UInt16 = 8890
    /// El primer instante de vídeo del .ts: el audio de antes no entra (IOS-54).
    private var firstVideoT: Int64?
    private var tsFile: FileHandle?
    private var tsURL: URL?
    /// La copia .mov del programa, donde quedó (el banco, junto al .ts; EMITIR, IOS-57).
    private var movURL: URL?
    /// IOS-58: el nombre de la pasada de EMITIR: el partido (si lo hay) y la hora.
    private lazy var runId: String = {
        let t = Int(Date().timeIntervalSince1970)
        let partido = (session.matchId ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return partido.isEmpty ? "zero-\(t)" : "\(partido)-\(t)"
    }()
    /// IOS-58: lo que ve la pantalla, rehecho una vez por segundo en el tic.
    private var partBytesSent = 0
    private var partFallbacks = 0
    private var programFpsMeter = RateMeter()
    private var partBytesMeter = RateMeter()
    private var lastStatusNs: UInt64 = 0
    private var statusSnapshot = SplitBench.idleStatus
    // IOS-57: la copia local del programa en .mov (con el audio del micro si lo hay).
    private var recorder: ProgramRecorder?
    /// 2026-10-14: los ficheros de la copia, en orden. Si su escritor falla (disco lleno,
    /// segundo plano), lo escrito queda (fragmentos) y lo que sigue va al siguiente, desde un
    /// IDR. Antes se perdía todo lo que venía después.
    private var movSegments: [URL] = []
    private var movOpenAttempts = 0
    private var movWaitingKeyframe = false
    private var movFailures: [String] = []
    private var movFramesClosed = (video: 0, audio: 0)
    /// Lo más que se intenta abrir la copia: pasado esto, el disco o el escritor no se
    /// arreglan solos y se deja de intentar en cada fotograma.
    private static let movMaxSegments = 8
    /// 2026-10-14: el latido, `Documents/bench/program-live-<lado>-<t>.json`, cada
    /// `liveEveryS`: lo que se sabe de la pasada aunque la app muera antes de PARAR (el
    /// informe de verdad solo se escribe al final).
    private var liveURL: URL?
    private var nextLiveS = 0.0
    private static let liveEveryS = 30.0
    /// La batería (0-1) y el disco libre (GB) una vez por minuto, como la térmica: en la
    /// cancha no hay cable.
    private var batteryByMinute: [Double] = []
    private var diskFreeGbByMinute: [Double] = []
    var audioFormat: () -> CMAudioFormatDescription? = { nil }
    /// La separación entre el reloj de la sesión de captura y el del host, por minuto (ms).
    var captureClockSkew: () -> [Double] = { [] }
    /// 2026-10-14: los descartes de la cámara por motivo (sin búferes, tarde, otros).
    var cameraDrops: () -> [String: Int64] = { [:] }
    /// Los contadores del transporte del enlace, para el informe (nil sin enlace de Network).
    var linkStats: () -> LinkTransportStats? = { nil }
    /// 2026-10-15: por qué no hay enlace, o que lo hay (nil sin enlace de Network). Va en el
    /// latido y en el informe, con la línea de tiempo del transporte: en el plan B de la
    /// cancha el esclavo no enlazó y nada de lo que dejó decía por qué.
    var linkDiagnosis: () -> LinkDiagnosis? = { nil }
    /// Lo que el maestro espera la parte del esclavo, en ms: `PART_MAX_WAIT_MS` del ADR
    /// 0023, o RIG_SPLIT_PART_WAIT_MS para medir otro valor (SPK-04).
    private lazy var partWaitMs: Int64 = env["RIG_SPLIT_PART_WAIT_MS"].flatMap(Int64.init)
        ?? LinkConstants.partMaxWaitMs
    /// Para y reanuda la cámara (IOS-84: RIG_SPLIT_CAM_OFF_S / RIG_SPLIT_CAM_ON_S).
    var cameraSwitch: ((Bool) -> Void)?
    private var cameraOffDone = false
    private var forceDone = false
    /// IOS-38: el desajuste de exposición del esclavo (RIG_SPLIT_EV a los RIG_SPLIT_EV_AT_S s).
    var exposureBias: ((Double) -> Void)?
    /// 2026-10-15: el spike de la duración de fotograma (RIG_SPIKE_FRAME_*): el plan, o por
    /// qué no se armó, y lo que se le pidió a la cámara de este lado. Lo aplica el
    /// CaptureEngine: armarlo con los fps nominales, pedir una duración (nil: la nominal) en
    /// el segundo de pasada y el instante del soporte, y leer lo que midió.
    private var frameSpikePlan: FrameDurationSpikePlan?
    private var frameSpikeError = ""
    private var frameSpikeCurrent: FrameDuration?
    var frameSpikeArm: ((Int) -> Void)?
    var frameDurationRequest: ((FrameDuration?, Double, Int64) -> Void)?
    var frameSpikeReport: () -> [String: Any] = { [:] }
    /// Lo que el desajuste aplicó de verdad (ISO y obturación antes y después).
    var exposureApplied: [String: Double] = [:]
    private var evDone = false
    /// IOS-38: [segundo, diferencia de luminancia en bruto, con las ganancias] por observación.
    private var colorSeries: [[Double]] = []
    /// IOS-48: el cue de la franja una vez por segundo y los overrides programados
    /// (RIG_ADS_OVERRIDES="gol:2@30,gol:1@200": nombre, vueltas y segundo del banco).
    private var adCues: [[Any]] = []
    private var lastAdCueT: Int64?
    private var adOverridesDone: [[String: Any]] = []
    /// La huella del proceso una vez por minuto, en MB: que no crezca (IOS-47/48).
    private var footprintMb: [Double] = []
    private var thermalByMinute: [String] = []
    private var sendAge = LatencyHistogram(boundsMs: MasterProgramStage.partAgeBoundsMs)
    private var cameraAge = LatencyHistogram(boundsMs: MasterProgramStage.partAgeBoundsMs)
    private var slaveRender = LatencyHistogram()
    /// La carga del detector de jugadores en el maestro (RIG_DETECT=<paquete>).
    private lazy var detect: BenchDetector? = {
        guard let paquete = config.detectorPackage else { return nil }
        // RIG_DETECT_CHAIN=vision: la carga de Vision; por defecto, la cadena de producción.
        if env["RIG_DETECT_CHAIN"] == "vision" { return DetectLoad(package: paquete) }
        return MetalDetectLoad(package: paquete, side: side)
    }()
    // MARK: IOS-06: la escalera actuando

    /// Lo que piden los sensores ahora, sin histéresis (térmica, presión de la cámara y
    /// carga). Lo da el CaptureEngine, que observa la presión del dispositivo; sin él, la
    /// térmica y la carga.
    var ladderSensors: () -> LadderLevel = {
        DegradationLadder.target(thermal: ThermalMonitor.level(from: ProcessInfo.processInfo.thermalState),
                                 pressure: .nominal, charging: UIDevice.current.batteryState != .unplugged)
    }
    private var governor: LadderGovernor
    /// Las acciones en vigor, rehechas en cada paso y con cada noticia del otro móvil.
    private var ladderActions = LadderActions.actions(for: .l0, role: .master)
    /// Qué instante de la rejilla toca detectar, a la cadencia de la escalera común.
    private var detectGate = DetectionGate(frameDurationMs: 1000 / SplitBench.fps)
    private var nextLadderS = 0.0
    private var lastLadderStepNs: UInt64?
    /// El nivel del último latido del otro, y si está caído (IOS-81): caído, no cuenta.
    private var peerLadderHeard: LadderLevel?
    private var peerDown = false
    /// La última orden `cadence` del maestro y cuándo salió, en s de la pasada.
    private var cadenceSent: LadderLevel?
    private var cadenceSentAtS = -Double.infinity
    private var cadenceCommandsSent = 0
    private var cadenceCommandsReceived = 0
    /// El maestro va con una lente (esclavo caído o en L4): lo último aplicado.
    private var singleLensApplied = false
    /// El factor del bitrate del programa ya aplicado (al techo del publicador o al codificador).
    private var programBitrateFactorApplied: Double?
    /// L4 en el esclavo: su parte, parada. Se lee en el hilo del pipeline, tras `lock`.
    private var partPaused = false
    private var partFramesPaused = 0
    /// Por minuto, como la térmica: el nivel de este móvil, el de su IA (el común) y las
    /// detecciones acumuladas.
    private var ladderByMinute: [Int] = []
    private var ladderAiByMinute: [Int] = []
    private var detectRunsAtMinute: [Int] = []
    /// Cada cambio de la escalera (la propia, la del otro, la común o la orden), con su
    /// instante y lo que se aplicó; acotado a `maxLadderChanges`.
    private var ladderChanges: [[String: Any]] = []
    private var ladderChangesDropped = 0
    private var ladderMark: LadderMark?
    private static let maxLadderChanges = 256
    /// Los últimos cambios que van en el latido.
    private static let liveLadderChanges = 20
    /// Instantes de detección sin un fotograma a ≤½ fotograma en el anillo.
    private var detectMissingFrame = 0
    /// El nivel de la escalera de este móvil para la pantalla (tras `lock`).
    private var ladderLevelShown = LadderLevel.l0

    /// Lo que se apunta como cambio de la escalera.
    private struct LadderMark: Equatable {
        var level: LadderLevel
        var ai: LadderLevel
        var peer: LadderLevel?
        var commanded: LadderLevel?
        var forced: Bool
        var master: Bool
    }

    /// IOS-64: la CPU del proceso al arrancar el banco, para su coste medio en el informe.
    private let cpuStartS = SplitBench.processCpuSeconds()
    private var cameraOnDone = false
    private var finished = false
    /// Por qué no se montó el programa (IOS-58: la pantalla lo dice).
    private var setUpProblem = ""

    // Medidas
    private var tickIntervalsMs: [Double] = []
    private var lastTickNs: UInt64?
    private var composeLatencyMs: [Double] = []
    private var programFrames = 0

    init(session: RigLinkSession, side: CameraSide, pipeline: @escaping () -> RigPipeline?,
         environment: [String: String] = ProcessInfo.processInfo.environment, config: ProgramRunConfig? = nil) {
        self.session = session
        self.side = side
        pipelineProvider = pipeline
        env = environment
        let ajustes = config ?? .bench(environment: environment)
        self.config = ajustes
        durationS = ajustes.durationS
        governor = LadderGovernor(force: ajustes.ladderForce.flatMap { $0.applies(to: side) ? $0 : nil })
        do {
            frameSpikePlan = try FrameDurationSpikePlan.parse(environment: environment)
        } catch {
            frameSpikeError = "\(error)"
            NSLog("[split] spike de la duración de fotograma sin armar: %@", frameSpikeError)
        }
    }

    private func number(_ key: String, _ def: Double) -> Double {
        env[key].flatMap(Double.init) ?? def
    }

    /// Una trama AAC del programa (micro o silencio; RIG_AUDIO=0 la quita): a la copia local.
    func audio(_ trama: AacFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            try? recorder?.append(audio: trama)
            // IOS-56: al publicador, todas; él espera al primer IDR.
            publisher?.audio(aacRaw: Data(trama.adts.dropFirst(Adts.headerLength)), rigMs: trama.rigMs)
            // IOS-54: el AAC también en el programa .ts, en el mismo eje que el vídeo
            // (rigMs × 90). El primer fotograma sale del codificador después de su
            // instante: hasta saberlo, las tramas esperan en una cola acotada (si se
            // llena, se tira la más vieja), y entran desde media trama antes de él.
            audioWaiting.append(trama)
            if audioWaiting.count > Self.audioWaitSlots { audioWaiting.removeFirst() }
            guard let primero = firstVideoT, let ts = tsFile else { return }
            let mediaTramaMs = 500 * Double(AudioConstants.samplesPerFrame) / Double(AudioConstants.sampleRate)
            for t in audioWaiting where t.rigMs >= Double(primero) - mediaTramaMs {
                let crudo = t.adts.dropFirst(Adts.headerLength)
                if let datos = try? muxer.muxAudio(aacRaw: Data(crudo), pts90k: Int64((t.rigMs * 90).rounded())) {
                    writerQueue.async { try? ts.write(contentsOf: datos) }
                    tsAudioFrames += 1
                }
            }
            audioWaiting.removeAll(keepingCapacity: true)
        }
    }
    /// Lo que espera el audio al primer fotograma: AudioConstants.encodedQueueSlots (~1,4 s).
    private static let audioWaitSlots = AudioConstants.encodedQueueSlots
    private var audioWaiting: [AacFrame] = []
    private var tsAudioFrames = 0

    func start() {
        // El spike de la duración de fotograma: la cadencia de la cámara se mide desde ya.
        if frameSpikePlan != nil { frameSpikeArm?(Int(Self.fps)) }
        // .strict: el sistema no agrupa los disparos para ahorrar energía.
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        // Cada disparo, justo después de un punto de la rejilla del programa: el tic
        // compone `rejilla(ahora − espera)`, y si cae a mitad de fotograma la latencia
        // añadida crece hasta un fotograma entero (p50 de 107 a 137 ms entre pasadas
        // iguales). Se rearma en cada disparo para el siguiente punto más el margen
        // (ProgramTickPhase): con `repeating`, GCD trunca el intervalo a ticks de mach y la
        // fase se iba 0,075 ms por minuto (2026-10-14: a los 40 min se perdían vistas del
        // director, a los 80 instantes del programa, y la latencia subía 33 ms).
        t.setEventHandler { [weak self, weak t] in
            guard let self else { return }
            self.tick()
            if let t { self.armTick(t) }
        }
        timer = t
        armTick(t)
        t.resume()
        observeApp()
        session.onViews = { [weak self] vistas in
            self?.linkTimeline.mark(.firstView)
            self?.slave?.receive(views: vistas)
        }
        session.onIdrRequest = { [weak self] _ in self?.slave?.requestIdr() }
        session.onPart = { [weak self] parte, _ in
            guard let self else { return }
            linkTimeline.mark(.firstPart)
            master?.receive(part: parte, arrivalRigMs: rigNowMs())
        }
        session.onNoPart = { [weak self] nada in self?.master?.receive(noPart: nada) }
        // IOS-81: con el esclavo caído, una lente y sin esperar su parte; al volver, las dos.
        // IOS-06: caído, su escalera no cuenta, y en el esclavo la orden del maestro caduca.
        session.onPeerState = { [weak self] estado in
            self?.queue.async {
                guard let self else { return }
                self.peerDown = estado == .down
                if self.peerDown { self.governor.setCommanded(level: nil) }
                if self.session.isMaster {
                    self.peerStates.append("\(self.rigNowMs()):\(estado.rawValue)")
                    self.peerStatesFootprintMb.append(Self.footprintMb())
                    if estado == .up { self.linkTimeline.mark(.peerUp) }
                }
                self.applyLadder()
            }
        }
        // IOS-06: el nivel del otro, de su latido; y en el esclavo, la cadencia común.
        session.onPeerLadder = { [weak self] nivel in
            self?.queue.async {
                guard let self else { return }
                self.peerLadderHeard = LadderLevel(rawValue: Int(nivel))
                self.applyLadder()
            }
        }
        session.onCadence = { [weak self] orden in
            self?.queue.async {
                guard let self else { return }
                self.cadenceCommandsReceived += 1
                self.governor.setCommanded(level: orden.level)
                self.applyLadder()
            }
        }
        session.onColorMeans = { [weak self] bgr in
            self?.queue.async { self?.slaveMeans = bgr }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { finish() }
    }

    static func nowMs() -> Int64 { RigLink.hostNowNs() / 1_000_000 }

    /// El instante en el reloj del soporte: el host más el desfase del RigClock. En el
    /// maestro de siempre el desfase es 0; en un esclavo promovido (IOS-85) no, y el anillo
    /// de fotogramas está sellado en este reloj: con la hora de host, el promovido no
    /// encontraba sus propios fotogramas y salía SIN SEÑAL.
    func rigNowMs() -> Int64 {
        let ns = RigLink.hostNowNs()
        return (ns + session.clock.offsetAt(ns: ns)) / 1_000_000
    }

    /// El siguiente disparo del tic: el próximo punto de la rejilla del programa más el
    /// margen, en el reloj del soporte. Uno cada vez, sin intervalo que acumule deriva; y
    /// si el reloj del soporte cambia (un relevo), el siguiente ya va con el nuevo.
    private func armTick(_ t: DispatchSourceTimer) {
        guard !finished else { return }
        let ns = RigLink.hostNowNs()
        let espera = tickPhase.delayToNextTickNs(nowRigNs: ns + session.clock.offsetAt(ns: ns))
        t.schedule(deadline: .now() + .nanoseconds(Int(espera)), leeway: .milliseconds(1))
    }

    // MARK: - 2026-10-14: la huella con su instante

    /// Avisos de memoria y cambios de primer plano, con su segundo y la huella.
    private func observeApp() {
        let sucesos: [(Notification.Name, String)] = [
            (UIApplication.didReceiveMemoryWarningNotification, "aviso de memoria"),
            (UIApplication.willResignActiveNotification, "deja de estar activa"),
            (UIApplication.didBecomeActiveNotification, "activa"),
            (UIApplication.didEnterBackgroundNotification, "al fondo"),
            (UIApplication.willEnterForegroundNotification, "vuelve del fondo"),
        ]
        for (nombre, texto) in sucesos {
            appObservers.append(NotificationCenter.default.addObserver(forName: nombre, object: nil, queue: nil) {
                [weak self] _ in
                self?.queue.async { self?.noteAppEvent(texto) }
            })
        }
    }

    private func noteAppEvent(_ texto: String) {
        guard appEvents.count < Self.maxAppEvents else { return }
        let s = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        appEvents.append(String(format: "%.1f [%.0f MB] ", s, Self.footprintMb()) + texto)
    }

    /// Cada `footprintCheckEveryS`: la huella y, si saltó, lo que pasaba en ese momento.
    private func sampleFootprint(_ transcurrido: Double) {
        guard transcurrido >= nextFootprintCheckS else { return }
        nextFootprintCheckS = transcurrido + Self.footprintCheckEveryS
        let picoPrograma = programEncoder?.takeInFlightPeak() ?? 0
        let picoParte = slaveEncoder?.takeInFlightPeak() ?? 0
        programEncoderInFlightPeak = max(programEncoderInFlightPeak, picoPrograma)
        guard let salto = footprintJumps.sample(mb: Self.footprintMb(), atS: transcurrido) else { return }
        var contexto: [String: Any] = [
            "s": salto.atS, "rig_ms": rigNowMs(), "from_mb": salto.fromMb, "to_mb": salto.toMb,
            "role": session.isMaster ? "master" : "slave",
            "thermal": Self.thermalName(ProcessInfo.processInfo.thermalState),
            "peer": peerStates.last ?? "",
            // Lo más que tuvieron dentro los codificadores en estos segundos: cada fotograma
            // retiene un búfer del pool de quien lo pintó.
            "program_encoder_in_flight_peak": picoPrograma,
            "part_encoder_in_flight_peak": picoParte,
            "program_frames": programFrames,
            "program_skipped_instants": programSkippedInstants,
            "missing_director_views": missingDirectorViews,
            "detect_runs": detect?.runCount ?? 0,
            "overlay_uploads": OverlayHub.shared?.uploads ?? 0,
            "camera_drops": cameraDrops(),
            "app_events": Array(appEvents.suffix(Self.appEventsInJump)),
        ]
        if let m = master {
            let st = m.stats
            contexto["two_lens_frames"] = st.twoLensFrames
            contexto["one_lens_frames"] = st.oneLensFrames
            contexto["parts_decoded"] = st.partsDecoded
            contexto["idr_requests"] = st.idrRequests
            contexto["compose_failures"] = st.composeFailures
            contexto["without_master_frame"] = st.withoutMasterFrame
        }
        if let s = slave {
            contexto["slave_parts"] = s.stats.parts
            contexto["slave_no_parts"] = s.stats.noParts
        }
        footprintJumpContexts.append(contexto)
        NSLog("[split] la huella saltó de %.0f a %.0f MB a los %.0f s", salto.fromMb, salto.toMb, salto.atS)
    }

    /// Cierra la latencia añadida del minuto que acaba: [p50, p95] en ms ([] sin programa).
    private func closeLatencyMinute() {
        let tramo = composeLatencyMs[latencyMinuteFrom...].sorted()
        latencyMinuteFrom = composeLatencyMs.count
        guard !tramo.isEmpty else {
            latencyByMinute.append([])
            return
        }
        func q(_ p: Double) -> Double { tramo[min(tramo.count - 1, Int(p * Double(tramo.count)))] }
        latencyByMinute.append([q(0.5), q(0.95)])
    }

    // MARK: - Montaje

    private func setUpIfNeeded() -> Bool {
        if rig != nil { return true }
        guard let pipeline = pipelineProvider() else { return false }
        let ring = pipeline.ring
        do {
            let (modelo, fuente) = try Self.loadRig(width: ring.width, height: ring.height, env: env)
            guard let ctx = MetalContext() else { return false }
            rig = modelo
            rigSource = fuente
            context = ctx
            overlap = OverlapMeans(rig: modelo, side: side, width: ring.width, height: ring.height,
                                   mountedUpsideDown: side == .left)

            // Esclavo: su parte. «Una cámara» no tiene a quién mandarla.
            if !config.singleCamera {
                let enc = try VideoEncoder(
                    width: Self.programWidth, height: Self.programHeight,
                    bitrateBps: config.partBitrateBps, viewId: side == .left ? 0 : 1
                )
                let s = SlavePartStage(
                    side: side,
                    resolver: SlaveViewResolver(frameDurationMs: 1000 / Self.fps),
                    renderer: try MetalPartRenderer(context: ctx, rig: modelo, side: side,
                                                    width: Self.programWidth, height: Self.programHeight),
                    encoder: enc
                )
                // RIG_SPLIT_SLAVE_NO_PARTS=1: el esclavo renderiza y codifica igual, pero manda
                // «sin parte» en lugar de la parte. El maestro sigue con el enlace vivo y sin
                // partes ni decodificador: separa la fuga de memoria de esos dos (2026-10-10).
                let soloSinParte = env["RIG_SPLIT_SLAVE_NO_PARTS"] == "1"
                s.onPart = { [weak self] p in
                    guard let self else { return }
                    linkTimeline.mark(.firstPartSent)
                    if soloSinParte {
                        session.send(noPart: NoPartPacket(frameRigMs: p.frameRigMs, viewId: p.view.viewId))
                        return
                    }
                    // IOS-43: la edad de la parte al salir del esclavo (captura → render →
                    // codificado), en el reloj del soporte. La de llegada menos esta es la red.
                    let ns = RigLink.hostNowNs()
                    let rig = (ns + session.clock.offsetAt(ns: ns)) / 1_000_000
                    lock.lock()
                    sendAge.record(ms: Double(rig - p.frameRigMs))
                    partBytesSent += p.accessUnit.count
                    lock.unlock()
                    session.send(part: p)
                }
                s.onNoPart = { [weak self] n in self?.session.send(noPart: n) }
                slaveEncoder = enc
                slave = s
                pipeline.onFrame = { [weak self] meta in self?.slaveFrame(meta, ring: ring) }
            }

            // Maestro: el programa.
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: Self.programWidth, kCVPixelBufferHeightKey: Self.programHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &pool)
            guard let pool else { return false }
            let m = MasterProgramStage(
                masterSide: side, frameDurationMs: 1000 / Self.fps,
                renderer: try MetalPartRenderer(context: ctx, rig: modelo, side: side,
                                                width: Self.programWidth, height: Self.programHeight),
                composer: try {
                    let c = try MetalProgramComposer(context: ctx, masterSide: side,
                                                     width: Self.programWidth, height: Self.programHeight)
                    c.overlay = OverlayHub.shared  // el marcador de Dart (IOS-47)
                    c.ads = AdHub.rotation         // la franja (IOS-48)
                    return c
                }(),
                masterPool: pool,
                maxWaitMs: partWaitMs
            )
            // IOS-48: con RIG_ADS=<fichero JSON en Documents/ads>, la lista del banco.
            if let fichero = env["RIG_ADS"],
               let raiz = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true),
               let json = try? String(contentsOf: raiz.appendingPathComponent("ads/\(fichero)"), encoding: .utf8) {
                do { try AdHub.apply(json: json) } catch { NSLog("[split] anuncios: %@", "\(error)") }
            }
            m.masterFrame = { ms in
                guard let lease = ring.acquire(nearest: ms, maxDistanceMs: Self.frameMatchMs) else { return nil }
                return (lease.buffer, lease.rigMs, { ring.release(lease) })
            }
            if config.benchFiles { m.onComposed = { [weak self] f in self?.logComposed(f) } }
            m.onIdrRequest = { [weak self] seq in self?.session.requestIdr(partSeq: seq) }
            // SPK-04 (2026-10-14): la fase entre las cámaras por minuto de la pasada; y
            // (2026-10-15) en cubos de 10 s de la rejilla del reloj del soporte, los mismos que
            // la cadencia del spike de la duración de fotograma.
            let inicioFase = (startHostNs + session.clock.offsetAt(ns: startHostNs)) / 1_000_000
            m.halvesPhase = HalvesPhaseTracker(startRigMs: inicioFase, frameDurationMs: 1000 / Self.fps)
            m.halvesPhaseBy10s = HalvesPhaseTracker(
                startRigMs: HalvesPhaseTracker.gridStart(inicioFase, bucketMs: HalvesPhaseTracker.fineBucketMs),
                frameDurationMs: 1000 / Self.fps, bucketMs: HalvesPhaseTracker.fineBucketMs,
                maxBuckets: HalvesPhaseTracker.fineMaxBuckets
            )
            // IOS-84: sin ninguna cámara, la tarjeta SIN SEÑAL (la sube Dart, oculta).
            m.onSourceChange = { fuente in OverlayHub.shared?.setVisible(.slate, fuente == .noSignal) }
            // «Una cámara»: una lente desde el principio, sin esperar ninguna parte.
            if config.singleCamera {
                m.peerDown = true
                singleLensApplied = true
            }
            if env["RIG_SPLIT_SCRIPT"] == "spk04" {
                spk04 = Spk04Script(rig: modelo)
            } else if config.singleCamera, config.director {
                let loop = try DirectorLoop.singleCamera(
                    rig: modelo, side: side, pitchLimitsRad: Self.directorPitchLimitsRad,
                    width: Self.programWidth, height: Self.programHeight, plan: ShotPlan.at(),
                    frameDurationMs: 1000 / Self.fps
                )
                director = DirectorService(loop: loop, soloSide: side)
            } else if config.director {
                let loop = try DirectorLoop(
                    rig: modelo, canvas: CylindricalCanvas.fit(modelo, pitchLimitsRad: Self.directorPitchLimitsRad),
                    width: Self.programWidth, height: Self.programHeight, plan: ShotPlan.at(),
                    frameDurationMs: 1000 / Self.fps
                )
                let d = DirectorService(loop: loop)
                let otroLado: CameraSide = side == .left ? .right : .left
                session.onDetections = { [weak d] t, _, cajas in
                    d?.receive(side: otroLado, targetRigMs: t, detections: cajas)
                }
                director = d
            }
            m.onProgram = { [weak self] buffer, t in self?.program(buffer, t: t) }
            master = m
            if let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) {
                let produccion = config.purpose == .production
                // IOS-58: en EMITIR, el partido y el dominio del reloj de verdad.
                let id = produccion ? runId : "banco-\(Int(Date().timeIntervalSince1970))"
                let url = docs.appendingPathComponent("n0/\(id)-\(side.rawValue).jsonl")
                e0URL = url
                e0 = try? E0Logger(
                    url: url,
                    header: .header(matchId: id, rigId: produccion ? "soporte" : "banco",
                                    // El dominio del reloj de host de este arranque (ADR 0023 §4).
                                    clockDomain: produccion ? RigClockDomain.current()
                                        : "banco" + String(format: "%08x", UInt32.random(in: .min ... .max)),
                                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                                    models: [], rigSha: nil, pitchSha: nil, bandSha: nil)
                )
            }
            programEncoder = try VideoEncoder(
                width: Self.programWidth, height: Self.programHeight,
                bitrateBps: Self.programBitrateBps, viewId: 0
            )
            return true
        } catch {
            NSLog("[split] no se pudo montar: %@", "\(error)")
            setUpProblem = "no se pudo montar el programa: \(error)"
            return false
        }
    }

    /// Documents/rig.json si lo hay (la calibración); si no, un soporte nominal.
    static func loadRig(width: Int, height: Int, env: [String: String]) throws -> (RigModel, String) {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let fichero = docs.appendingPathComponent("rig.json")
        if FileManager.default.fileExists(atPath: fichero.path) {
            return (try RigModel.load(from: fichero), "rig.json")
        }
        let grados = { (k: String, d: Double) in (env[k].flatMap(Double.init) ?? d) * .pi / 180 }
        let intr = try CameraIntrinsics.fromHfov(width: width, height: height,
                                                 hfovRad: grados("RIG_NOMINAL_HFOV_DEG", 106))
        // Las de partida de la referencia (DEFAULT_RIG_*): la calibración las corrige.
        let yaw = grados("RIG_NOMINAL_YAW_DEG", RigConstants.defaultRigYawDeg)
        let pitch = grados("RIG_NOMINAL_PITCH_DEG", RigConstants.defaultRigPitchDeg)
        return (RigModel(
            left: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: -yaw, pitchRad: pitch)),
            right: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: yaw, pitchRad: pitch))
        ), "nominal")
    }

    // MARK: - Esclavo

    private func slaveFrame(_ meta: RigPipeline.FrameMeta, ring: FrameRing) {
        guard !session.isMaster, case .connected = session.state, let slave else { return }
        // IOS-06: en L4 el esclavo deja de pintar y codificar su parte.
        lock.lock()
        let pausada = partPaused
        if pausada { partFramesPaused += 1 }
        lock.unlock()
        guard !pausada else { return }
        let ms = meta.rigNs / 1_000_000
        // IOS-43: la edad del fotograma al llegar a la app (el retraso de la cámara) y lo
        // que tarda el render en volver (la codificación sigue, asíncrona).
        let ns = RigLink.hostNowNs()
        let ahora = (ns + session.clock.offsetAt(ns: ns)) / 1_000_000
        guard let lease = ring.acquire(nearest: ms, maxDistanceMs: 1) else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        slave.process(frame: lease.buffer, frameRigMs: ms, ptsNs: meta.ptsNs)
        let renderMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        ring.release(lease)
        lock.lock()
        cameraAge.record(ms: Double(ahora - ms))
        slaveRender.record(ms: renderMs)
        lock.unlock()
    }

    // MARK: - Maestro

    /// El barrido de guion: un seno en yaw que cruza la costura, a pitch y HFOV fijos; con
    /// RIG_SPLIT_SCRIPT=spk04, el de SPK-04 (Spk04Script), que además abre y cierra el zoom.
    private func scriptedView(_ t: Int64) -> ViewCommand {
        guard let rig else { fatalError("sin soporte") }
        let a = number("RIG_SPLIT_SWEEP_DEG", 30) * .pi / 180
        let periodo = number("RIG_SPLIT_SWEEP_S", 20)
        var hfov = number("RIG_SPLIT_HFOV_DEG", 60) * .pi / 180
        var costura = (rig.camera(.left).pose.yawRad + rig.camera(.right).pose.yawRad) / 2
        var pitch = (rig.camera(.left).pose.pitchRad + rig.camera(.right).pose.pitchRad) / 2
        var yaw = costura + a * sin(2 * .pi * Double(t) / 1000 / periodo)
        if let guion = spk04 {
            (yaw, hfov) = guion.pose(atRigMs: t)
            costura = guion.seamYawRad
            pitch = guion.pitchRad
        }
        let lados: [CameraSide]
        if config.singleCamera {
            // «Una cámara»: sin barrido que cruce a la otra lente; quieta, al centro de la suya.
            yaw = rig.camera(side).pose.yawRad
            pitch = rig.camera(side).pose.pitchRad
            lados = [side]
        } else if let v = try? RectilinearView(yawRad: yaw, pitchRad: pitch, hfovRad: hfov,
                                               width: Self.programWidth, height: Self.programHeight) {
            lados = sidesFor(rig: rig, view: v)
        } else {
            lados = [.left, .right]
        }
        return ViewWire.quantized(ViewCommand(
            targetRigMs: t, viewId: UInt32(truncatingIfNeeded: t / 33), yawRad: yaw, pitchRad: pitch,
            hfovRad: hfov, sides: lados, seamYawRad: costura,
            featherRad: RigConstants.panoramaFeatherRad, gains: matcher.gains
        ))
    }

    /// La media del solape de la cámara propia, del último fotograma del anillo.
    private func ownMeans() -> [Double]? {
        guard let ring = pipelineProvider()?.ring, let overlap,
              let ultimo = ring.availableRigMs().last,
              let lease = ring.acquire(nearest: ultimo, maxDistanceMs: 0)
        else { return nil }
        defer { ring.release(lease) }
        return overlap.measure(lease.buffer)
    }

    /// Cada `colorEveryMs`: el esclavo manda su media; el maestro iguala con la suya.
    private func colorTick(now: Int64) {
        guard now - lastColorMs >= Self.colorEveryMs, let mias = ownMeans() else { return }
        lastColorMs = now
        if session.isMaster {
            guard let suyas = slaveMeans else { return }
            let (izq, der) = side == .left ? (mias, suyas) : (suyas, mias)
            matcher.observe(meanLeft: izq, meanRight: der)
            colorObservations += 1
            // Luma de unas medias BGR (BT.601) y su diferencia relativa en el solape.
            func luma(_ m: [Double]) -> Double { 0.114 * m[0] + 0.587 * m[1] + 0.299 * m[2] }
            func dif(_ a: Double, _ b: Double) -> Double { abs(a - b) / max((a + b) / 2, 1e-6) }
            let g = matcher.gains
            let conIzq = zip(izq, g.left).map(*), conDer = zip(der, g.right).map(*)
            colorSeries.append([Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9,
                                dif(luma(izq), luma(der)), dif(luma(conIzq), luma(conDer))])
        } else {
            session.send(colorMeans: mias)
        }
    }

    private func tick() {
        guard !finished else { return }
        let transcurrido = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        if transcurrido > durationS {
            finish()
            return
        }
        if let off = env["RIG_SPLIT_CAM_OFF_S"].flatMap(Double.init), transcurrido >= off, !cameraOffDone {
            cameraOffDone = true
            cameraSwitch?(false)
        }
        if let on = env["RIG_SPLIT_CAM_ON_S"].flatMap(Double.init), transcurrido >= on, !cameraOnDone {
            cameraOnDone = true
            cameraSwitch?(true)
        }
        scheduledAdOverrides(transcurrido: transcurrido)
        if let ev = env["RIG_SPLIT_EV"].flatMap(Double.init), let a = env["RIG_SPLIT_EV_AT_S"].flatMap(Double.init),
           transcurrido >= a, !evDone, !session.isMaster {
            evDone = true
            exposureBias?(ev)
        }
        // IOS-85: el operador pulsa «Este móvil dirige» en el esclavo con el enlace caído.
        if let a = env["RIG_SPLIT_FORCE_AT_S"].flatMap(Double.init), transcurrido >= a, !forceDone,
           !session.isMaster {
            if case .connected = session.state {} else {
                forceDone = true
                session.forceMaster { t in NSLog("[split] relevo forzado: term %d", t ?? -1) }
            }
        }
        stepLadder(transcurrido)
        stepFrameSpike(transcurrido)
        if transcurrido >= Double(footprintMb.count) * Self.footprintEveryS {
            // 2026-10-14: la latencia del minuto que acaba (la primera muestra abre el 0).
            if !footprintMb.isEmpty { closeLatencyMinute() }
            footprintMb.append(Self.footprintMb())
            // IOS-06: la escalera de este móvil, la de su IA y las detecciones hasta ahora.
            ladderByMinute.append(governor.level.rawValue)
            ladderAiByMinute.append(governor.aiLevel(isMaster: session.isMaster).rawValue)
            detectRunsAtMinute.append(detect?.runCount ?? 0)
            // SPK-54: el estado térmico, una vez por minuto.
            thermalByMinute.append(Self.thermalName(ProcessInfo.processInfo.thermalState))
            batteryByMinute.append(Double(UIDevice.current.batteryLevel))
            diskFreeGbByMinute.append(Double(CaptureEngine.freeDiskBytes()) / Self.bytesPerGb)
        }
        sampleFootprint(transcurrido)
        if transcurrido >= nextLiveS {
            nextLiveS = transcurrido + Self.liveEveryS
            writeLive(transcurrido: transcurrido, finished: false)
        }
        refreshStatus()
        // SPK-04: la 4K local, en cuanto hay cámara (antes, el CaptureEngine no sabe el tamaño).
        if config.record4K, !rec4kStarted, pipelineProvider() != nil {
            startRecording4K()
        }
        if case .connected = session.state { linkTimeline.mark(.sessionUp) }
        if case .connected = session.state, setUpIfNeeded() {
            colorTick(now: rigNowMs())
        }
        updatePublisher()
        // El esclavo detecta aquí; el maestro, después de componer: preparar la franja y
        // mandarla al runner antes de componer retrasaba el programa (latencia p95 de 114 a
        // 139 ms con los dos iPhone).
        if !session.isMaster { detectTick() }
        // El maestro compone SIEMPRE, con enlace o sin él (IOS-81: el programa no se
        // para porque caiga el esclavo); las vistas solo salen si hay sesión.
        guard session.isMaster, setUpIfNeeded(), let master else {
            return
        }
        let ahora = DispatchTime.now().uptimeNanoseconds
        if let previo = lastTickNs { tickIntervalsMs.append(Double(ahora - previo) / 1e6) }
        lastTickNs = ahora

        let ahoraNs = RigLink.hostNowNs()
        let ahoraRigNs = ahoraNs + session.clock.offsetAt(ns: ahoraNs)
        let now = ahoraRigNs / 1_000_000
        tickPhaseHist.record(ms: tickPhase.phaseMs(nowRigNs: ahoraRigNs))
        // La rejilla del programa: instantes k · 33,3 ms (ProgramClock, IOS-84).
        let reloj = ProgramClock(frameDurationMs: 1000 / Self.fps)
        let rejilla = { (ms: Int64) in reloj.gridInstant(atOrBefore: ms) }
        if let director {
            director.setGains(matcher.gains)
            // Un instante de la rejilla por vista: si el tic se saltó alguno (llegó tarde),
            // el director da también los de en medio. Si el reloj del soporte va hacia atrás
            // (un relevo), se empieza de nuevo.
            let objetivo = rejilla(now + Self.viewLeadMs)
            if let ultimo = lastDirectorT, objetivo < ultimo { lastDirectorT = nil }
            for instante in reloj.gridInstants(after: lastDirectorT, through: objetivo,
                                               limit: Self.directorCatchUpInstants) {
                if let (_, hist) = try? director.tick(targetRigMs: instante) {
                    hist.forEach { if history.view(at: $0.targetRigMs) == nil { history.append(ViewWire.quantized($0)) } }
                }
                lastDirectorT = instante
            }
        } else {
            history.append(scriptedView(rejilla(now + Self.viewLeadMs)))
        }
        if env["RIG_SPLIT_NO_VIEWS"] != "1" {
            session.send(views: history.message())
        }

        // El programa va siempre al mismo retraso, con el esclavo o sin él (IOS-81): sin
        // esperar, el instante «ahora» aún no tiene fotograma propio (salía SIN SEÑAL) y
        // el programa saltaba 100 ms adelante y atrás al caer y volver el par. Con el par
        // caído, lo que cambia es que MasterProgramStage no espera sus partes.
        let t = rejilla(now - partWaitMs)
        guard t != lastProgramT else { return }
        if let previo = lastProgramT, t > previo {
            let saltados = Int((Double(t - previo) * Self.fps / 1000).rounded()) - 1
            if saltados > 0 { programSkippedInstants += saltados }
        }
        lastProgramT = t
        let inicio = DispatchTime.now().uptimeNanoseconds
        let vistaPropia: ViewCommand
        if let v = history.view(at: t) {
            vistaPropia = v
        } else if director != nil, let v = history.view(atOrBefore: t) {
            // Sin vista del director para este instante: la del anterior. El barrido de
            // guion es de otro sitio y salía como un salto de plano de un fotograma.
            missingDirectorViews += 1
            vistaPropia = v
        } else {
            vistaPropia = scriptedView(t)
        }
        e0Ticks += 1
        if e0Ticks % Self.e0ViewEvery == 0 {
            let grados = 180 / Double.pi
            e0?.log(.view(rigMs: t, yawDeg: vistaPropia.yawRad * grados, pitchDeg: vistaPropia.pitchRad * grados,
                          hfovDeg: vistaPropia.hfovRad * grados, shot: scriptName))
        }
        if t - (lastAdCueT ?? t - Self.adCueEveryMs) >= Self.adCueEveryMs, let (_, cue) = AdHub.rotation?.strip(atRigMs: t) {
            lastAdCueT = t
            adCues.append([t, cue.ad.name, cue.frame])
        }
        if let decision = master.tick(programRigMs: t, nowRigMs: now, masterView: vistaPropia) {
            composeLatencyMs.append(Double(now - t) + Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6)
            // IOS-58: un retroceso es una vista que pedía las dos lentes y salió de una.
            if case .oneLens = decision, vistaPropia.sides.count > 1 { partFallbacks += 1 }
        }
        drainProgram()
        detectTick()
    }

    /// Quién da las vistas: el guion de SPK-04, el director o el barrido de siempre.
    private var scriptName: String {
        spk04 != nil ? "spk04" : director != nil ? "director" : "script"
    }

    // MARK: - SPK-04: las vistas de cada instante y la 4K local

    private func startRecording4K() {
        rec4kStarted = true
        diskFreeStartGb = Double(CaptureEngine.freeDiskBytes()) / Self.bytesPerGb
        guard let start = startLocal4K,
              let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
        else { return }
        // Una carpeta por pasada: el banco del Mac recoge esta y no las viejas.
        let dir = docs.appendingPathComponent("bench4k/\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rec4kDir = dir
        rec4kPath = start(dir.path, RecordingPolicy.benchReserveBytes(durationS: durationS))
        if rec4kPath.isEmpty { NSLog("[split] sin 4K: no queda libre la reserva de la pasada") }
    }

    /// Una línea por instante pintado: lo que REF-41 necesita para rehacerlo desde las 4K.
    private func logComposed(_ f: ComposedFrame) {
        if viewsURL == nil, let base = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("bench", isDirectory: true) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let url = base.appendingPathComponent("program-views-\(Int(Date().timeIntervalSince1970)).jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            viewsURL = url
            viewsFile = try? FileHandle(forWritingTo: url)
        }
        let v = f.view
        func num(_ x: Double) -> String { String(format: "%.7f", x) }
        func opt(_ x: Int64?) -> String { x.map(String.init) ?? "null" }
        func lista(_ a: [Double]) -> String { "[" + a.map(num).joined(separator: ",") + "]" }
        let lados = v.sides.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let linea = "{\"t\":\(f.programRigMs),\"src\":\"\(f.source.rawValue)\",\"view_id\":\(v.viewId)," +
            "\"yaw_rad\":\(num(v.yawRad)),\"pitch_rad\":\(num(v.pitchRad)),\"hfov_rad\":\(num(v.hfovRad))," +
            "\"seam_yaw_rad\":\(num(v.seamYawRad)),\"feather_rad\":\(num(v.featherRad)),\"sides\":[\(lados)]," +
            "\"gains_left\":\(lista(v.gains.left)),\"gains_right\":\(lista(v.gains.right))," +
            "\"master_frame_rig_ms\":\(opt(f.masterFrameRigMs)),\"part_frame_rig_ms\":\(opt(f.partFrameRigMs))," +
            "\"extrapolated\":\(f.extrapolated),\"torn\":\(f.torn)," +
            "\"gpu_ms\":\(f.gpuMs.map { String(format: "%.3f", $0) } ?? "null")}\n"
        viewsPending.append(Data(linea.utf8))
        viewsLines += 1
        if viewsLines % Self.viewsFlushEvery == 0 { flushViews() }
    }

    private func flushViews() {
        guard let fh = viewsFile, !viewsPending.isEmpty else { return }
        let datos = viewsPending
        viewsPending = Data()
        writerQueue.async { try? fh.write(contentsOf: datos) }
    }

    /// p50/p95/p99 y cuántos, de un histograma.
    private static func summary(_ h: LatencyHistogram) -> [String: Any] {
        ["p50": h.percentile(0.5), "p95": h.percentile(0.95), "p99": h.percentile(0.99), "n": h.total]
    }

    /// Una ruta relativa a Documents, como la pide `devicectl device copy from`.
    private static func documentsRelative(_ url: URL?) -> String? {
        guard let url, let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: false)
        else { return nil }
        let raiz = docs.standardizedFileURL.path + "/"
        let ruta = url.standardizedFileURL.path
        return ruta.hasPrefix(raiz) ? String(ruta.dropFirst(raiz.count)) : nil
    }

    /// Lo grabado en esta pasada, relativo a Documents: el banco del Mac lo recoge de aquí.
    private func recordedFiles() -> [String: Any] {
        var f: [String: Any] = [:]
        f["ts"] = Self.documentsRelative(tsURL)
        if !movSegments.isEmpty {
            f["mov"] = Self.documentsRelative(movURL)
            f["mov_segments"] = movSegments.compactMap(Self.documentsRelative)
        }
        f["views"] = Self.documentsRelative(viewsURL)
        if session.isMaster { f["e0"] = Self.documentsRelative(e0URL) }
        if let dir = rec4kDir {
            let movs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".mov") }.sorted()
            f["rec4k"] = movs.compactMap { Self.documentsRelative(dir.appendingPathComponent($0)) }
        }
        return f
    }

    /// La 4K de la pasada: ficheros, tamaño, fotogramas y disco.
    private func rec4kReport() -> [String: Any] {
        guard config.record4K else { return ["requested": false] }
        let movs = rec4kDir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey]) }?
            .filter { $0.pathExtension == "mov" } ?? []
        let bytes = movs.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return ["requested": true, "started": !rec4kPath.isEmpty, "segments": movs.count,
                "bytes": bytes, "frames": local4KFrames(), "clock": local4KClock(),
                "reserve_gb": Double(RecordingPolicy.benchReserveBytes(durationS: durationS)) / Self.bytesPerGb,
                "disk_free_gb_start": diskFreeStartGb ?? -1,
                "disk_free_gb_end": Double(CaptureEngine.freeDiskBytes()) / Self.bytesPerGb]
    }

    /// La aceptación de SPK-04 con lo que se sabe en este móvil. El PSNR en la rampa sale
    /// después, en el Mac (REF-41); la GPU del otro móvil, en su informe.
    private func spk04Acceptance(addedLatencyP95: Double) -> [String: Any] {
        if session.isMaster, let m = master {
            let p95 = m.gpuMs.percentile(0.95), p99 = m.gpuMs.percentile(0.99)
            return ["added_latency_ms_p95": addedLatencyP95,
                    "added_latency_ok": addedLatencyP95 <= Self.spk04LatencyP95Ms,
                    "gpu_ms_p95": p95, "gpu_ms_p99": p99, "gpu_ok": p99 <= Self.spk04GpuMs,
                    "torn_frames": m.stats.tornFrames, "torn_ok": m.stats.tornFrames == 0,
                    "psnr_ramp_db": "pendiente: REF-41 en el Mac (program-views + 4K + .ts)"]
        }
        guard let s = slave else { return [:] }
        let p95 = s.gpuMs.percentile(0.95), p99 = s.gpuMs.percentile(0.99)
        return ["gpu_ms_p95": p95, "gpu_ms_p99": p99, "gpu_ok": p99 <= Self.spk04GpuMs]
    }

    private static let footprintEveryS = 60.0
    /// Cada cuánto se mira si la huella saltó (2026-10-14), en s: el salto queda situado
    /// a 5 s y `task_info` cuesta microsegundos.
    private static let footprintCheckEveryS = 5.0
    /// Sucesos de la app que se guardan como mucho, y los últimos que van con cada salto.
    private static let maxAppEvents = 64
    private static let appEventsInJump = 4
    /// Instantes que el director recupera como mucho si el tic se los saltó: más de
    /// cuatro (133 ms) es un parón, no un tic tarde, y se sigue desde el último.
    private static let directorCatchUpInstants = 4
    /// Cubos de la fase del tic, en ms: de medio en medio hasta un fotograma.
    private static let tickPhaseBoundsMs: [Double] = stride(from: 0.5, through: 33.5, by: 0.5).map { $0 }
    /// Lo que el tic espera detrás de cada punto de la rejilla, en ms: lo justo para que
    /// el punto ya haya pasado aunque el temporizador se adelante un poco.
    private static let tickPhaseMarginMs = 2.0

    /// La detección en los dos papeles (IOS-73) a la cadencia de la escalera común (IOS-06,
    /// IOS-25): 7,5 Hz en L0, 5 en L1, nada desde L2. Los dos móviles detectan en los mismos
    /// instantes t_k del soporte (DetectionGate), así que el director del maestro empareja sus
    /// cajas con desfase cero. El esclavo manda sus cajas al maestro; el maestro las da a su
    /// director (si dirige el DirectorService).
    private func detectTick() {
        guard let d = detect, let ring = pipelineProvider()?.ring, let ultimo = ring.latestRigMs(),
              let objetivo = detectGate.due(latestRigMs: ultimo)
        else { return }
        guard let lease = ring.acquire(nearest: objetivo, maxDistanceMs: detectGate.halfFrameMs) else {
            detectMissingFrame += 1
            return
        }
        if d.onDetections == nil {
            d.onDetections = { [weak self] cajas, t, ms in
                guard let self else { return }
                if session.isMaster {
                    director?.receive(side: side, targetRigMs: t, detections: cajas)
                } else {
                    session.send(detections: cajas, targetRigMs: t, inferMs: ms)
                }
            }
        }
        d.offer(lease.buffer, rigMs: objetivo) { ring.release(lease) }
    }

    /// `phys_footprint` del proceso, lo que mira jetsam, en MB.
    /// Segundos de CPU del proceso (usuario + sistema, todos los hilos), de getrusage.
    static func processCpuSeconds() -> Double {
        var uso = rusage()
        getrusage(RUSAGE_SELF, &uso)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(uso.ru_utime) + s(uso.ru_stime)
    }

    static func thermalName(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    static func footprintMb() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Cada cuánto se apunta el cue de la franja en el informe.
    private static let adCueEveryMs: Int64 = 1000

    private func scheduledAdOverrides(transcurrido: Double) {
        guard let lista = env["RIG_ADS_OVERRIDES"], let store = AdHub.store, let rotation = AdHub.rotation else {
            return
        }
        for (i, item) in lista.split(separator: ",").enumerated() where i >= adOverridesDone.count {
            let partes = item.split(whereSeparator: { $0 == ":" || $0 == "@" }).map(String.init)
            guard partes.count == 3, let vueltas = Int(partes[1]), let s = Double(partes[2]) else { return }
            guard transcurrido >= s else { return }
            let clip = store.clip(named: partes[0])
            let ahora = AdHub.nowRigMs()
            rotation.set(override: clip, loops: vueltas, atRigMs: ahora)
            adOverridesDone.append(["name": partes[0], "loops": vueltas, "start_rig_ms": ahora,
                                    "frames": clip?.frames ?? 0, "fps": clip?.fps ?? 0])
        }
    }

    /// IOS-44: los intervalos entre fotogramas del programa al entrar al codificador, que
    /// es la cadencia que de verdad sale (el tic solo mide el temporizador).
    private var programIntervalsMs: [Double] = []
    private var lastProgramNs: UInt64?

    private func program(_ buffer: CVPixelBuffer, t: Int64) {
        let ahoraNs = DispatchTime.now().uptimeNanoseconds
        if let previo = lastProgramNs { programIntervalsMs.append(Double(ahoraNs - previo) / 1e6) }
        lastProgramNs = ahoraNs
        ThumbHub.shared.program(buffer)
        programEncoder?.encode(buffer, ptsNs: t * 1_000_000, rigMs: UInt64(max(0, t)))
        programFrames += 1
    }

    private func drainProgram() {
        guard let enc = programEncoder else { return }
        if config.benchFiles, tsFile == nil {
            let base = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                .appendingPathComponent("bench", isDirectory: true)
            if let base {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let url = base.appendingPathComponent("program-split-\(Int(Date().timeIntervalSince1970)).ts")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                tsURL = url
                tsFile = try? FileHandle(forWritingTo: url)
            }
        }
        while let f = enc.pop() {
            rollFailedRecorder(enc)
            // RIG_SPLIT_NO_MOV=1 / RIG_SPLIT_NO_TS=1: sin la copia .mov o sin el .ts, para
            // separar de dónde crece la memoria del maestro.
            if recorder == nil, env["RIG_SPLIT_NO_MOV"] != "1", movOpenAttempts < Self.movMaxSegments,
               !movWaitingKeyframe || f.isKeyframe, let fd = f.formatDescription,
               let url = programMovURL(segment: movOpenAttempts + 1) {
                movOpenAttempts += 1
                movWaitingKeyframe = false
                do {
                    recorder = try ProgramRecorder(url: url, videoFormat: fd, audioFormat: audioFormat())
                    movSegments.append(url)
                    if movURL == nil { movURL = url }
                } catch {
                    movFailures.append("abrir \(url.lastPathComponent): \(error)")
                }
            }
            try? recorder?.append(video: f)
            var avcc = f.data
            if f.isKeyframe, let fd = f.formatDescription {
                avcc = H264ParameterSets.avccNals(from: fd) + avcc
            }
            publisher?.video(avcc: avcc, isKeyframe: f.isKeyframe, rigMs: Double(f.ptsNs) / 1e6)
            let pts = f.ptsNs * 90 / 1_000_000
            if firstVideoT == nil { firstVideoT = f.ptsNs / 1_000_000 }
            if let ts = tsFile, !finished, env["RIG_SPLIT_NO_TS"] != "1" {
                let paquetes = muxer.muxVideo(avcc: avcc, parameterSets: [], isKeyframe: f.isKeyframe,
                                              pts90k: pts, dts90k: pts)
                writerQueue.async { try? ts.write(contentsOf: paquetes) }
            }
        }
    }

    // MARK: - IOS-58: EMITIR, lo que ve la pantalla

    /// Cada cuánto se rehace lo que ve la pantalla, en ns: Dart lo pide una vez por segundo.
    private static let statusEveryNs: UInt64 = 1_000_000_000
    private static let bitsPerByte = 8.0
    private static let bitsPerMegabit = 1e6

    /// Sin pasada en marcha.
    static let idleStatus = ProgramStatus(
        running: false, master: false, programFps: 0, programFrames: 0, srtState: "", srtTarget: "",
        srtDetail: "", srtBitrateBps: 0, srtRttMs: 0, srtReconnects: 0, partMbps: 0, partFallbacks: 0,
        partsLost: 0, detectorRuns: 0, detectorNote: "", problem: "", rigSource: ""
    )

    /// La copia del programa: en el banco, junto al .ts; en EMITIR, Documents/program-<id>.mov.
    /// Los segmentos siguientes (`segment` > 1), con su número: `program-<id>-2.mov`.
    private func programMovURL(segment: Int = 1) -> URL? {
        let base: URL?
        if config.benchFiles {
            base = tsURL?.deletingPathExtension()
        } else {
            base = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil,
                                                 create: true))?.appendingPathComponent("program-\(runId)")
        }
        guard let base else { return nil }
        let nombre = segment <= 1 ? base.lastPathComponent : "\(base.lastPathComponent)-\(segment)"
        return base.deletingLastPathComponent().appendingPathComponent(nombre).appendingPathExtension("mov")
    }

    /// Si el escritor de la copia falló, se suelta (lo suyo queda en sus fragmentos) y el
    /// siguiente IDR abre el segmento que sigue.
    private func rollFailedRecorder(_ enc: VideoEncoder) {
        guard let r = recorder, r.failed else { return }
        movFailures.append("\(r.url.lastPathComponent): \(r.failureDescription ?? "?")")
        NSLog("[split] la copia del programa falló (%@): sigue en otro fichero", r.failureDescription ?? "?")
        movFramesClosed.video += r.videoFrames
        movFramesClosed.audio += r.audioFrames
        recorder = nil
        movWaitingKeyframe = true
        enc.forceIDR()
    }

    /// El paquete del detector de EMITIR, si está en el móvil: RIG_DETECT si se lanzó con él;
    /// si no, el de la ficha del plan B, o el primer CenterNet de Documents/bench-resources.
    static func productionDetector(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let dir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false)
            .appendingPathComponent("bench-resources", isDirectory: true)
        else { return nil }
        let hay = { (nombre: String) in FileManager.default.fileExists(atPath: dir.appendingPathComponent(nombre).path) }
        if let pedido = env["RIG_DETECT"] { return hay(pedido) ? pedido : nil }
        if hay(ProgramRunConfig.productionDetectorPackage) { return ProgramRunConfig.productionDetectorPackage }
        let paquetes = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return paquetes.filter { $0.hasSuffix(".mlpackage") && $0.lowercased().contains("centernet") }.sorted().first
    }

    /// Lo que ve la pantalla: la copia que rehace el tic.
    func status() -> ProgramStatus {
        lock.lock(); defer { lock.unlock() }
        return statusSnapshot
    }

    /// En la cola del tic, una vez por segundo.
    private func refreshStatus() {
        let ahoraNs = DispatchTime.now().uptimeNanoseconds
        guard ahoraNs - lastStatusNs >= Self.statusEveryNs else { return }
        lastStatusNs = ahoraNs
        let esMaestro = session.isMaster
        let fps = programFpsMeter.rate(count: Double(programFrames), nowNs: ahoraNs)
        lock.lock()
        let enviados = partBytesSent
        lock.unlock()
        let bytesPorS = partBytesMeter.rate(count: Double(enviados), nowNs: ahoraNs)
        let enlace = master?.linkStats(nowRigMs: rigNowMs())
        let srt = publisher?.snapshot
        var srtState = ""
        if esMaestro, config.publish {
            srtState = publishTarget["source"] as? String == "none" ? "none" : (srt?.state ?? "stopped")
        }
        let destino = (publishTarget["host"] as? String).map { "\($0):\(publishTarget["port"] as? Int ?? 0)" } ?? ""
        let nota: String
        if config.detectorPackage == nil {
            nota = "sin modelo en Documents/bench-resources"
        } else if let error = detect?.loadError, !error.isEmpty {
            nota = error
        } else {
            nota = ""
        }
        let nuevo = ProgramStatus(
            running: !finished, master: esMaestro, programFps: esMaestro ? fps : 0,
            programFrames: Int64(programFrames), srtState: srtState, srtTarget: destino,
            srtDetail: srt?.lastError ?? "", srtBitrateBps: Int64(srt?.bitrateBps ?? 0), srtRttMs: srt?.rttMs ?? 0,
            srtReconnects: Int64(srt?.reconnects ?? 0),
            partMbps: esMaestro ? (enlace?.mbps ?? 0) : bytesPorS * Self.bitsPerByte / Self.bitsPerMegabit,
            partFallbacks: Int64(esMaestro ? partFallbacks : (slave?.stats.withoutView ?? 0)),
            partsLost: Int64(enlace?.lost ?? 0), detectorRuns: Int64(detect?.runCount ?? 0),
            detectorNote: nota, problem: setUpProblem, rigSource: rigSource
        )
        lock.lock()
        statusSnapshot = nuevo
        lock.unlock()
    }

    // MARK: - IOS-56: el programa por SRT

    /// Con RIG_SPLIT_PUBLISH=1, el maestro publica y el esclavo no: un maestro que deja de
    /// serlo para su publicador, o MediaMTX (overridePublisher) se lo pasaría del uno al
    /// otro cada 3 s (ADR 0022 §8).
    private func updatePublisher() {
        guard config.publish else { return }
        if session.isMaster, publisher == nil, let enc = programEncoder, publishTarget["source"] == nil {
            guard let (destino, origen) = Self.publishTarget(env) else {
                publishTarget = ["source": "none"]
                NSLog("[srt] publicar sin destino: ni RIG_SRT_HOST ni QR Soporte en el Keychain")
                return
            }
            publishTarget = ["source": origen, "host": destino.host, "port": Int(destino.port)]
            let p = ProgramPublisher(target: destino, audio: Self.programAudio, maximumBps: Self.programBitrateBps)
            p.onIdrRequest = { [weak enc] in enc?.forceIDR() }
            p.onBitrate = { [weak enc] bps in try? enc?.setBitrate(bps: bps) }
            p.onLog = { NSLog("[srt] %@", $0) }
            // IOS-06: si la escalera ya bajó el programa (L3), el publicador nace con su techo.
            if let factor = programBitrateFactorApplied, factor < 1 {
                p.setCeiling(bps: Self.programBitrateBps(factor: factor))
            }
            p.start()
            publisher = p
        } else if !session.isMaster, publisher != nil {
            stopPublisher()
            publishTarget = [:]  // si vuelve a ser maestro, publica otra vez
        }
    }

    private func stopPublisher() {
        guard let p = publisher else { return }
        p.stop()
        publishSessions.append(p.snapshot)
        publisher = nil
    }

    /// El destino: el de las variables de entorno si hay RIG_SRT_HOST (pruebas), o el
    /// bloque `srt` del QR Soporte del Keychain.
    static func publishTarget(_ env: [String: String]) -> (ProgramSrtTarget, String)? {
        if let host = env["RIG_SRT_HOST"] {
            return (ProgramSrtTarget(host: host, port: env["RIG_SRT_PORT"].flatMap(UInt16.init) ?? srtDefaultPort,
                                     user: env["RIG_SRT_USER"] ?? "", pass: env["RIG_SRT_PASS"] ?? "",
                                     passphrase: env["RIG_SRT_PASSPHRASE"] ?? ""), "env")
        }
        do {
            return try VpsPairingKeychain.load().map { ($0.srt, "keychain") }
        } catch {
            // Los errores de VpsPairing dicen el campo, nunca el valor.
            NSLog("[srt] el QR Soporte del Keychain no vale: %@", "\(error)")
            return nil
        }
    }

    private func publishReport() -> [String: Any] {
        guard config.publish else { return ["requested": false] }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let tramos = publishSessions.compactMap { s in
            (try? enc.encode(s)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        // Los fotogramas que VideoToolbox no entregó: con detalle de más para el bitrate y
        // el QP en su tope, el modo de baja latencia los tira (visto en el Mac con ruido).
        return ["requested": true, "target": publishTarget, "sessions": tramos,
                "program_encode_failures": programEncoder?.encodeFailures ?? 0]
    }

    // MARK: - IOS-06: la escalera actuando

    /// El nivel de la escalera de este móvil, para la pantalla (CaptureStatus.ladderLevel).
    var currentLadderLevel: LadderLevel {
        lock.lock(); defer { lock.unlock() }
        return ladderLevelShown
    }

    /// Una vez por segundo: la escalera con lo que piden los sensores (o el forzado del
    /// banco en su tramo), su nivel al latido y las acciones que cambien.
    private func stepLadder(_ transcurrido: Double) {
        guard transcurrido >= nextLadderS else { return }
        nextLadderS = transcurrido + LadderConstants.stepEveryS
        let ahora = DispatchTime.now().uptimeNanoseconds
        let dt = lastLadderStepNs.map { Double(ahora - $0) / 1e9 } ?? 0
        lastLadderStepNs = ahora
        governor.step(sensors: ladderSensors(), elapsedS: transcurrido, dtS: dt)
        session.setLadderLevel(UInt8(governor.level.rawValue))
        applyLadder()
    }

    /// Rehace las acciones en vigor y aplica lo que cambió: la cadencia de la IA y el director,
    /// el bitrate del programa, la parte del esclavo, la lente sola del maestro y la orden
    /// `cadence`. En la cola del tic: con cada paso y con cada noticia del otro móvil.
    private func applyLadder() {
        let esMaestro = session.isMaster
        governor.setPeer(level: peerDown ? nil : peerLadderHeard)
        let acciones = governor.actions(isMaster: esMaestro)
        let ia = governor.aiLevel(isMaster: esMaestro)
        ladderActions = acciones
        // La IA (L1, L2): la cadencia de la detección y, sin IA, el director al plano abierto
        // (con «sin detecciones» a secas se quedaría en el último plano).
        detectGate.set(hz: LadderGovernor.detectionHz(acciones))
        director?.setAI(enabled: acciones.aiEnabled)
        applyProgramBitrate(factor: acciones.programBitrateFactor)
        applyPart(enabled: acciones.partEnabled)
        applySingleLens()
        if esMaestro { sendCadence(ia) }
        noteLadder(ai: ia, actions: acciones, master: esMaestro)
    }

    static func programBitrateBps(factor: Double) -> Int {
        Int((Double(programBitrateBps) * factor).rounded())
    }

    /// L3: el programa ×`programBitrateFactor`. Con publicador, por su techo (él lleva el
    /// codificador con `onBitrate` y sube despacio al volver); sin él (la copia .mov sin
    /// destino), el codificador directamente. El alto de 720p de L3 no se aplica: ver PROGRESS.
    private func applyProgramBitrate(factor: Double) {
        guard factor != programBitrateFactorApplied, let enc = programEncoder else { return }
        programBitrateFactorApplied = factor
        let bps = Self.programBitrateBps(factor: factor)
        if let p = publisher {
            p.setCeiling(bps: factor < 1 ? bps : nil)
        } else {
            try? enc.setBitrate(bps: bps)
        }
        NSLog("[escalera] programa a %.1f Mbit/s (×%.2f)", Double(bps) / 1e6, factor)
    }

    /// L4 en el esclavo: deja de pintar y codificar su parte; al volver, la primera es un IDR
    /// (el maestro no tiene con qué decodificar una P suelta).
    private func applyPart(enabled: Bool) {
        lock.lock()
        let estaba = partPaused
        partPaused = !enabled
        lock.unlock()
        if estaba, enabled { slaveEncoder?.forceIDR() }
    }

    /// En el maestro: con el esclavo caído (IOS-81) o con su parte parada por la escalera
    /// (L4), una lente y sin esperar su parte; al volver, las dos. Con «Una cámara», siempre una.
    private func applySingleLens() {
        guard session.isMaster, let m = master else { return }
        let sola = config.singleCamera || peerDown || governor.peerStoppedParts
        guard sola != singleLensApplied else { return }
        singleLensApplied = sola
        m.peerDown = sola
        director?.setSingleLens(sola ? side : nil)
    }

    /// La orden `cadence` con la escalera común: al cambiar y cada `cadenceResendS`.
    private func sendCadence(_ comun: LadderLevel) {
        guard case .connected = session.state else {
            cadenceSent = nil
            return
        }
        let ahora = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        guard comun != cadenceSent || ahora - cadenceSentAtS >= LadderConstants.cadenceResendS else { return }
        session.send(cadence: CadenceCommand(level: comun))
        cadenceSent = comun
        cadenceSentAtS = ahora
        cadenceCommandsSent += 1
    }

    /// Apunta el cambio, si lo hay, con su instante y lo que se aplicó; y el nivel de la pantalla.
    private func noteLadder(ai: LadderLevel, actions a: LadderActions, master: Bool) {
        let transcurrido = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        let marca = LadderMark(
            level: governor.level, ai: ai, peer: governor.peerLevel, commanded: governor.commandedLevel,
            forced: governor.force?.isActive(elapsedS: transcurrido) ?? false, master: master
        )
        lock.lock()
        ladderLevelShown = marca.level
        lock.unlock()
        guard marca != ladderMark else { return }
        ladderMark = marca
        NSLog("[escalera] L%ld, IA L%ld (otro L%ld, orden L%ld)%@", marca.level.rawValue, ai.rawValue,
              marca.peer?.rawValue ?? -1, marca.commanded?.rawValue ?? -1, marca.forced ? ", forzada" : "")
        guard ladderChanges.count < Self.maxLadderChanges else {
            ladderChangesDropped += 1
            return
        }
        ladderChanges.append([
            "s": transcurrido, "rig_ms": rigNowMs(), "role": master ? "master" : "slave",
            "level": marca.level.rawValue, "ai_level": ai.rawValue,
            "peer_level": marca.peer?.rawValue ?? -1, "commanded_level": marca.commanded?.rawValue ?? -1,
            "forced": marca.forced, "detect_hz": LadderGovernor.detectionHz(a),
            "program_bitrate_factor": a.programBitrateFactor, "part": a.partEnabled,
            "single_lens": master && singleLensApplied,
        ])
    }

    /// Las detecciones de cada minuto de la pasada (el último, a medias).
    private func detectRunsByMinute() -> [Int] {
        let cuentas = detectRunsAtMinute + [detect?.runCount ?? 0]
        return zip(cuentas.dropFirst(), cuentas).map { $0 - $1 }
    }

    /// Lo que la escalera hizo en la pasada y lo que estaba en vigor al acabar.
    private func ladderReport() -> [String: Any] {
        let a = ladderActions
        lock.lock()
        let pausados = partFramesPaused
        lock.unlock()
        let forzado: [String: Any] = governor.force.map {
            ["level": $0.level.rawValue, "at_s": $0.atS, "until_s": $0.untilS, "side": $0.side?.rawValue ?? "both"]
        } ?? [:]
        return [
            "level": governor.level.rawValue,
            "ai_level": governor.aiLevel(isMaster: session.isMaster).rawValue,
            "peer_level": governor.peerLevel?.rawValue ?? -1,
            "commanded_level": governor.commandedLevel?.rawValue ?? -1,
            "force": forzado,
            // Las acciones en vigor. `program_height`, `ball`, `preview` y `handover` aún no
            // tienen a quién mandar en este camino (`not_wired`).
            "actions": [
                "player_hz": a.playerHz, "ai": a.aiEnabled, "ball": a.ballEnabled, "ball_roi_hz": a.ballRoiHz,
                "program_height": a.programHeight, "program_bitrate_factor": a.programBitrateFactor,
                "program": a.programEnabled, "part": a.partEnabled, "local_recording": a.localRecording,
                "preview": a.preview, "handover": a.requestsHandover,
            ] as [String: Any],
            "not_wired": ["program_height", "ball", "preview", "handover"],
            "changes": ladderChanges,
            "changes_dropped": ladderChangesDropped,
            "cadence_commands_sent": cadenceCommandsSent,
            "cadence_commands_received": cadenceCommandsReceived,
            "detect_hz": detectGate.hz,
            "detect_skipped_late": detectGate.skipped,
            "detect_missing_frame": detectMissingFrame,
            "part_frames_paused": pausados,
            "single_lens": singleLensApplied,
            "program_bitrate_bps": Self.programBitrateBps(factor: programBitrateFactorApplied ?? 1),
        ]
    }

    // MARK: - El spike de la duración de fotograma (2026-10-15)

    /// En cada tic, en los dos móviles: lo que pide el plan a este lado ahora; si cambia, se
    /// le pide a la cámara.
    private func stepFrameSpike(_ transcurrido: Double) {
        guard let plan = frameSpikePlan else { return }
        let ahora = rigNowMs()
        let pedida = plan.duration(for: side, atRigMs: ahora, benchS: transcurrido)
        guard pedida != frameSpikeCurrent else { return }
        frameSpikeCurrent = pedida
        frameDurationRequest?(pedida, transcurrido, ahora)
    }

    /// La fase del maestro cada 10 s: [inicio del cubo en el reloj del soporte, mediana con
    /// signo (ms), fotogramas de dos lentes, desgarros].
    private func phaseBy10s() -> [[Any]] {
        guard let f = master?.halvesPhaseBy10s else { return [] }
        return f.buckets.map { [f.startRigMs(of: $0), $0.medianMs, $0.frames, $0.torn] }
    }

    /// El spike, para el informe: el plan, lo que midió la cámara de este lado y, en el
    /// maestro, cada ventana de la pasada con lo que debería mover la fase (captura del
    /// maestro − de la parte: baja si se alarga el esclavo, sube si se alarga el maestro) y
    /// lo que la movió, del cubo de 10 s de antes de la ventana al de después.
    private func frameSpikeSection() -> [String: Any] {
        if !frameSpikeError.isEmpty { return ["error": frameSpikeError] }
        guard let plan = frameSpikePlan else { return [:] }
        var s = frameSpikeReport()
        s["plan"] = plan.report
        s["side"] = side.rawValue
        guard session.isMaster, let f = master?.halvesPhaseBy10s else { return s }
        let nominal = FrameDuration.nominal(fps: Int(Self.fps))
        let inicio = (startHostNs + session.clock.offsetAt(ns: startHostNs)) / 1_000_000
        let fases = f.buckets.filter { $0.frames >= HalvesPhaseTracker.minFramesForDrift }
            .map { (startRigMs: f.startRigMs(of: $0), medianMs: $0.medianMs) }
        let primera = inicio + Int64((plan.afterS * 1000).rounded())
        s["windows_columns"] = ["start_rig_ms", "end_rig_ms", "side", "duration_us", "predicted_phase_shift_ms",
                                "measured_phase_shift_ms"]
        s["windows"] = plan.windows(fromRigMs: primera, toRigMs: rigNowMs()).map { w -> [Any] in
            let retraso = plan.predictedShiftMs(w.duration, nominal: nominal)
            let medida = FrameDurationSpikePlan.measuredShiftMs(
                phases: fases, window: w, bucketMs: HalvesPhaseTracker.fineBucketMs, frameDurationMs: 1000 / Self.fps
            )
            return [w.startRigMs, w.endRigMs, w.side.rawValue, w.duration.microseconds,
                    w.side == side ? retraso : -retraso, medida.map { $0 as Any } ?? NSNull()]
        }
        return s
    }

    // MARK: - Informe

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()
        if latencyMinuteFrom < composeLatencyMs.count { closeLatencyMinute() }
        programEncoder?.flush()
        drainProgram()
        stopPublisher()
        e0?.flush()
        flushViews()
        if rec4kStarted { stopLocal4K?() }
        // El spike no deja la cámara alargada al acabar.
        if frameSpikeCurrent != nil {
            frameSpikeCurrent = nil
            frameDurationRequest?(nil, Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9, rigNowMs())
        }
        let espera = DispatchSemaphore(value: 0)
        if let r = recorder { r.finish { _ in espera.signal() }; _ = espera.wait(timeout: .now() + 5) }
        // Después de lo que quede por escribir en su cola.
        // `write(contentsOf:)` devuelve error en vez de abortar con una excepción de ObjC: lo
        // que llegue a la cola después de cerrar (un tic o un trozo de audio que ya estaba en
        // ella) se pierde sin tirar la app, como pasó el 6-oct.
        let ts = tsFile
        tsFile = nil
        let vistas = viewsFile
        viewsFile = nil
        writerQueue.sync {
            try? ts?.close()
            try? vistas?.close()
        }
        // 2026-10-15: el informe se escribe siempre. Aquí había un `guard session.isMaster ||
        // slave != nil`: el esclavo que no llegó a enlazar no monta su parte y se iba sin
        // informe ni latido final (el plan B de bench/partido-20261015-0902).
        func pct(_ xs: [Double], _ q: Double) -> Double {
            let o = xs.sorted()
            return o.isEmpty ? 0 : o[min(o.count - 1, Int(q * Double(o.count)))]
        }
        let ms = master?.stats ?? .init()
        let ss = slave?.stats ?? .init()
        let link = master?.linkStats(nowRigMs: rigNowMs())
        let transporte = linkStats()
        let enlace = linkEvents()
        let fpsTicks = tickIntervalsMs.map { 1000 / max($0, 0.001) }
        let latenciaP95 = pct(composeLatencyMs, 0.95)
        var guion: [String: Any] = [:]
        if let g = spk04 {
            guion = Spk04Script.parameters
            guion["seam_yaw_deg"] = g.seamYawRad * 180 / .pi
            guion["pitch_deg"] = g.pitchRad * 180 / .pi
        }
        var gpuPorFotograma: [String: Any] = [:]
        var gpuComposicion: [String: Any] = [:]
        var desfaseMitades: [String: Any] = [:]
        // 2026-10-14: la fase entre las cámaras por minuto, su deriva y cuánto falta para
        // el cruce de medio fotograma (donde salen los desgarros).
        let fase = master?.halvesPhase
        let fasePorMinuto: [[Any]] = (fase?.buckets ?? []).map { [$0.index, $0.medianMs, $0.frames, $0.torn] }
        if session.isMaster, let m = master {
            gpuPorFotograma = Self.summary(m.gpuMs)
            gpuPorFotograma["what"] = "render de la mitad propia + composición"
            gpuComposicion = Self.summary(m.composeGpuMs)
            desfaseMitades = Self.summary(m.halvesSkewMs)
        } else if let e = slave {
            gpuPorFotograma = Self.summary(e.gpuMs)
            gpuPorFotograma["what"] = "render de la parte"
        }
        let informe: [String: Any] = [
            // SPK-04: quién dirige, la GPU por fotograma, los desgarros, lo grabado y la
            // aceptación con lo que ya se sabe en este móvil.
            "script": scriptName,
            "spk04_script": guion,
            "gpu_ms_per_frame": gpuPorFotograma,
            "compose_gpu_ms": gpuComposicion,
            "torn_frames": ms.tornFrames,
            "extrapolated_view_frames": ms.extrapolatedViewFrames,
            "halves_skew_ms": desfaseMitades,
            // [minuto, mediana con signo (captura del maestro − de la parte, ms),
            // fotogramas de dos lentes, desgarros]; la deriva en ms/min y los minutos que
            // le quedaban a la última fase hasta ±½ fotograma (−1 sin dos lentes).
            "halves_phase_by_minute": fasePorMinuto,
            "halves_phase_drift_ms_per_min": fase?.driftMsPerMinute() ?? -1,
            "halves_phase_minutes_to_half_frame": fase?.minutesToHalfFrame() ?? -1,
            // 2026-10-15: lo mismo cada 10 s: [inicio del cubo en el reloj del soporte,
            // mediana con signo (ms), fotogramas de dos lentes, desgarros].
            "halves_phase_by_10s": phaseBy10s(),
            "frame_duration_spike": frameSpikeSection(),
            // El tic: su fase frente a la rejilla (en el margen, ~2 ms), los instantes del
            // programa que se saltó, los que no tenían vista del director y la latencia
            // añadida de cada minuto [p50, p95].
            "tick_phase_ms": Self.summary(tickPhaseHist),
            "program_skipped_instants": programSkippedInstants,
            "missing_director_views": missingDirectorViews,
            "added_latency_ms_by_minute": latencyByMinute,
            // La huella: cada salto de ≥20 MB entre dos muestras de 5 s con lo que pasaba,
            // la huella en cada cambio del esclavo (en paralelo a `peer_states`), los
            // sucesos de la app y lo más que tuvo dentro el codificador del programa.
            "footprint_jumps": footprintJumpContexts,
            "footprint_jumps_dropped": footprintJumps.dropped,
            "peer_states_footprint_mb": peerStatesFootprintMb,
            "app_events": appEvents,
            "program_encoder_in_flight_peak": programEncoderInFlightPeak,
            "camera_drops": cameraDrops(),
            "files": recordedFiles(),
            "rec4k": rec4kReport(),
            "publish": publishReport(),
            "spk04_acceptance": spk04Acceptance(addedLatencyP95: latenciaP95),
            "name": "program-split",
            "purpose": config.purpose.rawValue,
            // «Una cámara (sin pareja)»: sin esclavo, sin parte y sin enlace, a propósito.
            "single_camera": config.singleCamera,
            "elapsed_s": Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9,
            "part_fallbacks": partFallbacks,
            "device": BenchRunner.machine(),
            "side": side.rawValue,
            "role": session.isMaster ? "master" : "slave",
            "rig": rigSource,
            "duration_s": durationS,
            "ts": tsURL?.lastPathComponent ?? "",
            "program_frames": programFrames,
            "two_lens_frames": ms.twoLensFrames,
            "one_lens_frames": ms.oneLensFrames,
            "parts_received": ms.partsReceived,
            "parts_decoded": ms.partsDecoded,
            // IOS-43: la edad de la parte al llegar; IOS-52: lo que tarda en cerrarse un hueco.
            "part_age_ms": master.map { m in ["p50": m.partAge.percentile(0.5), "p95": m.partAge.percentile(0.95),
                                               "p99": m.partAge.percentile(0.99)] } ?? [:],
            "slave_send_age_ms": slave == nil ? [:] : {
                lock.lock(); defer { lock.unlock() }
                return ["p50": sendAge.percentile(0.5), "p95": sendAge.percentile(0.95), "p99": sendAge.percentile(0.99),
                        "camera_age_p50": cameraAge.percentile(0.5), "camera_age_p95": cameraAge.percentile(0.95),
                        "render_p50": slaveRender.percentile(0.5), "render_p95": slaveRender.percentile(0.95)]
            }(),
            "idr_recovery_ms": master.map { m in ["count": m.idrRecovery.total, "p50": m.idrRecovery.percentile(0.5),
                                                   "p99": m.idrRecovery.percentile(0.99)] } ?? [:],
            "parts_lost": link?.lost ?? 0,
            "parts_mbps": link?.mbps ?? 0,
            "parts_jitter_ms": link?.jitterMs ?? 0,
            "idr_requests": ms.idrRequests,
            "without_master_frame": ms.withoutMasterFrame,
            "compose_failures": ms.composeFailures,
            "mov_video_frames": movFramesClosed.video + (recorder?.videoFrames ?? 0),
            "mov_audio_frames": movFramesClosed.audio + (recorder?.audioFrames ?? 0),
            // 2026-10-14: los segmentos de la copia, por qué se cortó y las sesiones de
            // VideoToolbox rehechas (al volver del segundo plano).
            "mov_segments": movSegments.count,
            "mov_failures": movFailures,
            "vt_session_resets": ["program_encoder": programEncoder?.sessionResets ?? 0,
                                  "part_encoder": slaveEncoder?.sessionResets ?? 0,
                                  "part_decoder": master?.decoderSessionResets ?? 0],
            "battery_by_minute": batteryByMinute,
            "disk_free_gb_by_minute": diskFreeGbByMinute,
            // IOS-06: la escalera actuando. El nivel de este móvil y el de su IA (la común)
            // por minuto, las detecciones de cada minuto (el último, a medias), y en `ladder`
            // cada cambio con su instante y lo que estaba en vigor al acabar.
            "ladder_by_minute": ladderByMinute,
            "ladder_ai_by_minute": ladderAiByMinute,
            "detect_runs_by_minute": detectRunsByMinute(),
            "ladder": ladderReport(),
            // Cómo emparejó el director las cajas de las dos cámaras: con la cadencia común en
            // la rejilla del soporte, completas y con desfase 0 (huérfanas solo al cambiar).
            "director_pairing": director.map { d -> [String: Any] in
                let p = d.pairing
                return ["complete": p.complete, "orphan_left": p.orphanLeft, "orphan_right": p.orphanRight,
                        "max_abs_skew_ms": Double(p.maxAbsSkewNs) / 1e6, "cycles": d.cyclesIngested]
            } ?? [:],
            "ts_audio_frames": tsAudioFrames,
            "peer_states": peerStates,
            "program_sources": master?.sources.counts ?? [:],
            "e0_written": e0?.written ?? 0,
            "e0_dropped": e0?.dropped ?? 0,
            "overlay_uploads": OverlayHub.shared?.uploads ?? 0,
            "ad_cues": adCues,
            "ad_bytes": AdHub.store?.usedBytes ?? 0,
            "ad_budget_bytes": AdHub.store?.budgetBytes ?? 0,
            "footprint_mb": footprintMb,
            // 2026-10-10: lo recibido por control (en el maestro, las miniaturas del
            // esclavo) y lo más que guardó su búfer; antes se quedaba con todo.
            "control_rx_bytes": transporte?.controlBytesReceived ?? -1,
            "control_buffer_peak_bytes": transporte?.controlBufferPeakBytes ?? -1,
            // 2026-10-11: cuándo subió cada pieza del enlace (ms desde el arranque del banco,
            // −1 si nunca), la línea de tiempo del transporte (sus segundos cuentan desde
            // `transport_t0_ms`), cuánto tardó la app en abrir el enlace desde que la lanzaron
            // y el arranque en el reloj del soporte, común a los dos móviles.
            "link_timeline_ms": linkTimeline.report(transport: transporte),
            "transport_events": enlace?.events ?? [],
            "transport_t0_ms": enlace.map { linkTimeline.msSinceStart($0.createdNs) } ?? 0,
            // 2026-10-15: cómo acaba el enlace y, si no está arriba, por qué.
            "link": linkReport(),
            "launch_to_bench_ms": LinkStartupTimeline.processStartUnixMs().map { startUnixMs - $0 } ?? -1,
            "bench_start_unix_ms": startUnixMs,
            "bench_start_rig_ms": (startHostNs + session.clock.offsetAt(ns: startHostNs)) / 1_000_000,
            "link_switches": ["RIG_SPLIT_NO_VIEWS", "RIG_SPLIT_NO_THUMBS", "RIG_SPLIT_SLAVE_NO_PARTS",
                              "RIG_SPLIT_NO_MOV", "RIG_SPLIT_NO_TS"].filter { env[$0] == "1" },
            "color_series": colorSeries,
            "exposure_bias": exposureApplied,
            "thermal_by_minute": thermalByMinute,
            "capture_clock_skew_ms": captureClockSkew(),
            "part_wait_ms": partWaitMs,
            "battery": Double(UIDevice.current.batteryLevel),
            "detect": detect?.report() ?? [:],
            // El coste medio de la app entera durante el banco, en % de UN núcleo
            // (100 = un núcleo lleno; el iPhone 17 tiene 6).
            "cpu_pct_one_core": 100 * (Self.processCpuSeconds() - cpuStartS)
                / max(1e-3, Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9),
            "cpu_cores": ProcessInfo.processInfo.activeProcessorCount,
            "ad_overrides": adOverridesDone,
            "ad_playlist": AdHub.rotation.map { r -> [String: Any] in
                let (desde, lista) = r.started
                return ["start_rig_ms": desde, "slots": lista.slots.map {
                    ["name": $0.ad.name, "frames": $0.ad.frames, "fps": $0.ad.fps, "loops": $0.loops]
                }]
            } ?? [:],
            "overlay_last_upload_ms": OverlayHub.shared?.lastUploadMs ?? 0,
            "color_observations": colorObservations,
            "color_gains_left": matcher.gains.left,
            "color_gains_right": matcher.gains.right,
            "program_fps_p5": pct(programIntervalsMs.map { 1000 / max($0, 0.001) }, 0.05),
            "program_interval_ms_p99": pct(programIntervalsMs, 0.99),
            "tick_fps_p5": pct(fpsTicks, 0.05),
            "tick_fps_p50": pct(fpsTicks, 0.5),
            "added_latency_ms_p50": pct(composeLatencyMs, 0.5),
            "added_latency_ms_p95": latenciaP95,
            "slave_parts": ss.parts,
            "slave_no_parts": ss.noParts,
            "slave_without_view": ss.withoutView,
            "slave_render_failures": ss.renderFailures,
            "slave_dropped": ss.dropped,
            "slave_idr_requests": ss.idrRequests,
        ]
        // El informe y el latido final, siempre los dos; los latidos que quedaran en la cola
        // del disco ya salieron con el `writerQueue.sync` de arriba.
        guard let base = Self.benchDirectory() else {
            NSLog("[split] sin carpeta Documents/bench: la pasada se queda sin informe")
            return
        }
        do {
            try ProgramRunFiles.writeFinal(
                report: informe,
                live: liveSnapshot(transcurrido: Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9,
                                   finished: true),
                directory: base, side: side.rawValue, startUnixMs: startUnixMs,
                endUnixS: Int64(Date().timeIntervalSince1970)
            )
        } catch {
            NSLog("[split] no se pudo escribir el informe final: %@", "\(error)")
        }
    }

    /// Documents/bench, donde van los informes, los latidos y lo grabado del banco.
    static func benchDirectory() -> URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("bench", isDirectory: true)
    }

    // MARK: - 2026-10-14: el latido

    /// El latido, cada `liveEveryS`: lo de `liveSnapshot`, al disco en su cola.
    private func writeLive(transcurrido: Double, finished: Bool) {
        if liveURL == nil, let base = Self.benchDirectory() {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            liveURL = base.appendingPathComponent(ProgramRunFiles.liveName(side: side.rawValue, startUnixMs: startUnixMs))
        }
        guard let url = liveURL,
              let datos = try? ProgramRunFiles.encode(liveSnapshot(transcurrido: transcurrido, finished: finished))
        else { return }
        writerQueue.async { try? datos.write(to: url, options: .atomic) }
    }

    /// Lo que se sabe de la pasada, barato (sin percentiles): contadores, la huella, la
    /// térmica, la batería y el disco, y lo grabado. En la cola del tic.
    private func liveSnapshot(transcurrido: Double, finished: Bool) -> [String: Any] {
        let ms = master?.stats ?? .init()
        let ss = slave?.stats ?? .init()
        let srt = publisher?.snapshot
        return [
            "name": "program-live",
            "purpose": config.purpose.rawValue,
            "single_camera": config.singleCamera,
            "finished": finished,
            "side": side.rawValue,
            "role": session.isMaster ? "master" : "slave",
            "device": BenchRunner.machine(),
            "elapsed_s": transcurrido,
            "bench_start_unix_ms": startUnixMs,
            "updated_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "rig": rigSource,
            "problem": setUpProblem,
            "program_frames": programFrames,
            "two_lens_frames": ms.twoLensFrames,
            "one_lens_frames": ms.oneLensFrames,
            "torn_frames": ms.tornFrames,
            "without_master_frame": ms.withoutMasterFrame,
            "part_fallbacks": partFallbacks,
            "parts_received": ms.partsReceived,
            "program_skipped_instants": programSkippedInstants,
            "slave_parts": ss.parts,
            "slave_no_parts": ss.noParts,
            "slave_without_view": ss.withoutView,
            "detect_runs": detect?.runCount ?? 0,
            "detect_runs_by_minute": detectRunsByMinute(),
            "ladder_level": governor.level.rawValue,
            "ladder_ai_level": governor.aiLevel(isMaster: session.isMaster).rawValue,
            "ladder_by_minute": ladderByMinute,
            "ladder_changes": Array(ladderChanges.suffix(Self.liveLadderChanges)),
            "peer_states": Array(peerStates.suffix(Self.livePeerStates)),
            "app_events": Array(appEvents.suffix(Self.livePeerStates)),
            "footprint_mb": Self.footprintMb(),
            "thermal": Self.thermalName(ProcessInfo.processInfo.thermalState),
            "thermal_by_minute": thermalByMinute,
            "battery": Double(UIDevice.current.batteryLevel),
            "battery_by_minute": batteryByMinute,
            "disk_free_gb": Double(CaptureEngine.freeDiskBytes()) / Self.bytesPerGb,
            "publish_source": publishTarget["source"] as? String ?? "",
            "srt_state": srt?.state ?? "",
            "mov_segments": movSegments.count,
            "mov_failures": movFailures,
            "mov_video_frames": movFramesClosed.video + (recorder?.videoFrames ?? 0),
            "vt_session_resets": ["program_encoder": programEncoder?.sessionResets ?? 0,
                                  "part_encoder": slaveEncoder?.sessionResets ?? 0,
                                  "part_decoder": master?.decoderSessionResets ?? 0],
            "files": recordedFiles(),
            // 2026-10-15: el enlace, en una frase y en cifras, y la línea de tiempo del
            // transporte (el arranque y los últimos sucesos): antes solo iba en el informe
            // final, y el esclavo que no enlazaba no lo escribía.
            "link": linkReport(),
            "transport_events": linkEvents()?.events ?? [],
        ]
    }

    /// El enlace para el latido y el informe: la frase («no ve al otro en 600 s…») y lo que
    /// la sostiene, con el estado de la sesión. Vacío sin enlace de Network.
    private func linkReport() -> [String: Any] {
        linkDiagnosis()?.report(session: session.state) ?? [:]
    }

    /// Los últimos cambios del esclavo y sucesos de la app que van en el latido.
    private static let livePeerStates = 20
}

// MARK: - La pareja de fotogramas para calibrar (IOS-70)

// El maestro elige los instantes (CalibrationPlan), se los manda al esclavo por el enlace
// y los dos guardan del anillo el fotograma de cada uno en Documents/calib/<id>/: JPEG q95
// 4K y su JSON. El id es el primer destino, el mismo en los dos móviles, así las parejas
// se encuentran por nombre. Lo sube IOS-71. Con RIG_CALIB_AT_S=<s> en el entorno, el
// maestro lo dispara solo a los <s> segundos de conectar (banco desatendido).

final class CalibrationPairs {
    private let session: RigLinkSession
    private let side: CameraSide
    private let engine: CaptureEngine
    private let lock = NSLock()
    private var capture: CalibrationStillCapture?
    private var autoArmed = false

    init(session: RigLinkSession, side: CameraSide, engine: CaptureEngine) {
        self.session = session
        self.side = side
        self.engine = engine
        session.onCalibrationCapture = { [weak self] destinos in
            self?.run(targets: destinos) { resumen in NSLog("[calib] esclavo: %@", resumen) }
        }
    }

    /// El reloj del soporte de este móvil, en ms: el del host más el desfase del enlace.
    private func nowRigMs() -> Int64 {
        let ns = RigLink.hostNowNs()
        return (ns + session.clock.offsetAt(ns: ns)) / 1_000_000
    }

    /// Lo dispara el maestro: manda los destinos y captura los suyos. Devuelve el
    /// resumen en JSON (o el error) cuando termina.
    func start(completion: @escaping (String) -> Void) {
        guard session.isMaster, case .connected = session.state else {
            completion(#"{"error":"solo el maestro con enlace calibra"}"#)
            return
        }
        // Desde el último fotograma propio: el adelanto y la separación son fotogramas
        // enteros a 30 fps (500 y 1000 ms), así los destinos caen en la rejilla del
        // maestro y el esclavo queda a la distancia de la fase, no de medio fotograma.
        let base = engine.rigPipeline?.ring.availableRigMs().last ?? nowRigMs()
        let destinos = CalibrationPlan.targets(nowRigMs: base)
        session.send(calibrationCapture: destinos)
        run(targets: destinos, completion: completion)
    }

    /// Con RIG_CALIB_AT_S, se arma una vez al tomar el rol de maestro y dispara a los <s>
    /// segundos de que haya enlace. El maestro toma su rol al arrancar, solo: contar desde
    /// ahí dejaba sin pareja la pasada en la que el esclavo llega tarde (`…-20261010-1106`,
    /// a los 102 s: a los 30 no había con quién calibrar y no se volvía a intentar).
    func armAutoTrigger(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let s = environment["RIG_CALIB_AT_S"].flatMap(Double.init), !autoArmed else { return }
        autoArmed = true
        fireWhenLinked(afterS: s)
    }

    /// Cada cuánto se mira si ya hay enlace para empezar a contar el disparo automático.
    private static let autoTriggerPollS = 1.0

    private func fireWhenLinked(afterS s: Double) {
        guard case .connected = session.state else {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.autoTriggerPollS) { [weak self] in
                self?.fireWhenLinked(afterS: s)
            }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, session.isMaster else { return }
            start { resumen in NSLog("[calib] maestro: %@", resumen) }
        }
    }

    private func run(targets: [Int64], completion: @escaping (String) -> Void) {
        guard let pipeline = engine.rigPipeline, let primero = targets.first else {
            completion(#"{"error":"sin cámara"}"#)
            return
        }
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let carpeta = docs.appendingPathComponent("calib/\(primero)", isDirectory: true)
        let look = engine.look()
        let cap = CalibrationStillCapture(
            side: side, ring: pipeline.ring,
            intrinsics: { [weak pipeline] ms in pipeline?.intrinsics(atRigMs: ms) },
            mountedUpsideDown: side == .left,
            directory: carpeta,
            extraMeta: {
                var m: [String: Any] = [
                    "device": BenchRunner.machine(),
                    "ios": UIDevice.current.systemVersion,
                ]
                if let look {
                    m["look"] = ["exposure_ns": look.exposureNs, "iso": look.iso, "aperture": look.aperture,
                                 "kelvin": look.kelvin, "tint": look.tint]
                }
                return m
            }
        )
        lock.lock(); capture = cap; lock.unlock()
        cap.capture(targets: targets, nowRigMs: { [weak self] in self?.nowRigMs() ?? 0 }) { resultado in
            let resumen: [String: Any]
            switch resultado {
            case let .success(fotos):
                resumen = [
                    "side": self.side.rawValue, "id": primero, "count": fotos.count,
                    "delta_ms": fotos.map(\.deltaMs), "rig_ms": fotos.map(\.rigMs),
                    "bytes_max": fotos.map(\.bytes).max() ?? 0,
                    "with_intrinsics": fotos.filter(\.hasIntrinsics).count,
                ]
            case let .failure(e):
                resumen = ["side": self.side.rawValue, "id": primero, "error": e.description]
            }
            let datos = (try? JSONSerialization.data(withJSONObject: resumen, options: [.sortedKeys])) ?? Data()
            try? datos.write(to: carpeta.appendingPathComponent("summary-\(self.side.rawValue).json"))
            completion(String(data: datos, encoding: .utf8) ?? "{}")
        }
    }
}

// MARK: - Las miniaturas del panel local (IOS-64)

// La última miniatura JPEG de cada cámara y del programa, a 1 Hz: la propia sale del
// anillo del pipeline; la del otro móvil llega por el enlace (`thumb`, la manda el
// esclavo); la del programa, del banco program-split. El panel las pide por Pigeon.

final class ThumbHub {
    static let shared = ThumbHub()

    private let lock = NSLock()
    private var latest: [String: Data] = [:]
    private var timer: DispatchSourceTimer?
    private let thumbnailer = Thumbnailer()
    private let programThumbnailer = Thumbnailer()
    private var programFrames = 0
    /// Cada cuántos fotogramas del programa se hace su miniatura (1 Hz a 30 fps).
    static let programEvery = 30

    func jpeg(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return latest[name]
    }

    private func store(_ name: String, _ data: Data) {
        lock.lock(); latest[name] = data; lock.unlock()
    }

    /// Arranca la de la cámara propia; si hay enlace, la manda (esclavo) o recibe la del
    /// otro (maestro).
    func start(side: CameraSide, pipeline: @escaping () -> RigPipeline?, session: RigLinkSession?,
               environment: [String: String] = ProcessInfo.processInfo.environment) {
        stop()
        let otro = side == .left ? "right" : "left"
        // RIG_SPLIT_NO_THUMBS=1: el esclavo no la manda (el banco de la memoria del maestro).
        let mandar = environment["RIG_SPLIT_NO_THUMBS"] != "1"
        session?.onThumb = { [weak self] d in self?.store(otro, d) }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.footballai.zero.thumbs", qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let ring = pipeline()?.ring, let ultimo = ring.availableRigMs().last,
                  let lease = ring.acquire(nearest: ultimo, maxDistanceMs: 0)
            else { return }
            let jpeg = thumbnailer?.jpeg(from: lease.buffer)
            ring.release(lease)
            guard let jpeg else { return }
            store(side.rawValue, jpeg)
            if mandar, let session, !session.isMaster { session.send(thumb: jpeg) }
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Un fotograma del programa: uno de cada `programEvery` se vuelve miniatura.
    func program(_ buffer: CVPixelBuffer) {
        programFrames += 1
        guard programFrames % Self.programEvery == 0, let jpeg = programThumbnailer?.jpeg(from: buffer) else { return }
        store("program", jpeg)
    }
}

// MARK: - El dominio del reloj del soporte (ADR 0023 §4, IOS-13/IOS-82)

// `clock_domain` nombra un reloj del soporte continuo. El maestro que arranca la
// referencia desde su reloj de host lo crea al azar; sobrevive a reiniciar la APP (se
// guarda junto a la hora de arranque del SISTEMA, y mientras esa no cambie el reloj de
// host es el mismo) y cambia si se reinicia el dispositivo. El esclavo adopta el del
// maestro con la pizarra (IOS-82) y lo conserva si se promueve: su recta del reloj sigue
// extrapolando desde su host, sin salto.

enum RigClockDomain {
    private static let keyDomain = "zero.clockDomain"
    private static let keyBoot = "zero.clockDomainBoot"
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Segundos de la hora de arranque del sistema (kern.boottime).
    static func bootTimeS() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Int(tv.tv_sec)
    }

    /// El dominio vigente: el guardado si es de este arranque del sistema; si no, uno nuevo.
    static func current() -> String {
        let d = UserDefaults.standard
        if let guardado = d.string(forKey: keyDomain), d.integer(forKey: keyBoot) == bootTimeS() {
            return guardado
        }
        let nuevo = "r" + String((0..<15).map { _ in alphabet.randomElement()! })
        adopt(nuevo)
        return nuevo
    }

    /// Adopta el dominio del maestro (lo trae la pizarra). Solo si es válido.
    static func adopt(_ domain: String) {
        guard domain.range(of: "^[a-z0-9]{8,32}$", options: .regularExpression) != nil else { return }
        UserDefaults.standard.set(domain, forKey: keyDomain)
        UserDefaults.standard.set(bootTimeS(), forKey: keyBoot)
    }
}


// MARK: - La carga del detector en el banco (SPK-54, parcial; IOS-73)

// El modelo de jugadores mientras se compone el programa. Vision recorta la franja central
// del fotograma de la cámara (todo el ancho y PLAYER_INPUT_HEIGHT / PLAYER_BAND_SCALE filas,
// a escala ×0,5 en los dos ejes, como la franja de verdad) y la lleva a la entrada del modelo.
// La salida heatmap del plan B se decodifica a cajas nativas con PlayerDecoder, y las cajas
// salen por `onDetections`: el esclavo las manda al maestro por el enlace; el maestro, a su
// director. Una sola petición a la vez: si el modelo sigue ocupado, el fotograma se salta y se
// cuenta; nunca se encola (CLAUDE.md §2).
/// Lo que el banco pide a un detector: ofrecerle un fotograma y su informe.
protocol BenchDetector: AnyObject {
    var onDetections: (([PlayerDetection], Int64, Double) -> Void)? { get set }
    /// Pasadas hechas y el error al montar, sin ordenar nada: la pantalla lo lee cada
    /// segundo desde la cola del programa (IOS-58).
    var runCount: Int { get }
    var loadError: String { get }
    func offer(_ buffer: CVPixelBuffer, rigMs: Int64, release: @escaping () -> Void)
    func report() -> [String: Any]
}

final class DetectLoad: BenchDetector {
    /// Las clases y el paso del CenterNet-MNv4 del plan B (ADR 0020).
    static let classes = ["goalkeeper", "player", "referee"]
    static let heatmapStride = 4

    var onDetections: (([PlayerDetection], Int64, Double) -> Void)?
    private let request: VNCoreMLRequest
    private let decoder: PlayerDecoder
    private let queue = DispatchQueue(label: "io.footballai.zero.split.detect", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var runs = 0
    private var skipped = 0
    private var failures = 0
    private var detections = 0
    private var latenciasMs: [Double] = []
    private var decodeMs: [Double] = []
    private let compileMs: Double
    private var layouts: [String: InputLayout] = [:]
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return runs }
    let loadError = ""

    init?(package: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = docs.appendingPathComponent("bench-resources/\(package)")
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let compilado = try MLModel.compileModel(at: url)
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let modelo = try VNCoreMLModel(for: MLModel(contentsOf: compilado, configuration: config))
            request = VNCoreMLRequest(model: modelo)
            request.imageCropAndScaleOption = .scaleFill
            decoder = try PlayerDecoder(
                classNames: Self.classes, postprocess: .heatmap, boxFormat: .heatmapStride,
                heatmapStride: Self.heatmapStride
            )
        } catch {
            NSLog("[split] detector %@: %@", package, "\(error)")
            return nil
        }
        compileMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// La franja central del fotograma (`ancho`×`alto` nativos) y su layout a la entrada.
    private func band(width: Int, height: Int) throws -> (CGRect, InputLayout) {
        let filas = min(Double(height), Double(DetectionSpec.playerInputHeight) / DetectionSpec.playerBandScale)
        let arriba = (Double(height) - filas) / 2
        let clave = "\(width)x\(height)"
        let layout = try layouts[clave] ?? InputLayout(regions: [InputRegion(
            dstX: 0, dstY: 0, dstW: DetectionSpec.playerInputWidth, dstH: DetectionSpec.playerInputHeight,
            srcX: 0, srcY: arriba, srcW: Double(width), srcH: filas
        )])
        layouts[clave] = layout
        // Vision mide desde abajo a la izquierda, normalizado.
        return (CGRect(x: 0, y: arriba / Double(height), width: 1, height: filas / Double(height)), layout)
    }

    func offer(_ buffer: CVPixelBuffer, rigMs: Int64, release: @escaping () -> Void) {
        lock.lock()
        if busy {
            skipped += 1
            lock.unlock()
            release()
            return
        }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            var cajas: [PlayerDetection]?
            var msDecode = 0.0
            do {
                let (roi, layout) = try band(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                request.regionOfInterest = roi
                try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
                var arrays: [String: MLMultiArray] = [:]
                for o in request.results as? [VNCoreMLFeatureValueObservation] ?? [] {
                    arrays[o.featureName] = o.featureValue.multiArrayValue
                }
                let t1 = DispatchTime.now().uptimeNanoseconds
                if let h = arrays["heatmap"], let off = arrays["offset"], let sz = arrays["size"] {
                    cajas = try decoder.decodeHeatmap(
                        heatmap: CoreMLPlayerDetector.planes(h), offset: CoreMLPlayerDetector.planes(off),
                        size: CoreMLPlayerDetector.planes(sz), layout: layout
                    )
                }
                msDecode = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
            } catch {
                cajas = nil
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            release()
            lock.lock()
            if let cajas {
                runs += 1
                detections += cajas.count
                latenciasMs.append(ms)
                decodeMs.append(msDecode)
            } else {
                failures += 1
            }
            busy = false
            lock.unlock()
            if let cajas { onDetections?(cajas, rigMs, ms) }
        }
    }

    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        func p(_ xs: [Double], _ q: Double) -> Double {
            let o = xs.sorted()
            return o.isEmpty ? 0 : o[min(o.count - 1, Int(q * Double(o.count)))]
        }
        return ["runs": runs, "skipped": skipped, "failures": failures, "detections": detections,
                "compile_load_ms": compileMs, "p50_ms": p(latenciasMs, 0.5), "p90_ms": p(latenciasMs, 0.9),
                "p99_ms": p(latenciasMs, 0.99), "decode_p50_ms": p(decodeMs, 0.5), "decode_p99_ms": p(decodeMs, 0.99)]
    }
}


// La cadena de PRODUCCIÓN en el banco (IOS-21/22/23 con el plan B): la franja central del
// NV12 a 1920x576 en Metal (DetectorInputBuilder), la inferencia en el ANE por el carril de
// jugadores (CoreMLRunner) y el heatmap a cajas nativas (PlayerDecoder), todo por
// CoreMLPlayerDetector. Se monta con el primer fotograma, que da el tamaño de la cámara.
final class MetalDetectLoad: BenchDetector {
    var onDetections: (([PlayerDetection], Int64, Double) -> Void)?
    private let queue = DispatchQueue(label: "io.footballai.zero.split.detect-metal", qos: .userInitiated)
    private let url: URL
    private let side: CameraSide
    private let lock = NSLock()
    private var detector: CoreMLPlayerDetector?
    private var montando = false
    private var busy = false
    private var runs = 0, skipped = 0, failures = 0, detections = 0
    private var totalMs: [Double] = []
    private var inferMs: [Double] = []
    private var loadMs = 0.0
    private var error = ""
    var runCount: Int { lock.lock(); defer { lock.unlock() }; return runs }
    var loadError: String { lock.lock(); defer { lock.unlock() }; return error }

    init?(package: String, side: CameraSide) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        url = docs.appendingPathComponent("bench-resources/\(package)")
        self.side = side
    }

    /// La ficha del CenterNet-MNv4 del plan B a 1920x576 (ADR 0020).
    private static func entry() throws -> ModelManifest.Entry {
        let (w, h, paso) = (DetectionSpec.playerInputWidth, DetectionSpec.playerInputHeight, DetectLoad.heatmapStride)
        let mapa = [1, DetectLoad.classes.count, h / paso, w / paso]
        return try ModelManifest.parse([
            "version": 1,
            "models": ["players": [
                "version": "0.0.0-sembrado", "file": "players-centernet-mnv4.mlpackage",
                "sha256": String(repeating: "0", count: 64), "min_ios": 18, "classes": DetectLoad.classes,
                "input": ["name": "image", "shape": [1, 3, h, w], "color": "RGB"],
                "outputs": [
                    ["name": "heatmap", "shape": mapa, "meaning": "heatmap"],
                    ["name": "offset", "shape": [1, 2, h / paso, w / paso], "meaning": "offset"],
                    ["name": "size", "shape": [1, 2, h / paso, w / paso], "meaning": "size"],
                ],
                "postprocess": "heatmap", "box_format": "heatmap_stride", "heatmap_stride": paso,
            ]],
        ]).models["players"]!
    }

    private func montar(width: Int, height: Int) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        Task.detached { [self] in
            do {
                let filas = min(height, Int(Double(DetectionSpec.playerInputHeight) / DetectionSpec.playerBandScale))
                let arriba = (height - filas) / 2
                let banda = try BandGeometry.fromDictionary([
                    "version": BandGeometry.fileVersion, "rows": [arriba, arriba + filas],
                    "input_size": [DetectionSpec.playerInputWidth, DetectionSpec.playerInputHeight],
                    "regions": [["dst": [0, 0, DetectionSpec.playerInputWidth, DetectionSpec.playerInputHeight],
                                 "src": [0, Double(arriba), Double(width), Double(filas)]]],
                    "side": side.rawValue,
                ])
                guard let ctx = MetalContext() else { throw RigError.message("sin Metal") }
                let builder = try DetectorInputBuilder(
                    context: ctx, band: banda, sourceWidth: width, sourceHeight: height, upsideDown: side == .left
                )
                let runner = try await CoreMLRunner.load(url: url, entry: Self.entry())
                let d = try CoreMLPlayerDetector(builder: builder, runner: runner, layout: banda.layout)
                lock.lock()
                detector = d
                loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                lock.unlock()
            } catch {
                lock.lock()
                self.error = "\(error)"
                lock.unlock()
                NSLog("[split] cadena del detector: %@", "\(error)")
            }
        }
    }

    func offer(_ buffer: CVPixelBuffer, rigMs: Int64, release: @escaping () -> Void) {
        lock.lock()
        guard let d = detector else {
            let montar = !montando && error.isEmpty
            montando = true
            lock.unlock()
            if montar { self.montar(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
            release()
            return
        }
        if busy {
            skipped += 1
            lock.unlock()
            release()
            return
        }
        busy = true
        lock.unlock()
        let t0 = DispatchTime.now().uptimeNanoseconds
        // La franja (Metal) y el envío al runner, fuera de la cola del tic del programa.
        queue.async { [self] in self.run(d, buffer, rigMs: rigMs, t0: t0, release: release) }
    }

    private func run(
        _ d: CoreMLPlayerDetector, _ buffer: CVPixelBuffer, rigMs: Int64, t0: UInt64, release: @escaping () -> Void
    ) {
        d.detect(buffer) { [self] resultado in
            // El builder ya copió la franja a su propio búfer: el del anillo se suelta aquí.
            release()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            lock.lock()
            busy = false
            switch resultado {
            case let .success((cajas, infer)):
                runs += 1
                detections += cajas.count
                totalMs.append(ms)
                inferMs.append(infer)
                lock.unlock()
                onDetections?(cajas, rigMs, ms)
            case .failure:
                failures += 1
                lock.unlock()
            }
        }
    }

    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        func p(_ xs: [Double], _ q: Double) -> Double {
            let o = xs.sorted()
            return o.isEmpty ? 0 : o[min(o.count - 1, Int(q * Double(o.count)))]
        }
        // 2026-10-14: la inferencia por tramos de ~1 min (450 pasadas a 7,5 Hz): si Core ML
        // cambia de unidad de cálculo a mitad (y con ello la memoria), se ve en el tramo.
        let tramos = stride(from: 0, to: inferMs.count, by: Self.runsPerMinute).map {
            p(Array(inferMs[$0..<min(inferMs.count, $0 + Self.runsPerMinute)]), 0.5)
        }
        return ["chain": "metal", "runs": runs, "skipped": skipped, "failures": failures, "detections": detections,
                "load_ms": loadMs, "error": error, "p50_ms": p(totalMs, 0.5), "p90_ms": p(totalMs, 0.9),
                "p99_ms": p(totalMs, 0.99), "infer_p50_ms": p(inferMs, 0.5), "infer_p99_ms": p(inferMs, 0.99),
                "infer_p50_ms_by_minute": tramos]
    }

    /// Pasadas del detector en un minuto a 7,5 Hz (L0). Con la escalera en L1 (5 Hz) cada
    /// tramo dura minuto y medio; las detecciones de cada minuto de verdad van en
    /// `detect_runs_by_minute` del informe.
    private static let runsPerMinute = 450
}
