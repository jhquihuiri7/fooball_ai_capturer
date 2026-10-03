// El pintado del código de tiempo sobre el buffer de la cámara (ADR 0012, B1a).
//
// La mitad con framework del código: RigCore sabe qué bits son, aquí se escriben en el
// plano de luma. Se escribe sobre el buffer de la cámara porque es el mismo que va al
// archivo y al stream: pintado una vez, sale en los dos.

import CoreVideo
import Foundation
import RigCore

public extension RigTimecode {
    /// Pinta el código en el plano de luma del buffer, en su sitio.
    ///
    /// Devuelve `false` si no hay sitio o el buffer no es 4:2:0 planar con la luma en
    /// el plano 0; en ese caso no toca nada.
    @discardableResult
    static func write(valueMs: UInt64, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard valueMs <= payloadMax,
              CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2
        else {
            return false
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let side = cellSide(width: width)
        guard width >= side * bits, height >= side else {
            return false
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return false
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let code = word(valueMs: valueMs)
        for row in 0..<side {
            let rowStart = luma + row * stride
            for index in 0..<bits {
                let bit = (code >> UInt64(bits - 1 - index)) & 1
                memset(rowStart + index * side, Int32(bit == 1 ? lumaOne : lumaZero), side)
            }
        }
        return true
    }
}
