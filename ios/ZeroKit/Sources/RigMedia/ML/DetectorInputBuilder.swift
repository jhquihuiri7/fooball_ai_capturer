// La entrada del detector de jugadores (IOS-21): orquesta preprocess_nv12.
//
// Del fotograma NV12 del FrameRing a un CVPixelBuffer 32BGRA de 1920×576 del pool,
// que entra tal cual como la ImageType del modelo (la escala 1/255 va dentro del
// modelo, ML-35). Sin reservas por fotograma: el pool está precalentado y, si no
// queda hueco, el fotograma de IA se descarta y se cuenta, nunca se encola.

import CoreVideo
import Foundation
import Metal
import RigCore

public final class DetectorInputBuilder {
    private let context: MetalContext
    private let nv12Pipeline: MTLComputePipelineState
    private let bgraPipeline: MTLComputePipelineState
    private let pool: PixelBufferPool
    private var params: [Float]

    /// Fotogramas de IA descartados por no quedar hueco en el pool.
    public private(set) var dropped = 0

    /// El orden de PreprocessParams en Preprocess.metal.
    private static let maxRegions = 4
    private static let paramCount = 10 + maxRegions * 8

    public init(
        context: MetalContext,
        band: BandGeometry,
        sourceWidth: Int,
        sourceHeight: Int,
        upsideDown: Bool,
        poolCapacity: Int = 3
    ) throws {
        self.context = context
        func pipeline(_ nombre: String) throws -> MTLComputePipelineState {
            guard let f = context.library.makeFunction(name: nombre) else {
                throw ReprojectKernelError.pipeline("falta \(nombre) en la biblioteca Metal")
            }
            return try context.device.makeComputePipelineState(function: f)
        }
        nv12Pipeline = try pipeline("preprocess_nv12")
        bgraPipeline = try pipeline("preprocess_bgra")
        guard band.layout.regions.count <= Self.maxRegions else {
            throw ReprojectKernelError.size("el kernel admite hasta \(Self.maxRegions) regiones")
        }
        guard let pool = PixelBufferPool(
            width: band.inputWidth, height: band.inputHeight,
            pixelFormat: kCVPixelFormatType_32BGRA, capacity: poolCapacity
        ) else {
            throw ReprojectKernelError.texture("no se pudo crear el pool de la entrada")
        }
        self.pool = pool
        params = Self.packParams(band, sourceWidth: sourceWidth, sourceHeight: sourceHeight, upsideDown: upsideDown)
    }

    /// Codifica la entrada desde un NV12 (el fotograma del FrameRing).
    public func encode(nv12 source: CVPixelBuffer, into destination: CVPixelBuffer, commandBuffer: MTLCommandBuffer) throws {
        guard let luma = context.texture(from: source, plane: 0, format: .r8Unorm),
              let croma = context.texture(from: source, plane: 1, format: .rg8Unorm)
        else {
            throw ReprojectKernelError.texture("la fuente tiene que ser NV12 con IOSurface")
        }
        try encode(pipeline: nv12Pipeline, textures: [luma, croma], destination: destination, commandBuffer: commandBuffer)
    }

    /// Codifica la entrada desde un BGRA: la ruta de los dorados de REF-14.
    public func encode(bgra source: CVPixelBuffer, into destination: CVPixelBuffer, commandBuffer: MTLCommandBuffer) throws {
        guard let imagen = context.texture(from: source, plane: 0, format: .bgra8Unorm) else {
            throw ReprojectKernelError.texture("la fuente tiene que ser 32BGRA con IOSurface")
        }
        try encode(pipeline: bgraPipeline, textures: [imagen], destination: destination, commandBuffer: commandBuffer)
    }

    /// Una entrada del detector, asíncrona: toma un buffer del pool, encola el kernel y
    /// lo entrega al completarse la GPU. Sin hueco en el pool, `completion(nil)` y el
    /// descarte se cuenta.
    public func build(from source: CVPixelBuffer, completion: @escaping (CVPixelBuffer?) -> Void) throws {
        guard let destino = pool.take() else {
            dropped += 1
            completion(nil)
            return
        }
        guard let cb = context.queue.makeCommandBuffer() else {
            throw ReprojectKernelError.pipeline("no hay command buffer")
        }
        try encode(nv12: source, into: destino, commandBuffer: cb)
        cb.addCompletedHandler { hecho in
            completion(hecho.error == nil ? destino : nil)
        }
        cb.commit()
    }

    private func encode(
        pipeline: MTLComputePipelineState, textures: [MTLTexture],
        destination: CVPixelBuffer, commandBuffer: MTLCommandBuffer
    ) throws {
        guard let salida = context.texture(from: destination, plane: 0, format: .bgra8Unorm) else {
            throw ReprojectKernelError.texture("el destino tiene que ser 32BGRA con IOSurface")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ReprojectKernelError.pipeline("no hay encoder de cómputo")
        }
        encoder.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() {
            encoder.setTexture(t, index: i)
        }
        encoder.setTexture(salida, index: 2)
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let ancho = pipeline.threadExecutionWidth
        let alto = max(1, pipeline.maxTotalThreadsPerThreadgroup / ancho)
        encoder.dispatchThreads(
            MTLSize(width: salida.width, height: salida.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: ancho, height: alto, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Los parámetros del kernel. El recorte se redondea como `round()` de Python en
    /// compose_band_input: la escala de cada región sale de ese recorte, no de src_w.
    static func packParams(_ band: BandGeometry, sourceWidth: Int, sourceHeight: Int, upsideDown: Bool) -> [Float] {
        let kr = 0.2126, kb = 0.0722, kg = 1 - kr - kb
        var p: [Float] = [
            Float(band.layout.regions.count), upsideDown ? 1 : 0,
            Float(sourceWidth), Float(sourceHeight),
            Float(255.0 / 219.0), Float(255.0 / 224.0),
            Float(2 * (1 - kr)), Float(2 * kb * (1 - kb) / kg), Float(2 * kr * (1 - kr) / kg), Float(2 * (1 - kb)),
        ]
        for i in 0..<maxRegions {
            guard i < band.layout.regions.count else {
                p += [Float](repeating: 0, count: 8)
                continue
            }
            let r = band.layout.regions[i]
            func redondeo(_ v: Double) -> Float { Float(v.rounded(.toNearestOrEven)) }
            p += [Float(r.dstX), Float(r.dstY), Float(r.dstW), Float(r.dstH),
                  redondeo(r.srcX), redondeo(r.srcY), redondeo(r.srcW), redondeo(r.srcH)]
        }
        precondition(p.count == paramCount)
        return p
    }
}
