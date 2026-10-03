// Pool de CVPixelBuffer con IOSurface (IOS-04): preasignado, compatible con Metal y
// con tope duro.
//
// La regla del servidor, aplicada al móvil: nada de reservar memoria dentro del bucle
// de frames. El pool se precalienta al arrancar y `take()` devuelve `nil` antes que
// reservar por encima del tope (`kCVPixelBufferPoolAllocationThresholdKey`): quedarse
// sin hueco es un descarte que se cuenta, no una reserva que el jetsam cobra.

import CoreVideo
import Foundation

public final class PixelBufferPool {
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    public let width: Int
    public let height: Int
    public let pixelFormat: OSType
    public let capacity: Int

    public init?(width: Int, height: Int, pixelFormat: OSType, capacity: Int) {
        guard width > 0, height > 0, capacity > 0 else { return nil }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.capacity = capacity

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            // IOSurface vacío = «dame uno»; es lo que hace al buffer compartible con
            // Metal y con VideoToolbox sin copias.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: capacity,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            return nil
        }
        self.pool = pool
        auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey: capacity
        ] as CFDictionary

        prewarm()
    }

    /// Reserva los `capacity` buffers de golpe y los suelta al pool: a partir de aquí,
    /// `take()` solo recicla.
    private func prewarm() {
        var retenidos: [CVPixelBuffer] = []
        retenidos.reserveCapacity(capacity)
        for _ in 0..<capacity {
            if let buffer = take() {
                retenidos.append(buffer)
            }
        }
        retenidos.removeAll()
    }

    /// Un buffer del pool, o `nil` si los `capacity` están en uso. Nunca reserva más.
    public func take() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let estado = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttributes, &buffer
        )
        guard estado == kCVReturnSuccess else { return nil }
        return buffer
    }
}
