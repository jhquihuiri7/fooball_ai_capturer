// El tiempo del soporte, pintado dentro de la imagen (ADR 0012, enmienda B1a).
//
// Espejo exacto de `libs/vision/source/timecode.py` del servidor. Si cambia algo aquí,
// cambia allí el mismo día, o el emparejado deja de funcionar sin dar ningún error.
//
// Por qué en la imagen y no en el PTS: entre el móvil y el servidor hay relés (MediaMTX,
// RTSP) que reescriben las marcas de tiempo. Lo único que sobrevive a cualquier
// transporte, y a la recompresión, es lo que está pintado. Y queda en el archivo local,
// así que el diferido se empareja igual.
//
// Formato: 64 celdas cuadradas en una fila desde el píxel (0, 0) del plano de luma.
//   bits  0–7    preámbulo 0xB2 (10110010)
//   bits  8–55   milisegundos del reloj del soporte, sin signo, big-endian
//   bits 56–63   CRC-8 (polinomio 0x07, inicial 0) de esos seis bytes

import CoreVideo
import Foundation

enum RigTimecode {
    static let bits = 64
    static let payloadBits = 48
    static let payloadMax: UInt64 = (1 << 48) - 1
    static let preamble: UInt64 = 0xB2

    /// Celdas que cabrían a lo ancho del frame: fija el lado de cada celda
    /// (`RIG_TIMECODE_CELLS_ACROSS`). 16 px en 4K.
    static let cellsAcross = 240

    /// Lado mínimo, para que el códec no se coma una celda (`RIG_TIMECODE_MIN_CELL_PX`).
    static let minCellPx = 4

    /// Blanco y negro de vídeo, no de PC: 235 y 16 son los límites legales del rango
    /// de vídeo y ningún códec los recorta (`RIG_TIMECODE_LUMA_ONE` / `_ZERO`).
    static let lumaOne: UInt8 = 235
    static let lumaZero: UInt8 = 16

    static let crcPolynomial: UInt8 = 0x07

    /// Lado de una celda para un frame de ese ancho.
    ///
    /// Redondeo al par en los .5, como hace `round` de Python en el servidor: 3000/240
    /// tiene que dar 12 en los dos lados, no 12 aquí y 13 allí.
    static func cellSide(width: Int) -> Int {
        let side = (Double(width) / Double(cellsAcross)).rounded(.toNearestOrEven)
        return max(minCellPx, Int(side))
    }

    /// Filas que ocupa el código. Quien analice la imagen debe ignorarlas.
    static func stripHeight(width: Int) -> Int {
        cellSide(width: width)
    }

    /// CRC-8 con polinomio 0x07 y valor inicial 0 (CRC-8/SMBUS). Diez líneas, igual que
    /// en el servidor, para que las dos implementaciones se lean igual.
    static func crc8(_ data: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 0x80) != 0 ? (crc << 1) ^ crcPolynomial : crc << 1
            }
        }
        return crc
    }

    /// Los 64 bits del código, del más al menos significativo.
    static func word(valueMs: UInt64) -> UInt64 {
        precondition(valueMs <= payloadMax, "el tiempo no cabe en 48 bits")
        let payload = (0..<payloadBits / 8).map { index in
            UInt8((valueMs >> UInt64(8 * (payloadBits / 8 - 1 - index))) & 0xFF)
        }
        return (preamble << UInt64(payloadBits + 8)) | (valueMs << 8) | UInt64(crc8(payload))
    }

    /// Pinta el código en el plano de luma del buffer, en su sitio.
    ///
    /// Devuelve `false` si no hay sitio o el buffer no es 4:2:0 planar con la luma en
    /// el plano 0; en ese caso no toca nada. Se escribe sobre el buffer de la cámara
    /// porque es el mismo que va al archivo y al stream: pintado una vez, sale en los dos.
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
