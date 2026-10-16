// El publicador del programa por SRT al VPS (IOS-56; ADR 0022 §1-§3 y §8).
//
// El maestro codifica el programa (VideoEncoder, con la SEI del rigMs en cada fotograma) y
// el AAC (AacEncoder); aquí entran esas unidades de acceso, se multiplexan en MPEG-TS
// (TsMuxer) justo al enviarlas y salen por SrtSocket a `publish:programa:<user>:<pass>`.
//
// - Cola acotada (ProgramSendQueue, ~1 s): si SRT no traga, se tira hasta el siguiente IDR
//   y se pide uno (`onIdrRequest`); nunca se encola sin fin.
// - Con el búfer de envío de SRT por encima de `congestionSendBufferMs` no se le mete más:
//   se retiene en la cola, que es la que decide tirar. Mientras se retiene no se piden IDR:
//   llegarían retenidos y la cola los tiraría al segundo (y pediría otro: 84 IDR forzados
//   en 160 s a 1 Mbit/s, medido el 2026-10-15). Se dejan pendientes y se piden cuando el
//   búfer baja.
// - El vigía de atasco (2026-10-15): si la conexión sigue viva pero en `stallReconnectS`
//   no ha entrado ningún fotograma de vídeo en SRT aunque el codificador los traiga, se
//   cierra y se vuelve a conectar como tras un corte (`stallReconnects` lo cuenta).
// - Bitrate adaptativo (AdaptiveRate) con las estadísticas de SRT una vez por segundo; el
//   bitrate nuevo sale por `onBitrate` para el codificador.
// - Reconexión cada 3 s (ReconnectBackoff; tras rechazos seguidos, hasta 30 s). Un
//   streamid o una passphrase que no valen no se reintentan: `.failed`.
// - Al conectar se vacía la cola, se pide un IDR y el TS empieza de nuevo (PAT/PMT y
//   contadores): MediaMTX ve un publicador nuevo.
//
// Ni el usuario, ni la clave, ni la passphrase salen de aquí: los logs dicen host y
// puerto, y los errores son los de SrtError, que no los llevan.
//
// Todo pasa en una cola serie propia; la conexión, que bloquea hasta 5 s, en otra. Los
// avisos (`onBitrate`, `onIdrRequest`, `onState`, `onLog`) llegan en la cola del
// publicador: no llaman a `stop()` desde ellos.

import Foundation
import RigCore

/// Lo que el publicador necesita de un socket SRT: SrtSocket, o uno falso en las pruebas.
public protocol ProgramSrtSink: AnyObject {
    func connect(to target: ProgramSrtTarget, query: String?, latencyMs: Int32, timeoutMs: Int32) throws
    var isConnected: Bool { get }
    func send(_ data: Data) throws -> Int
    func stats(clear: Bool) throws -> SrtStats
    func sendBufferMs() -> Int?
    func close()
}

extension SrtSocket: ProgramSrtSink {}

public final class ProgramPublisher {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        case publishing
        /// Tras un fallo, hasta el próximo intento. El porqué, sin secretos.
        case waiting(String)
        /// El destino no vale (streamid o passphrase): no se reintenta.
        case failed(String)
    }

    public struct Timing: Sendable {
        public var statsEveryS = ProgramPublish.statsEveryS
        /// Multiplica las esperas de reconexión: 1 en la app; las pruebas las acortan.
        public var reconnectScale = 1.0
        public var latencyMs = ProgramSrt.latencyMs
        public var connectTimeoutMs = ProgramSrt.connectTimeoutMs
        /// El reloj monótono, en ms: la espera de la cola se mide con él.
        public var nowMs: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

        public init() {}
    }

    /// Lo que se cuenta para el informe del banco y la telemetría (IOS-89). Los totales de
    /// SRT suman todas las conexiones.
    public struct Stats: Codable, Equatable, Sendable {
        public var state = "stopped"
        public var connects = 0
        public var reconnects = 0
        public var connectFailures = 0
        public var rejections = 0
        public var lastError: String?
        public var publishingS = 0.0
        public var bitrateBps = 0
        public var bitrateMinBps = 0
        public var bitrateChanges = 0
        public var sendRateMbps = 0.0
        public var rttMs = 0.0
        public var rttMsMax = 0.0
        public var sendBufferMsMax = 0
        public var srtPacketsSent: Int64 = 0
        public var srtPacketsLost: Int64 = 0
        public var srtPacketsRetransmitted: Int64 = 0
        public var srtPacketsDropped: Int64 = 0
        public var srtBytesSent: UInt64 = 0
        public var videoFramesSent = 0
        public var audioFramesSent = 0
        public var videoDropped = 0
        public var audioDropped = 0
        /// Fotogramas y tramas que llegaron sin conexión (conectando o esperando).
        public var videoDroppedWhileDown = 0
        public var audioDroppedWhileDown = 0
        public var congestions = 0
        public var idrRequests = 0
        public var partialSends = 0
        public var sendHolds = 0
        /// Reconexiones del vigía de atasco: la conexión seguía viva y en `stallReconnectS`
        /// no entró vídeo en SRT.
        public var stallReconnects = 0
        /// El rigMs del último fotograma entregado a SRT: el `anchor` del túnel (IOS-65).
        public var lastSentRigMs: UInt64?
        /// Segundos desde que el último fotograma de vídeo entró en SRT, en cualquier
        /// conexión; nil si aún ninguno. Lo que el informe y el latido enseñan como
        /// «último vídeo enviado hace N s».
        public var lastSentAgeS: Double?
    }

    public var onBitrate: ((Int) -> Void)?
    public var onIdrRequest: (() -> Void)?
    public var onState: ((State) -> Void)?
    public var onLog: ((String) -> Void)?

    private let target: ProgramSrtTarget
    private let query: String?
    private let audio: TsMuxer.AudioConfig?
    private let timing: Timing
    private let makeSink: () -> ProgramSrtSink
    private let queue = DispatchQueue(label: "io.footballai.zero.program-publisher", qos: .userInitiated)
    private let connectQueue = DispatchQueue(label: "io.footballai.zero.program-publisher.connect", qos: .utility)

    // Solo en `queue`.
    private var state: State = .stopped
    private var generation = 0
    private var sink: ProgramSrtSink?
    private var muxer: TsMuxer
    private var sendQueue = ProgramSendQueue()
    private var rate: AdaptiveRate
    private var backoff = ReconnectBackoff()
    private var ceilingBps: Int?
    private var timer: DispatchSourceTimer?
    private var stats = Stats()
    /// Los totales de SRT de las conexiones ya cerradas, y los últimos de la vigente.
    private var closed = (sent: Int64(0), bytes: UInt64(0), lost: Int64(0), retx: Int64(0), dropped: Int64(0))
    private var lastTotals = SrtStats()
    private var connectedAtMs: Double?
    private var congestionsAtSample = 0
    private var partialsAtSample = 0
    /// Cuándo (reloj monótono) entró en SRT el último fotograma de vídeo.
    private var lastVideoSentAtMs: Double?
    /// Cuándo llegó el primer fotograma de vídeo que aún no ha salido por esta conexión:
    /// lo que mide el vigía de atasco. nil mientras lo que llega va saliendo.
    private var firstUnsentVideoAtMs: Double?
    /// Un IDR que se debió pedir mientras SRT estaba retenido: se pide al bajar el búfer.
    private var idrPending = false
    /// Desde cuándo (reloj monótono) la muestra ve el búfer de envío por encima de la
    /// latencia SRT; nil cuando baja.
    private var bufferOverLatencySinceMs: Double?

    /// `maximumBps` es el techo de fábrica (PROGRAM_VIDEO_BITRATE_BPS); `startBps`, el
    /// bitrate con el que arranca el codificador (por defecto, el techo).
    public init(target: ProgramSrtTarget, query: String? = nil, audio: TsMuxer.AudioConfig?,
                maximumBps: Int, startBps: Int? = nil, timing: Timing = .init(),
                makeSink: @escaping () -> ProgramSrtSink = { SrtSocket() }) {
        self.target = target
        self.query = query
        self.audio = audio
        self.timing = timing
        self.makeSink = makeSink
        muxer = TsMuxer(audio: audio)
        rate = AdaptiveRate(maximumBps: maximumBps, startBps: startBps)
        stats.bitrateBps = rate.currentBps
        stats.bitrateMinBps = rate.currentBps
    }

    deinit {
        timer?.cancel()
        sink?.close()
    }

    /// El bitrate que se le pide al codificador ahora.
    public var bitrateBps: Int { queue.sync { rate.currentBps } }

    public var snapshot: Stats { queue.sync { currentStats() } }

    public func start() {
        queue.async { [self] in
            guard state == .stopped else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + timing.statsEveryS, repeating: timing.statsEveryS)
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
            log("publicando en \(target.host):\(target.port)")
            connect()
        }
    }

    /// Para y cierra. Lo que llegue después se ignora. No se llama desde los avisos.
    public func stop() {
        queue.sync {
            generation += 1
            timer?.cancel()
            timer = nil
            closeSink()
            sendQueue.restart()
            setState(.stopped)
        }
    }

    /// El techo vigente (la escalera de degradación); nil, el de fábrica.
    public func setCeiling(bps: Int?) {
        queue.async { [self] in ceilingBps = bps }
    }

    /// Un fotograma del programa: la muestra AVCC con la SEI y, si es IDR, con SPS y PPS
    /// delante (TsMuxer no los pone si no se le dan). `rigMs` es su instante: PTS = rigMs × 90.
    public func video(avcc: Data, isKeyframe: Bool, rigMs: Double) {
        let unidad = ProgramUnit(kind: .video(keyframe: isKeyframe), payload: avcc, rigMs: rigMs)
        let llegada = timing.nowMs()
        queue.async { [weak self] in self?.enqueue(unidad, arrivalMs: llegada) }
    }

    /// Una trama AAC cruda (sin ADTS) del instante `rigMs`.
    public func audio(aacRaw: Data, rigMs: Double) {
        guard audio != nil else { return }
        let unidad = ProgramUnit(kind: .audio, payload: aacRaw, rigMs: rigMs)
        let llegada = timing.nowMs()
        queue.async { [weak self] in self?.enqueue(unidad, arrivalMs: llegada) }
    }

    // MARK: - Conexión

    private func connect() {
        setState(.connecting)
        let gen = generation
        let nuevo = makeSink()
        connectQueue.async { [weak self, target, query, timing] in
            let resultado = Result { try nuevo.connect(to: target, query: query, latencyMs: timing.latencyMs,
                                                       timeoutMs: timing.connectTimeoutMs) }
            guard let self else { nuevo.close(); return }
            queue.async { self.connected(nuevo, resultado, gen) }
        }
    }

    private func connected(_ nuevo: ProgramSrtSink, _ resultado: Result<Void, Error>, _ gen: Int) {
        guard gen == generation, state == .connecting else {
            nuevo.close()
            return
        }
        switch resultado {
        case .success:
            sink = nuevo
            connectedAtMs = timing.nowMs()
            lastTotals = SrtStats()
            backoff.connected()
            if let bps = rate.reset(ceilingBps: ceilingBps) {
                stats.bitrateChanges += 1
                log(String(format: "bitrate %.1f Mbit/s, el de antes del corte", Double(bps) / 1e6))
                onBitrate?(bps)
            }
            stats.connects += 1
            if stats.connects > 1 { stats.reconnects += 1 }
            muxer = TsMuxer(audio: audio)
            sendQueue.restart()
            // Lo tirado durante el corte no es congestión de esta conexión: sin esto, la
            // primera muestra tras reconectar bajaba el bitrate (medido en el Mac: 6 → 4,9).
            congestionsAtSample = sendQueue.counts.congestions
            partialsAtSample = stats.partialSends
            firstUnsentVideoAtMs = nil
            bufferOverLatencySinceMs = nil
            idrPending = false
            setState(.publishing)
            log("conectado a \(target.host):\(target.port)")
            requestIdr()
        case .failure(let error):
            nuevo.close()
            stats.connectFailures += 1
            fail(error, wasPublishing: false)
        }
    }

    private func fail(_ error: Error, wasPublishing: Bool) {
        closeSink()
        sendQueue.restart()
        let porque = (error as? SrtError)?.description ?? "\(type(of: error))"
        stats.lastError = porque
        let fallo: ReconnectBackoff.Failure
        switch error as? SrtError {
        case .invalid?:
            setState(.failed(porque))
            log("no se reintenta: \(porque)")
            return
        case .rejected?:
            stats.rejections += 1
            fallo = .rejected
        default:
            fallo = wasPublishing ? .lost : .unreachable
        }
        let espera = backoff.delayS(after: fallo)
        setState(.waiting(porque))
        log("\(porque); otra vez en \(Int(espera)) s")
        let gen = generation
        queue.asyncAfter(deadline: .now() + espera * timing.reconnectScale) { [weak self] in
            guard let self, gen == generation, case .waiting = state else { return }
            connect()
        }
    }

    private func closeSink() {
        guard let s = sink else { return }
        if let t = try? s.stats(clear: false) { lastTotals = t }
        closed.sent += lastTotals.packetsSent
        closed.bytes += lastTotals.bytesSent
        closed.lost += Int64(lastTotals.packetsLost)
        closed.retx += Int64(lastTotals.packetsRetransmitted)
        closed.dropped += Int64(lastTotals.packetsDropped)
        lastTotals = SrtStats()
        if let desde = connectedAtMs { stats.publishingS += (timing.nowMs() - desde) / 1000 }
        connectedAtMs = nil
        firstUnsentVideoAtMs = nil
        s.close()
        sink = nil
    }

    // MARK: - Envío

    /// `arrivalMs`, cuando se entregó (no cuando la cola la atiende): la espera es esa.
    private func enqueue(_ unidad: ProgramUnit, arrivalMs: Double) {
        guard state == .publishing else {
            if state != .stopped {
                if unidad.isVideo { stats.videoDroppedWhileDown += 1 } else { stats.audioDroppedWhileDown += 1 }
            }
            return
        }
        if unidad.isVideo, firstUnsentVideoAtMs == nil { firstUnsentVideoAtMs = arrivalMs }
        if sendQueue.push(unidad, nowMs: arrivalMs) { requestIdr() }
        drain()
    }

    /// Retenido: el búfer de envío de SRT por encima del tope; no se le mete más.
    private func isHeld(_ s: ProgramSrtSink) -> Bool {
        (s.sendBufferMs() ?? 0) > ProgramPublish.congestionSendBufferMs
    }

    private func drain() {
        guard state == .publishing, let s = sink else { return }
        if idrPending, !isHeld(s) { requestIdr() }
        while let unidad = sendQueue.peek() {
            if isHeld(s) {
                stats.sendHolds += 1
                return
            }
            _ = sendQueue.pop()
            guard let ts = mux(unidad) else { continue }
            do {
                let n = try s.send(ts)
                guard n == ts.count else {
                    // El búfer de SRT se llenó a mitad del fotograma: lo que sigue no se
                    // puede decodificar hasta el próximo IDR.
                    stats.partialSends += 1
                    if sendQueue.dropUntilIdr() { requestIdr() }
                    return
                }
                if unidad.isVideo {
                    stats.videoFramesSent += 1
                    stats.lastSentRigMs = UInt64(max(0, unidad.rigMs))
                    lastVideoSentAtMs = timing.nowMs()
                    firstUnsentVideoAtMs = nil
                } else {
                    stats.audioFramesSent += 1
                }
            } catch {
                fail(error, wasPublishing: true)
                return
            }
        }
    }

    private func mux(_ unidad: ProgramUnit) -> Data? {
        let pts = Int64((unidad.rigMs * 90).rounded())
        switch unidad.kind {
        case .video(let clave):
            return muxer.muxVideo(avcc: unidad.payload, parameterSets: [], isKeyframe: clave,
                                  pts90k: pts, dts90k: pts)
        case .audio:
            return try? muxer.muxAudio(aacRaw: unidad.payload, pts90k: pts)
        }
    }

    /// Pide un IDR al codificador. Con SRT retenido no vale la pena: llegaría retenido, la
    /// cola lo tiraría al segundo y se pediría otro. Queda pendiente y `drain` lo pide
    /// cuando el búfer baja.
    private func requestIdr() {
        if let s = sink, isHeld(s) {
            idrPending = true
            return
        }
        idrPending = false
        stats.idrRequests += 1
        onIdrRequest?()
    }

    // MARK: - Cada segundo

    /// La muestra de cada segundo, a mano (pruebas).
    func sampleNow() {
        queue.sync { tick() }
    }

    private func tick() {
        guard state == .publishing, let s = sink else { return }
        guard s.isConnected else {
            fail(SrtError.notConnected, wasPublishing: true)
            return
        }
        let muestra: SrtStats
        do {
            muestra = try s.stats(clear: true)
        } catch {
            fail(error, wasPublishing: true)
            return
        }
        lastTotals = muestra
        stats.sendRateMbps = muestra.sendRateMbps
        stats.rttMs = muestra.rttMs
        stats.rttMsMax = max(stats.rttMsMax, muestra.rttMs)
        stats.sendBufferMsMax = max(stats.sendBufferMsMax, Int(muestra.sendBufferMs))
        if stalled(muestra) { return }
        let congestionado = Int(muestra.sendBufferMs) > ProgramPublish.congestionSendBufferMs
            || sendQueue.counts.congestions > congestionsAtSample || stats.partialSends > partialsAtSample
        congestionsAtSample = sendQueue.counts.congestions
        partialsAtSample = stats.partialSends
        if let nuevo = rate.sample(congested: congestionado, measuredBps: Int(muestra.sendRateMbps * 1e6),
                                   ceilingBps: ceilingBps) {
            stats.bitrateChanges += 1
            stats.bitrateMinBps = min(stats.bitrateMinBps, nuevo)
            log(String(format: "bitrate %.1f Mbit/s (salió %.1f, búfer %d ms)", Double(nuevo) / 1e6,
                       muestra.sendRateMbps, muestra.sendBufferMs))
            onBitrate?(nuevo)
        }
        drain()
    }

    /// El vigía de atasco (2026-10-15), en cada muestra. Reconecta, y devuelve true, si la
    /// conexión está viva pero (a) llevan `stallReconnectS` llegando fotogramas sin que
    /// ninguno entre en SRT, o (b) el búfer de envío lleva `bufferOverLatencyReconnectS`
    /// por encima de la latencia SRT. El búfer que mira `drain` es «el más nuevo menos el
    /// más viejo sin confirmar»: si el otro lado deja de confirmar, esa lectura se congela
    /// y la retención no acabaría nunca (medido: 1100 s «publishing» sin un fotograma).
    private func stalled(_ muestra: SrtStats) -> Bool {
        let ahora = timing.nowMs()
        let bufferMs = Int(muestra.sendBufferMs)
        if bufferMs > Int(timing.latencyMs) {
            if bufferOverLatencySinceMs == nil { bufferOverLatencySinceMs = ahora }
        } else {
            bufferOverLatencySinceMs = nil
        }
        let porque: SrtError
        if let desde = firstUnsentVideoAtMs, (ahora - desde) / 1000 >= ProgramPublish.stallReconnectS {
            porque = .stalled(stalledS: Int((ahora - desde) / 1000), sendBufferMs: bufferMs)
        } else if let desde = bufferOverLatencySinceMs,
                  (ahora - desde) / 1000 >= ProgramPublish.bufferOverLatencyReconnectS {
            porque = .sendBufferOverLatency(sendBufferMs: bufferMs, latencyMs: Int(timing.latencyMs),
                                            heldS: Int((ahora - desde) / 1000))
        } else {
            return false
        }
        stats.stallReconnects += 1
        let cola = sendQueue.waitingForIdr ? "esperando IDR" : "\(sendQueue.count) unidades"
        log("atasco: \(porque.description); cola \(cola)")
        fail(porque, wasPublishing: true)
        return true
    }

    // MARK: - Estado

    private func setState(_ nuevo: State) {
        guard nuevo != state else { return }
        state = nuevo
        onState?(nuevo)
    }

    private func log(_ texto: String) {
        onLog?(texto)
    }

    private func currentStats() -> Stats {
        var s = stats
        s.state = Self.name(state)
        s.bitrateBps = rate.currentBps
        s.srtPacketsSent = closed.sent + lastTotals.packetsSent
        s.srtBytesSent = closed.bytes + lastTotals.bytesSent
        s.srtPacketsLost = closed.lost + Int64(lastTotals.packetsLost)
        s.srtPacketsRetransmitted = closed.retx + Int64(lastTotals.packetsRetransmitted)
        s.srtPacketsDropped = closed.dropped + Int64(lastTotals.packetsDropped)
        let c = sendQueue.counts
        s.videoDropped = c.videoDropped
        s.audioDropped = c.audioDropped
        s.congestions = c.congestions
        let ahora = timing.nowMs()
        if let desde = connectedAtMs { s.publishingS += (ahora - desde) / 1000 }
        s.lastSentAgeS = lastVideoSentAtMs.map { (ahora - $0) / 1000 }
        return s
    }

    private static func name(_ state: State) -> String {
        switch state {
        case .stopped: "stopped"
        case .connecting: "connecting"
        case .publishing: "publishing"
        case .waiting: "waiting"
        case .failed: "failed"
        }
    }
}
