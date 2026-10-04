// El multiplexor MPEG-TS del programa (IOS-53), puro y determinista.
//
// H.264 (stream_type 0x1B) y AAC en ADTS (0x0F) en paquetes de 188 B. Por cada
// fotograma: AUD, y delante de cada IDR el SPS/PPS y las tablas PAT y PMT, para que
// quien se enganche a mitad (HLS, un segmento nuevo) arranque en el siguiente IDR.
// El SEI del fotograma (H264Sei) va DENTRO de la unidad de acceso y de su PES: fuera,
// HLS lo pierde (ADR 0022). El PCR va en el PID de vídeo, en el primer paquete de
// cada fotograma: a 25–30 fps, cada ≤40 ms.

import Foundation

/// Las constantes del formato (ISO/IEC 13818-1): las fija el estándar, no el producto.
public enum TsFormat {
    public static let packetSize = 188
    static let headerSize = 4
    static let payloadSize = packetSize - headerSize
    static let syncByte: UInt8 = 0x47
    static let patPid: UInt16 = 0x0000
    public static let pmtPid: UInt16 = 0x1000
    public static let videoPid: UInt16 = 0x0100
    public static let audioPid: UInt16 = 0x0101
    static let programNumber: UInt16 = 1
    static let transportStreamId: UInt16 = 1
    static let streamTypeH264: UInt8 = 0x1B
    static let streamTypeAacAdts: UInt8 = 0x0F
    static let videoStreamId: UInt8 = 0xE0
    static let audioStreamId: UInt8 = 0xC0
    /// Los PTS/DTS son de 33 bits en un reloj de 90 kHz.
    public static let clockHz: Int64 = 90_000
    static let timestampMask: Int64 = (1 << 33) - 1
    /// El PCR va por detrás del DTS lo que el decodificador necesita para llenar su
    /// búfer antes de mostrar: con un fotograma de 1080p de bajo retardo basta un
    /// fotograma largo, y se deja 100 ms (el máximo que permite el estándar entre PCRs).
    static let pcrDelay90k: Int64 = 9_000
}

public final class TsMuxer {
    /// El audio del programa, si lo hay.
    public struct AudioConfig: Equatable, Sendable {
        public let sampleRate: Int
        public let channels: Int

        public init(sampleRate: Int, channels: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    private let audio: AudioConfig?
    private var continuity: [UInt16: UInt8] = [:]
    private var tablesWritten = false

    public init(audio: AudioConfig?) {
        self.audio = audio
    }

    /// Una unidad de acceso H.264 en AVCC (lo que da VideoToolbox, con el SEI dentro).
    /// `parameterSets` son el SPS y el PPS del formato: van delante de cada IDR si el
    /// fotograma no los trae ya.
    public func muxVideo(
        avcc: Data, parameterSets: [Data], isKeyframe: Bool, pts90k: Int64, dts90k: Int64
    ) -> Data {
        var salida = Data()
        if isKeyframe || !tablesWritten {
            salida += psiPacket(pid: TsFormat.patPid, section: patSection())
            salida += psiPacket(pid: TsFormat.pmtPid, section: pmtSection())
            tablesWritten = true
        }

        let tipos = NalUnits.types(inAvcc: avcc)
        var es = Data([0, 0, 0, 1, 0x09, 0xF0])  // AUD: cualquier tipo de corte
        if isKeyframe && !(tipos.contains(7) && tipos.contains(8)) {
            for ps in parameterSets {
                es += Data([0, 0, 0, 1]) + ps
            }
        }
        NalUnits.forEachNal(inAvcc: avcc) { nal in
            guard let primero = nal.first, primero & 0x1F != 9 else { return }  // su AUD sobra
            es += Data([0, 0, 0, 1]) + nal
        }

        let pes = pesHeader(
            streamId: TsFormat.videoStreamId, pts90k: pts90k,
            dts90k: dts90k == pts90k ? nil : dts90k, payloadLength: nil
        ) + es
        let pcr = (dts90k - TsFormat.pcrDelay90k) & TsFormat.timestampMask
        salida += packetize(pid: TsFormat.videoPid, payload: pes, pcr90k: pcr, randomAccess: isKeyframe)
        return salida
    }

    /// Una trama AAC cruda: se le pone la cabecera ADTS y va en su propio PES.
    public func muxAudio(aacRaw: Data, pts90k: Int64) throws -> Data {
        guard let audio else {
            throw RigError.message("el multiplexor se creó sin audio")
        }
        let trama = try Adts.header(
            payloadLength: aacRaw.count, sampleRate: audio.sampleRate, channels: audio.channels
        ) + aacRaw
        var salida = Data()
        if !tablesWritten {
            salida += psiPacket(pid: TsFormat.patPid, section: patSection())
            salida += psiPacket(pid: TsFormat.pmtPid, section: pmtSection())
            tablesWritten = true
        }
        let pes = pesHeader(
            streamId: TsFormat.audioStreamId, pts90k: pts90k, dts90k: nil, payloadLength: trama.count
        ) + trama
        salida += packetize(pid: TsFormat.audioPid, payload: pes, pcr90k: nil, randomAccess: false)
        return salida
    }

    // MARK: - PSI

    func patSection() -> Data {
        var cuerpo = Data()
        cuerpo += be16(TsFormat.transportStreamId)
        cuerpo += Data([0xC1, 0x00, 0x00])  // versión 0, actual; sección 0 de 0
        cuerpo += be16(TsFormat.programNumber)
        cuerpo += be16(0xE000 | TsFormat.pmtPid)
        return section(tableId: 0x00, body: cuerpo)
    }

    func pmtSection() -> Data {
        var cuerpo = Data()
        cuerpo += be16(TsFormat.programNumber)
        cuerpo += Data([0xC1, 0x00, 0x00])
        cuerpo += be16(0xE000 | TsFormat.videoPid)  // el PCR va en el vídeo
        cuerpo += be16(0xF000)  // sin descriptores de programa
        cuerpo += Data([TsFormat.streamTypeH264]) + be16(0xE000 | TsFormat.videoPid) + be16(0xF000)
        if audio != nil {
            cuerpo += Data([TsFormat.streamTypeAacAdts]) + be16(0xE000 | TsFormat.audioPid) + be16(0xF000)
        }
        return section(tableId: 0x02, body: cuerpo)
    }

    /// Una sección PSI con su cabecera larga y su CRC32 de MPEG-2.
    private func section(tableId: UInt8, body: Data) -> Data {
        let largo = body.count + 4  // + CRC
        var s = Data([tableId]) + be16(0xB000 | UInt16(largo)) + body
        s += be32(Self.crc32Mpeg2(s))
        return s
    }

    private func psiPacket(pid: UInt16, section: Data) -> Data {
        var payload = Data([0x00]) + section  // pointer_field
        payload += Data(repeating: 0xFF, count: TsFormat.payloadSize - payload.count)
        return header(pid: pid, unitStart: true, adaptation: false) + payload
    }

    /// CRC-32/MPEG-2: polinomio 0x04C11DB7, inicial 0xFFFFFFFF, sin reflejar ni XOR final.
    public static func crc32Mpeg2(_ datos: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in datos {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    // MARK: - PES

    private func pesHeader(streamId: UInt8, pts90k: Int64, dts90k: Int64?, payloadLength: Int?) -> Data {
        let opcional = dts90k == nil ? 5 : 10
        var h = Data([0x00, 0x00, 0x01, streamId])
        // El vídeo va sin longitud (0): un IDR de 1080p pasa de los 65 535 B.
        let largo = payloadLength.map { $0 + 3 + opcional } ?? 0
        h += be16(UInt16(largo > 0xFFFF ? 0 : largo))
        h += Data([0x80, dts90k == nil ? 0x80 : 0xC0, UInt8(opcional)])
        h += timestamp(pts90k, marker: dts90k == nil ? 0x2 : 0x3)
        if let dts90k {
            h += timestamp(dts90k, marker: 0x1)
        }
        return h
    }

    private func timestamp(_ t90k: Int64, marker: UInt8) -> Data {
        let t = UInt64(t90k & TsFormat.timestampMask)
        return Data([
            (marker << 4) | UInt8((t >> 29) & 0x0E) | 0x01,
            UInt8((t >> 22) & 0xFF),
            UInt8((t >> 14) & 0xFE) | 0x01,
            UInt8((t >> 7) & 0xFF),
            UInt8((t << 1) & 0xFE) | 0x01,
        ])
    }

    // MARK: - Paquetes

    private func header(pid: UInt16, unitStart: Bool, adaptation: Bool) -> Data {
        let cc = continuity[pid, default: 0]
        continuity[pid] = (cc + 1) & 0x0F
        return Data([
            TsFormat.syncByte,
            (unitStart ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F),
            UInt8(pid & 0xFF),
            (adaptation ? 0x30 : 0x10) | cc,
        ])
    }

    /// Trocea un PES en paquetes. El primero lleva el PCR y el acceso aleatorio si
    /// tocan; el último se rellena con el campo de adaptación (nunca con 0xFF en el
    /// payload, que el PES contaría como datos).
    private func packetize(pid: UInt16, payload: Data, pcr90k: Int64?, randomAccess: Bool) -> Data {
        var salida = Data()
        var offset = 0
        var primero = true
        while offset < payload.count {
            let especial = primero && (pcr90k != nil || randomAccess)
            // Bytes del campo de adaptación tras su byte de longitud: flags y PCR.
            let base = especial ? 1 + (pcr90k != nil ? 6 : 0) : 0
            let quedan = payload.count - offset
            let cabe = TsFormat.payloadSize - (especial ? 1 + base : 0)
            let trozo: Int
            var campo: Data?
            if quedan >= cabe {
                trozo = cabe
                if especial { campo = adaptationField(length: base, base: base, pcr90k: pcr90k, randomAccess: randomAccess) }
            } else {
                trozo = quedan
                let total = TsFormat.payloadSize - quedan  // con el byte de longitud
                campo = adaptationField(
                    length: total - 1, base: base,
                    pcr90k: especial ? pcr90k : nil, randomAccess: especial && randomAccess
                )
            }
            salida += header(pid: pid, unitStart: primero, adaptation: campo != nil)
            if let campo { salida += campo }
            salida += payload[payload.startIndex + offset ..< payload.startIndex + offset + trozo]
            offset += trozo
            primero = false
        }
        return salida
    }

    private func adaptationField(length: Int, base: Int, pcr90k: Int64?, randomAccess: Bool) -> Data {
        var campo = Data([UInt8(length)])
        guard length > 0 else { return campo }
        campo += Data([(randomAccess ? 0x40 : 0x00) | (pcr90k != nil ? 0x10 : 0x00)])
        if let pcr90k {
            let b = UInt64(pcr90k & TsFormat.timestampMask)
            campo += Data([
                UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF), UInt8((b >> 9) & 0xFF),
                UInt8((b >> 1) & 0xFF), UInt8(((b & 0x1) << 7) | 0x7E), 0x00,  // extensión 0
            ])
        }
        campo += Data(repeating: 0xFF, count: length - max(base, 1))
        return campo
    }

    private func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }

    private func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
