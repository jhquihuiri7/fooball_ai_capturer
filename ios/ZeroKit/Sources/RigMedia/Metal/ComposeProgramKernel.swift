// El programa del maestro (IOS-41): codifica compose_program.
//
// Mezcla la parte propia (reproyectada por ReprojectKernel) y la del esclavo con la
// costura recalculada desde la vista, pone encima el gráfico y el anuncio, y escribe
// NV12 en un buffer del pool del codificador. Caminos de una lente: solo la parte
// propia, o solo la del esclavo, más el gráfico.

import CoreVideo
import Foundation
import Metal
import RigCore

/// Una textura RGBA8 que se sube solo cuando cambia su contenido.
public final class UploadTexture {
    public let texture: MTLTexture
    public private(set) var generation: Int = -1

    public init?(device: MTLDevice, width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
    }

    /// Sube `rgba` (filas seguidas, 4 bytes por píxel) si `generation` es nueva.
    public func upload(rgba: [UInt8], generation: Int) {
        guard generation != self.generation else { return }
        precondition(rgba.count == texture.width * texture.height * 4, "tamaño de la capa")
        rgba.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: texture.width * 4
            )
        }
        self.generation = generation
    }
}

public final class ComposeProgramKernel {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState
    /// Relleno para las entradas que un camino no usa: el kernel no las lee.
    private let vacia: MTLTexture
    private let vaciaLuma: MTLTexture
    private let vaciaCroma: MTLTexture

    private static let paramCount = 16

    public init(context: MetalContext) throws {
        self.context = context
        guard let funcion = context.library.makeFunction(name: "compose_program") else {
            throw ReprojectKernelError.pipeline("falta compose_program en la biblioteca Metal")
        }
        pipeline = try context.device.makeComputePipelineState(function: funcion)
        func textura(_ formato: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: formato, width: 1, height: 1, mipmapped: false
            )
            d.usage = [.shaderRead]
            guard let t = context.device.makeTexture(descriptor: d) else {
                throw ReprojectKernelError.texture("no se pudo crear la textura de relleno")
            }
            return t
        }
        vacia = try textura(.rgba8Unorm)
        vaciaLuma = try textura(.r8Unorm)
        vaciaCroma = try textura(.rg8Unorm)
    }

    /// El anuncio de la franja: premultiplicado y su alfa inversa por canal, RGB en
    /// los canales r, g, b de cada textura, del alto de la franja.
    public struct Strip {
        public let premul: MTLTexture
        public let inverse: MTLTexture

        public init(premul: MTLTexture, inverse: MTLTexture) {
            self.premul = premul
            self.inverse = inverse
        }
    }

    /// Codifica el programa de un instante.
    ///
    /// - `master`/`slave`: las partes NV12; `nil` es el camino de una lente.
    /// - `masterSide`: de qué lado es la cámara del maestro, para el peso de la costura.
    /// - `graphic`: el gráfico RGBA SIN premultiplicar del tamaño del programa.
    public func encode(
        master: CVPixelBuffer?,
        masterSide: CameraSide,
        slave: CVPixelBuffer?,
        view: RectilinearView,
        seamYawRad: Double,
        featherRad: Double = RigConstants.panoramaFeatherRad,
        graphic: MTLTexture?,
        strip: Strip?,
        destination: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer
    ) throws {
        func planos(_ b: CVPixelBuffer?) throws -> (MTLTexture, MTLTexture)? {
            guard let b else { return nil }
            guard let l = context.texture(from: b, plane: 0, format: .r8Unorm),
                  let c = context.texture(from: b, plane: 1, format: .rg8Unorm)
            else {
                throw ReprojectKernelError.texture("las partes tienen que ser NV12 con IOSurface")
            }
            return (l, c)
        }
        let m = try planos(master)
        let s = try planos(slave)
        guard let (dstLuma, dstCroma) = try planos(destination) else {
            throw ReprojectKernelError.texture("falta el destino")
        }
        guard dstLuma.width % 2 == 0, dstLuma.height % 2 == 0 else {
            throw ReprojectKernelError.size("el programa NV12 tiene que tener lados pares")
        }

        let t = view.pose.matrix()
        let altoFranja = strip?.premul.height ?? 0
        var params: [Float] = [
            m == nil ? 0 : 1,
            s == nil ? 0 : 1,
            masterSide == .left ? 1 : 0,
            graphic == nil ? 0 : 1,
            Float(strip == nil ? dstLuma.height : dstLuma.height - altoFranja),
        ]
        params += [t[0, 0], t[0, 1], t[0, 2], t[2, 0], t[2, 1], t[2, 2]].map { Float($0) }
        params += [
            Float(view.focalPx),
            Float(Double(view.width) / 2 - 0.5),
            Float(Double(view.height) / 2 - 0.5),
            Float(seamYawRad),
            Float(featherRad),
        ]
        precondition(params.count == Self.paramCount)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ReprojectKernelError.pipeline("no hay encoder de cómputo")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(m?.0 ?? vaciaLuma, index: 0)
        encoder.setTexture(m?.1 ?? vaciaCroma, index: 1)
        encoder.setTexture(s?.0 ?? vaciaLuma, index: 2)
        encoder.setTexture(s?.1 ?? vaciaCroma, index: 3)
        encoder.setTexture(graphic ?? vacia, index: 4)
        encoder.setTexture(strip?.premul ?? vacia, index: 5)
        encoder.setTexture(strip?.inverse ?? vacia, index: 6)
        encoder.setTexture(dstLuma, index: 7)
        encoder.setTexture(dstCroma, index: 8)
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        let ancho = pipeline.threadExecutionWidth
        let alto = max(1, pipeline.maxTotalThreadsPerThreadgroup / ancho)
        encoder.dispatchThreads(
            MTLSize(width: dstCroma.width, height: dstCroma.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: ancho, height: alto, depth: 1)
        )
        encoder.endEncoding()
    }
}
