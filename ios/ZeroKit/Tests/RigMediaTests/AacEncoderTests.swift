import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// El AAC del programa (IOS-54) con un tono sintético: tramas ADTS seguidas, sin huecos,
/// con su instante, y que al decodificarlas vuelve el tono.
final class AacEncoderTests: XCTestCase {
    private let rate = Double(AudioConstants.sampleRate)

    /// `segundos` de un tono de `hz` en búferes de 10 ms, como los da el micro.
    private func tono(_ hz: Double, segundos: Double, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let porBufer = 480
        let total = Int(segundos * rate)
        return stride(from: 0, to: total, by: porBufer).map { inicio in
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(porBufer))!
            b.frameLength = AVAudioFrameCount(porBufer)
            for c in 0..<Int(format.channelCount) {
                for i in 0..<porBufer {
                    b.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * hz * Double(inicio + i) / rate))
                }
            }
            return b
        }
    }

    func testTramasSeguidasConSuInstanteYElTonoVuelve() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let enc = try AacEncoder(input: fmt)
        var tramas: [AacFrame] = []
        for (n, b) in tono(1000, segundos: 10, format: fmt).enumerated() {
            try enc.append(b, rigMs: 5000 + Double(n) * 10)
            while let f = enc.pop() { tramas.append(f) }
        }
        // 10 s son 468,75 tramas; el convertidor se guarda la última a medias.
        XCTAssertGreaterThanOrEqual(tramas.count, 466)
        XCTAssertEqual(enc.dropped, 0)
        for f in tramas {
            XCTAssertEqual(Array(f.adts.prefix(2)), [0xFF, 0xF1], "sincronía ADTS")
            let largo = (Int(f.adts[3] & 0x3) << 11) | (Int(f.adts[4]) << 3) | Int(f.adts[5] >> 5)
            XCTAssertEqual(largo, f.adts.count, "frame_length de la cabecera")
        }
        // Ningún hueco: cada trama, 1024 muestras después de la anterior.
        let paso = 1000.0 * Double(AudioConstants.samplesPerFrame) / rate
        for (a, b) in zip(tramas, tramas.dropFirst()) {
            XCTAssertEqual(b.rigMs - a.rigMs, paso, accuracy: 1e-9)
        }
        XCTAssertEqual(tramas[0].rigMs, 5000)
        // ~128 kbit/s.
        let bits = Double(tramas.reduce(0) { $0 + $1.adts.count - Adts.headerLength } * 8)
        XCTAssertEqual(bits / (Double(tramas.count) * paso / 1000), 128_000, accuracy: 20_000)

        // Decodificado, vuelve un 1 kHz con energía (y no silencio ni basura).
        let pcm = try decodifica(tramas, channels: 2)
        let energia = pcm.suffix(48_000).reduce(0) { $0 + Double($1 * $1) } / 48_000
        XCTAssertGreaterThan(energia, 0.05, "el tono vuelve")
        var cruces = 0
        let ultimo = Array(pcm.suffix(48_000))
        for (a, b) in zip(ultimo, ultimo.dropFirst()) where (a < 0) != (b < 0) { cruces += 1 }
        XCTAssertEqual(Double(cruces) / 2, 1000, accuracy: 20, "1 kHz: dos cruces por ciclo")
    }

    func testOtraFrecuenciaNoSeAcepta() throws {
        let f44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        XCTAssertThrowsError(try AacEncoder(input: f44))
    }

    /// AAC con ADTS → PCM Float (un canal), con el convertidor de Apple al revés.
    private func decodifica(_ tramas: [AacFrame], channels: Int) throws -> [Float] {
        var desc = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0
        )
        let aac = AVAudioFormat(streamDescription: &desc)!
        let pcmFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let conv = try XCTUnwrap(AVAudioConverter(from: aac, to: pcmFmt))
        var muestras: [Float] = []
        var i = 0
        while true {
            let salida = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: 4096)!
            var error: NSError?
            let estado = conv.convert(to: salida, error: &error) { _, st in
                guard i < tramas.count else { st.pointee = .endOfStream; return nil }
                let crudo = tramas[i].adts.dropFirst(Adts.headerLength)
                i += 1
                let b = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: crudo.count)
                crudo.withUnsafeBytes { b.data.copyMemory(from: $0.baseAddress!, byteCount: crudo.count) }
                b.byteLength = UInt32(crudo.count)
                b.packetCount = 1
                b.packetDescriptions![0] = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(crudo.count)
                )
                st.pointee = .haveData
                return b
            }
            if let error { throw error }
            muestras += UnsafeBufferPointer(start: salida.floatChannelData![0], count: Int(salida.frameLength))
            if estado == .endOfStream || estado == .error || salida.frameLength == 0 { break }
        }
        return muestras
    }
}
