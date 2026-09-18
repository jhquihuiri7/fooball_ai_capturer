// Emisión al servidor por SRT o RTMP (ADR 0012, TASK A5).
//
// HaishinKit (BSD-3) codifica en HEVC con VideoToolbox y lo saca por SRT (MPEG-TS sobre
// UDP, el preferido) o por RTMP (TCP, el que entra a un pod de RunPod). El protocolo lo
// decide el esquema de la URL. Lo que este fichero decide, y que una app de directo
// normal no haría:
//
//   1. **Bitrate fijo.** Los dos móviles comparten Starlink y dos controles adaptativos
//      se pelean hasta oscilar (ADR 0012, decisión 7). Media fija con tope por segundo.
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
        let video = Self.videoSettings(settings: settings, applied: applied)
        withLock { video_ = video }

        // La bomba: saca frames de la cola, en orden, y se los da al stream si lo hay.
        // Es una sola tarea a propósito: una tarea por frame no garantiza el orden.
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await buffer in frames {
                guard let self, let stream = self.currentStream else { continue }
                await stream.append(buffer)
            }
        }
        connectTask = Task.detached { [weak self] in
            await self?.run(url: url, video: video)
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

    /// Cambia el bitrate en caliente (por calor, TASK A7). Se aplica al stream activo y
    /// queda fijado para las reconexiones.
    func setBitRate(_ bitRate: Int) {
        var updated: VideoCodecSettings?
        var stream: (any StreamConvertible)?
        withLock {
            guard var video = video_, video.bitRate != bitRate else { return }
            video.bitRate = bitRate
            video.dataRateLimits = [Double(bitRate) / 8.0, 1.0]
            video_ = video
            updated = video
            stream = currentStream_
        }
        guard let updated, let stream else { return }
        NSLog("[stream] bitrate a %d bit/s", bitRate)
        Task { try? await stream.setVideoSettings(updated) }
    }

    /// Un frame de la cámara, ya con el código de tiempo pintado. Se llama desde la cola
    /// de captura y no bloquea: si la cola está llena, se descarta el más viejo.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard state_ == .streaming, let continuation = continuation_ else { return }
        if case .dropped = continuation.yield(sampleBuffer) {
            droppedFrames_ += 1
        }
    }

    // MARK: - Conexión

    private func run(url: URL, video initialVideo: VideoCodecSettings) async {
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
    private static func videoSettings(
        settings: CaptureSettings,
        applied: AppliedCameraSettings
    ) -> VideoCodecSettings {
        let bitRate = Int(settings.bitrateBps)
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
