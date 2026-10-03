// Paso AVCC ↔ Annex B (IOS-51).
//
// Las dos formas de empaquetar NALs de H.264: AVCC les antepone la longitud (4 bytes
// big-endian; lo que da VideoToolbox y lo que viaja por el enlace) y Annex B un código
// de arranque 00 00 00 01 (lo que entiende un .ts o ffmpeg a pelo). La conversión es
// mecánica pero con dos trampas: los códigos de arranque de 3 bytes también valen, y
// una longitud corrupta no puede mandar a leer fuera del búfer.
//
// Puro a propósito: bytes que entran, bytes que salen, probado en RigCoreTests.

import Foundation

public enum NalUnits {
    /// El código de arranque largo del Annex B.
    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    /// AVCC → Annex B: cada longitud se vuelve un código de arranque. Una muestra
    /// truncada devuelve lo convertido hasta donde cuadraba.
    public static func annexB(fromAvcc sample: Data) -> Data {
        var out = Data(capacity: sample.count + 16)
        forEachNal(inAvcc: sample) { nal in
            out.append(startCode)
            out.append(nal)
        }
        return out
    }

    /// Annex B → AVCC: cada código de arranque (de 3 o de 4 bytes) se vuelve una
    /// longitud de 4 bytes.
    public static func avcc(fromAnnexB stream: Data) -> Data {
        var out = Data(capacity: stream.count + 8)
        var inicio: Int? = nil  // índice del primer byte de la NAL en curso
        var i = stream.startIndex

        func cerrar(hasta fin: Int) {
            guard let desde = inicio, fin > desde else { return }
            out.appendBigEndian(UInt32(fin - desde))
            out.append(stream.subdata(in: desde..<fin))
        }

        while i < stream.endIndex {
            let quedan = stream.endIndex - i
            if quedan >= 3, stream[i] == 0, stream[i + 1] == 0 {
                if stream[i + 2] == 1 {
                    cerrar(hasta: i)
                    inicio = i + 3
                    i += 3
                    continue
                }
                if quedan >= 4, stream[i + 2] == 0, stream[i + 3] == 1 {
                    cerrar(hasta: i)
                    inicio = i + 4
                    i += 4
                    continue
                }
            }
            i += 1
        }
        cerrar(hasta: stream.endIndex)
        return out
    }

    /// Los tipos de NAL de una muestra AVCC, en orden. 5 es un corte IDR, 7 el SPS,
    /// 8 el PPS y 6 una SEI.
    public static func types(inAvcc sample: Data) -> [UInt8] {
        var tipos: [UInt8] = []
        forEachNal(inAvcc: sample) { nal in
            if let primero = nal.first {
                tipos.append(primero & 0x1F)
            }
        }
        return tipos
    }

    /// Recorre las NAL de una muestra AVCC. Para en cuanto una longitud no cuadra.
    public static func forEachNal(inAvcc sample: Data, _ body: (Data) -> Void) {
        var offset = sample.startIndex
        while offset + 4 <= sample.endIndex {
            var reader = BigEndianReader(data: sample.subdata(in: offset..<(offset + 4)))
            guard let length = reader.read(UInt32.self) else { return }
            let inicio = offset + 4
            guard length > 0, inicio + Int(length) <= sample.endIndex else { return }
            body(sample.subdata(in: inicio..<(inicio + Int(length))))
            offset = inicio + Int(length)
        }
    }
}
