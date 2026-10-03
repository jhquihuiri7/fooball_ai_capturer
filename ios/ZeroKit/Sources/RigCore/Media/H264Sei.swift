// La SEI con el tiempo del soporte (IOS-50, ADR 0022).
//
// Cada fotograma codificado lleva una SEI user_data_unregistered con el rigMs y el
// viewId DENTRO de su unidad de acceso: viajando con el fotograma sobrevive al PES, a
// HLS y a cualquier relé, que es justo donde un canal aparte la perdería (ADR 0022).
//
// Es puro a propósito: construye y lee bytes, sin VideoToolbox, para poder probarlo en
// RigCoreTests y replicarlo contra los dorados si algún día hace falta. La parte con
// trampa es la prevención de emulación del Anexo B del H.264: dentro de una NAL no
// puede aparecer 00 00 00/01/02/03, así que al escribir se intercala 03
// (00 00 xx → 00 00 03 xx) y al leer se quita. Un rigMs pequeño empieza por ceros y
// cae en ello SIEMPRE: sin el escape, el decodificador vería un arranque falso.

import Foundation

public enum H264Sei {
    /// El UUID de ISO/IEC 11578 que identifica nuestras SEI: 16 bytes fijos. Legible a
    /// propósito, para reconocerlo en un volcado hexadecimal.
    public static let uuid = Data("football-ai.rig0".utf8)

    /// `user_data_unregistered` del Anexo D.
    private static let payloadType: UInt8 = 5
    /// nal_ref_idc 0 + nal_unit_type 6 (SEI).
    private static let nalHeader: UInt8 = 0x06
    /// UUID (16) + rigMs (8, big-endian) + viewId (1).
    private static let payloadSize = 25

    // MARK: - Construcción

    /// La NAL SEI completa (cabecera + RBSP escapado), sin prefijo de longitud ni de
    /// arranque: quien la mete en AVCC le antepone los 4 bytes de longitud.
    public static func build(rigMs: UInt64, viewId: UInt8) -> Data {
        var rbsp = Data()
        rbsp.append(payloadType)
        rbsp.append(UInt8(payloadSize))
        rbsp.append(uuid)
        rbsp.appendBigEndian(rigMs)
        rbsp.append(viewId)
        rbsp.append(0x80)  // rbsp_trailing_bits

        var nal = Data()
        nal.append(nalHeader)
        nal.append(escape(rbsp))
        return nal
    }

    /// Lee una NAL SEI. `nil` si no es una SEI nuestra (otro tipo de NAL, otro
    /// payload, otro UUID o bytes que no cuadran).
    public static func parse(nal: Data) -> (rigMs: UInt64, viewId: UInt8)? {
        guard nal.count >= 2, nal[nal.startIndex] & 0x1F == 0x06 else { return nil }
        // `unescape` devuelve un Data nuevo con índices desde cero.
        let rbsp = unescape(nal.subdata(in: (nal.startIndex + 1)..<nal.endIndex))
        guard rbsp.count >= 2 + payloadSize,
              rbsp[0] == payloadType,
              rbsp[1] == UInt8(payloadSize),
              rbsp.subdata(in: 2..<18) == uuid
        else {
            return nil
        }
        var reader = BigEndianReader(data: rbsp.subdata(in: 18..<26))
        guard let rigMs = reader.read(UInt64.self) else { return nil }
        return (rigMs: rigMs, viewId: rbsp[26])
    }

    // MARK: - AVCC

    /// Antepone la SEI al resto de NALs de la muestra AVCC (longitudes de 4 bytes):
    /// queda dentro de la unidad de acceso, que es lo que manda el ADR 0022.
    public static func insert(intoAvcc sample: Data, rigMs: UInt64, viewId: UInt8) -> Data {
        let nal = build(rigMs: rigMs, viewId: viewId)
        var out = Data(capacity: 4 + nal.count + sample.count)
        out.appendBigEndian(UInt32(nal.count))
        out.append(nal)
        out.append(sample)
        return out
    }

    /// Busca nuestra SEI recorriendo las NALs de una muestra AVCC. `nil` si no está.
    public static func find(inAvcc sample: Data) -> (rigMs: UInt64, viewId: UInt8)? {
        var offset = sample.startIndex
        while offset + 4 <= sample.endIndex {
            var reader = BigEndianReader(data: sample.subdata(in: offset..<(offset + 4)))
            guard let length = reader.read(UInt32.self) else { return nil }
            let start = offset + 4
            guard start + Int(length) <= sample.endIndex else { return nil }
            let nal = sample.subdata(in: start..<(start + Int(length)))
            if let found = parse(nal: nal) {
                return found
            }
            offset = start + Int(length)
        }
        return nil
    }

    // MARK: - Prevención de emulación

    /// 00 00 00/01/02/03 no puede aparecer dentro de una NAL: tras dos ceros se
    /// intercala un 03 antes de cualquier byte ≤ 3.
    static func escape(_ rbsp: Data) -> Data {
        var out = Data(capacity: rbsp.count + 8)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 0x03 {
                out.append(0x03)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Quita los 03 de emulación: 00 00 03 xx → 00 00 xx (solo si xx ≤ 3).
    static func unescape(_ nal: Data) -> Data {
        var out = Data(capacity: nal.count)
        var zeros = 0
        var index = nal.startIndex
        while index < nal.endIndex {
            let byte = nal[index]
            if zeros >= 2, byte == 0x03, index + 1 < nal.endIndex, nal[index + 1] <= 0x03 {
                zeros = 0  // el 03 era de emulación: se salta
            } else {
                out.append(byte)
                zeros = byte == 0 ? zeros + 1 : 0
            }
            index += 1
        }
        return out
    }
}
