import Darwin
import Foundation
import XCTest

import RigCore
import RigMedia
import RigNet

/// El publicador del programa (IOS-56) con SRT de verdad y el programa sintético del
/// VideoEncoder y el AacEncoder.
///
/// - Contra el eco SRT (`srt-live-transmit` en escucha, con passphrase): corre siempre que
///   esté instalado, 8 s.
/// - Contra MediaMTX en el Mac, con la config del VPS reducida (SRT por IPv4, RTSP local y
///   el usuario `any` desde 127.0.0.1), leído de vuelta por RTSP; a un tercio se mata
///   MediaMTX y se relanza, y el publicador tiene que volver solo:
///
///       RIG_SRT_MEDIAMTX=1 swift test --filter ProgramPublisherSrtTests            # 90 s
///       RIG_SRT_MEDIAMTX=1 RIG_PUBLISH_S=120 swift test --filter …                 # 2 min
///
///   Con football-ai al lado (FOOTBALL_AI_DIR, por defecto ../fooball_ai_streaming desde
///   la raíz del repo, con `uv`), además pasa `tools/nube/sei_probe.py` por el RTSP.
/// - Contra el VPS (allí `programa` se lee desde el propio VPS, con ffprobe o la sonda):
///
///       RIG_SRT_HOST=… RIG_SRT_USER=… RIG_SRT_PASS=… RIG_SRT_PASSPHRASE=… RIG_PUBLISH_S=1800 \
///         swift test --filter ProgramPublisherSrtTests/testPublicaElProgramaEnMediaMtx
final class ProgramPublisherSrtTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    private func publisher(_ destino: ProgramSrtTarget, latencyMs: Int32 = ProgramSrt.latencyMs) -> ProgramPublisher {
        var timing = ProgramPublisher.Timing()
        timing.latencyMs = latencyMs
        let p = ProgramPublisher(target: destino, audio: .init(sampleRate: AudioConstants.sampleRate,
                                                               channels: AudioConstants.programChannels),
                                 maximumBps: SyntheticProgram.bitrateBps, timing: timing)
        p.onLog = { print("[srt] \($0)") }
        return p
    }

    private func wait(_ what: String, timeout: Double, _ cond: () -> Bool) {
        let fin = Date().addingTimeInterval(timeout)
        while !cond() && Date() < fin { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(cond(), what)
    }

    func testElProgramaLlegaAlEcoConSuSeiYSuAudio() throws {
        guard let slt = SrtTestSupport.tool("srt-live-transmit") else {
            throw XCTSkip("sin srt-live-transmit en este Mac (brew install srt)")
        }
        let dir = try SrtTestSupport.tempDir(self)
        let puerto = SrtTestSupport.freeUdpPort()
        let frase = "frase-de-paso-del-banco"
        let salida = dir.appendingPathComponent("eco.ts")
        let eco = try SrtTestSupport.launch(slt, ["-q", "srt://127.0.0.1:\(puerto)?mode=listener&passphrase=\(frase)",
                                                  "file://con"], stdout: salida, in: self)
        let p = publisher(ProgramSrtTarget(host: "127.0.0.1", port: puerto, user: "maestro", pass: "clave",
                                           passphrase: frase), latencyMs: 120)
        let programa = try SyntheticProgram(publisher: p)
        p.start()
        wait("conecta con el eco", timeout: 10) { p.snapshot.state == "publishing" }
        programa.start()
        Thread.sleep(forTimeInterval: 8)
        programa.stop()
        Thread.sleep(forTimeInterval: 1)
        let s = p.snapshot
        p.stop()
        eco.interrupt()
        eco.waitUntilExit()

        print("eco · \(s)")
        print("programa · \(programa.framesEncoded) fotogramas, pool sin búfer \(programa.poolFailures), tic máx \(programa.tickMsMax) ms, fallos \(programa.video.encodeFailures)")
        XCTAssertEqual(s.connects, 1)
        XCTAssertEqual(s.videoDropped, 0)
        XCTAssertEqual(s.audioDropped, 0)
        XCTAssertEqual(s.partialSends, 0)
        XCTAssertGreaterThanOrEqual(s.videoFramesSent, 230)
        XCTAssertEqual(s.videoFramesSent, programa.framesEncoded)
        XCTAssertEqual(s.audioFramesSent, programa.aacFrames)
        XCTAssertEqual(try ProgramCheck.codecs(salida), ["h264", "aac"])
        let (fotogramas, rig) = try ProgramCheck.seiRigMs(salida, dir: dir)
        XCTAssertEqual(fotogramas, s.videoFramesSent)
        XCTAssertEqual(rig.count, fotogramas, "la SEI del rigMs en cada fotograma")
        XCTAssertEqual(zip(rig, rig.dropFirst()).filter { $0 >= $1 }.count, 0, "rigMs siempre creciente")
        let sei = try ProgramCheck.ffprobeSeiFrames(salida)
        XCTAssertEqual(sei.withSei, sei.frames, "ffprobe -show_frames ve la SEI en todos")
    }

    /// MediaMTX con la config del VPS reducida: SRT en 0.0.0.0 (IPv4, lo que necesitan los
    /// iPhone por la Wi-Fi), RTSP solo en 127.0.0.1 y por TCP, y lectura sin clave desde el
    /// propio Mac (el `any` del VPS).
    private func mediamtxConfig(srt: UInt16, rtsp: UInt16, destino: ProgramSrtTarget) -> String {
        """
        logLevel: info
        srt: yes
        srtAddress: 0.0.0.0:\(srt)
        rtsp: yes
        rtspAddress: 127.0.0.1:\(rtsp)
        rtspTransports: [tcp]
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
          - user: any
            pass:
            ips: [127.0.0.0/8]
            permissions: [{action: read, path: \(ProgramSrt.path)}]
        paths:
          \(ProgramSrt.path):
            source: publisher
            overridePublisher: yes
            srtPublishPassphrase: \(destino.passphrase)
        """
    }

    func testPublicaElProgramaEnMediaMtx() throws {
        let segundos = Double(env["RIG_PUBLISH_S"] ?? "") ?? 90
        let dir = try SrtTestSupport.tempDir(self)
        var mediamtx: (path: String, config: URL)?
        var rtspPuerto: UInt16 = 0
        let destino: ProgramSrtTarget
        if let host = env["RIG_SRT_HOST"] {
            destino = ProgramSrtTarget(host: host, port: UInt16(env["RIG_SRT_PORT"] ?? "") ?? 8890,
                                       user: env["RIG_SRT_USER"] ?? "", pass: env["RIG_SRT_PASS"] ?? "",
                                       passphrase: env["RIG_SRT_PASSPHRASE"] ?? "")
        } else {
            guard env["RIG_SRT_MEDIAMTX"] == "1" else {
                throw XCTSkip("prueba larga: RIG_SRT_MEDIAMTX=1 (Mac) o RIG_SRT_HOST… (VPS)")
            }
            guard let bin = SrtTestSupport.tool("mediamtx") else { throw XCTSkip("sin mediamtx (brew install mediamtx)") }
            let srt = SrtTestSupport.freeUdpPort()
            rtspPuerto = Self.freeTcpPort()
            destino = ProgramSrtTarget(host: "127.0.0.1", port: srt, user: "maestro", pass: "clave-del-maestro",
                                       passphrase: "frase-de-paso-del-banco")
            let config = dir.appendingPathComponent("mediamtx.yml")
            try mediamtxConfig(srt: srt, rtsp: rtspPuerto, destino: destino).write(to: config, atomically: true, encoding: .utf8)
            mediamtx = (bin, config)
        }
        var servidor = try mediamtx.map {
            try SrtTestSupport.launch($0.path, [$0.config.path], stdout: dir.appendingPathComponent("mediamtx-1.log"), in: self)
        }

        let p = publisher(destino)
        let programa = try SyntheticProgram(publisher: p)
        p.start()
        programa.start()
        let inicio = Date()
        func transcurrido() -> Double { Date().timeIntervalSince(inicio) }
        var informe = 0
        var reiniciado = false
        var lectura: (ffmpeg: Process, ts: URL, sonda: Process?, json: URL)?
        while transcurrido() < segundos {
            Thread.sleep(forTimeInterval: 0.25)
            if Int(transcurrido()) / 10 > informe {
                informe = Int(transcurrido()) / 10
                print(String(format: "%3.0f s · %@", transcurrido(), "\(p.snapshot)"))
            }
            // A un tercio, MediaMTX se cae 2 s y vuelve: el publicador reconecta solo.
            if let m = mediamtx, !reiniciado, transcurrido() >= segundos / 3 {
                reiniciado = true
                servidor?.terminate()
                servidor?.waitUntilExit()
                Thread.sleep(forTimeInterval: 2)
                servidor = try SrtTestSupport.launch(m.path, [m.config.path],
                                                     stdout: dir.appendingPathComponent("mediamtx-2.log"), in: self)
            }
            // Los últimos 25 s (o menos), leídos de vuelta por RTSP.
            if mediamtx != nil, lectura == nil, transcurrido() >= segundos - 25 {
                lectura = try leer(rtsp: "rtsp://127.0.0.1:\(rtspPuerto)/\(ProgramSrt.path)", segundos: 20, dir: dir)
            }
        }
        programa.stop()
        Thread.sleep(forTimeInterval: 0.5)
        p.stop()
        let s = p.snapshot
        print("final · \(s)")
        XCTAssertEqual(s.state, "stopped")
        XCTAssertEqual(s.partialSends, 0)
        XCTAssertEqual(s.videoFramesSent + s.videoDropped + s.videoDroppedWhileDown, programa.framesEncoded, accuracy: 3)
        if mediamtx == nil {
            // El VPS: ninguna reconexión sin causa. Lo demás (congestión, bitrate, RTT) se
            // mira en lo impreso.
            XCTAssertEqual(s.reconnects, 0, "reconexiones sin causa")
        } else {
            XCTAssertEqual(s.reconnects, 1, "una reconexión por el reinicio")
            XCTAssertEqual(s.bitrateBps, SyntheticProgram.bitrateBps, "tras el corte, al bitrate de antes")
            // Fuera de los segundos del reinicio no hay nada que tirar.
            XCTAssertGreaterThan(Double(s.videoFramesSent), (segundos - 10) * SyntheticProgram.fps)
        }

        guard let l = lectura else { return }
        l.ffmpeg.waitUntilExit()
        l.sonda?.waitUntilExit()
        XCTAssertEqual(try ProgramCheck.codecs(l.ts), ["h264", "aac"])
        let (fotogramas, rig) = try ProgramCheck.seiRigMs(l.ts, dir: dir)
        XCTAssertGreaterThan(fotogramas, 500)
        XCTAssertEqual(rig.count, fotogramas, "la SEI del rigMs en cada fotograma, tras MediaMTX")
        let sei = try ProgramCheck.ffprobeSeiFrames(l.ts)
        print("RTSP · \(fotogramas) fotogramas, SEI en \(rig.count); ffprobe -show_frames: \(sei.withSei) de \(sei.frames)")
        XCTAssertEqual(sei.withSei, sei.frames)
        if l.sonda != nil {
            let datos = try Data(contentsOf: l.json)
            let m20 = try XCTUnwrap(try JSONSerialization.jsonObject(with: datos) as? [String: Any])
            print("sei_probe · \(String(decoding: datos, as: UTF8.self))")
            XCTAssertEqual(m20["sei_ok"] as? Bool, true)
            XCTAssertEqual(m20["rig_ms_backwards"] as? Int, 0)
        }
    }

    /// ffmpeg graba `segundos` del RTSP con `-c copy`; a la vez, si football-ai está al lado,
    /// su sonda de SEI lee el mismo RTSP.
    private func leer(rtsp: String, segundos: Int, dir: URL) throws -> (Process, URL, Process?, URL) {
        let ffmpeg = try XCTUnwrap(SrtTestSupport.tool("ffmpeg"))
        let ts = dir.appendingPathComponent("rtsp.ts")
        let grabar = try SrtTestSupport.launch(ffmpeg, ["-v", "error", "-rtsp_transport", "tcp", "-i", rtsp, "-t", "\(segundos)",
                                                        "-c", "copy", "-f", "mpegts", ts.path],
                                               stdout: dir.appendingPathComponent("ffmpeg.log"), in: self)
        let json = dir.appendingPathComponent("m20.json")
        var sonda: Process?
        let raiz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..")
            .standardizedFileURL
        let fai = URL(fileURLWithPath: env["FOOTBALL_AI_DIR"] ?? raiz.appendingPathComponent("fooball_ai_streaming").path)
        if let uv = SrtTestSupport.tool("uv"), FileManager.default.fileExists(atPath: fai.appendingPathComponent("tools/nube/sei_probe.py").path) {
            let s = Process()
            s.executableURL = URL(fileURLWithPath: uv)
            s.currentDirectoryURL = fai
            s.arguments = ["run", "--no-sync", "python", "tools/nube/sei_probe.py", "--source", rtsp,
                           "--seconds", "\(segundos)", "--out", json.path]
            s.standardOutput = FileHandle.nullDevice
            s.standardError = FileHandle.nullDevice
            try s.run()
            addTeardownBlock { if s.isRunning { s.terminate() } }
            sonda = s
        } else {
            print("sin football-ai al lado (FOOTBALL_AI_DIR) o sin uv: la sonda de SEI no corre")
        }
        return (grabar, ts, sonda, json)
    }

    private static func freeTcpPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(fd, $0, len)
                _ = getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }
}
