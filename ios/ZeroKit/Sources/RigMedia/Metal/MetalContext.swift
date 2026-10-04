// El contexto Metal compartido (IOS-04): dispositivo, cola, caché de texturas y la
// biblioteca de kernels.
//
// Uno por proceso y se pasa, no se crea por frame: crear colas y cachés es caro y el
// pipeline no reserva nada dentro del bucle (la regla del servidor).

import CoreVideo
import Foundation
import Metal

public final class MetalContext {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache
    public let library: MTLLibrary

    /// `nil` solo donde no hay Metal, que en un iPhone o un Mac de verdad no pasa.
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            return nil
        }
        self.device = device
        self.queue = queue

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache
        else {
            return nil
        }
        self.textureCache = textureCache

        // Los .metal del paquete compilan a default.metallib dentro de Bundle.module.
        // `swift test` por CLI no lo compila: copia las fuentes, y entonces se compilan
        // aquí, juntas, para que los kernels de verdad existan también en los tests.
        if let url = Bundle.module.url(forResource: "default", withExtension: "metallib"),
           let library = try? device.makeLibrary(URL: url) {
            self.library = library
        } else if let fuentes = Self.bundledSources(),
                  let library = try? device.makeLibrary(source: fuentes, options: nil) {
            self.library = library
        } else if let library = try? device.makeLibrary(source: Self.fallbackSource, options: nil) {
            self.library = library
        } else {
            return nil
        }
    }

    /// Una vista MTLTexture de un plano de un CVPixelBuffer con IOSurface, por la caché.
    ///
    /// Los formatos del pipeline: NV12 luma `r8Unorm` (plano 0) y croma `rg8Unorm`
    /// (plano 1), `bgra8Unorm` para compuestos y `r16Float` para los heatmaps.
    public func texture(
        from buffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferIsPlanar(buffer)
            ? CVPixelBufferGetWidthOfPlane(buffer, plane)
            : CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferIsPlanar(buffer)
            ? CVPixelBufferGetHeightOfPlane(buffer, plane)
            : CVPixelBufferGetHeight(buffer)
        var texture: CVMetalTexture?
        let estado = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format, width, height, plane, &texture
        )
        guard estado == kCVReturnSuccess, let texture else { return nil }
        return CVMetalTextureGetTexture(texture)
    }

    /// Las fuentes .metal copiadas al bundle, en un solo texto. `nil` si no hay.
    private static func bundledSources() -> String? {
        let urls = (Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let textos = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        return textos.isEmpty ? nil : textos.joined(separator: "\n")
    }

    /// Lo mínimo que compila: mantiene viva la ruta `makeLibrary(source:)` hasta que
    /// lleguen los kernels de verdad (IOS-30 en adelante).
    private static let fallbackSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void rig_noop(uint2 gid [[thread_position_in_grid]]) {}
    """
}
