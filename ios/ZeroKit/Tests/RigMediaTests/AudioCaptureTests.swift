import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// El micro y su vigilante (IOS-54): el AAC del programa no se corta aunque el micro
/// calle (sin permiso, o tomado por una llamada), y lo que vuelve cae en su instante.
final class AudioCaptureTests: XCTestCase {
    private let msPorMuestra = 1000 / AudioSignals.rate

    /// Un CMSampleBuffer como los del micro: Int16 mono con su PTS.
    private func muestra(_ pcm: AVAudioPCMBuffer, ms: Double) throws -> CMSampleBuffer {
        var asbd = pcm.format.streamDescription.pointee
        var fmt: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &fmt
        ), noErr)
        var tiempo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(AudioSignals.rate)),
            presentationTimeStamp: CMTime(seconds: ms / 1000, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt, sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &tiempo, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb
        ), noErr)
        let buffer = try XCTUnwrap(sb)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pcm.audioBufferList
        ), noErr)
        return buffer
    }

    /// 1 s de micro, 2 s callado (una llamada) con el vigilante cada 100 ms, y vuelve con
    /// un chasquido: el AAC no tiene huecos y el chasquido cae en su instante.
    func testElMicroSeCallaYElAacSigueConSilencio() throws {
        let captura = try AudioCapture { CMTimeGetSeconds($0) * 1000 }
        var tramas: [AacFrame] = []
        var pcmDelMicro = 0
        var buferesDelMicro = 0
        captura.onFrame = { tramas.append($0) }
        captura.onPcm = { _, _ in pcmDelMicro += 1 }
        captura.onSampleBuffer = { _ in buferesDelMicro += 1 }

        var senal = [Float](repeating: 0, count: Int(AudioSignals.rate) * 2)
        AudioSignals.chasquido(en: Int(AudioSignals.rate * 1.5), senal: &senal)
        let buferes = AudioSignals.microInt16(senal)
        let paso = 1024 * msPorMuestra
        let callado = 2000.0
        var ahora = 0.0
        var enviados = 0
        for (n, b) in buferes.enumerated() {
            // El contenido del segundo 1 en adelante llega después de la llamada.
            let ms = Double(n) * paso + (Double(n) * paso >= 1000 ? callado : 0)
            while ahora + 100 < ms {  // el vigilante corre mientras el micro calla
                ahora += 100
                captura.keepAlive(nowRigMs: ahora)
            }
            captura.receive(try muestra(b, ms: ms))
            enviados += 1
            ahora = ms + paso  // el búfer llega cuando acaba
            captura.keepAlive(nowRigMs: ahora)
        }
        XCTAssertEqual(captura.failures, 0)
        XCTAssertEqual(captura.buffersIn, enviados)
        XCTAssertEqual(pcmDelMicro, enviados, "el DSP solo recibe lo que oyó el micro")
        XCTAssertEqual(buferesDelMicro, enviados)
        XCTAssertEqual(captura.gaps, 1, "un hueco del micro")
        XCTAssertGreaterThan(captura.silenceTicks, 10, "el vigilante rellenó la llamada")
        XCTAssertEqual(captura.syncStats.reanchors, 0)
        let pasoTrama = 1000.0 * Double(AudioConstants.samplesPerFrame) / AudioSignals.rate
        for (a, b) in zip(tramas, tramas.dropFirst()) {
            XCTAssertEqual(b.rigMs - a.rigMs, pasoTrama, accuracy: 1e-9, "sin hueco en el AAC")
        }
        let pcm = try AudioSignals.decodifica(tramas)[0]
        let llega = try XCTUnwrap(AudioSignals.inicio(pcm))
        XCTAssertEqual(tramas[0].rigMs + Double(llega) * msPorMuestra, 1500 + callado, accuracy: 0.2)
    }

    func testElPcmPasaACMSampleBufferYVuelveIgual() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: AudioSignals.rate, channels: 2)!
        let pcm = AudioSignals.tono(440, segundos: 0.01, format: fmt)[0]
        let muestra = try XCTUnwrap(AudioCapture.sampleBuffer(pcm, ptsNs: 1_234_567_890))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(muestra).value, 1_234_567_890)
        XCTAssertEqual(CMSampleBufferGetNumSamples(muestra), 480)
        let vuelta = try XCTUnwrap(AudioCapture.pcm(of: muestra))
        XCTAssertEqual(vuelta.format, fmt)
        for c in 0..<2 {
            for i in 0..<480 { XCTAssertEqual(vuelta.floatChannelData![c][i], pcm.floatChannelData![c][i]) }
        }
    }

    /// La pista de la 4K con el PCM alineado: AVAssetWriter escribe las muestras seguidas
    /// sin mirar su PTS, y aun así, con el micro derivando 300 ppm, el chasquido del minuto
    /// suena en su instante (con el PCM del micro tal cual llegaba 18 ms tarde).
    func testLaPistaDeLa4KNoDerivaConElPcmAlineado() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pista = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioConstants.sampleRate,
            AVNumberOfChannelsKey: AudioConstants.programChannels, AVEncoderBitRateKey: AudioConstants.aacBitrateBps,
        ])
        writer.add(pista)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: CMTime(value: 1_000_000_000_000, timescale: 1_000_000_000))  // 1000 s

        let captura = try AudioCapture { CMTimeGetSeconds($0) * 1000 }
        var trozos: [(AVAudioPCMBuffer, Double)] = []
        captura.onAlignedPcm = { trozos.append(($0, $1)) }
        let ppm = 300.0
        var senal = [Float](repeating: 0, count: 61 * Int(AudioSignals.rate))
        AudioSignals.chasquido(en: 60 * Int(AudioSignals.rate), senal: &senal)
        let host = { (i: Int) in 1_000_000 + Double(i) * self.msPorMuestra * (1 - ppm * 1e-6) }
        for (n, b) in AudioSignals.microInt16(senal).enumerated() {
            captura.receive(try muestra(b, ms: host(n * 1024)))
        }
        for (pcm, ms) in trozos {
            while !pista.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(pista.append(try XCTUnwrap(AudioCapture.sampleBuffer(pcm, ptsNs: Int64((ms * 1e6).rounded())))))
        }
        pista.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let asset = AVURLAsset(url: url)
        let lector = try AVAssetReader(asset: asset)
        let salida = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .audio)[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1,
        ])
        lector.add(salida)
        XCTAssertTrue(lector.startReading())
        var leidas: [Float] = []
        var t0: Double?
        while let sb = salida.copyNextSampleBuffer() {
            if t0 == nil { t0 = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) }
            let bloque = try XCTUnwrap(CMSampleBufferGetDataBuffer(sb))
            let n = CMBlockBufferGetDataLength(bloque) / MemoryLayout<Float>.size
            var trozo = [Float](repeating: 0, count: n)
            _ = trozo.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(bloque, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            leidas += trozo
        }
        let llega = try XCTUnwrap(AudioSignals.inicio(leidas))
        let enMs = (try XCTUnwrap(t0) + Double(llega) / AudioSignals.rate) * 1000
        // El fichero cuenta desde el principio de la sesión, que es el instante 1000 s.
        XCTAssertEqual(enMs, host(60 * Int(AudioSignals.rate)) - 1_000_000, accuracy: 2, "el chasquido del minuto")
    }

    /// Sin permiso de micro: el formato está desde el principio y el vigilante da un AAC
    /// de silencio que el relé puede copiar.
    func testSinMicroElVigilanteDaUnAacDeSilencio() throws {
        let captura = try AudioCapture { CMTimeGetSeconds($0) * 1000 }
        XCTAssertNotNil(captura.formatDescription)
        var tramas: [AacFrame] = []
        captura.onFrame = { tramas.append($0) }
        for t in stride(from: 10_000.0, through: 13_000, by: Double(AudioConstants.silenceTickMs)) {
            captura.keepAlive(nowRigMs: t)
        }
        XCTAssertGreaterThan(tramas.count, 130)
        XCTAssertEqual(captura.buffersIn, 0)
        // Va `micStallMs` por detrás de «ahora», con el cebado delante.
        XCTAssertEqual(tramas[0].rigMs, 10_000 - AudioConstants.micStallMs - 2112 * msPorMuestra, accuracy: 1e-9)
        XCTAssertEqual(AudioSignals.adtsChannels(tramas[0].adts), AudioConstants.programChannels)
    }
}
