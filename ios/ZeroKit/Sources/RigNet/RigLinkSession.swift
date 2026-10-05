// La sesión del enlace sobre LinkTransport (IOS-12, ADR 0023).
//
// Es el RigLink de hoy reescrito sobre el transporte nuevo: mismo contrato hacia
// fuera (estado, sellos de reloj, PTS, color, órdenes), otro cable por debajo. Lo que
// cambia con el ADR:
//   - las preguntas de hora van por MEDIOS (`clock_ping`/`clock_pong`) y solo
//     pregunta el esclavo: un reenvío de TCP falsearía la ida y vuelta;
//   - PTS, color y órdenes van por CONTROL, encapsulando el RigMessage de hoy en
//     tramas `legacy` hasta que cada tipo estrene su payload propio;
//   - todo pasa por el apretón de manos de IOS-16: hello → auth → clave de sesión →
//     tag por trama, con la ventana de 64 en medios.
//
// Sin reloj propio: los plazos entran por la cola que inyecta quien la crea, y los
// tests la sustituyen por una síncrona.

import CryptoKit
import Foundation
import os
import RigCore

public final class RigLinkSession {
    public enum Side: String, Codable, Sendable {
        case left, right
    }

    public enum State: Equatable, Sendable {
        case searching
        case authenticating
        case connected(peer: String)
        case rejected(String)
        /// Dos maestros de partidos distintos (ADR 0023 §7): sin partes ni órdenes, y las
        /// dos pantallas piden elegir.
        case conflict
        case off
    }

    /// El hello, en JSON como manda la decisión 1.
    struct Hello: Codable, Equatable {
        var linkVersion: Int
        var side: String
        var role: String
        var term: Int
        var matchId: String?
        var deviceId: String
        var appVersion: String
        var nonce: String  // 16 B en base64url
        /// «Este móvil dirige» (IOS-80). Opcional: un hello sin él es el de antes.
        var prefersMaster: Bool?

        enum CodingKeys: String, CodingKey {
            case linkVersion = "link_version"
            case side, role, term
            case matchId = "match_id"
            case deviceId = "device_id"
            case appVersion = "app_version"
            case nonce
            case prefersMaster = "prefers_master"
        }
    }

    public static let linkVersion = 1

    /// La ráfaga del reloj: 10 × 250 ms y después cada RIG_CLOCK_STEADY_S (5 s).
    static let clockBurstCount = 10
    static let clockBurstIntervalS = 0.25
    static let clockSteadyIntervalS = 5.0
    static let ptsTimeoutS = 1.5

    public var onState: ((State) -> Void)?
    /// Los cuatro sellos de una pregunta de hora, en ns del reloj de host.
    public var onStamps: ((Int64, Int64, Int64, Int64) -> Void)?
    /// Cada estimación nueva del reloj nativo (IOS-13). Solo la emite el esclavo, que
    /// es quien pregunta; la cámara lee `clock` directamente, sin pasar por aquí.
    public var onClockEstimate: ((RigClockEstimate) -> Void)?

    /// El reloj del soporte, alimentado con cada clock_pong. Es seguro entre hilos: la
    /// cámara le pregunta el desfase por fotograma mientras esta cola añade muestras.
    public let clock = RigClock()
    public var onLook: ((CameraLook) -> Void)?
    public var onCommand: ((RigWireCommand) -> Void)?
    /// De dónde saca el maestro sus PTS y su color cuando el esclavo los pide.
    public var recentPts: (() -> [Int64])?
    public var currentLook: (() -> CameraLook?)?
    /// El reloj de host, inyectable para los tests.
    public var hostNowNs: () -> Int64 = { 0 }

    /// Lo que este móvil dice de sí en el hello (IOS-80). Se fija antes de `start`; por
    /// defecto, lo de antes de los roles: el izquierdo dirige.
    public var claimedRole: RigRole
    public var term = 0
    public var matchId: String?
    public var prefersMaster: Bool

    /// El rol que salió de la negociación al conectar, con su term y partido. Hasta
    /// entonces, el reclamado.
    public private(set) var rigRole: RigRole
    public var isMaster: Bool { rigRole == .master }

    /// Cada negociación resuelta: rol, term y partido con los que sigue este móvil.
    public var onRole: ((RigRole, Int, String?) -> Void)?

    // MARK: - El render repartido (IOS-52, ADR 0023 §5)

    /// El esclavo recibe las últimas vistas del maestro (VIEW_HISTORY), de la más vieja
    /// a la más nueva.
    public var onViews: (([ViewCommand]) -> Void)?
    /// El maestro recibe una parte, con su hora de llegada en el reloj de host (ns).
    public var onPart: ((PartPacket, Int64) -> Void)?
    /// El maestro sabe que el esclavo no pinta nada en ese instante.
    public var onNoPart: ((NoPartPacket) -> Void)?
    /// El esclavo debe forzar un IDR: el maestro tiene un hueco en `part_seq`.
    public var onIdrRequest: ((UInt32) -> Void)?
    /// El maestro recibe la media BGR del solape del esclavo (IOS-38).
    public var onColorMeans: (([Double]) -> Void)?
    /// El esclavo debe guardar los fotogramas de estos instantes para calibrar (IOS-70).
    public var onCalibrationCapture: (([Int64]) -> Void)?

    public private(set) var state: State = .off {
        didSet { if oldValue != state { onState?(state) } }
    }

    private let transport: LinkTransport
    private let secret: Data
    private let side: Side
    private let deviceId: String
    private let appVersion: String
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "io.footballai.zero", category: "link-session")

    private var myHelloBytes = Data()
    private var theirHelloBytes = Data()
    private var theirHello: Hello?
    private var myNonce = Data()
    private var sessionKey: CryptoSessionKey?
    private var sessionId: UInt32 = 0
    private var seqControl: UInt32 = 0
    private var seqMedia: UInt32 = 0
    private var replay = ReplayWindow()
    private var pingGeneration = 0
    private var sentPings = 0
    private var pingT1BySeq: [UInt32: Int64] = [:]
    private var pendingPts: [(deadline: Date, completion: ([Int64]) -> Void)] = []

    public init(
        transport: LinkTransport,
        secret: Data,
        side: Side,
        deviceId: String,
        appVersion: String,
        queue: DispatchQueue = DispatchQueue(label: "io.footballai.zero.link-session")
    ) {
        self.transport = transport
        self.secret = secret
        self.side = side
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.queue = queue
        claimedRole = side == .left ? .master : .slave
        prefersMaster = side == .left
        rigRole = side == .left ? .master : .slave
        transport.onFrame = { [weak self] frame, channel in
            self?.queue.async { self?.handle(frame: frame, on: channel) }
        }
        transport.onState = { [weak self] estado in
            self?.queue.async { self?.transportChanged(estado) }
        }
    }

    // MARK: - Ciclo de vida

    public func start() {
        queue.async { [self] in
            state = .searching
            transport.start()
        }
    }

    public func stop() {
        queue.async { [self] in
            pingGeneration += 1
            transport.stop()
            resetSession()
            state = .off
        }
    }

    private func resetSession() {
        sessionKey = nil
        sessionId = 0
        seqControl = 0
        seqMedia = 0
        replay = ReplayWindow()
        theirHello = nil
        theirHelloBytes = Data()
        pingT1BySeq.removeAll()
    }

    private func transportChanged(_ estado: LinkTransportState) {
        switch estado {
        case .connected:
            sendHello()
        case .listening, .connecting:
            resetSession()
            if state != .off { state = .searching }
        case .failed, .idle:
            resetSession()
        }
    }

    // MARK: - El apretón de manos

    private func sendHello() {
        myNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let hello = Hello(
            linkVersion: Self.linkVersion,
            side: side.rawValue,
            role: claimedRole.rawValue,
            term: term,
            matchId: matchId,
            deviceId: deviceId,
            appVersion: appVersion,
            nonce: myNonce.base64EncodedString(),
            prefersMaster: prefersMaster
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        myHelloBytes = (try? encoder.encode(hello)) ?? Data()
        state = .authenticating
        send(type: .hello, payload: myHelloBytes, preSession: true)
    }

    private func handleHello(_ frame: LinkFrame) {
        guard let hello = try? JSONDecoder().decode(Hello.self, from: frame.payload) else {
            return reject("hello ilegible")
        }
        guard hello.linkVersion == Self.linkVersion else {
            return reject("versiones distintas (\(hello.linkVersion) y \(Self.linkVersion))")
        }
        guard hello.side != side.rawValue else {
            return reject("los dos dicen \(side.rawValue): invierte un lado")
        }
        theirHello = hello
        theirHelloBytes = frame.payload
        let mac = LinkAuth.authMac(secret: secret, myHello: myHelloBytes, theirHello: theirHelloBytes)
        send(type: .auth, payload: mac, preSession: true)
    }

    private func handleAuth(_ frame: LinkFrame) {
        guard let hello = theirHello else { return reject("auth antes del hello") }
        guard LinkAuth.verifyAuth(
            secret: secret, mac: frame.payload,
            theirHello: theirHelloBytes, myHello: myHelloBytes
        ) else {
            return reject("secreto distinto: empareja de nuevo")
        }
        guard let suNonce = Data(base64Encoded: hello.nonce) else {
            return reject("nonce ilegible")
        }
        let (nonceIzq, nonceDer) = side == .left ? (myNonce, suNonce) : (suNonce, myNonce)
        let key = LinkAuth.sessionKey(secret: secret, nonceLeft: nonceIzq, nonceRight: nonceDer)
        sessionKey = CryptoSessionKey(key: key)
        sessionId = LinkAuth.sessionId(key: key)
        let suyo = RoleClaim(
            side: hello.side == "left" ? .left : .right,
            role: RigRole(rawValue: hello.role) ?? .slave,
            term: hello.term,
            matchId: hello.matchId,
            prefersMaster: hello.prefersMaster ?? (hello.side == "left")
        )
        let mio = RoleClaim(
            side: side == .left ? .left : .right, role: claimedRole, term: term,
            matchId: matchId, prefersMaster: prefersMaster
        )
        switch RoleNegotiation.negotiate(mine: mio, theirs: suyo) {
        case .conflict:
            log.error("enlace en conflicto: dos maestros de partidos distintos")
            state = .conflict
            return
        case let .resolved(rol, nuevoTerm, partido, error):
            if let error { log.error("\(error)") }
            rigRole = rol
            term = nuevoTerm
            matchId = partido
            onRole?(rol, nuevoTerm, partido)
        }
        state = .connected(peer: hello.deviceId)
        // El maestro del reloj es el maestro del soporte: pregunta el esclavo.
        if !isMaster {
            startPinging()
        }
    }

    private func reject(_ motivo: String) {
        log.error("enlace rechazado: \(motivo)")
        resetSession()
        state = .rejected(motivo)
    }

    // MARK: - El reloj (solo pregunta el esclavo, por medios)

    private func startPinging() {
        pingGeneration += 1
        sentPings = 0
        schedulePing(generation: pingGeneration, after: 0)
    }

    private func schedulePing(generation: Int, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.pingGeneration,
                  case .connected = self.state
            else {
                return
            }
            self.seqMedia &+= 1
            let seq = self.seqMedia
            // El sello, lo más pegado posible al envío.
            let t1 = self.hostNowNs()
            self.pingT1BySeq[seq] = t1
            var payload = Data()
            payload.appendBigEndian(t1)
            self.send(type: .clockPing, payload: payload, seq: seq, channel: .media)
            self.sentPings += 1
            let siguiente = self.sentPings < Self.clockBurstCount
                ? Self.clockBurstIntervalS
                : Self.clockSteadyIntervalS
            self.schedulePing(generation: generation, after: siguiente)
        }
    }

    // MARK: - PTS, color y órdenes (por control)

    /// Los PTS recientes del maestro, o vacío si no contesta a tiempo.
    public func masterRecentPts(completion: @escaping ([Int64]) -> Void) {
        queue.async { [self] in
            guard case .connected = state else { return completion([]) }
            pendingPts.append((Date().addingTimeInterval(Self.ptsTimeoutS), completion))
            sendLegacy(.ptsRequest(seq: nextControlSeq()))
            queue.asyncAfter(deadline: .now() + Self.ptsTimeoutS) { [weak self] in
                self?.expirePendingPts()
            }
        }
    }

    private func expirePendingPts() {
        let ahora = Date()
        let vencidas = pendingPts.filter { $0.deadline <= ahora }
        pendingPts.removeAll { $0.deadline <= ahora }
        vencidas.forEach { $0.completion([]) }
    }

    /// El maestro manda una orden. El esclavo nunca manda: dos móviles mandándose el
    /// uno al otro se quedarían en un bucle.
    public func send(command: RigWireCommand) {
        queue.async { [self] in
            guard isMaster, case .connected = state else { return }
            sendLegacy(.command(seq: nextControlSeq(), command: command))
        }
    }

    public func publish(look: CameraLook) {
        queue.async { [self] in
            guard isMaster, case .connected = state else { return }
            sendLegacy(.look(seq: nextControlSeq(), look: look))
        }
    }

    /// El maestro manda las últimas vistas (las del director, IOS-42/IOS-73).
    public func send(views: [ViewCommand]) {
        queue.async { [self] in
            guard isMaster, case .connected = state else { return }
            seqMedia &+= 1
            send(type: .view, payload: ViewWire.encodeHistory(views), seq: seqMedia, channel: .media)
        }
    }

    /// El esclavo manda su parte codificada (IOS-43).
    public func send(part: PartPacket) {
        queue.async { [self] in
            guard !isMaster, case .connected = state else { return }
            seqMedia &+= 1
            let trama = part.frame()
            send(type: .part, payload: trama.payload, seq: seqMedia, channel: .media,
                 flags: trama.flags, rigMs: trama.rigMs)
        }
    }

    /// El esclavo dice que esta vista no necesita su lado.
    public func send(noPart: NoPartPacket) {
        queue.async { [self] in
            guard !isMaster, case .connected = state else { return }
            seqMedia &+= 1
            let trama = noPart.frame()
            send(type: .noPart, payload: trama.payload, seq: seqMedia, channel: .media, rigMs: trama.rigMs)
        }
    }

    /// El esclavo manda la media BGR de su solape (IOS-38), a 0,5 Hz.
    public func send(colorMeans bgr: [Double]) {
        queue.async { [self] in
            guard !isMaster, case .connected = state else { return }
            seqMedia &+= 1
            send(type: .colorMeans, payload: ColorMeansWire.encode(bgr: bgr), seq: seqMedia, channel: .media)
        }
    }

    /// El maestro pide al esclavo los fotogramas de estos instantes (IOS-70): `command`
    /// por control, en JSON, con `kind: calibration_capture` (ADR 0023 §1).
    public func send(calibrationCapture targets: [Int64]) {
        queue.async { [self] in
            guard isMaster, case .connected = state,
                  let payload = try? JSONSerialization.data(withJSONObject: [
                      "kind": Self.calibrationCaptureKind, "targets": targets,
                  ])
            else { return }
            send(type: .command, payload: payload, seq: nextControlSeq())
        }
    }

    static let calibrationCaptureKind = "calibration_capture"

    /// El maestro pide un IDR, por control, con el part_seq del hueco.
    public func requestIdr(partSeq: UInt32) {
        queue.async { [self] in
            guard isMaster, case .connected = state else { return }
            send(type: .idrRequest, payload: IdrRequestWire.encode(partSeq: partSeq), seq: nextControlSeq())
        }
    }

    // MARK: - Recepción

    private func handle(frame: LinkFrame, on channel: LinkChannel) {
        let llegada = hostNowNs()
        switch frame.type {
        case .hello:
            return handleHello(frame)
        case .auth:
            return handleAuth(frame)
        default:
            break
        }
        // Del apretón para abajo, todo va firmado y con la sesión puesta.
        guard let sessionKey, frame.session == sessionId,
              LinkAuth.verifyTag(key: sessionKey.key, frame: frame)
        else {
            return
        }
        if channel == .media, !replay.accept(frame.seq) {
            return
        }
        switch frame.type {
        case .clockPing:
            guard isMaster else { return }
            var reader = BigEndianReader(data: frame.payload)
            guard let t1 = reader.read(Int64.self) else { return }
            var payload = Data()
            payload.appendBigEndian(t1)
            payload.appendBigEndian(llegada)          // t2
            payload.appendBigEndian(hostNowNs())      // t3
            seqMedia &+= 1
            send(type: .clockPong, payload: payload, seq: seqMedia, channel: .media)
        case .clockPong:
            guard !isMaster else { return }
            var reader = BigEndianReader(data: frame.payload)
            guard let t1 = reader.read(Int64.self),
                  let t2 = reader.read(Int64.self),
                  let t3 = reader.read(Int64.self)
            else {
                return
            }
            onStamps?(t1, t2, t3, llegada)
            clock.add(solveClockSample(t1: t1, t2: t2, t3: t3, t4: llegada))
            if let estimate = clock.estimate {
                onClockEstimate?(estimate)
            }
        case .legacy:
            handleLegacy(frame.payload)
        case .view:
            guard !isMaster, let vistas = ViewWire.decodeHistory(frame.payload) else { return }
            onViews?(vistas)
        case .part:
            guard isMaster, let parte = PartPacket.decode(frame) else { return }
            onPart?(parte, llegada)
        case .noPart:
            guard isMaster, let nada = NoPartPacket.decode(frame) else { return }
            onNoPart?(nada)
        case .idrRequest:
            guard !isMaster, let seq = IdrRequestWire.decode(frame.payload) else { return }
            onIdrRequest?(seq)
        case .colorMeans:
            guard isMaster, let bgr = ColorMeansWire.decode(frame.payload) else { return }
            onColorMeans?(bgr)
        case .command:
            guard !isMaster,
                  let orden = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                  orden["kind"] as? String == Self.calibrationCaptureKind,
                  let destinos = orden["targets"] as? [NSNumber]
            else { return }
            onCalibrationCapture?(destinos.map(\.int64Value))
        default:
            break
        }
    }

    private func handleLegacy(_ payload: Data) {
        guard let mensaje = RigMessage.decode(payload) else { return }
        switch mensaje {
        case let .ptsRequest(seq):
            guard isMaster else { return }
            sendLegacy(.ptsReply(seq: seq, pts: recentPts?() ?? []))
        case let .ptsReply(_, pts):
            let pendientes = pendingPts
            pendingPts.removeAll()
            pendientes.forEach { $0.completion(pts) }
        case let .lookRequest(seq):
            guard isMaster, let look = currentLook?() else { return }
            sendLegacy(.look(seq: seq, look: look))
        case let .look(_, look):
            guard !isMaster else { return }
            onLook?(look)
        case let .command(_, command):
            guard !isMaster else { return }
            onCommand?(command)
        case .ping, .pong:
            break  // el reloj va por clock_ping/clock_pong, no por legacy
        }
    }

    // MARK: - Envío

    private func nextControlSeq() -> UInt32 {
        seqControl &+= 1
        return seqControl
    }

    private func sendLegacy(_ mensaje: RigMessage) {
        send(type: .legacy, payload: mensaje.encode(), seq: nextControlSeq(), channel: .control)
    }

    private func send(
        type: LinkFrameType,
        payload: Data,
        seq: UInt32 = 0,
        channel: LinkChannel = .control,
        preSession: Bool = false,
        flags: LinkFrame.Flags = [],
        rigMs: UInt64 = 0
    ) {
        var frame = LinkFrame(
            type: type,
            flags: flags,
            session: preSession ? 0 : sessionId,
            seq: seq,
            rigMs: rigMs,
            payload: payload,
            tag: Data()
        )
        if !preSession {
            guard let sessionKey else { return }
            frame.tag = LinkAuth.tag(key: sessionKey.key, frame: frame)
        }
        transport.send(frame, on: channel)
    }
}

/// La clave vive envuelta para no exponer CryptoKit en la firma pública.
struct CryptoSessionKey {
    let key: SymmetricKey
}
