// El multiplexor MPEG-TS (IOS-53): CRC de las tablas, la forma de los paquetes, ADTS y,
// con ffmpeg en el Mac, 10 s muxados que ffprobe lee sin errores, con PTS monótonos y
// la sincronía A/V por debajo de 20 ms.

import CryptoKit
import Foundation
import RigCore
import XCTest

final class TsMuxerTests: XCTestCase {
    func testElCrcDeLaPatConocida() {
        // La PAT por defecto de ffmpeg (tsid 1, programa 1 → PMT 0x1000): CRC 2AB104B2.
        let pat = Data([0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00])
        XCTAssertEqual(TsMuxer.crc32Mpeg2(pat), 0x2AB1_04B2)
        // Y una sección con su propio CRC al final da residuo cero.
        var conCrc = pat
        let crc = TsMuxer.crc32Mpeg2(pat)
        conCrc += Data([UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        XCTAssertEqual(TsMuxer.crc32Mpeg2(conCrc), 0)
    }

    func testLaPatYLaPmtQueEscribe() throws {
        let mux = TsMuxer(audio: .init(sampleRate: 48000, channels: 2))
        let ts = mux.muxVideo(avcc: Self.avcc([[0x65, 0x88, 0x84]]), parameterSets: [Data([0x67, 0x42]), Data([0x68, 0xCE])],
                              isKeyframe: true, pts90k: 0, dts90k: 0)
        let paquetes = Self.paquetes(ts)
        // PAT idéntica a la de ffmpeg, con su CRC.
        XCTAssertEqual(Array(paquetes[0][0..<21]), [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0x2A, 0xB1, 0x04, 0xB2])
        // PMT en 0x1000 con vídeo 0x1B en 0x100 y audio 0x0F en 0x101, CRC con residuo 0.
        let pmt = paquetes[1]
        XCTAssertEqual(Array(pmt[0..<3]), [0x47, 0x50, 0x00])
        let largo = Int(pmt[6] & 0x0F) << 8 | Int(pmt[7])
        let seccion = Data(pmt[5..<(8 + largo)])
        XCTAssertEqual(TsMuxer.crc32Mpeg2(seccion), 0)
        XCTAssertTrue(seccion.range(of: Data([0x1B, 0xE1, 0x00])) != nil)
        XCTAssertTrue(seccion.range(of: Data([0x0F, 0xE1, 0x01])) != nil)
    }

    func testLosPaquetesYLosContadores() throws {
        let mux = TsMuxer(audio: nil)
        var ts = Data()
        for i in 0..<5 {
            // Un fotograma grande, que ocupa varios paquetes y deja relleno al final.
            let nal = Data([0x41]) + Data(repeating: UInt8(i), count: 1000 + i * 37)
            ts += mux.muxVideo(avcc: Self.avcc([[UInt8](nal)]), parameterSets: [], isKeyframe: i == 0,
                               pts90k: Int64(i) * 3000, dts90k: Int64(i) * 3000)
        }
        XCTAssertEqual(ts.count % TsFormat.packetSize, 0)
        var cc: UInt8?
        for p in Self.paquetes(ts) {
            XCTAssertEqual(p[0], 0x47)
            let pid = (UInt16(p[1] & 0x1F) << 8) | UInt16(p[2])
            guard pid == TsFormat.videoPid else { continue }
            let actual = p[3] & 0x0F
            if let cc { XCTAssertEqual(actual, (cc + 1) & 0x0F, "contador de continuidad") }
            cc = actual
        }
    }

    func testLaCabeceraAdts() throws {
        let h = try Adts.header(payloadLength: 100, sampleRate: 48000, channels: 2)
        XCTAssertEqual(h.count, 7)
        XCTAssertEqual(Array(h[0..<2]), [0xFF, 0xF1])
        let largo = (Int(h[3] & 0x3) << 11) | (Int(h[4]) << 3) | Int(h[5] >> 5)
        XCTAssertEqual(largo, 107)
        XCTAssertEqual((h[2] >> 2) & 0xF, 3, "índice de 48 kHz")
        XCTAssertThrowsError(try Adts.header(payloadLength: 10, sampleRate: 47000, channels: 2))
    }

    func testBytesDoradosDeUnaEntradaPequena() {
        // Congela la salida: cualquier cambio del formato tiene que ser a propósito.
        let mux = TsMuxer(audio: nil)
        var ts = mux.muxVideo(avcc: Self.avcc([[0x65, 1, 2, 3]]), parameterSets: [Data([0x67, 1]), Data([0x68, 2])],
                              isKeyframe: true, pts90k: 9000, dts90k: 9000)
        ts += mux.muxVideo(avcc: Self.avcc([[0x41, 4, 5]]), parameterSets: [], isKeyframe: false, pts90k: 12000, dts90k: 12000)
        let sha = SHA256.hash(data: ts).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ts.count, 4 * TsFormat.packetSize)
        XCTAssertEqual(sha, Self.shaDorado, "si el cambio es a propósito, actualiza el dorado")
    }

    /// 10 s de H.264 y AAC de ffmpeg, muxados aquí y leídos por ffprobe.
    func testDiezSegundosQueFfprobeLeeSinErrores() throws {
        guard let ffmpeg = Self.herramienta("ffmpeg"), let ffprobe = Self.herramienta("ffprobe") else {
            throw XCTSkip("sin ffmpeg/ffprobe en este Mac")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let h264 = dir.appendingPathComponent("v.h264"), aac = dir.appendingPathComponent("a.aac")
        try Self.correr(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30:duration=10",
                                 "-c:v", "libx264", "-bf", "0", "-g", "30", "-x264-params", "aud=1", "-f", "h264", h264.path])
        try Self.correr(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=10",
                                 "-ac", "2", "-c:a", "aac", "-f", "adts", aac.path])

        let mux = TsMuxer(audio: .init(sampleRate: 48000, channels: 2))
        var ts = Data()
        let unidades = Self.unidadesDeAcceso(try Data(contentsOf: h264))
        let tramas = Self.tramasAdts(try Data(contentsOf: aac))
        var (v, a) = (0, 0)
        let inicio: Int64 = 90_000
        while v < unidades.count || a < tramas.count {
            let ptsV = inicio + Int64(v) * 3000, ptsA = inicio + Int64(a) * 1920  // 1024 muestras a 48 kHz
            if v < unidades.count && (a >= tramas.count || ptsV <= ptsA) {
                let nals = unidades[v]
                let tipos = nals.compactMap { $0.first.map { $0 & 0x1F } }
                ts += mux.muxVideo(avcc: Self.avcc(nals.map { [UInt8]($0) }), parameterSets: [],
                                   isKeyframe: tipos.contains(5), pts90k: ptsV, dts90k: ptsV)
                v += 1
            } else {
                ts += try mux.muxAudio(aacRaw: tramas[a], pts90k: ptsA)
                a += 1
            }
        }
        let salida = dir.appendingPathComponent("p.ts")
        try ts.write(to: salida)
        XCTAssertGreaterThan(unidades.count, 290)

        let (errores, paquetes) = try Self.correr(ffprobe, ["-v", "error", "-show_entries", "packet=stream_index,pts_time",
                                                            "-of", "csv=p=0", salida.path])
        XCTAssertEqual(errores.trimmingCharacters(in: .whitespacesAndNewlines), "", "ffprobe se queja")
        var ultimos: [String: Double] = [:], primeros: [String: Double] = [:]
        for linea in paquetes.split(separator: "\n") {
            let partes = linea.split(separator: ",")
            guard partes.count == 2, let t = Double(partes[1]) else { continue }
            let s = String(partes[0])
            if let u = ultimos[s] { XCTAssertGreaterThan(t, u, "PTS no monótono en el flujo \(s)") }
            ultimos[s] = t
            if primeros[s] == nil { primeros[s] = t }
        }
        XCTAssertEqual(primeros.count, 2, "vídeo y audio")
        let desfase = abs(primeros["0"]! - primeros["1"]!)
        XCTAssertLessThan(desfase, 0.020, "sincronía A/V")
        try ts.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ios53-diez-segundos.ts"))
    }

    // MARK: - Soporte

    static let shaDorado = "656941192e4a96a5e953c6796915a9f9a4b2d800ce79927088184942e88d1054"

    private static func avcc(_ nals: [[UInt8]]) -> Data {
        var d = Data()
        for n in nals {
            let l = UInt32(n.count)
            d += Data([UInt8(l >> 24), UInt8((l >> 16) & 0xFF), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF)]) + Data(n)
        }
        return d
    }

    private static func paquetes(_ ts: Data) -> [[UInt8]] {
        stride(from: 0, to: ts.count, by: TsFormat.packetSize).map { [UInt8](ts[$0..<($0 + TsFormat.packetSize)]) }
    }

    /// Annex B partido por AUD: cada unidad de acceso, sus NAL sin el AUD.
    private static func unidadesDeAcceso(_ es: Data) -> [[Data]] {
        let bytes = [UInt8](es)
        var inicios: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { inicios.append(i + 3); i += 3 } else { i += 1 }
        }
        var unidades: [[Data]] = []
        for (k, s) in inicios.enumerated() {
            var fin = k + 1 < inicios.count ? inicios[k + 1] - 3 : bytes.count
            while fin > s, bytes[fin - 1] == 0 { fin -= 1 }
            let nal = Data(bytes[s..<fin])
            if nal.first.map({ $0 & 0x1F }) == 9 { unidades.append([]); continue }
            if unidades.isEmpty { unidades.append([]) }
            unidades[unidades.count - 1].append(nal)
        }
        return unidades.filter { !$0.isEmpty }
    }

    /// Las tramas AAC crudas de un .aac ADTS (sin su cabecera).
    private static func tramasAdts(_ datos: Data) -> [Data] {
        let b = [UInt8](datos)
        var tramas: [Data] = []
        var i = 0
        while i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF0 == 0xF0 {
            let largo = (Int(b[i + 3] & 0x3) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
            let cabecera = b[i + 1] & 0x01 == 1 ? 7 : 9
            tramas.append(Data(b[(i + cabecera)..<(i + largo)]))
            i += largo
        }
        return tramas
    }

    private static func herramienta(_ nombre: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + nombre }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func correr(_ ruta: String, _ args: [String]) throws -> (String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ruta)
        p.arguments = args
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = out
        try p.run()
        let salida = out.fileHandleForReading.readDataToEndOfFile()
        let errores = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: errores, as: UTF8.self), String(decoding: salida, as: UTF8.self))
    }
}
