// El spike de concurrencia de VideoToolbox (SPK-03).
//
// La pregunta que responde: ¿aguanta este iPhone, A LA VEZ, la captura 4K30, la
// grabación HEVC de 45 Mbit/s, el H.264 1080p de baja latencia (IOS-50) y —en el
// maestro— la decodificación 1080p (IOS-51)? El escalado 4K→1080p va por
// VTPixelTransferSession a propósito: mide el hardware de vídeo, no nuestros kernels.
//
// Registra lo que pide la tarjeta: los −12915 (VideoToolbox sin hueco para otra
// sesión), los fps de la cámara, didDrop y lo que descartan las colas. ÉXITO del
// spike: sin −12915, p5 de fps ≥29,5 y 0 didDrop en 30 min.
//
//   perfil master: HEVC 4K 45 Mbit/s + H.264 6 Mbit/s + decodificación
//   perfil slave:  HEVC 4K 45 Mbit/s + H.264 25 Mbit/s (sin decodificación)
//
// Parámetros: profile (master), duration_s (1800). Para humo: duration_s=30.

import AVFoundation
import CoreMedia
import Foundation
import RigCore
import VideoToolbox

enum VtConcurrencyBench {
    struct Config: Equatable {
        enum Profile: String {
            case master, slave
        }

        var profile: Profile
        var durationS: Double
        /// La HEVC 4K del maestro se puede apagar (`hevc=0`): es la repetición que la
        /// tarjeta prescribe si la pasada completa no sostiene 30 fps.
        var hevc: Bool

        /// Bitrate del H.264 1080p según el perfil, en bits por segundo (la tarjeta:
        /// 6 Mbit/s el maestro hacia el VPS, 25 el esclavo hacia el maestro).
        var h264BitrateBps: Int {
            profile == .master ? 6_000_000 : 25_000_000
        }
    }

    /// El HEVC 4K de archivo, en bits por segundo (blueprint: la grabación es la verdad).
    static let hevcBitrateBps = 45_000_000

    static func config(from params: [String: String]) -> Config {
        Config(
            profile: Config.Profile(rawValue: params["profile"] ?? "") ?? .master,
            durationS: Double(params["duration_s"] ?? "") ?? 1800,
            hevc: params["hevc"] != "0"
        )
    }

    static func run(report: inout BenchReport, progress: BenchRunner.Progress?) throws {
        let config = config(from: report.params)
        let worker = try Worker(config: config)
        worker.start()

        let inicio = Date()
        var ultimaTermica = Date()
        while Date().timeIntervalSince(inicio) < config.durationS {
            Thread.sleep(forTimeInterval: 1)
            let transcurrido = Date().timeIntervalSince(inicio)
            if Int(transcurrido) % 5 == 0 {
                progress?(
                    transcurrido / config.durationS,
                    "minuto \(Int(transcurrido) / 60)/\(Int(config.durationS) / 60)"
                )
            }
            // La línea térmica de los bancos largos: una muestra cada 5 minutos.
            if Date().timeIntervalSince(ultimaTermica) >= 300 {
                report.thermal.append(Self.thermalWord())
                ultimaTermica = Date()
            }
        }
        worker.stop()
        worker.fill(report: &report)
    }

    private static func thermalWord() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "critical"
        }
    }

    // MARK: - El trabajador

    private final class Worker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let config: Config
        private let session = AVCaptureSession()
        private let output = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "io.footballai.vt-concurrency")
        /// La decodificación va en su propia cola, como en la realidad: las partes
        /// llegan por el enlace, no en el hilo de la cámara. La primera pasada
        /// (2026-10-03) la tenía en línea y eso también frenaba la captura.
        private let decodeQueue = DispatchQueue(label: "io.footballai.vt-concurrency.decode")

        private var writer: AVAssetWriter?
        private var writerInput: AVAssetWriterInput?
        private var writerStarted = false
        private let hevcURL: URL

        private var transfer: VTPixelTransferSession?
        private var encoder: VideoEncoder?
        private var decoder: VideoDecoder?

        private var intervalo = LatencyHistogram()
        private var escala = LatencyHistogram()
        private var frames = 0
        private var didDrop = 0
        private var encoded = 0
        private var decoded = 0
        private var hevcDropped = 0
        private var transferErrors = 0
        private var err12915 = 0
        private var creationErrors = 0
        /// Fotogramas sin búfer 1080p: el pool del codificador agotado porque VT va
        /// por detrás. La primera pasada los perdía en silencio.
        private var poolStarved = 0
        private var firstPtsNs: Int64?
        private var lastPtsNs: Int64?

        init(config: Config) throws {
            self.config = config
            hevcURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("vt-concurrency-\(Int(Date().timeIntervalSince1970)).mov")
            super.init()

            guard let device = AVCaptureDevice.default(for: .video) else {
                throw BenchError.unknownBench("vt-concurrency: sin cámara")
            }
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                throw BenchError.unknownBench("vt-concurrency: la cámara no entra")
            }
            session.addInput(input)
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            session.commitConfiguration()

            // 4K30 si el cacharro lo tiene; si no (el Mac de desarrollo), el que haya.
            if let formato = device.formats.first(where: { formato in
                let dims = CMVideoFormatDescriptionGetDimensions(formato.formatDescription)
                return dims.width == 3840 && dims.height == 2160
                    && formato.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
            }) {
                try? device.lockForConfiguration()
                device.activeFormat = formato
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }
        }

        func start() {
            session.startRunning()
        }

        func stop() {
            session.stopRunning()
            queue.sync {}  // lo que estaba en vuelo, terminado
            decodeQueue.sync {}
            if let writer, writer.status == .writing {
                writerInput?.markAsFinished()
                let listo = DispatchSemaphore(value: 0)
                writer.finishWriting { listo.signal() }
                _ = listo.wait(timeout: .now() + 5)
            }
            try? FileManager.default.removeItem(at: hevcURL)
        }

        func fill(report: inout BenchReport) {
            report.stagesMs["intervalo_captura"] = BenchReport.StageSummary(histogram: intervalo)
            report.stagesMs["escala_4k_1080"] = BenchReport.StageSummary(histogram: escala)
            report.counters["frames"] = frames
            report.counters["did_drop"] = didDrop
            report.counters["encoded"] = encoded
            report.counters["decoded"] = decoded
            report.counters["hevc_dropped"] = hevcDropped
            report.counters["err_12915"] = err12915
            report.counters["creation_errors"] = creationErrors
            report.counters["vt_errors"] = transferErrors
                + (encoder?.encodeFailures ?? 0) + (decoder?.decodeFailures ?? 0)
            report.counters["pool_starved"] = poolStarved
            report.counters["encoder_dropped"] = encoder?.queueCounts.dropped ?? 0
            report.counters["decoder_dropped"] = decoder?.queueCounts.dropped ?? 0
            if let primero = firstPtsNs, let ultimo = lastPtsNs, ultimo > primero, frames > 1 {
                let fps = Double(frames - 1) / (Double(ultimo - primero) / 1e9)
                report.counters["fps_x100"] = Int(fps * 100)
            }
        }

        /// Las sesiones de VT se crean con el primer fotograma, ya con el tamaño real
        /// en la mano: es además donde aparece el −12915 si no hay hueco.
        private func setUpPipelines(width: Int, height: Int) {
            var creada: VTPixelTransferSession?
            let estado = VTPixelTransferSessionCreate(
                allocator: nil, pixelTransferSessionOut: &creada
            )
            if estado == noErr {
                transfer = creada
            } else {
                creationErrors += 1
                if estado == -12915 { err12915 += 1 }
            }

            do {
                encoder = try VideoEncoder(
                    width: 1920, height: 1080,
                    bitrateBps: config.h264BitrateBps, viewId: 0
                )
            } catch let VideoEncoder.EncoderError.create(status) {
                creationErrors += 1
                if status == -12915 { err12915 += 1 }
            } catch {
                creationErrors += 1
            }
            if config.profile == .master {
                decoder = VideoDecoder()
            }

            guard config.hevc else { return }
            let writer = try? AVAssetWriter(url: hevcURL, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: VtConcurrencyBench.hevcBitrateBps,
                ],
            ])
            input.expectsMediaDataInRealTime = true
            if let writer, writer.canAdd(input) {
                writer.add(input)
                self.writer = writer
                writerInput = input
            } else {
                creationErrors += 1
            }
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsNs = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value

            if frames == 0 {
                setUpPipelines(
                    width: CVPixelBufferGetWidth(pixels),
                    height: CVPixelBufferGetHeight(pixels)
                )
                firstPtsNs = ptsNs
            }
            if let ultimo = lastPtsNs {
                intervalo.record(ms: Double(ptsNs - ultimo) / 1e6)
            }
            lastPtsNs = ptsNs
            frames += 1

            // 1. El archivo HEVC 4K, como en un partido.
            if let writer, let writerInput {
                if !writerStarted {
                    writer.startWriting()
                    writer.startSession(atSourceTime: pts)
                    writerStarted = true
                }
                if writerInput.isReadyForMoreMediaData {
                    writerInput.append(sampleBuffer)
                } else {
                    hevcDropped += 1
                }
            }

            // 2. 4K → 1080p por el hardware, al pool del codificador.
            guard let transfer, let encoder, let pool = encoder.pixelBufferPool else { return }
            var reducido: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &reducido)
            guard let reducido else {
                poolStarved += 1
                return
            }
            let antes = Date()
            let estado = VTPixelTransferSessionTransferImage(transfer, from: pixels, to: reducido)
            guard estado == noErr else {
                transferErrors += 1
                if estado == -12915 { err12915 += 1 }
                return
            }
            escala.record(ms: Date().timeIntervalSince(antes) * 1000)

            // 3. H.264 1080p de baja latencia y, en el maestro, la vuelta por el
            //    decodificador con los SPS/PPS en banda, como viajará por el enlace.
            encoder.encode(reducido, ptsNs: ptsNs, rigMs: UInt64(max(0, ptsNs / 1_000_000)))
            while let frame = encoder.pop() {
                encoded += 1
                guard decoder != nil else { continue }
                var data = frame.data
                if frame.isKeyframe, let formato = frame.formatDescription {
                    var conSets = H264ParameterSets.avccNals(from: formato)
                    conSets.append(data)
                    data = conSets
                }
                let pts = frame.ptsNs
                decodeQueue.async { [weak self] in
                    guard let self, let decoder = self.decoder else { return }
                    decoder.decode(avcc: data, ptsNs: pts)
                    while decoder.pop() != nil {
                        self.decoded += 1
                    }
                }
            }
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didDrop sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            didDrop += 1
        }
    }
}
