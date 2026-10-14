import Foundation
import XCTest

import RigCore
import RigNet

/// La aceptación de IOS-55 contra MediaMTX: publicar un MPEG-TS con H.264 y AAC en
/// `programa` con streamid de usuario y clave y passphrase, sin errores, con estadísticas a
/// 1 Hz, y leerlo de vuelta. No corre por defecto:
///
///     RIG_SRT_MEDIAMTX=1 swift test --filter SrtMediaMtxTests           # 20 s en el Mac
///     RIG_SRT_MEDIAMTX=1 RIG_SRT_SOAK_S=600 swift test --filter …      # los 10 min
///
/// Contra el VPS (no se lee de vuelta: allí `programa` solo se lee desde el propio VPS; se
/// mira con ffprobe en él):
///
///     RIG_SRT_HOST=… RIG_SRT_USER=… RIG_SRT_PASS=… RIG_SRT_PASSPHRASE=… RIG_SRT_SOAK_S=600 \
///       swift test --filter SrtMediaMtxTests/testPublicaSinErrores
final class SrtMediaMtxTests: XCTestCase {
    private struct Banco {
        let destino: ProgramSrtTarget
        let lector: String?  // streamid de lectura, solo en el MediaMTX local
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var segundos: Int { Int(env["RIG_SRT_SOAK_S"] ?? "") ?? 20 }

    /// El VPS si hay RIG_SRT_HOST; si no, un MediaMTX propio con la config del VPS reducida
    /// a SRT. En el Mac escucha solo por IPv6 (`[::1]`), y así se prueba esa familia.
    private func banco() throws -> Banco {
        if let host = env["RIG_SRT_HOST"] {
            return Banco(destino: ProgramSrtTarget(host: host, port: UInt16(env["RIG_SRT_PORT"] ?? "") ?? 8890,
                                                   user: env["RIG_SRT_USER"] ?? "", pass: env["RIG_SRT_PASS"] ?? "",
                                                   passphrase: env["RIG_SRT_PASSPHRASE"] ?? ""), lector: nil)
        }
        guard env["RIG_SRT_MEDIAMTX"] == "1" else {
            throw XCTSkip("prueba larga: RIG_SRT_MEDIAMTX=1 (Mac) o RIG_SRT_HOST… (VPS)")
        }
        guard let mediamtx = SrtTestSupport.tool("mediamtx") else { throw XCTSkip("sin mediamtx (brew install mediamtx)") }
        let puerto = SrtTestSupport.freeUdpPort()
        let destino = ProgramSrtTarget(host: "::1", port: puerto, user: "maestro", pass: "clave-del-maestro",
                                       passphrase: "frase-de-paso-del-banco")
        let dir = try SrtTestSupport.tempDir(self)
        let config = dir.appendingPathComponent("mediamtx.yml")
        try """
        logLevel: info
        srt: yes
        srtAddress: :\(puerto)
        rtsp: no
        rtmp: no
        hls: no
        webrtc: no
        api: no
        metrics: no
        pprof: no
        playback: no
        moq: no
        authMethod: internal
        authInternalUsers:
          - user: \(destino.user)
            pass: \(destino.pass)
            ips: []
            permissions: [{action: publish, path: \(ProgramSrt.path)}]
          - user: lector
            pass: clave-del-lector
            ips: []
            permissions: [{action: read, path: \(ProgramSrt.path)}]
        paths:
          \(ProgramSrt.path):
            source: publisher
            overridePublisher: yes
            srtPublishPassphrase: \(destino.passphrase)
        """.write(to: config, atomically: true, encoding: .utf8)
        _ = try SrtTestSupport.launch(mediamtx, [config.path], stdout: dir.appendingPathComponent("mediamtx.log"), in: self)
        return Banco(destino: destino, lector: "read:\(ProgramSrt.path):lector:clave-del-lector")
    }

    /// `segundos` de 720p30 en H.264 a 6 Mbit/s constantes (el techo del programa,
    /// PROGRAM_VIDEO_BITRATE_BPS) y AAC, en MPEG-TS, de ffmpeg.
    private func programa(_ dir: URL) throws -> Data {
        guard let ffmpeg = SrtTestSupport.tool("ffmpeg") else { throw XCTSkip("sin ffmpeg") }
        let ts = dir.appendingPathComponent("programa.ts")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30:duration=\(segundos)",
                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(segundos)",
                       "-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-bf", "0", "-b:v", "6M",
                       "-minrate", "6M", "-maxrate", "6M", "-bufsize", "3M", "-x264-params", "nal-hrd=cbr",
                       "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-f", "mpegts", ts.path]
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: ts)
    }

    func testPublicaSinErrores() throws {
        let banco = try banco()
        let dir = try SrtTestSupport.tempDir(self)
        let ts = try programa(dir)
        let socket = SrtSocket()
        defer { socket.close() }
        // El caller repite el handshake cada 250 ms: conecta en cuanto MediaMTX escucha.
        try SrtTestSupport.connect(socket, attempts: 3) { try $0.connect(to: banco.destino) }

        var lectura: (Process, URL)?
        if let lector = banco.lector, let slt = SrtTestSupport.tool("srt-live-transmit") {
            let salida = dir.appendingPathComponent("leido.ts")
            let uri = "srt://[\(banco.destino.host)]:\(banco.destino.port)?streamid=\(lector)"
            lectura = (try SrtTestSupport.launch(slt, ["-q", uri, "file://con"], stdout: salida, in: self), salida)
        }

        // Al ritmo del fichero: cada 10 ms, lo que toca, en paquetes TS enteros.
        let porSegundo = Double(ts.count) / Double(segundos)
        let inicio = Date()
        var enviado = 0, ultimoInforme = 0
        while enviado < ts.count {
            let toca = min(ts.count, Int(Date().timeIntervalSince(inicio) * porSegundo) / 188 * 188)
            if toca > enviado {
                let n = try socket.send(ts.subdata(in: enviado..<toca))
                XCTAssertEqual(n, toca - enviado, "búfer de SRT lleno en el segundo \(enviado / Int(porSegundo))")
                enviado = toca
            }
            let segundo = Int(Date().timeIntervalSince(inicio))
            if segundo > ultimoInforme {
                ultimoInforme = segundo
                XCTAssertTrue(socket.isConnected, "SRT cayó en el segundo \(segundo)")
                let stats = try socket.stats()
                if segundo % 60 == 0 || segundo == segundos - 1 { print("SRT \(segundo) s · \(stats)") }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let stats = try socket.stats()
        print("SRT final · \(stats)")
        XCTAssertEqual(stats.packetsDropped, 0)
        XCTAssertGreaterThanOrEqual(stats.bytesSent, UInt64(ts.count))

        guard let (lector, salida) = lectura else { return }
        Thread.sleep(forTimeInterval: Double(ProgramSrt.latencyMs) / 1000 + 1)
        socket.close()
        lector.interrupt()
        lector.waitUntilExit()
        let leido = try Data(contentsOf: salida)
        // El lector entra unas décimas tarde y MediaMTX remultiplexa: no son los mismos
        // bytes, pero sí casi todo el programa, con su H.264 y su AAC.
        XCTAssertGreaterThan(Double(leido.count), 0.8 * Double(ts.count))
        if let ffprobe = SrtTestSupport.tool("ffprobe") {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", salida.path]
            p.standardOutput = pipe
            try p.run()
            let codecs = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(Set(codecs.split(separator: "\n").map(String.init)), ["h264", "aac"])
        }
    }

    func testCredencialesOPassphraseMalasSeRechazan() throws {
        let banco = try banco()
        let d = banco.destino
        let malas = [
            ("passphrase", ProgramSrtTarget(host: d.host, port: d.port, user: d.user, pass: d.pass,
                                            passphrase: "otra-frase-de-paso")),
            ("clave", ProgramSrtTarget(host: d.host, port: d.port, user: d.user, pass: "otra-clave",
                                       passphrase: d.passphrase)),
        ]
        for (que, destino) in malas {
            let socket = SrtSocket()
            // Con el timeout de siempre: MediaMTX espera 2 s antes de rechazar unas
            // credenciales malas, y con menos llegaría como timeout.
            XCTAssertThrowsError(try SrtTestSupport.connect(socket, attempts: 3) { try $0.connect(to: destino) },
                                 "con \(que) mala") {
                // MediaMTX contesta lo mismo a las dos; su log dice «invalid passphrase» o
                // «failed to authenticate».
                XCTAssertEqual($0 as? SrtError, .rejected(SrtError.rejectPeer), "con \(que) mala")
            }
        }
    }
}
