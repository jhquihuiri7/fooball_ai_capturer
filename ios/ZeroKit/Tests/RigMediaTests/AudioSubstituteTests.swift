import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// El sonido de un vídeo del mando en lugar del micro (IOS-103, ADR 0027): el AAC del
/// programa lleva el del sustituto mientras contesta, por su eje y sin huecos, y la pista
/// de la 4K (`onAligned`) sigue con lo que oyó el micro.
final class AudioSubstituteTests: XCTestCase {
    private let rate = Double(AudioConstants.sampleRate)

    /// Un tono de 1 kHz entre `desdeMs` y `hastaMs`; fuera, nil (suena el micro).
    private final class Tono: ProgramAudioSubstitute {
        let desdeMs: Double
        let hastaMs: Double
        var pedidos: [(count: Int, rigMs: Double)] = []
        init(desdeMs: Double, hastaMs: Double) {
            self.desdeMs = desdeMs
            self.hastaMs = hastaMs
        }

        func samples(count: Int, atRigMs rigMs: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
            pedidos.append((count, rigMs))
            guard rigMs >= desdeMs, rigMs < hastaMs,
                  let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else { return nil }
            b.frameLength = AVAudioFrameCount(count)
            let rate = format.sampleRate
            for c in 0..<Int(format.channelCount) {
                for i in 0..<count {
                    let t = rigMs / 1000 + Double(i) / rate
                    b.floatChannelData![c][i] = Float(0.5 * sin(2 * .pi * 1000 * t))
                }
            }
            return b
        }
    }

    func testElProgramaSuenaAlSustitutoYLa4KAlMicro() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let enc = try AacEncoder()
        let tono = Tono(desdeMs: 6000, hastaMs: 7000)
        enc.setSubstitute(tono)
        var alineado: [Float] = []
        enc.onAligned = { pcm, _ in
            alineado += UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
        }
        var tramas: [AacFrame] = []
        // 3 s del micro en silencio, en búferes de 10 ms, desde el instante 5000.
        for n in 0..<300 {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
            b.frameLength = 480
            for c in 0..<2 { b.floatChannelData![c].update(repeating: 0, count: 480) }
            try enc.append(b, rigMs: 5000 + Double(n) * 10)
            while let f = enc.pop() { tramas.append(f) }
        }

        XCTAssertEqual(AudioSignals.energia(alineado), 0, "la 4K lleva el micro, no el vídeo")
        // El eje pide seguido: cada trozo empieza donde acabó el anterior.
        for (a, b) in zip(tono.pedidos, tono.pedidos.dropFirst()) {
            XCTAssertEqual(b.rigMs, a.rigMs + Double(a.count) * 1000 / rate, accuracy: 1e-6)
        }
        XCTAssertEqual(tono.pedidos.first?.rigMs ?? 0, 5000, accuracy: 1e-9)

        let pcm = try AudioSignals.decodifica(tramas)[0]
        let cero = try XCTUnwrap(tramas.first).rigMs
        func trozo(_ desde: Double, _ hasta: Double) -> [Float] {
            let a = Int((desde - cero) * rate / 1000), b = Int((hasta - cero) * rate / 1000)
            return Array(pcm[a..<b])
        }
        XCTAssertGreaterThan(AudioSignals.energia(trozo(6100, 6900)), 0.08, "el tono del vídeo")
        XCTAssertEqual(AudioSignals.ciclos(trozo(6100, 6900)), 800, accuracy: 4, "a 1 kHz")
        XCTAssertLessThan(AudioSignals.energia(trozo(5200, 5900)), 1e-4, "antes, el micro")
        XCTAssertLessThan(AudioSignals.energia(trozo(7100, 7800)), 1e-4, "después, el micro otra vez")

        enc.setSubstitute(nil)
        let antes = tono.pedidos.count
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        b.frameLength = 480
        try enc.append(b, rigMs: 8000)
        XCTAssertEqual(tono.pedidos.count, antes, "sin sustituto no se le pregunta")
    }
}
