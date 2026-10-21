import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// Bug C (2026-10-21): el micro muerto se rehace solo. El 16-oct el programa salió en ceros
/// exactos a tramos (con el micro quitado por otra app y, después, puesto pero mudo) y
/// solo lo arreglaba matar Zero.
final class MicWatchTests: XCTestCase {
    private typealias W = MicWatch

    func testQueLeOcurreAlMicro() {
        let sano = MicHealth(buffersIn: 100, withoutBuffersS: 0.02)
        XCTAssertNil(W.problem(attached: true, health: sano))
        XCTAssertEqual(W.problem(attached: false, health: sano), .removed)
        XCTAssertEqual(W.problem(attached: true, health: MicHealth(withoutBuffersS: 3.5)), .noBuffers(3.5))
        XCTAssertNil(W.problem(attached: true, health: MicHealth(withoutBuffersS: 2.5)), "un parón corto no")
        XCTAssertEqual(W.problem(attached: true, health: MicHealth(digitalSilenceS: 6)), .digitalSilence(6))
        XCTAssertNil(W.problem(attached: true, health: MicHealth(digitalSilenceS: 4)))
        XCTAssertEqual(W.problem(attached: true, health: MicHealth(failingS: 4)), .failing(4))
    }

    /// Muerto: se rehace ya, y si sigue muerto, a los 5, 15, 30 y 60 s, y 60 s después.
    func testLosIntentosSeEspacianYVuelvenACeroAlSonar() {
        var w = W()
        let muerto = MicHealth(withoutBuffersS: 10)
        var intentos: [Double] = []
        for decimas in 0...3000 {  // 300 s, cada 100 ms como el vigilante
            let t = Double(decimas) / 10
            if w.check(nowS: t, running: true, allowed: true, callActive: false, attached: true, health: muerto) != nil {
                intentos.append(t)
            }
        }
        XCTAssertEqual(intentos, [0, 5, 20, 50, 110, 170, 230, 290])
        // Vuelve a sonar: la cuenta se pone a cero y el siguiente corte se ataca enseguida.
        XCTAssertNil(w.check(nowS: 300, running: true, allowed: true, callActive: false, attached: true,
                             health: MicHealth(buffersIn: 1, withoutBuffersS: 0.02)))
        XCTAssertEqual(w.attempts, 0)
        XCTAssertNotNil(w.check(nowS: 301, running: true, allowed: true, callActive: false, attached: false,
                                health: MicHealth()))
    }

    /// Con una llamada en curso, la cámara parada o sin permiso, el micro no se toca.
    func testNiConLlamadaNiParadoNiSinPermiso() {
        var w = W()
        let muerto = MicHealth(withoutBuffersS: 10)
        XCTAssertNil(w.check(nowS: 0, running: true, allowed: true, callActive: true, attached: false, health: muerto))
        XCTAssertNil(w.check(nowS: 0, running: false, allowed: true, callActive: false, attached: false, health: muerto))
        XCTAssertNil(w.check(nowS: 0, running: true, allowed: false, callActive: false, attached: false, health: muerto))
        XCTAssertEqual(w.attempts, 0)
        XCTAssertEqual(w.check(nowS: 1, running: true, allowed: true, callActive: false, attached: false, health: muerto),
                       .removed)
    }

    /// La salud que mide AudioCapture: búferes, ceros exactos y el reloj que vuelve a contar
    /// al poner el micro.
    func testAudioCaptureMideBuferesYCerosExactos() throws {
        nonisolated(unsafe) var ahora: UInt64 = 1_000_000_000
        let captura = try AudioCapture(rigMsOf: { CMTimeGetSeconds($0) * 1000 }, nowNs: { ahora })
        let segundo: UInt64 = 1_000_000_000
        // Sin ningún búfer: cuenta desde que se creó.
        ahora += 4 * segundo
        XCTAssertEqual(captura.health().withoutBuffersS, 4, accuracy: 1e-9)
        captura.micAttached()
        XCTAssertEqual(captura.health().withoutBuffersS, 0, accuracy: 1e-9)

        // Llega señal: sano. Después, ceros exactos durante 6 s.
        let senal = (0..<1024).map { Float(0.3 * sin(Double($0) / 5)) }
        captura.receive(try muestra(AudioSignals.microInt16(senal)[0], ms: 0))
        XCTAssertNil(captura.health().digitalSilenceS)
        let ceros = [Float](repeating: 0, count: 1024)
        for n in 1...7 {
            ahora += segundo
            captura.receive(try muestra(AudioSignals.microInt16(ceros)[0], ms: Double(n) * 21.3))
        }
        let h = captura.health()
        XCTAssertEqual(h.buffersIn, 8)
        XCTAssertEqual(h.withoutBuffersS, 0, accuracy: 1e-9)
        XCTAssertEqual(h.digitalSilenceS ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(MicWatch.problem(attached: true, health: h), .digitalSilence(6))
        XCTAssertEqual(h.inputRateHz, 48_000)
        // Vuelve el ruido de fondo, por bajo que sea: sano.
        captura.receive(try muestra(AudioSignals.microInt16([Float](repeating: 0.0001, count: 1024))[0], ms: 200))
        XCTAssertNil(captura.health().digitalSilenceS)
    }

    func testCeroExactoEnTodosLosFormatos() {
        for comun in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32] {
            for intercalado in [true, false] {
                let fmt = AVAudioFormat(commonFormat: comun, sampleRate: 48_000, channels: 2, interleaved: intercalado)!
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 64)!
                b.frameLength = 64
                XCTAssertTrue(AudioCapture.isDigitalSilence(b), "\(comun.rawValue) \(intercalado)")
                // Una sola muestra distinta de cero, la última del último canal.
                let ultima = intercalado ? 127 : 63
                let plano = intercalado ? 0 : 1
                switch comun {
                case .pcmFormatFloat32: b.floatChannelData![plano][ultima] = 1e-6
                case .pcmFormatInt16: b.int16ChannelData![plano][ultima] = 1
                default: b.int32ChannelData![plano][ultima] = 1
                }
                XCTAssertFalse(AudioCapture.isDigitalSilence(b), "\(comun.rawValue) \(intercalado)")
            }
        }
    }

    /// Un CMSampleBuffer como los del micro, con su PTS.
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
}
