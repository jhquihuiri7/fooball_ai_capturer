import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// La copia local del programa (IOS-57): H.264 y AAC de verdad en un .mov sin recodificar,
/// que AVFoundation vuelve a leer con sus dos pistas y su duración.
final class ProgramRecorderTests: XCTestCase {
    func testDosSegundosDeProgramaConAudioEnUnMov() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("programa-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // Vídeo: 60 fotogramas 320×180 a 30 fps.
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 0)
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        let px = try XCTUnwrap(b)
        var frames: [EncodedFrame] = []
        for i in 0..<60 {
            enc.encode(px, ptsNs: Int64(i) * 33_333_333, rigMs: UInt64(i * 33))
            while let f = enc.pop() { frames.append(f) }
        }
        enc.flush()
        while let f = enc.pop() { frames.append(f) }
        // Audio: 2 s de tono.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let aac = try AacEncoder(input: fmt)
        var tramas: [AacFrame] = []
        for n in 0..<200 {
            let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
            pcm.frameLength = 480
            for i in 0..<480 { pcm.floatChannelData![0][i] = Float(0.3 * sin(Double(n * 480 + i) * 0.13)) }
            try aac.append(pcm, rigMs: Double(n) * 10)
            while let t = aac.pop() { tramas.append(t) }
        }

        let rec = try ProgramRecorder(
            url: url, videoFormat: try XCTUnwrap(frames.first?.formatDescription),
            audioFormat: try XCTUnwrap(aac.formatDescription)
        )
        var a = 0
        for f in frames {
            try rec.append(video: f)
            while a < tramas.count, tramas[a].rigMs <= Double(f.rigMs) { try rec.append(audio: tramas[a]); a += 1 }
        }
        let hecho = expectation(description: "cerrado")
        nonisolated(unsafe) var ok = false
        rec.finish { ok = $0; hecho.fulfill() }
        await fulfillment(of: [hecho], timeout: 10)
        XCTAssertTrue(ok)
        XCTAssertEqual(rec.videoFrames, 60)
        XCTAssertGreaterThan(rec.audioFrames, 80)

        let asset = AVURLAsset(url: url)
        let pistas = try await asset.load(.tracks)
        XCTAssertEqual(Set(pistas.map(\.mediaType)), [.video, .audio])
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, 2.0, accuracy: 0.15)
    }
}
