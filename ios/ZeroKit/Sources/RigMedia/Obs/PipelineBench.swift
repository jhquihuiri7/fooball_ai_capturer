// El banco del enganche del pipeline (IOS-09): fotogramas sintéticos por el blit.
//
// Mide lo único que IOS-09 añade al camino de la cámara: la copia NV12 al anillo.
// Sin cámara ni códecs: eso ya lo miden la grabación y SPK-54. Parámetros: `frames`
// (300 por defecto: 10 s a 30 fps) y `width`/`height` (4K por defecto).

import CoreMedia
import CoreVideo
import Foundation
import RigCore

enum PipelineBench {
    static func run(report: inout BenchReport, progress: BenchRunner.Progress?) throws {
        let frames = Int(report.params["frames"] ?? "") ?? 300
        let width = Int(report.params["width"] ?? "") ?? 3840
        let height = Int(report.params["height"] ?? "") ?? 2160

        guard let pipeline = RigPipeline(width: width, height: height),
              let pool = PixelBufferPool(
                  width: width, height: height,
                  pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  capacity: 2
              ),
              let fuente = pool.take()
        else {
            throw BenchError.unknownBench("pipeline-noop: sin Metal o sin memoria")
        }

        var histograma = LatencyHistogram()
        let frameNs: Int64 = 33_333_333
        for indice in 0..<frames {
            let sample = try makeSample(from: fuente, indexNs: Int64(indice) * frameNs)
            pipeline.ingest(sample, rigNs: Int64(indice) * frameNs)
            // El banco espera a cada blit: mide la copia, no la cadencia de llegada.
            let tope = Date().addingTimeInterval(1)
            while pipeline.stored + pipeline.dropped <= indice, Date() < tope {
                usleep(200)
            }
            histograma.record(ms: pipeline.lastBlitMs)
            if indice % 50 == 0 {
                progress?(Double(indice) / Double(frames), "fotograma \(indice)/\(frames)")
            }
        }

        report.stagesMs["blit"] = BenchReport.StageSummary(histogram: histograma)
        report.counters["stored"] = pipeline.stored
        report.counters["dropped"] = pipeline.dropped
        report.counters["frames"] = frames
    }

    private static func makeSample(from pixels: CVPixelBuffer, indexNs: Int64) throws -> CMSampleBuffer {
        var formato: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &formato
        )
        var tiempo = CMSampleTimingInfo(
            duration: CMTime(value: 33_333_333, timescale: 1_000_000_000),
            presentationTimeStamp: CMTime(value: indexNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let estado = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixels,
            formatDescription: formato!,
            sampleTiming: &tiempo,
            sampleBufferOut: &sample
        )
        guard estado == noErr, let sample else {
            throw BenchError.unknownBench("pipeline-noop: no se pudo crear el sample")
        }
        return sample
    }
}
