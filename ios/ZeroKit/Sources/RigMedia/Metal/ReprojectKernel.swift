// La parte de una cámara en el programa (IOS-40): codifica reproject_part.
//
// Lee el NV12 de la cámara, escribe el NV12 1920×1080 del programa (con negro donde
// la cámara no llega) directo en un buffer del pool del codificador, sin copias.

import CoreVideo
import Foundation
import Metal
import RigCore

public enum ReprojectKernelError: Error, CustomStringConvertible {
    case pipeline(String)
    case texture(String)
    case size(String)

    public var description: String {
        switch self {
        case let .pipeline(m), let .texture(m), let .size(m): return m
        }
    }
}

/// Una zona ciega en píxeles de la cámara: la franja del código de tiempo.
public struct BlindRect: Equatable, Sendable {
    public let x0: Int
    public let y0: Int
    public let x1: Int
    public let y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

public final class ReprojectKernel {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState

    /// El orden de ReprojectParams en Reproject.metal.
    private static let paramCount = 18

    public init(context: MetalContext) throws {
        self.context = context
        guard let funcion = context.library.makeFunction(name: "reproject_part") else {
            throw ReprojectKernelError.pipeline("falta reproject_part en la biblioteca Metal")
        }
        pipeline = try context.device.makeComputePipelineState(function: funcion)
    }

    /// Codifica la parte de una cámara en `commandBuffer`.
    ///
    /// - `homography`: programa → píxeles del buffer de la cámara tal como llega (la
    ///   de IOS-31, compuesta con la montura si la cámara va del revés).
    /// - `gains`: ganancia por canal en el orden BGR de la referencia (`_apply_gain`).
    /// - `blind`: la franja del código de tiempo en píxeles de la cámara; se ensancha
    ///   PANORAMA_BLIND_MARGIN_PX, como mask_blind.
    public func encode(
        source: CVPixelBuffer,
        homography: Mat3,
        gains: (b: Double, g: Double, r: Double) = (1, 1, 1),
        blind: BlindRect? = nil,
        destination: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let srcLuma = context.texture(from: source, plane: 0, format: .r8Unorm),
              let srcChroma = context.texture(from: source, plane: 1, format: .rg8Unorm),
              let dstLuma = context.texture(from: destination, plane: 0, format: .r8Unorm),
              let dstChroma = context.texture(from: destination, plane: 1, format: .rg8Unorm)
        else {
            throw ReprojectKernelError.texture("los buffers tienen que ser NV12 con IOSurface")
        }
        guard dstLuma.width % 2 == 0, dstLuma.height % 2 == 0 else {
            throw ReprojectKernelError.size("el programa NV12 tiene que tener lados pares")
        }

        let margen = RigConstants.panoramaBlindMarginPx
        // Sin zona ciega, un rectángulo vacío: x0 > x1 no contiene nada.
        let ciega: [Float] = blind.map { (z: BlindRect) -> [Float] in
            [Float(z.x0 - margen), Float(z.y0 - margen), Float(z.x1 + margen), Float(z.y1 + margen)]
        } ?? [1, 1, 0, 0]
        var params = homography.values.map { Float($0) }
        params += [Float(gains.b), Float(gains.g), Float(gains.r)]
        params += ciega
        params += [Float(srcLuma.width), Float(srcLuma.height)]
        precondition(params.count == Self.paramCount)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ReprojectKernelError.pipeline("no hay encoder de cómputo")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(srcLuma, index: 0)
        encoder.setTexture(srcChroma, index: 1)
        encoder.setTexture(dstLuma, index: 2)
        encoder.setTexture(dstChroma, index: 3)
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let ancho = pipeline.threadExecutionWidth
        let alto = max(1, pipeline.maxTotalThreadsPerThreadgroup / ancho)
        encoder.dispatchThreads(
            MTLSize(width: dstChroma.width, height: dstChroma.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: ancho, height: alto, depth: 1)
        )
        encoder.endEncoding()
    }
}
