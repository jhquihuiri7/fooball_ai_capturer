// El enganche del pipeline en la captura (IOS-09).
//
// La regla que lo gobierna: la cámara no espera a nadie y NUNCA hay más de un búfer
// suyo retenido. `ingest` apunta el trabajo y vuelve; una cola propia copia los planos
// NV12 al FrameRing con un blit de Metal y suelta el búfer de la cámara al terminar.
// Si llega un fotograma con otro en vuelo, se descarta y se cuenta: el detector va a
// 7,5 Hz y el render lee del anillo, así que perder uno de 30 no le quita nada a nadie.
//
// Hoy los consumidores están vacíos (esqueleto): el detector (IOS-23+) y el render
// (IOS-40+) se cuelgan de `onFrame` y del anillo. La grabación y la emisión de hoy no
// pasan por aquí y no cambian.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import RigCore

public final class RigPipeline {
    /// Lo que se guarda por fotograma, además de los píxeles del anillo.
    public struct FrameMeta: Equatable, Sendable {
        public let rigNs: Int64
        /// El PTS local de la cámara, sin el desfase del soporte.
        public let ptsNs: Int64
        /// Contador de fotogramas ingeridos, sin huecos por los descartes.
        public let index: Int
        /// La matriz intrínseca por fotograma (fila a fila), si la cámara la dio.
        public let intrinsics: [Float]?
    }

    private let context: MetalContext
    public let ring: FrameRing
    private let queue = DispatchQueue(label: "io.footballai.zero.pipeline", qos: .userInitiated)
    private let lock = NSLock()
    private let log = Logger(subsystem: Signposts.subsystem, category: "pipeline")

    private var inFlight = false
    private var nextIndex = 0

    public private(set) var stored = 0
    public private(set) var dropped = 0
    /// El último blit medido, en ms de pared. El histograma fino lo lleva el banco.
    public private(set) var lastBlitMs: Double = 0

    /// El consumidor del fotograma recién copiado (el detector, cuando exista).
    public var onFrame: ((FrameMeta) -> Void)?

    /// Gancho de los tests: corre dentro de la cola, justo antes del blit.
    var beforeStoreForTesting: (() -> Void)?

    public init?(width: Int, height: Int, slots: Int = PipelineConstants.frameRingSlots) {
        guard let context = MetalContext(),
              let ring = FrameRing(slots: slots, width: width, height: height)
        else {
            return nil
        }
        self.context = context
        self.ring = ring
    }

    /// No bloquea. Retiene el `sampleBuffer` (y con él el búfer de la cámara) hasta
    /// completar el blit; con uno en vuelo, el nuevo se descarta sin retener nada.
    public func ingest(_ sampleBuffer: CMSampleBuffer, rigNs: Int64) {
        lock.lock()
        if inFlight {
            dropped += 1
            lock.unlock()
            return
        }
        inFlight = true
        let index = nextIndex
        nextIndex += 1
        lock.unlock()

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        let intrinsics = Self.intrinsics(from: sampleBuffer)

        queue.async { [self] in
            defer {
                lock.lock()
                inFlight = false
                lock.unlock()
            }
            beforeStoreForTesting?()
            guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let state = Signposts.begin(.blit)
            let inicio = CMClockGetTime(CMClockGetHostTimeClock())
            let ok = ring.store(rigMs: rigNs / 1_000_000) { destino in
                blit(from: pixels, to: destino)
            }
            let fin = CMClockGetTime(CMClockGetHostTimeClock())
            lastBlitMs = CMTimeGetSeconds(CMTimeSubtract(fin, inicio)) * 1000
            Signposts.end(.blit, state)
            guard ok else {
                lock.lock()
                dropped += 1
                lock.unlock()
                return
            }
            lock.lock()
            stored += 1
            lock.unlock()
            onFrame?(FrameMeta(rigNs: rigNs, ptsNs: ptsNs, index: index, intrinsics: intrinsics))
        }
    }

    /// Copia los dos planos NV12 por el blit encoder. Espera al final DENTRO de la
    /// cola propia: el callback de la cámara ya volvió hace rato.
    private func blit(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        guard let command = context.queue.makeCommandBuffer(),
              let encoder = command.makeBlitCommandEncoder()
        else {
            log.error("sin command buffer para el blit")
            return
        }
        let planos: [(Int, MTLPixelFormat)] = [(0, .r8Unorm), (1, .rg8Unorm)]
        for (plano, formato) in planos {
            guard let origen = context.texture(from: source, plane: plano, format: formato),
                  let destino = context.texture(from: destination, plane: plano, format: formato)
            else {
                continue
            }
            encoder.copy(
                from: origen, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: origen.width, height: origen.height, depth: 1),
                to: destino, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
    }

    /// La matriz 3×3 del adjunto de la cámara, fila a fila. `matrix_float3x3` guarda
    /// columnas de 4 floats (la cuarta es relleno): se salta el relleno al leer.
    static func intrinsics(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let adjunto = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) else {
            return nil
        }
        let data = adjunto as! CFData
        guard CFDataGetLength(data) >= 48 else { return nil }
        var columnas = [Float](repeating: 0, count: 12)
        columnas.withUnsafeMutableBytes { raw in
            CFDataGetBytes(
                data,
                CFRange(location: 0, length: 48),
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            )
        }
        // Columnas (c, fila) → filas (fila, c).
        return (0..<3).flatMap { fila in (0..<3).map { col in columnas[col * 4 + fila] } }
    }
}
