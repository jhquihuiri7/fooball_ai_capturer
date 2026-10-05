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

    /// La sesión, para los bancos que hablan el render repartido (program-split).
    let session: RigLinkSession
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
//   RIG_SPLIT_PART_MBPS     bitrate de la parte (12: por Wi-Fi caben ~15, SPK-02)
//   RIG_SPLIT_SWEEP_DEG     amplitud del barrido en yaw (30)
//   RIG_SPLIT_SWEEP_S       periodo del barrido (20)
//   RIG_SPLIT_HFOV_DEG      el encuadre (60)
//   RIG_SPLIT_DIRECTOR      1: dirige el DirectorService (IOS-73) con las detecciones
//   RIG_NOMINAL_YAW_DEG     sin Documents/rig.json, la apertura de cada cámara (DEFAULT_RIG_YAW_DEG)
//   RIG_NOMINAL_HFOV_DEG    y su HFOV (106, la ultra gran angular)
//   RIG_NOMINAL_PITCH_DEG   y su pitch (DEFAULT_RIG_PITCH_DEG)

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

    private let session: RigLinkSession
    private let side: CameraSide
    private let pipelineProvider: () -> RigPipeline?
    private let env: [String: String]
    private let queue = DispatchQueue(label: "io.footballai.zero.split", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let startNs = DispatchTime.now().uptimeNanoseconds
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
    /// El micro del iPhone es mono: el PMT declara el AAC desde el primer paquete.
    private static let micChannels = 1
    private let muxer = TsMuxer(
        audio: CaptureEngine.audioEnabled
            ? TsMuxer.AudioConfig(sampleRate: AudioConstants.sampleRate, channels: micChannels) : nil
    )
    /// El primer instante de vídeo del .ts: el audio de antes no entra (IOS-54).
    private var firstVideoT: Int64?
    private var tsFile: FileHandle?
    private var tsURL: URL?
    // IOS-57: la copia local del programa en .mov (con el audio del micro si lo hay).
    private var recorder: ProgramRecorder?
    var audioFormat: () -> CMAudioFormatDescription? = { nil }
    /// Para y reanuda la cámara (IOS-84: RIG_SPLIT_CAM_OFF_S / RIG_SPLIT_CAM_ON_S).
    var cameraSwitch: ((Bool) -> Void)?
    private var cameraOffDone = false
    /// IOS-48: el cue de la franja una vez por segundo y los overrides programados
    /// (RIG_ADS_OVERRIDES="gol:2@30,gol:1@200": nombre, vueltas y segundo del banco).
    private var adCues: [[Any]] = []
    private var lastAdCueT: Int64?
    private var adOverridesDone: [[String: Any]] = []
    /// La huella del proceso una vez por minuto, en MB: que no crezca (IOS-47/48).
    private var footprintMb: [Double] = []
    private var cameraOnDone = false
    private var finished = false

    // Medidas
    private var tickIntervalsMs: [Double] = []
    private var lastTickNs: UInt64?
    private var composeLatencyMs: [Double] = []
    private var programFrames = 0

    init(session: RigLinkSession, side: CameraSide, pipeline: @escaping () -> RigPipeline?,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.session = session
        self.side = side
        pipelineProvider = pipeline
        env = environment
        durationS = environment["RIG_SPLIT_S"].flatMap(Double.init) ?? 600
    }

    private func number(_ key: String, _ def: Double) -> Double {
        env[key].flatMap(Double.init) ?? def
    }

    /// Una trama AAC del micro (con RIG_AUDIO=1): a la copia local del programa.
    func audio(_ trama: AacFrame) {
        queue.async { [weak self] in
            guard let self else { return }
            try? recorder?.append(audio: trama)
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
                    ts.write(datos)
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
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Self.fps, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        session.onViews = { [weak self] vistas in self?.slave?.receive(views: vistas) }
        session.onIdrRequest = { [weak self] _ in self?.slave?.requestIdr() }
        session.onPart = { [weak self] parte, _ in
            self?.master?.receive(part: parte, arrivalRigMs: Self.nowMs())
        }
        session.onNoPart = { [weak self] nada in self?.master?.receive(noPart: nada) }
        // IOS-81: con el esclavo caído, una lente y sin esperar su parte; al volver, las dos.
        session.onPeerState = { [weak self] estado in
            self?.queue.async {
                guard let self, self.session.isMaster else { return }
                self.peerStates.append("\(Self.nowMs()):\(estado.rawValue)")
                let caido = estado == .down
                self.master?.peerDown = caido
                self.director?.setSingleLens(caido ? self.side : nil)
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

            // Esclavo: su parte.
            let enc = try VideoEncoder(
                width: Self.programWidth, height: Self.programHeight,
                bitrateBps: Int(number("RIG_SPLIT_PART_MBPS", 12) * 1_000_000), viewId: side == .left ? 0 : 1
            )
            let s = SlavePartStage(
                side: side,
                resolver: SlaveViewResolver(frameDurationMs: 1000 / Self.fps),
                renderer: try MetalPartRenderer(context: ctx, rig: modelo, side: side,
                                                width: Self.programWidth, height: Self.programHeight),
                encoder: enc
            )
            s.onPart = { [weak self] p in self?.session.send(part: p) }
            s.onNoPart = { [weak self] n in self?.session.send(noPart: n) }
            slaveEncoder = enc
            slave = s
            pipeline.onFrame = { [weak self] meta in self?.slaveFrame(meta, ring: ring) }

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
                masterPool: pool
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
                return (lease.buffer, { ring.release(lease) })
            }
            m.onIdrRequest = { [weak self] seq in self?.session.requestIdr(partSeq: seq) }
            // IOS-84: sin ninguna cámara, la tarjeta SIN SEÑAL (la sube Dart, oculta).
            m.onSourceChange = { fuente in OverlayHub.shared?.setVisible(.slate, fuente == .noSignal) }
            if env["RIG_SPLIT_DIRECTOR"] == "1" {
                let loop = try DirectorLoop(
                    rig: modelo, canvas: CylindricalCanvas.fit(modelo, pitchLimitsRad: (-0.5, 0.1)),
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
                let id = "banco-\(Int(Date().timeIntervalSince1970))"
                e0 = try? E0Logger(
                    url: docs.appendingPathComponent("n0/\(id)-\(side.rawValue).jsonl"),
                    header: .header(matchId: id, rigId: "banco",
                                    // El dominio del reloj de host de este arranque (ADR 0023 §4).
                                    clockDomain: "banco" + String(format: "%08x", UInt32.random(in: .min ... .max)),
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
        let ms = meta.rigNs / 1_000_000
        guard let lease = ring.acquire(nearest: ms, maxDistanceMs: 1) else { return }
        slave.process(frame: lease.buffer, frameRigMs: ms, ptsNs: meta.ptsNs)
        ring.release(lease)
    }

    // MARK: - Maestro

    /// El barrido de guion: un seno en yaw que cruza la costura, a pitch y HFOV fijos.
    private func scriptedView(_ t: Int64) -> ViewCommand {
        guard let rig else { fatalError("sin soporte") }
        let a = number("RIG_SPLIT_SWEEP_DEG", 30) * .pi / 180
        let periodo = number("RIG_SPLIT_SWEEP_S", 20)
        let hfov = number("RIG_SPLIT_HFOV_DEG", 60) * .pi / 180
        let costura = (rig.camera(.left).pose.yawRad + rig.camera(.right).pose.yawRad) / 2
        let pitch = (rig.camera(.left).pose.pitchRad + rig.camera(.right).pose.pitchRad) / 2
        let yaw = costura + a * sin(2 * .pi * Double(t) / 1000 / periodo)
        let lados: [CameraSide]
        if let v = try? RectilinearView(yawRad: yaw, pitchRad: pitch, hfovRad: hfov,
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
        if transcurrido >= Double(footprintMb.count) * Self.footprintEveryS {
            footprintMb.append(Self.footprintMb())
        }
        if case .connected = session.state, setUpIfNeeded() {
            colorTick(now: Self.nowMs())
        }
        // El maestro compone SIEMPRE, con enlace o sin él (IOS-81: el programa no se
        // para porque caiga el esclavo); las vistas solo salen si hay sesión.
        guard session.isMaster, setUpIfNeeded(), let master else {
            return
        }
        let ahora = DispatchTime.now().uptimeNanoseconds
        if let previo = lastTickNs { tickIntervalsMs.append(Double(ahora - previo) / 1e6) }
        lastTickNs = ahora

        let now = Self.nowMs()
        // La rejilla del programa: instantes k · 33,3 ms (ProgramClock, IOS-84).
        let reloj = ProgramClock(frameDurationMs: 1000 / Self.fps)
        let rejilla = { (ms: Int64) in reloj.gridInstant(atOrBefore: ms) }
        if let director {
            director.setGains(matcher.gains)
            if let (_, hist) = try? director.tick(targetRigMs: rejilla(now + Self.viewLeadMs)) {
                hist.forEach { if history.view(at: $0.targetRigMs) == nil { history.append(ViewWire.quantized($0)) } }
            }
        } else {
            history.append(scriptedView(rejilla(now + Self.viewLeadMs)))
        }
        session.send(views: history.message())

        // Con el esclavo caído no se espera su parte (IOS-81).
        let espera = master.peerDown ? 0 : LinkConstants.partMaxWaitMs
        let t = rejilla(now - espera)
        guard t != lastProgramT else { return }
        lastProgramT = t
        let inicio = DispatchTime.now().uptimeNanoseconds
        let vistaPropia = history.view(at: t) ?? scriptedView(t)
        e0Ticks += 1
        if e0Ticks % Self.e0ViewEvery == 0 {
            let grados = 180 / Double.pi
            e0?.log(.view(rigMs: t, yawDeg: vistaPropia.yawRad * grados, pitchDeg: vistaPropia.pitchRad * grados,
                          hfovDeg: vistaPropia.hfovRad * grados, shot: director == nil ? "script" : "director"))
        }
        if t - (lastAdCueT ?? t - Self.adCueEveryMs) >= Self.adCueEveryMs, let (_, cue) = AdHub.rotation?.strip(atRigMs: t) {
            lastAdCueT = t
            adCues.append([t, cue.ad.name, cue.frame])
        }
        if master.tick(programRigMs: t, nowRigMs: now, masterView: vistaPropia) != nil {
            composeLatencyMs.append(Double(now - t) + Double(DispatchTime.now().uptimeNanoseconds - inicio) / 1e6)
        }
        drainProgram()
    }

    private static let footprintEveryS = 60.0

    /// `phys_footprint` del proceso, lo que mira jetsam, en MB.
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

    private func program(_ buffer: CVPixelBuffer, t: Int64) {
        ThumbHub.shared.program(buffer)
        programEncoder?.encode(buffer, ptsNs: t * 1_000_000, rigMs: UInt64(max(0, t)))
        programFrames += 1
    }

    private func drainProgram() {
        guard let enc = programEncoder else { return }
        if tsFile == nil {
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
            if recorder == nil, let fd = f.formatDescription, let url = tsURL?.deletingPathExtension().appendingPathExtension("mov") {
                recorder = try? ProgramRecorder(url: url, videoFormat: fd, audioFormat: audioFormat())
            }
            try? recorder?.append(video: f)
            var avcc = f.data
            if f.isKeyframe, let fd = f.formatDescription {
                avcc = H264ParameterSets.avccNals(from: fd) + avcc
            }
            let pts = f.ptsNs * 90 / 1_000_000
            if firstVideoT == nil { firstVideoT = f.ptsNs / 1_000_000 }
            tsFile?.write(muxer.muxVideo(avcc: avcc, parameterSets: [], isKeyframe: f.isKeyframe,
                                         pts90k: pts, dts90k: pts))
        }
    }

    // MARK: - Informe

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        programEncoder?.flush()
        drainProgram()
        e0?.flush()
        let espera = DispatchSemaphore(value: 0)
        if let r = recorder { r.finish { _ in espera.signal() }; _ = espera.wait(timeout: .now() + 5) }
        try? tsFile?.close()
        guard session.isMaster || slave != nil else { return }
        func pct(_ xs: [Double], _ q: Double) -> Double {
            let o = xs.sorted()
            return o.isEmpty ? 0 : o[min(o.count - 1, Int(q * Double(o.count)))]
        }
        let ms = master?.stats ?? .init()
        let ss = slave?.stats ?? .init()
        let link = master?.linkStats(nowRigMs: Self.nowMs())
        let fpsTicks = tickIntervalsMs.map { 1000 / max($0, 0.001) }
        let informe: [String: Any] = [
            "name": "program-split",
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
            "parts_lost": link?.lost ?? 0,
            "parts_mbps": link?.mbps ?? 0,
            "parts_jitter_ms": link?.jitterMs ?? 0,
            "idr_requests": ms.idrRequests,
            "without_master_frame": ms.withoutMasterFrame,
            "compose_failures": ms.composeFailures,
            "mov_video_frames": recorder?.videoFrames ?? 0,
            "mov_audio_frames": recorder?.audioFrames ?? 0,
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
            "tick_fps_p5": pct(fpsTicks, 0.05),
            "tick_fps_p50": pct(fpsTicks, 0.5),
            "added_latency_ms_p50": pct(composeLatencyMs, 0.5),
            "added_latency_ms_p95": pct(composeLatencyMs, 0.95),
            "slave_parts": ss.parts,
            "slave_no_parts": ss.noParts,
            "slave_without_view": ss.withoutView,
            "slave_render_failures": ss.renderFailures,
            "slave_dropped": ss.dropped,
            "slave_idr_requests": ss.idrRequests,
        ]
        guard let base = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            .appendingPathComponent("bench", isDirectory: true),
            let json = try? JSONSerialization.data(withJSONObject: informe, options: [.sortedKeys, .prettyPrinted])
        else { return }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? json.write(to: base.appendingPathComponent(
            "program-split-\(side.rawValue)-\(Int(Date().timeIntervalSince1970)).json"))
    }
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

    /// Con RIG_CALIB_AT_S, se arma una vez al conectar como maestro.
    func armAutoTrigger(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let s = environment["RIG_CALIB_AT_S"].flatMap(Double.init), !autoArmed else { return }
        autoArmed = true
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
    func start(side: CameraSide, pipeline: @escaping () -> RigPipeline?, session: RigLinkSession?) {
        stop()
        let otro = side == .left ? "right" : "left"
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
            if let session, !session.isMaster { session.send(thumb: jpeg) }
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
