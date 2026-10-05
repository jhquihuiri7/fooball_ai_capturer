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
import Foundation
import Network
import RigCore
import RigMedia
import RigNet
import UIKit

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

    private let session: RigLinkSession
    private let transport: NWLinkTransport

    /// La IP del otro móvil, o nil sin enlace (IOS-63).
    var peerHost: String? { transport.peerHost }

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

    /// La interfaz del enlace: Ethernet por el hub (ADR 0023) salvo RIG_LINK_INTERFACE=wifi,
    /// el banco sin cables.
    static func interfaceType(_ valor: String? = ProcessInfo.processInfo.environment["RIG_LINK_INTERFACE"])
        -> NWInterface.InterfaceType
    {
        valor == "wifi" ? .wifi : .wiredEthernet
    }

    /// El secreto del soporte, mientras no exista la provisión del Keychain (IOS-97).
    static func benchSecret() -> Data? {
        guard let valor = ProcessInfo.processInfo.environment["RIG_LINK_SECRET"],
              let secreto = Data(base64Encoded: valor),
              !secreto.isEmpty
        else {
            return nil
        }
        return secreto
    }

    /// El secreto del mando del partido (ADR 0023 §3), derivado aquí para que S no salga
    /// de nativo. nil sin secreto del soporte.
    static func controlSecret(matchId: String) -> String? {
        guard let secreto = benchSecret() else { return nil }
        return LinkAuth.controlSecret(secret: secreto, matchId: matchId)
    }

    /// El rol que negoció el enlace (IOS-80), con su term y su partido.
    var onRigRole: ((RigCore.RigRole, Int, String?) -> Void)?

    init(role: CameraRole, secret: Data, prefersMaster: Bool) {
        let side: RigLinkSession.Side = role == .left ? .left : .right
        // Escucha el izquierdo y conecta el derecho (ADR 0023): el anuncio lleva el lado
        // y la huella del secreto en la TXT, para no invitar a un soporte ajeno.
        let transport: NWLinkTransport
        if side == .left {
            transport = NWLinkTransport(mode: .advertise(
                name: UIDevice.current.name,
                txt: ["side": "left", "fp": LinkAuth.fingerprint(secret: secret)]
            ), interfaceType: Self.interfaceType())
        } else {
            transport = NWLinkTransport(mode: .browse, interfaceType: Self.interfaceType())
        }
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
                self?.onState?(.searching, "")
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
    }

    func stop() {
        session.stop()
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
//   RIG_LINK_INTERFACE  ethernet (por defecto, el hub) | wifi (banco sin cables)
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

    static func run(progress: BenchRunner.Progress?) throws -> URL {
        let entorno = ProcessInfo.processInfo.environment
        guard let lado = entorno["RIG_LINK_SIDE"].flatMap(RigLinkSession.Side.init(rawValue:)) else {
            throw BenchError.unknownBench("link-bench: falta RIG_LINK_SIDE=left|right")
        }
        guard let secreto = RigLinkNW.benchSecret() else {
            throw BenchError.unknownBench("link-bench: falta RIG_LINK_SECRET (base64)")
        }
        let interfaz = RigLinkNW.interfaceType(entorno["RIG_LINK_INTERFACE"])
        let duracion = entorno["RIG_LINK_BENCH_S"].flatMap(Double.init) ?? defaultDurationS
        let corteEn = entorno["RIG_LINK_CUT_AT_S"].flatMap(Int.init) ?? defaultCutAtS

        let transporte: NWLinkTransport = lado == .left
            ? NWLinkTransport(
                mode: .advertise(name: UIDevice.current.name,
                                 txt: ["side": "left", "fp": LinkAuth.fingerprint(secret: secreto)]),
                interfaceType: interfaz)
            : NWLinkTransport(mode: .browse, interfaceType: interfaz)
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
            progress?(Double(s + 1) / Double(pasos), "enlace \(lado.rawValue): \(conexiones > 0 ? "conectado" : "buscando")")
        }
        carga?.stop()
        let stats = transporte.stats
        let deLaCarga = carga?.counters() ?? [:]
        sesion.stop()

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
                "interface": entorno["RIG_LINK_INTERFACE"] ?? "ethernet",
                "peer": par,
                "internet_path": ruta,
                "rejections": rechazos.joined(separator: " | "),
                "rig_role": rolNegociado,
                "prefers_master": sesion.prefersMaster ? "1" : "0",
                "parts_profile": carga?.profileDescription ?? "",
                "pacing": "\(transporte.pacingBurstDatagrams) cada \(transporte.pacingIntervalUs) us",
            ],
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
        let destino = base.appendingPathComponent("link-bench-\(lado.rawValue)-\(informe.startedEpochS).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(informe).write(to: destino, options: .atomic)
        return destino
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
