// La cabecera ADTS de una trama AAC (IOS-53): lo que convierte el AAC crudo del
// codificador en algo que un demultiplexor de MPEG-TS sabe leer (stream_type 0x0F).

import Foundation

public enum Adts {
    /// Bytes de la cabecera sin CRC (protection_absent = 1).
    public static let headerLength = 7

    /// Las frecuencias de muestreo que ADTS sabe nombrar, por su índice (ISO 14496-3).
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// El objeto de audio AAC-LC, el que da AudioToolbox por defecto.
    public static let aacLowComplexity = 2

    /// La trama máxima: frame_length son 13 bits.
    static let maxFrameLength = (1 << 13) - 1

    /// La cabecera para una trama de `payloadLength` bytes de AAC crudo.
    public static func header(
        payloadLength: Int, sampleRate: Int, channels: Int, objectType: Int = aacLowComplexity
    ) throws -> Data {
        guard let indice = sampleRates.firstIndex(of: sampleRate) else {
            throw RigError.message("ADTS no tiene índice para \(sampleRate) Hz")
        }
        guard (1...7).contains(channels) else {
            throw RigError.message("ADTS admite de 1 a 7 canales, no \(channels)")
        }
        let largo = payloadLength + headerLength
        guard largo <= maxFrameLength else {
            throw RigError.message("una trama AAC de \(payloadLength) B no cabe en ADTS")
        }
        let perfil = objectType - 1
        let plenitud = 0x7FF  // buffer fullness: tasa variable
        let b2: Int = (perfil << 6) | (indice << 2) | ((channels >> 2) & 0x1)
        let b3: Int = ((channels & 0x3) << 6) | ((largo >> 11) & 0x3)
        let b4: Int = (largo >> 3) & 0xFF
        let b5: Int = ((largo & 0x7) << 5) | ((plenitud >> 6) & 0x1F)
        let b6: Int = (plenitud & 0x3F) << 2  // y una sola trama AAC
        // 0xFF 0xF1: sincronía, MPEG-4, capa 0, sin CRC.
        return Data([0xFF, 0xF1, UInt8(b2), UInt8(b3), UInt8(b4), UInt8(b5), UInt8(b6)])
    }
}
