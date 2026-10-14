import AVFoundation
import CoreVideo
import Foundation
import XCTest

import RigCore
import RigMedia
import RigNet

/// Un programa sintético como el del maestro (IOS-56): 1080p30 del VideoEncoder de verdad,
/// con la SEI del rigMs, a 6 Mbit/s, y AAC estéreo 48 kHz del AacEncoder, entregados al
/// publicador en tiempo real. El rigMs es el reloj monótono del Mac (mach_absolute_time,
/// el mismo que el `time.monotonic` de Python): así la sonda de SEI del VPS
/// (`tools/nube/sei_probe.py`) mide la latencia de verdad del codificador a su lectura.
final class SyntheticProgram {
    static let width = 1920
    static let height = 1080
    static let fps = 30.0
    static let bitrateBps = 6_000_000
    /// Hz del tono del AAC.
    static let toneHz = 440.0
    /// Muestras por entrega de PCM: 20 ms a 48 kHz, como un búfer del micro.
    static let pcmChunk = 960
    /// La franja de ruido es 1/n del alto: con un tercio y ruido entero, el codificador no
    /// cabía en 6 Mbit/s ni con el QP en su tope y tiraba tres de cada cuatro fotogramas.
    static let noiseFraction = 8

    let video: VideoEncoder
    let aac: AacEncoder
    private let publisher: ProgramPublisher
    private let pool: CVPixelBufferPool
    /// Ruido de luma para que el codificador tenga trabajo: una franja del cuadro cambia en
    /// cada fotograma (sin ella, un degradado cabe en unos cientos de kbit/s).
    private let noise: [UInt8]
    private let queue = DispatchQueue(label: "synthetic-program", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var samples = 0
    private var startMs = 0.0
    private(set) var framesEncoded = 0
    private(set) var aacFrames = 0

    static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    init(publisher: ProgramPublisher) throws {
        self.publisher = publisher
        video = try VideoEncoder(width: Self.width, height: Self.height, bitrateBps: Self.bitrateBps, viewId: 0)
        aac = try AacEncoder()
        pool = try XCTUnwrap(video.pixelBufferPool, "el codificador no expone su pool")
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        noise = (0..<(4 << 20)).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return 64 + UInt8(truncatingIfNeeded: x) & 0x3F
        }
        let v = video
        publisher.onIdrRequest = { v.forceIDR() }
        publisher.onBitrate = { try? v.setBitrate(bps: $0) }
    }

    func start() {
        queue.async { [self] in
            startMs = Self.nowMs()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: 1 / Self.fps, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            video.flush()
            drain()
        }
    }

    private(set) var poolFailures = 0
    private(set) var tickMsMax = 0.0

    private func tick() {
        let ahora = Self.nowMs()
        defer { tickMsMax = max(tickMsMax, Self.nowMs() - ahora) }
        if let buffer = makeFrame(frame) {
            video.encode(buffer, ptsNs: Int64(ahora * 1e6), rigMs: UInt64(ahora))
            frame += 1
        } else {
            poolFailures += 1
        }
        // El PCM hasta ahora, en trozos de 20 ms, en el eje de muestras desde el arranque.
        let hasta = Int((ahora - startMs) / 1000 * Double(AudioConstants.sampleRate))
        while samples + Self.pcmChunk <= hasta {
            let ms = startMs + Double(samples) * 1000 / Double(AudioConstants.sampleRate)
            if let pcm = tone(from: samples) { try? aac.append(pcm, rigMs: ms) }
            samples += Self.pcmChunk
        }
        drain()
    }

    private func drain() {
        while let f = video.pop() {
            var avcc = f.data
            if f.isKeyframe, let fd = f.formatDescription { avcc = H264ParameterSets.avccNals(from: fd) + avcc }
            publisher.video(avcc: avcc, isKeyframe: f.isKeyframe, rigMs: Double(f.rigMs))
            framesEncoded += 1
        }
        while let t = aac.pop() {
            publisher.audio(aacRaw: Data(t.adts.dropFirst(Adts.headerLength)), rigMs: t.rigMs)
            aacFrames += 1
        }
    }

    private func makeFrame(_ i: Int) -> CVPixelBuffer? {
        var creado: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &creado)
        guard let buffer = creado else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var fila = [UInt8](repeating: 0, count: Self.width)
        for x in 0..<Self.width { fila[x] = UInt8(64 + (x / 16 + i) % 128) }
        let ruido = Self.height / Self.noiseFraction
        noise.withUnsafeBytes { n in
            for f in 0..<Self.height {
                if f < ruido {
                    let desde = (i * 7919 + f * Self.width) % (noise.count - Self.width)
                    (y + f * stride).copyMemory(from: n.baseAddress! + desde, byteCount: Self.width)
                } else {
                    fila.withUnsafeBytes { (y + f * stride).copyMemory(from: $0.baseAddress!, byteCount: Self.width) }
                }
            }
        }
        memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        return buffer
    }

    private func tone(from sample: Int) -> AVAudioPCMBuffer? {
        guard let formato = AVAudioFormat(standardFormatWithSampleRate: Double(AudioConstants.sampleRate),
                                          channels: AVAudioChannelCount(AudioConstants.programChannels)),
              let pcm = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: AVAudioFrameCount(Self.pcmChunk))
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(Self.pcmChunk)
        for c in 0..<Int(formato.channelCount) {
            let canal = pcm.floatChannelData![c]
            for k in 0..<Self.pcmChunk {
                canal[k] = Float(0.3 * sin(2 * .pi * Self.toneHz * Double(sample + k) / Double(AudioConstants.sampleRate)))
            }
        }
        return pcm
    }
}

/// Lo que se comprueba del TS que sale: códecs, y la SEI del rigMs en cada fotograma.
enum ProgramCheck {
    /// Corre una herramienta y devuelve su salida estándar.
    @discardableResult
    static func run(_ tool: String, _ args: [String], stderr: URL? = nil) throws -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = try stderr.map { FileManager.default.createFile(atPath: $0.path, contents: nil)
            return try FileHandle(forWritingTo: $0) } ?? FileHandle.nullDevice
        try p.run()
        let salida = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: salida, as: UTF8.self)
    }

    static func codecs(_ file: URL) throws -> Set<String> {
        let ffprobe = try XCTUnwrap(SrtTestSupport.tool("ffprobe"), "sin ffprobe")
        let salida = try run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", file.path])
        return Set(salida.split(separator: "\n").map(String.init))
    }

    /// (fotogramas, rigMs de la SEI de cada uno) del vídeo de `file`: el H.264 se saca en
    /// Anexo B con ffmpeg y se cuenta un fotograma por AUD (el TsMuxer pone uno en cada uno;
    /// MediaMTX y ffmpeg también).
    static func seiRigMs(_ file: URL, dir: URL) throws -> (frames: Int, rigMs: [UInt64]) {
        let ffmpeg = try XCTUnwrap(SrtTestSupport.tool("ffmpeg"), "sin ffmpeg")
        let es = dir.appendingPathComponent(UUID().uuidString + ".h264")
        try run(ffmpeg, ["-v", "error", "-y", "-i", file.path, "-map", "0:v", "-c", "copy", "-bsf:v", "h264_mp4toannexb",
                         "-f", "h264", es.path])
        let avcc = NalUnits.avcc(fromAnnexB: try Data(contentsOf: es))
        var frames = 0
        var rig: [UInt64] = []
        NalUnits.forEachNal(inAvcc: avcc) { nal in
            guard let h = nal.first else { return }
            if h & 0x1F == 9 { frames += 1 }
            if let s = H264Sei.parse(nal: nal) { rig.append(s.rigMs) }
        }
        return (frames, rig)
    }

    /// Fotogramas que ffprobe -show_frames ve con la SEI user_data_unregistered.
    static func ffprobeSeiFrames(_ file: URL) throws -> (frames: Int, withSei: Int) {
        let ffprobe = try XCTUnwrap(SrtTestSupport.tool("ffprobe"), "sin ffprobe")
        let salida = try run(ffprobe, ["-v", "error", "-select_streams", "v", "-show_frames",
                                       "-show_entries", "frame=pts:frame_side_data=side_data_type", "-of", "json", file.path])
        let json = try JSONSerialization.jsonObject(with: Data(salida.utf8)) as? [String: Any]
        let lista = json?["frames"] as? [[String: Any]] ?? []
        let con = lista.filter { f in
            (f["side_data_list"] as? [[String: Any]] ?? []).contains {
                ($0["side_data_type"] as? String ?? "").contains("User Data Unregistered")
            }
        }
        return (lista.count, con.count)
    }
}
