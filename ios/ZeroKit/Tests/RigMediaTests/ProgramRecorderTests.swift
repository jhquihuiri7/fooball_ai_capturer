import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// La copia local del programa (IOS-57): H.264 y AAC de verdad en un .mov sin recodificar,
/// que AVFoundation vuelve a leer con sus dos pistas y su duración.
final class ProgramRecorderTests: XCTestCase {
    func testDosSegundosDeProgramaConAudioEnUnMov() async throws {
        try await dosSegundosConAudio(fragmentIntervalS: RecordingPolicy.movieFragmentIntervalS)
    }

    /// Lo mismo cruzando cuatro fragmentos: el vídeo y el AAC en passthrough siguen enteros.
    func testDosSegundosDeProgramaConAudioEnFragmentosDeMedioSegundo() async throws {
        try await dosSegundosConAudio(fragmentIntervalS: 0.5)
    }

    private func dosSegundosConAudio(fragmentIntervalS: Double) async throws {
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
        let aac = try AacEncoder()
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
            audioFormat: try XCTUnwrap(aac.formatDescription), fragmentIntervalS: fragmentIntervalS
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

    // MARK: - 2026-10-14: la app que muere a mitad del partido

    /// `segundos` de programa a 30 fps (320×180), ya codificado.
    private func programa(segundos: Int) throws -> [EncodedFrame] {
        let enc = try VideoEncoder(width: 320, height: 180, bitrateBps: 1_000_000, viewId: 0)
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        let px = try XCTUnwrap(b)
        var frames: [EncodedFrame] = []
        for i in 0..<(segundos * 30) {
            enc.encode(px, ptsNs: Int64(i) * 33_333_333, rigMs: UInt64(i * 33))
            while let f = enc.pop() { frames.append(f) }
        }
        enc.flush()
        while let f = enc.pop() { frames.append(f) }
        return frames
    }

    /// La copia del fichero tal como está en el disco ahora, como lo dejaría una app que
    /// muere: lo que dura si se puede abrir, o nil.
    private func duracionDeUnaCopia(de url: URL) async -> Double? {
        let copia = url.deletingLastPathComponent().appendingPathComponent("copia-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: copia) }
        guard (try? FileManager.default.copyItem(at: url, to: copia)) != nil else { return nil }
        let asset = AVURLAsset(url: copia)
        guard let pistas = try? await asset.load(.tracks), pistas.contains(where: { $0.mediaType == .video }),
              let dur = try? await asset.load(.duration).seconds, dur.isFinite, dur > 0
        else { return nil }
        return dur
    }

    /// Lo que espera la prueba a que el escritor (asíncrono, en tiempo real) baje al disco.
    private static let esperaDiscoS = 10.0
    private static let sondeoNs: UInt64 = 200_000_000

    func testUnMovCortadoAMitadSeLeeHastaElUltimoFragmento() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("programa-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try programa(segundos: 4)
        let rec = try ProgramRecorder(url: url, videoFormat: try XCTUnwrap(frames.first?.formatDescription),
                                      audioFormat: nil, fragmentIntervalS: 1)
        for f in frames { try rec.append(video: f) }
        // Sin cerrar: lo que hay en el disco es lo que quedaría si la app muriera ahora.
        var leida: Double?
        let limite = Date().addingTimeInterval(Self.esperaDiscoS)
        while Date() < limite {
            if let d = await duracionDeUnaCopia(de: url), d >= 2 { leida = d; break }
            try await Task.sleep(nanoseconds: Self.sondeoNs)
        }
        let dur = try XCTUnwrap(leida, "el .mov a medio escribir no se abre: sin fragmentos se pierde entero")
        XCTAssertLessThanOrEqual(dur, 4.1)
        XCTAssertFalse(rec.failed)

        // Y cerrado como siempre, entero.
        let hecho = expectation(description: "cerrado")
        nonisolated(unsafe) var ok = false
        rec.finish { ok = $0; hecho.fulfill() }
        await fulfillment(of: [hecho], timeout: 10)
        XCTAssertTrue(ok)
        let final = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(final, 4.0, accuracy: 0.15)
    }

    /// Lo que pasaba antes: sin fragmentos, el mismo .mov a medio escribir no se abre.
    func testSinFragmentosElMovAMedioEscribirNoSeAbre() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("programa-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try programa(segundos: 4)
        let rec = try ProgramRecorder(url: url, videoFormat: try XCTUnwrap(frames.first?.formatDescription),
                                      audioFormat: nil, fragmentIntervalS: nil)
        for f in frames { try rec.append(video: f) }
        try await Task.sleep(nanoseconds: UInt64(Self.esperaDiscoS / 5 * 1e9))
        let dur = await duracionDeUnaCopia(de: url)
        XCTAssertNil(dur)
        let hecho = expectation(description: "cerrado")
        rec.finish { _ in hecho.fulfill() }
        await fulfillment(of: [hecho], timeout: 10)
    }

    func testNoPisaUnFicheroQueYaExiste() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("programa-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let viejo = Data("el tramo anterior".utf8)
        try viejo.write(to: url)
        let frames = try programa(segundos: 1)
        XCTAssertThrowsError(try ProgramRecorder(url: url, videoFormat: try XCTUnwrap(frames.first?.formatDescription),
                                                 audioFormat: nil)) { error in
            XCTAssertEqual(error as? ProgramRecorder.RecorderError, .exists)
        }
        XCTAssertEqual(try Data(contentsOf: url), viejo)
    }

    func testCerrarSinNingunFotogramaNoAbortaNiDejaFichero() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("programa-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try programa(segundos: 1)
        let rec = try ProgramRecorder(url: url, videoFormat: try XCTUnwrap(frames.first?.formatDescription),
                                      audioFormat: nil)
        let hecho = expectation(description: "cerrado")
        nonisolated(unsafe) var ok = true
        rec.finish { ok = $0; hecho.fulfill() }
        await fulfillment(of: [hecho], timeout: 5)
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
