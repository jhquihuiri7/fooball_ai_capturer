// Emisión al servidor por SRT o RTMP (ADR 0012, TASK A5).
//
// HaishinKit (BSD-3) codifica en HEVC con VideoToolbox y lo saca por SRT (MPEG-TS sobre
// UDP, el preferido) o por RTMP (TCP, el que entra a un pod de RunPod). El protocolo lo
// decide el esquema de la URL. Lo que este fichero decide, y que una app de directo
// normal no haría:
//
//   1. **Bitrate con techo, que baja solo si la red no lo traga.** El techo es el de la
//      configuración (y el calor). Por debajo manda `AdaptiveBitRate`: si la cola del
//      socket crece tres segundos seguidos, se baja a lo que de verdad ha salido; se sube
//      despacio cuando lleva un rato sin cola. Sin esto, con una subida de 2 Mbit/s y
//      15 codificados, el vídeo se acumula en el móvil y llega con minutos de retraso
//      (medido el 2026-09-21 contra un pod). La subida lenta es lo que evita que dos
//      móviles que comparten Starlink se peleen (ADR 0012, decisión 7).
//   2. **Los frames entran por una cola de dos huecos que descarta el más viejo.** Si el
//      codificador va por detrás, el frame se pierde y se cuenta; nunca se encola retraso.
//   3. **Se reconecta sola mientras nadie pulse PARAR.** Un traspaso de satélite no puede
//      dejar el partido sin emitir hasta que alguien mire el móvil.
//
// La grabación local no pasa por aquí: es independiente a propósito (decisión 5).

import AVFoundation
import Foundation
import HaishinKit
import Logboard
import RTMPHaishinKit
import SRTHaishinKit
import VideoToolbox

/// La regla de subir y bajar el bitrate según lo que la red deja pasar.
///
/// HaishinKit mide cada segundo cuánto ha salido por el socket y cuánto espera en su
/// cola, y avisa con `publishInsufficientBWOccured` cuando la cola lleva tres segundos
/// creciendo. Aquí se decide qué hacer con eso. `mamimumVideoBitRate` (sic, es el nombre
/// del protocolo) es el techo de fábrica; el vigente, que el calor puede bajar, lo da
/// `ceiling`.
final actor AdaptiveBitRate: StreamBitRateStrategy {
    /// Por debajo de esto un 4K es papilla: mejor que se note el corte a que se emita eso.
    static let minimumBitRate = 1_000_000

    /// Segundos seguidos sin cola antes de subir un escalón. Quince: subir es barato de
    /// deshacer, pero dos móviles subiendo a la vez por un enlace justo se lo quitan uno
    /// al otro, y despacio convergen en vez de oscilar.
    static let raiseAfterSamples = 15

    /// Fracción de lo medido a la que se baja: lo que salió menos un margen, para que la
    /// cola se vacíe y no solo deje de crecer.
    static let backoff = 0.8

    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate = 0

    private let ceiling: @Sendable () -> Int
    private let onChange: @Sendable (Int) -> Void
    private var stableSamples = 0

    init(maximum: Int, ceiling: @escaping @Sendable () -> Int, onChange: @escaping @Sendable (Int) -> Void) {
        mamimumVideoBitRate = maximum
        self.ceiling = ceiling
        self.onChange = onChange
    }

    /// A qué bajar cuando la cola crece: lo que salió con margen, nunca más de lo que
    /// había, y nunca por debajo del mínimo. Con `measured` 0 (no salió nada) a la mitad.
    static func next(current: Int, measured: Int) -> Int {
        let target = measured > 0 ? Int(Double(measured) * backoff) : current / 2
        return max(min(current, target), minimumBitRate)
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        var video = await stream.videoSettings
        let top = max(min(mamimumVideoBitRate, ceiling()), Self.minimumBitRate)
        switch event {
        case .status:
            stableSamples += 1
            guard video.bitRate < top, stableSamples >= Self.raiseAfterSamples else { return }
            stableSamples = 0
            await apply(min(video.bitRate + mamimumVideoBitRate / 10, top), to: &video, on: stream)
        case let .publishInsufficientBWOccured(report):
            stableSamples = 0
            await apply(Self.next(current: video.bitRate, measured: report.currentBytesOutPerSecond * 8), to: &video, on: stream)
        case .reset:
            // Reconexión: se conserva el bitrate, que es lo último que se sabe que cabía.
            stableSamples = 0
        }
    }

    private func apply(_ bitRate: Int, to video: inout VideoCodecSettings, on stream: some StreamConvertible) async {
        guard bitRate != video.bitRate else { return }
        video.bitRate = bitRate
        video.dataRateLimits = [Double(bitRate) / 8.0, 1.0]
        try? await stream.setVideoSettings(video)
        onChange(bitRate)
    }
}

final class StreamPublisher {
    enum StreamError: LocalizedError {
        case unsupportedURL(URL)

        var errorDescription: String? {
            switch self {
            case let .unsupportedURL(url):
                return "ninguna sesión sabe emitir a \(url.absoluteString)"
            }
        }
    }

    enum State: Equatable {
        case off
        case connecting
        case streaming
        case reconnecting(String)
        case failed(String)
    }

    /// Nanosegundos entre reintentos cuando la conexión cae o no abre.
    private static let reconnectDelayNs: UInt64 = 3_000_000_000

    /// Huecos de la cola de frames hacia el codificador: el que se está codificando y el
    /// siguiente. Más sería encolar retraso.
    private static let frameQueueSlots = 2

    /// Bitrate con el que arranca una emisión por internet (RTMP a un pod), antes de que
    /// `AdaptiveBitRate` suba hasta el techo si la red da. Arrancar al techo (15 Mbit/s)
    /// por una subida de 2 llenaba la cola del socket antes de que la adaptación
    /// reaccionara, el servidor cortaba por silencio a los 10 s y se perdían dos minutos
    /// en reconexiones (medido el 2026-09-22). Con buena subida se llega al techo en
    /// menos de dos minutos, subiendo un escalón cada 15 s.
    static let internetStartBitRate = 4_000_000

    /// Segundos entre frames clave. Dos: lo que tarda en engancharse un lector nuevo y lo
    /// que se pierde de vídeo tras un paquete perdido que SRT no recupere.
    private static let keyFrameIntervalSeconds: Int32 = 2

    /// El registro del protocolo SRT en la fábrica de sesiones, una sola vez por proceso.
    private static let registration = Task {
        // Con todo lo que SRT diga en la consola: cuando algo no conecta en la cancha,
        // el log es lo único que hay.
        LBLogger(kHaishinKitIdentifier).level = .info
        LBLogger(kSRTHaishinKitIdentifier).level = .info
        await SRTLogger.shared.setLevel(.notice)
        await SessionBuilderFactory.shared.register(SRTSessionFactory())
        // RTMP es el único transporte que entra directo a un pod de RunPod (sin UDP).
        // HaishinKit anuncia HEVC por E-RTMP por defecto y MediaMTX lo acepta.
        await SessionBuilderFactory.shared.register(RTMPSessionFactory())
    }

    private let lock = NSLock()
    private var state_: State = .off
    private var droppedFrames_: Int64 = 0
    private var wanted_ = false
    private var continuation_: AsyncStream<CMSampleBuffer>.Continuation?
    private var currentStream_: (any StreamConvertible)?
    private var lostContinuation_: AsyncStream<Void>.Continuation?

    private var video_: VideoCodecSettings?
    /// Techo vigente del bitrate: el de la configuración, bajado por calor si hace falta.
    private var ceiling_ = 0

    private var connectTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var session: (any Session)?

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return state_
    }

    /// Frames que la cola descartó porque el codificador iba por detrás.
    var droppedFrames: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrames_
    }

    /// Bitrate al que se codifica ahora mismo (el vigente tras la adaptación), o 0 apagado.
    var currentBitRate: Int {
        lock.lock()
        defer { lock.unlock() }
        return state_ == .off ? 0 : (video_?.bitRate ?? 0)
    }

    // MARK: - Ciclo de vida

    func start(url: URL, settings: CaptureSettings, applied: AppliedCameraSettings) {
        stop()
        let frames = AsyncStream<CMSampleBuffer>(
            bufferingPolicy: .bufferingNewest(Self.frameQueueSlots)
        ) { continuation in
            self.withLock { self.continuation_ = continuation }
        }
        withLock {
            wanted_ = true
            state_ = .connecting
            droppedFrames_ = 0
        }
        let ceiling = Int(settings.bitrateBps)
        let video = Self.videoSettings(
            settings: settings,
            applied: applied,
            bitRate: Self.startBitRate(for: url, configured: ceiling)
        )
        withLock {
            video_ = video
            ceiling_ = ceiling
        }

        // La bomba: saca frames de la cola, en orden, y se los da al stream si lo hay.
        // Es una sola tarea a propósito: una tarea por frame no garantiza el orden.
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await buffer in frames {
                guard let self, let stream = self.currentStream else { continue }
                await stream.append(buffer)
            }
        }
        connectTask = Task.detached { [weak self] in
            await self?.run(url: url, video: video, maximum: ceiling)
        }
    }

    func stop() {
        withLock {
            wanted_ = false
            currentStream_ = nil
            continuation_?.finish()
            continuation_ = nil
            lostContinuation_?.finish()
            lostContinuation_ = nil
            state_ = .off
        }
        connectTask?.cancel()
        connectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        let closing = session
        session = nil
        if let closing {
            Task { try? await closing.close() }
        }
    }

    /// Baja o restablece el techo del bitrate (por calor, TASK A7). Si lo vigente supera el
    /// techo nuevo se aplica al momento; si queda por debajo, lo sube `AdaptiveBitRate`
    /// cuando la red lleve un rato sin cola. Se aplica al stream activo y queda para la
    /// próxima reconexión.
    func setBitRate(_ bitRate: Int) {
        var updated: VideoCodecSettings?
        var stream: (any StreamConvertible)?
        withLock {
            ceiling_ = bitRate
            guard var video = video_, video.bitRate > bitRate else { return }
            video.bitRate = bitRate
            video.dataRateLimits = [Double(bitRate) / 8.0, 1.0]
            video_ = video
            updated = video
            stream = currentStream_
        }
        guard let updated, let stream else { return }
        Task { try? await stream.setVideoSettings(updated) }
        NSLog("[stream] bitrate a %d bit/s", bitRate)
    }

    /// Lo que `AdaptiveBitRate` acaba de poner: se guarda para la reconexión y el estado.
    private func adapted(to bitRate: Int) {
        withLock {
            guard var video = video_ else { return }
            video.bitRate = bitRate
            video.dataRateLimits = [Double(bitRate) / 8.0, 1.0]
            video_ = video
        }
        NSLog("[stream] la red pide %d bit/s", bitRate)
    }

    private var ceiling: Int {
        lock.lock()
        defer { lock.unlock() }
        return ceiling_
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard state_ == .streaming, let continuation = continuation_ else { return }
        if case .dropped = continuation.yield(sampleBuffer) {
            droppedFrames_ += 1
        }
    }

    // MARK: - Conexión

    private func run(url: URL, video initialVideo: VideoCodecSettings, maximum: Int) async {
        await Self.registration.value
        NSLog("[stream] emitiendo a %@", url.absoluteString)
        while wanted, !Task.isCancelled {
            do {
                // El bitrate vigente, que puede haber bajado por calor desde el arranque.
                let video = currentVideo ?? initialVideo
                guard let session = try await SessionBuilderFactory.shared
                    .make(url)
                    .setMode(.publish)
                    .build()
                else {
                    throw StreamError.unsupportedURL(url)
                }
                self.session = session
                let stream = await session.stream
                // Sin audio: si no se dice, el muxer de TS espera una pista que nunca
                // llega y no sale ni un paquete.
                if let srt = stream as? SRTStream {
                    await srt.setExpectedMedias([.video])
                }
                try await stream.setVideoSettings(video)
                await stream.setBitRateStrategy(
                    AdaptiveBitRate(
                        maximum: maximum,
                        ceiling: { [weak self] in self?.ceiling ?? maximum },
                        onChange: { [weak self] in self?.adapted(to: $0) }
                    )
                )

                let lost = AsyncStream<Void> { continuation in
                    self.withLock { self.lostContinuation_ = continuation }
                }
                try await session.connect { [weak self] in
                    self?.withLock { self?.lostContinuation_?.yield() }
                }
                NSLog("[stream] conectado: %@", url.absoluteString)
                withLock {
                    currentStream_ = stream
                    state_ = .streaming
                }
                // Aquí se queda mientras la conexión viva. Cae: se sale y se reintenta.
                var iterator = lost.makeAsyncIterator()
                _ = await iterator.next()
                NSLog("[stream] enlace perdido")
                withLock {
                    currentStream_ = nil
                    if wanted_ { state_ = .reconnecting("se perdió el enlace") }
                }
            } catch {
                NSLog("[stream] no conecta: %@ (%@)", error.localizedDescription, String(describing: error))
                withLock {
                    currentStream_ = nil
                    if wanted_ { state_ = .reconnecting(error.localizedDescription) }
                }
            }
            guard wanted, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: Self.reconnectDelayNs)
        }
    }

    // MARK: - Ajustes

    /// HEVC a la resolución de la cámara, sin reordenar frames y con la tasa media fijada
    /// y acotada por segundo: lo más parecido a un bitrate constante que da VideoToolbox
    /// sin entrar en su modo CBR, que tiene condiciones propias por modelo.
    /// Con qué bitrate arranca: por SRT (la red local o un relé propio) al techo; por RTMP
    /// (internet hasta un pod) a `internetStartBitRate`, y que la adaptación suba.
    static func startBitRate(for url: URL, configured: Int) -> Int {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme.hasPrefix("rtmp") ? min(configured, internetStartBitRate) : configured
    }

    private static func videoSettings(
        settings: CaptureSettings,
        applied: AppliedCameraSettings,
        bitRate: Int
    ) -> VideoCodecSettings {
        return VideoCodecSettings(
            videoSize: CGSize(width: applied.width, height: applied.height),
            bitRate: bitRate,
            profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: keyFrameIntervalSeconds,
            allowFrameReordering: false,
            dataRateLimits: [Double(bitRate) / 8.0, 1.0],
            isLowLatencyRateControlEnabled: false,
            isHardwareAcceleratedEnabled: true,
            expectedFrameRate: applied.actualFps
        )
    }

    // MARK: - Estado compartido

    private var wanted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted_
    }

    private var currentVideo: VideoCodecSettings? {
        lock.lock()
        defer { lock.unlock() }
        return video_
    }

    private var currentStream: (any StreamConvertible)? {
        lock.lock()
        defer { lock.unlock() }
        return currentStream_
    }

    private func withLock(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }
}
