import AVFoundation
import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// El vídeo del mando en el programa (IOS-103, ADR 0027): cada instante del programa toma
/// el fotograma que toca, a 1080p con bandas; el sonido sale por el eje del AAC; y al
/// acabar el hub lo quita y avisa una vez. Los MP4 se escriben aquí mismo.
final class ProgramVideoPlayerTests: XCTestCase {
    private let ancho = 1920
    private let alto = 1080
    private let cero = 10_000.0
    private let canonico = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioConstants.sampleRate), channels: 2, interleaved: false
    )!

    /// 2 s de 640×480 a 30 fps: el primer segundo gris oscuro y el segundo claro, y un tono
    /// de 1 kHz si `conAudio`. `giro` es la transformación de la pista (vertical: 90°).
    private func mp4(conAudio: Bool = true, giro: CGAffineTransform = .identity) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480,
        ])
        video.transform = giro
        let adaptador = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        var audio: AVAssetWriterInput?
        if conAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioConstants.sampleRate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: AudioConstants.aacBitrateBps,
            ])
            writer.add(a)
            audio = a
        }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let oscuro = try nv12(bgr: [UInt8](repeating: 40, count: 640 * 480 * 3), ancho: 640, alto: 480)
        let claro = try nv12(bgr: [UInt8](repeating: 210, count: 640 * 480 * 3), ancho: 640, alto: 480)
        let tonos = AudioSignals.tono(1000, segundos: 2, format: AVAudioFormat(
            standardFormatWithSampleRate: Double(AudioConstants.sampleRate), channels: 2
        )!)
        // En orden de tiempo, para que el escritor intercale sin esperar a la otra pista.
        var eventos: [(ms: Double, entrada: AVAssetWriterInput, accion: () -> Bool)] = []
        for i in 0..<60 {
            let ms = Double(i) * 1000 / 30
            eventos.append((ms, video, {
                adaptador.append(i < 30 ? oscuro : claro, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
            }))
        }
        if let audio {
            for (n, b) in tonos.enumerated() {
                let ms = Double(n) * 10
                eventos.append((ms, audio, {
                    guard let sb = AudioCapture.sampleBuffer(b, ptsNs: Int64(ms * 1_000_000)) else { return false }
                    return audio.append(sb)
                }))
            }
        }
        // Se espera solo a la entrada que recibe: esperar a las dos puede bloquear al
        // escritor, que retiene una mientras la otra no le da datos.
        for e in eventos.sorted(by: { $0.ms < $1.ms }) {
            var esperas = 0
            while !e.entrada.isReadyForMoreMediaData, esperas < 2000 {
                Thread.sleep(forTimeInterval: 0.001)
                esperas += 1
            }
            XCTAssertTrue(e.accion())
        }
        video.markAsFinished()
        audio?.markAsFinished()
        let fin = expectation(description: "mp4")
        writer.finishWriting { fin.fulfill() }
        wait(for: [fin], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// Espera a que el lector tenga preparado el vídeo hasta `ms` (o haya acabado).
    private func espera(_ p: ProgramVideoPlayer, videoMs: Double? = nil, audioMs: Double? = nil) {
        let limite = Date().addingTimeInterval(5)
        while Date() < limite {
            let b = p.buffered
            let videoListo = videoMs.map { ms in b.videoDone || (b.videoMs ?? -1) >= ms } ?? true
            let audioListo = audioMs.map { ms in b.audioDone || (b.audioMs ?? -1) >= ms } ?? true
            if videoListo && audioListo { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTFail("el lector no llegó a tiempo")
    }

    private func abre(_ url: URL, id: Int64 = 7) async throws -> ProgramVideoPlayer {
        try await ProgramVideoPlayer.open(url: url, id: id, startRigMs: cero, width: ancho, height: alto)
    }

    private func luma(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        return Int(base[y * CVPixelBufferGetBytesPerRowOfPlane(b, 0) + x])
    }

    func testCadaInstanteTomaSuFotogramaA1080pConBandas() async throws {
        let url = try mp4()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try await abre(url)
        p.start()
        defer { p.stop() }
        XCTAssertEqual(p.durationMs, 2000, accuracy: 40)
        XCTAssertNil(p.frame(atRigMs: cero - 1), "antes de su cero, el programa de siempre")

        var oscuros = 0, claros = 0
        for paso in 0..<59 {
            let m = Double(paso) * 1000 / 30
            espera(p, videoMs: m)
            let f = try XCTUnwrap(p.frame(atRigMs: cero + m))
            XCTAssertEqual(CVPixelBufferGetWidth(f), ancho)
            XCTAssertEqual(CVPixelBufferGetHeight(f), alto)
            let centro = luma(f, 960, 540)
            if m < 960 { XCTAssertEqual(centro, 50, accuracy: 12, "gris oscuro en \(m) ms"); oscuros += 1 }
            if m > 1040 { XCTAssertEqual(centro, 196, accuracy: 12, "gris claro en \(m) ms"); claros += 1 }
            // 4:3 en 16:9: 1440 de ancho, bandas negras de 240 a cada lado.
            XCTAssertLessThanOrEqual(luma(f, 100, 540), 20, "banda izquierda")
            XCTAssertLessThanOrEqual(luma(f, 1820, 540), 20, "banda derecha")
        }
        XCTAssertGreaterThan(oscuros, 25)
        XCTAssertGreaterThan(claros, 25)
        XCTAssertFalse(p.isFinished(atRigMs: cero + p.durationMs - 1))
        XCTAssertTrue(p.isFinished(atRigMs: cero + p.durationMs))
        XCTAssertNil(p.frame(atRigMs: cero + p.durationMs), "pasada su duración, vuelve el programa")
    }

    func testUnVideoEnVerticalSeEnderezaConBandasAnchas() async throws {
        let url = try mp4(conAudio: false, giro: CGAffineTransform(rotationAngle: .pi / 2))
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try await abre(url)
        p.start()
        defer { p.stop() }
        espera(p, videoMs: 100)
        let f = try XCTUnwrap(p.frame(atRigMs: cero + 100))
        // 480×640 de pie en 1920×1080: 810 de ancho en el centro, de 555 a 1365.
        XCTAssertLessThanOrEqual(luma(f, 400, 540), 20, "banda ancha")
        XCTAssertEqual(luma(f, 960, 540), 50, accuracy: 12)
    }

    func testSuSonidoSaleEnElEjeDelAac() async throws {
        let url = try mp4()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try await abre(url)
        p.start()
        defer { p.stop() }
        XCTAssertNil(p.samples(count: 1024, atRigMs: cero - 1000, format: canonico), "antes, el micro")

        espera(p, audioMs: 400)
        // Un trozo que empieza 10 ms antes del cero: la mitad de antes va en silencio.
        let cabalgando = try XCTUnwrap(p.samples(count: 960, atRigMs: cero - 10, format: canonico))
        let antes = Array(UnsafeBufferPointer(start: cabalgando.floatChannelData![0], count: 480))
        XCTAssertEqual(AudioSignals.energia(antes), 0)

        espera(p, audioMs: 800)
        let trozo = try XCTUnwrap(p.samples(count: 4800, atRigMs: cero + 200, format: canonico))
        XCTAssertEqual(Int(trozo.frameLength), 4800)
        for c in 0..<2 {
            let x = Array(UnsafeBufferPointer(start: trozo.floatChannelData![c], count: 4800))
            XCTAssertGreaterThan(AudioSignals.energia(x), 0.08, "el tono, canal \(c)")
            XCTAssertEqual(AudioSignals.ciclos(x), 100, accuracy: 3, "1 kHz en 100 ms")
        }
        XCTAssertNil(p.samples(count: 1024, atRigMs: cero + p.durationMs + 100, format: canonico), "después, el micro")
    }

    func testSinPistaDeAudioSuenaASilencioYNoAlMicro() async throws {
        let url = try mp4(conAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try await abre(url)
        p.start()
        defer { p.stop() }
        let trozo = try XCTUnwrap(p.samples(count: 1024, atRigMs: cero + 300, format: canonico))
        XCTAssertEqual(AudioSignals.energia(Array(UnsafeBufferPointer(start: trozo.floatChannelData![0], count: 1024))), 0)
        XCTAssertEqual(p.underruns, 0, "sin audio no es ir tarde")
    }

    func testElHubAvisaUnaVezAlAcabarYNoAlParar() async throws {
        let url = try mp4(conAudio: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let hub = ProgramVideoHub()
        var avisos: [Int64] = []
        hub.onEnded = { avisos.append($0) }
        XCTAssertNil(hub.frame(atRigMs: cero), "sin vídeo, nada")

        let p = try await abre(url, id: 3)
        hub.play(p)
        XCTAssertEqual(hub.playingId, 3)
        espera(p, videoMs: 500)
        XCTAssertNotNil(hub.frame(atRigMs: cero + 500))
        XCTAssertNil(hub.frame(atRigMs: cero + p.durationMs + 1))
        XCTAssertNil(hub.frame(atRigMs: cero + p.durationMs + 40))
        XCTAssertEqual(avisos, [3])
        XCTAssertNil(hub.playingId)
        XCTAssertNil(hub.samples(count: 1024, atRigMs: cero + 100, format: canonico))

        let q = try await abre(url, id: 4)
        hub.play(q)
        hub.stop()
        XCTAssertNil(hub.frame(atRigMs: cero + 100))
        XCTAssertEqual(avisos, [3], "parar no avisa: quien lo pidió ya lo sabe")
    }

    func testLoQueNoEsUnVideoNoAbre() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("falso-\(UUID().uuidString).mp4")
        try Data("no soy un vídeo".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await abre(url)
            XCTFail("abrió algo que no es un vídeo")
        } catch {}
    }
}
