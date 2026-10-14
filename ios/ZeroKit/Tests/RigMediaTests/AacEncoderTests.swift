import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// El AAC del programa (IOS-54) con señales sintéticas: tramas ADTS estéreo seguidas, sin
/// huecos, con su instante ya descontado el cebado, y que al decodificarlas cada sonido
/// cae en su instante aunque el reloj del micro derive o el micro se corte.
final class AacEncoderTests: XCTestCase {
    private let rate = Double(AudioConstants.sampleRate)
    private var msPorMuestra: Double { 1000 / rate }

    func testTramasSeguidasConSuInstanteYElTonoVuelve() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let enc = try AacEncoder()
        var tramas: [AacFrame] = []
        for (n, b) in AudioSignals.tono(1000, segundos: 10, format: fmt).enumerated() {
            try enc.append(b, rigMs: 5000 + Double(n) * 10)
            while let f = enc.pop() { tramas.append(f) }
        }
        // 10 s más el cebado son 470,8 tramas; el convertidor se guarda la última a medias.
        XCTAssertGreaterThanOrEqual(tramas.count, 468)
        XCTAssertEqual(enc.dropped, 0)
        XCTAssertEqual(enc.primingSamples, 2112, "el cebado del AAC de Apple")
        for f in tramas {
            XCTAssertEqual(Array(f.adts.prefix(2)), [0xFF, 0xF1], "sincronía ADTS")
            let largo = (Int(f.adts[3] & 0x3) << 11) | (Int(f.adts[4]) << 3) | Int(f.adts[5] >> 5)
            XCTAssertEqual(largo, f.adts.count, "frame_length de la cabecera")
            XCTAssertEqual(AudioSignals.adtsChannels(f.adts), AudioConstants.programChannels, "estéreo")
        }
        // Ningún hueco: cada trama, 1024 muestras después de la anterior.
        let paso = 1000.0 * Double(AudioConstants.samplesPerFrame) / rate
        for (a, b) in zip(tramas, tramas.dropFirst()) {
            XCTAssertEqual(b.rigMs - a.rigMs, paso, accuracy: 1e-9)
        }
        // La primera trama empieza 2112 muestras antes de la primera muestra: su cebado.
        XCTAssertEqual(tramas[0].rigMs, 5000 - 2112 * msPorMuestra, accuracy: 1e-9)
        // ~128 kbit/s.
        let bits = Double(tramas.reduce(0) { $0 + $1.adts.count - Adts.headerLength } * 8)
        XCTAssertEqual(bits / (Double(tramas.count) * paso / 1000), 128_000, accuracy: 20_000)

        // Decodificado, vuelve un 1 kHz con energía (y no silencio ni basura).
        let pcm = try AudioSignals.decodifica(tramas)[0]
        let ultimo = Array(pcm.suffix(48_000))
        XCTAssertGreaterThan(AudioSignals.energia(ultimo), 0.05, "el tono vuelve")
        XCTAssertEqual(AudioSignals.ciclos(ultimo), 1000, accuracy: 20, "1 kHz")
    }

    /// El micro del iPhone da Int16 mono intercalado: sale AAC estéreo, igual en los dos.
    func testElMicroMonoInt16SaleEstereoIgualEnLosDosCanales() throws {
        let enc = try AacEncoder()
        var tramas: [AacFrame] = []
        let senal = (0..<Int(rate) * 3).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / rate)) }
        for (n, b) in AudioSignals.microInt16(senal).enumerated() {
            try enc.append(b, rigMs: Double(n) * 1024 * msPorMuestra)
            while let f = enc.pop() { tramas.append(f) }
        }
        XCTAssertEqual(AudioSignals.adtsChannels(tramas[0].adts), 2)
        let canales = try AudioSignals.decodifica(tramas)
        XCTAssertEqual(canales.count, 2)
        let izq = Array(canales[0].suffix(48_000)), der = Array(canales[1].suffix(48_000))
        XCTAssertGreaterThan(AudioSignals.energia(izq), 0.05)
        XCTAssertEqual(AudioSignals.energia(izq), AudioSignals.energia(der), accuracy: 1e-4)
        XCTAssertEqual(AudioSignals.ciclos(der), 440, accuracy: 10)
    }

    /// Un chasquido en un instante conocido vuelve en ese instante. Sin descontar el cebado
    /// sonaba 44 ms tarde (igual con ffmpeg: medido el 2026-10-14).
    func testUnChasquidoVuelveEnSuInstante() throws {
        let enc = try AacEncoder()
        var senal = [Float](repeating: 0, count: Int(rate) * 3)
        AudioSignals.chasquido(en: 48_000, senal: &senal)
        var tramas: [AacFrame] = []
        for (n, b) in AudioSignals.microInt16(senal).enumerated() {
            try enc.append(b, rigMs: 1000 + Double(n) * 1024 * msPorMuestra)
            while let f = enc.pop() { tramas.append(f) }
        }
        let pcm = try AudioSignals.decodifica(tramas)[0]
        let llega = try XCTUnwrap(AudioSignals.inicio(pcm))
        XCTAssertEqual(tramas[0].rigMs + Double(llega) * msPorMuestra, 2000, accuracy: 0.2)
    }

    /// El reloj del micro se adelanta al del soporte (aquí 150 ppm, tres veces lo medido):
    /// contando muestras, a los 3 min el audio iría 27 ms tarde. Con el eje, en su sitio.
    func testLaDerivaDelMicroNoDescuadraElAudio() throws {
        let enc = try AacEncoder()
        let ppm = 150.0
        let minutos = 3
        var senal = [Float](repeating: 0, count: minutos * 60 * Int(rate))
        let chasquidos = [30, 90, 170].map { $0 * Int(rate) }
        for c in chasquidos { AudioSignals.chasquido(en: c, senal: &senal) }
        // Instante (en el soporte) de la muestra `i` del micro.
        let host = { (i: Int) in 1000 + Double(i) * self.msPorMuestra * (1 - ppm * 1e-6) }
        var tramas: [AacFrame] = []
        for (n, b) in AudioSignals.microInt16(senal).enumerated() {
            try enc.append(b, rigMs: host(n * 1024))
            while let f = enc.pop() { tramas.append(f) }
        }
        XCTAssertEqual(enc.dropped, 0)
        XCTAssertGreaterThan(enc.syncStats.nudges, 1000)
        XCTAssertEqual(enc.syncStats.reanchors, 0)
        let pcm = try AudioSignals.decodifica(tramas)[0]
        for c in chasquidos {
            let desde = Int((host(c) - 50 - tramas[0].rigMs) / msPorMuestra)
            let llega = try XCTUnwrap(AudioSignals.inicio(pcm, desde: desde))
            let error = tramas[0].rigMs + Double(llega) * msPorMuestra - host(c)
            XCTAssertEqual(error, 0, accuracy: AudioSync.toleranceMs + 0.3, "chasquido a los \(c / 48_000) s")
        }
    }

    /// El micro calla 500 ms (se perdieron búferes): el AAC sigue sin hueco y lo que viene
    /// después cae en su instante.
    func testUnHuecoDelMicroSeRellenaYLoQueSigueCaeEnSuSitio() throws {
        let enc = try AacEncoder()
        var senal = [Float](repeating: 0, count: Int(rate) * 4)
        AudioSignals.chasquido(en: 3 * Int(rate), senal: &senal)
        let buferes = AudioSignals.microInt16(senal)
        let hueco = 500.0
        var tramas: [AacFrame] = []
        for (n, b) in buferes.enumerated() {
            var ms = Double(n) * 1024 * msPorMuestra
            if ms >= 2000 { ms += hueco } else if ms >= 1500 { continue }  // 1,5-2 s no llegan
            try enc.append(b, rigMs: ms)
            while let f = enc.pop() { tramas.append(f) }
        }
        let paso = 1000.0 * Double(AudioConstants.samplesPerFrame) / rate
        for (a, b) in zip(tramas, tramas.dropFirst()) {
            XCTAssertEqual(b.rigMs - a.rigMs, paso, accuracy: 1e-9, "sin hueco en el AAC")
        }
        XCTAssertEqual(Double(enc.syncStats.silenceSamples), (hueco + 500) * rate / 1000, accuracy: 1024)
        let pcm = try AudioSignals.decodifica(tramas)[0]
        let llega = try XCTUnwrap(AudioSignals.inicio(pcm))
        XCTAssertEqual(tramas[0].rigMs + Double(llega) * msPorMuestra, 3000 + hueco, accuracy: 0.2)
    }

    /// El PCM alineado (la pista de la 4K): trozos seguidos, sin huecos ni solapes, y cada
    /// sonido en su instante aunque el micro derive y se corte.
    func testElPcmAlineadoVaSeguidoYEnSuInstante() throws {
        let enc = try AacEncoder()
        var trozos: [(pcm: AVAudioPCMBuffer, ms: Double)] = []
        enc.onAligned = { trozos.append(($0, $1)) }
        let ppm = 150.0
        var senal = [Float](repeating: 0, count: 60 * Int(rate))
        AudioSignals.chasquido(en: 50 * Int(rate), senal: &senal)
        let host = { (i: Int) in 1000 + Double(i) * self.msPorMuestra * (1 - ppm * 1e-6) }
        for (n, b) in AudioSignals.microInt16(senal).enumerated() where !(800..<820).contains(n) {
            try enc.append(b, rigMs: host(n * 1024) + (n >= 820 ? 300 : 0))  // un corte de 300 ms
            while enc.pop() != nil {}
        }
        for (a, b) in zip(trozos, trozos.dropFirst()) {
            XCTAssertEqual(b.ms - a.ms, Double(a.pcm.frameLength) * msPorMuestra, accuracy: 1e-6, "seguidos")
            XCTAssertEqual(b.pcm.format, a.pcm.format)
        }
        let todo = trozos.flatMap { UnsafeBufferPointer(start: $0.pcm.floatChannelData![1], count: Int($0.pcm.frameLength)) }
        let llega = try XCTUnwrap(AudioSignals.inicio(todo))
        let esperado = host(50 * Int(rate)) + 300
        XCTAssertEqual(trozos[0].ms + Double(llega) * msPorMuestra, esperado, accuracy: AudioSync.toleranceMs + 0.1)
    }

    /// Sin micro, el vigilante solo: un AAC de silencio con su instante, sin huecos.
    func testSoloSilencioDelVigilante() throws {
        let enc = try AacEncoder()
        var tramas: [AacFrame] = []
        for t in stride(from: 1000.0, through: 3000, by: 100) {
            try enc.appendSilence(untilRigMs: t)
            while let f = enc.pop() { tramas.append(f) }
        }
        XCTAssertGreaterThanOrEqual(Double(tramas.count), 2000 / 21.34 - 1)
        XCTAssertEqual(tramas[0].rigMs, 1000 - 2112 * msPorMuestra, accuracy: 1e-9)
        let pcm = try AudioSignals.decodifica(tramas)[0]
        XCTAssertLessThan(AudioSignals.energia(pcm), 1e-8)
        XCTAssertEqual(enc.syncStats.silenceSamples, 2000 * 48)
    }

    func testOtraFrecuenciaNoSeAcepta() throws {
        let f44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: f44, frameCapacity: 441)!
        b.frameLength = 441
        XCTAssertThrowsError(try AacEncoder().append(b, rigMs: 0)) {
            XCTAssertEqual($0 as? AacEncoder.EncoderError, .format)
        }
    }

    /// Las cifras del contrato del programa (football-ai/tools/program_contract.py):
    /// escritas a mano, así que si cambian allí este test lo recuerda aquí.
    func testElFormatoEsElDelContratoDelPrograma() {
        XCTAssertEqual(AudioConstants.sampleRate, 48_000)  // PROGRAM_AUDIO_RATE_HZ
        XCTAssertEqual(AudioConstants.programChannels, 2)  // PROGRAM_AUDIO_CHANNELS
        XCTAssertEqual(AudioConstants.aacBitrateBps, 128_000)  // PROGRAM_AUDIO_BITRATE_BPS
    }
}

/// Señales de prueba y su vuelta, compartidas con AudioCaptureTests.
enum AudioSignals {
    static let rate = Double(AudioConstants.sampleRate)

    /// `segundos` de un tono de `hz` en búferes de 10 ms (Float32).
    static func tono(_ hz: Double, segundos: Double, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
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

    /// El formato del micro del iPhone: Int16 mono intercalado, 48 kHz.
    static let microFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true
    )!

    /// La señal en búferes de 1024 muestras con el formato del micro.
    static func microInt16(_ senal: [Float], porBufer: Int = 1024) -> [AVAudioPCMBuffer] {
        stride(from: 0, to: senal.count, by: porBufer).map { inicio in
            let n = min(porBufer, senal.count - inicio)
            let b = AVAudioPCMBuffer(pcmFormat: microFormat, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { b.int16ChannelData![0][i] = Int16(senal[inicio + i] * 32_000) }
            return b
        }
    }

    /// Un chasquido de 1 ms (4 kHz) que empieza en la muestra `en`.
    static func chasquido(en: Int, senal: inout [Float]) {
        for i in 0..<48 { senal[en + i] = Float(0.9 * sin(2 * .pi * 4000 * Double(i) / rate)) }
    }

    /// La primera muestra por encima de 0,05 desde `desde`.
    static func inicio(_ pcm: [Float], desde: Int = 0) -> Int? {
        pcm[max(0, desde)...].firstIndex { abs($0) > 0.05 }
    }

    static func energia(_ x: [Float]) -> Double {
        x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))
    }

    /// Ciclos en la señal (dos cruces por cero por ciclo): en un segundo, los Hz.
    static func ciclos(_ x: [Float]) -> Double {
        var cruces = 0
        for (a, b) in zip(x, x.dropFirst()) where (a < 0) != (b < 0) { cruces += 1 }
        return Double(cruces) / 2
    }

    /// El channel_configuration de una cabecera ADTS.
    static func adtsChannels(_ adts: Data) -> Int {
        (Int(adts[2] & 0x1) << 2) | Int(adts[3] >> 6)
    }

    /// AAC con ADTS → PCM Float por canal, con el convertidor de Apple al revés. Como
    /// ffmpeg, no quita el cebado: la muestra 0 es la primera de la primera trama.
    static func decodifica(_ tramas: [AacFrame]) throws -> [[Float]] {
        let channels = adtsChannels(tramas[0].adts)
        var desc = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0
        )
        let aac = AVAudioFormat(streamDescription: &desc)!
        let pcmFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let conv = try XCTUnwrap(AVAudioConverter(from: aac, to: pcmFmt))
        var canales = [[Float]](repeating: [], count: channels)
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
            for c in 0..<channels {
                canales[c] += UnsafeBufferPointer(start: salida.floatChannelData![c], count: Int(salida.frameLength))
            }
            if estado == .endOfStream || estado == .error || salida.frameLength == 0 { break }
        }
        return canales
    }
}
