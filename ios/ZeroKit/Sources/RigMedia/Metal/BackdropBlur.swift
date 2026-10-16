// La cancha desenfocada detrás de la tarjeta de entretiempo (ADR 0027, enmienda del
// 2026-10-16): la tarjeta tapa la pantalla entera con un velo translúcido y detrás se sigue
// viendo el partido, borroso.
//
// Tres pasadas en el mismo command buffer, todas sobre texturas propias para que Metal
// ordene las dependencias entre ellas: la composición de siempre sin gráfico ni franja en
// `nitida`; un gaussiano de MPS por plano en `borrosa` (la croma va a la mitad de
// resolución, con la mitad de sigma); y otra composición, de una sola lente, desde
// `borrosa` con el gráfico encima, al destino. La franja de anuncios no sale: la tarjeta
// la tapa.

import CoreVideo
import Metal
import MetalPerformanceShaders
import RigCore

public final class BackdropBlur {
    private let nitida: (MTLTexture, MTLTexture)
    private let borrosa: (MTLTexture, MTLTexture)
    private let luma: MPSImageGaussianBlur
    private let croma: MPSImageGaussianBlur
    /// Sigma del gaussiano de la luma, en px del programa.
    public let sigmaPx: Float

    public init(device: MTLDevice, width: Int, height: Int, sigmaPx: Float) throws {
        func textura(_ formato: MTLPixelFormat, _ ancho: Int, _ alto: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: formato, width: ancho, height: alto, mipmapped: false
            )
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else {
                throw ReprojectKernelError.texture("sin memoria para el desenfoque de la cancha")
            }
            return t
        }
        nitida = (try textura(.r8Unorm, width, height), try textura(.rg8Unorm, width / 2, height / 2))
        borrosa = (try textura(.r8Unorm, width, height), try textura(.rg8Unorm, width / 2, height / 2))
        luma = MPSImageGaussianBlur(device: device, sigma: sigmaPx)
        croma = MPSImageGaussianBlur(device: device, sigma: sigmaPx / 2)
        // Sin esto, el borde del cuadro se oscurece: MPS lee ceros fuera de la imagen.
        luma.edgeMode = .clamp
        croma.edgeMode = .clamp
        self.sigmaPx = sigmaPx
    }

    /// El sigma de OverlaySpec (`backdrop_blur_sigma`, px sobre 1920) a la escala del programa.
    public static func sigma(forWidth width: Int) -> Float {
        Float(OverlaySpec.halftime["backdrop_blur_sigma"] ?? 0) * Float(width) / Float(OverlaySpec.refWidth)
    }

    /// Codifica las tres pasadas: el programa de `master` y `slave`, desenfocado, y encima
    /// `graphic`, en `destination`.
    public func encode(
        kernel: ComposeProgramKernel,
        master: CVPixelBuffer?,
        masterSide: CameraSide,
        slave: CVPixelBuffer?,
        view: RectilinearView,
        seamYawRad: Double,
        featherRad: Double,
        graphic: MTLTexture?,
        destination: CVPixelBuffer,
        commandBuffer: MTLCommandBuffer
    ) throws {
        try kernel.encode(
            masterPlanes: try master.map(kernel.planes(of:)), masterSide: masterSide,
            slavePlanes: try slave.map(kernel.planes(of:)), view: view,
            seamYawRad: seamYawRad, featherRad: featherRad, graphic: nil, strip: nil,
            destinationPlanes: nitida, commandBuffer: commandBuffer
        )
        luma.encode(commandBuffer: commandBuffer, sourceTexture: nitida.0, destinationTexture: borrosa.0)
        croma.encode(commandBuffer: commandBuffer, sourceTexture: nitida.1, destinationTexture: borrosa.1)
        // La cancha borrosa entra como la parte de una sola lente: el kernel la lee tal cual
        // y pone el gráfico encima.
        try kernel.encode(
            masterPlanes: borrosa, masterSide: masterSide, slavePlanes: nil, view: view,
            seamYawRad: seamYawRad, featherRad: featherRad, graphic: graphic, strip: nil,
            destinationPlanes: try kernel.planes(of: destination), commandBuffer: commandBuffer
        )
    }
}
