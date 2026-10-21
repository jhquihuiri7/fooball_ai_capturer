// El codificador AAC del programa (IOS-54).
//
// PCM del micro (Int16 o Float32, intercalado o no, mono o estéreo, a 48 kHz o pasado a
// 48 kHz) → Float32 estéreo → AVAudioConverter → AAC-LC a 128 kbit/s → tramas con su cabecera ADTS en una
// BoundedQueue con descarte de lo viejo. Es el formato del contrato del programa
// (football-ai/tools/program_contract.py): el relé lo copia sin recodificar (ADR 0011).
//
// Cada trama son 1024 muestras (21,33 ms) y lleva el rigMs de su primera muestra según
// AudioTimeline, que sigue el sello del micro y no solo la cuenta de muestras: el reloj
// del micro se separa ~45 ppm del del soporte. Al rigMs se le resta el cebado del
// codificador (2112 muestras, 44 ms): el AAC sale con ellas delante y un decodificador de
// TS (ffmpeg) no las quita, así que sin restarlas el audio sonaba 44 ms tarde.

import AVFoundation
import Foundation
import RigCore

public enum AudioConstants {
    /// Frecuencia del programa, en Hz: `PROGRAM_AUDIO_RATE_HZ` de
    /// football-ai/tools/program_contract.py, escrito a mano (ningún generador lo exporta).
    public static let sampleRate = 48_000
    /// Canales del AAC del programa: `PROGRAM_AUDIO_CHANNELS`, estéreo. El micro del
    /// iPhone es mono y va igual a los dos canales.
    public static let programChannels = 2
    /// AAC-LC a 128 kbit/s: `PROGRAM_AUDIO_BITRATE_BPS`, un 2 % del programa.
    public static let aacBitrateBps = 128_000
    /// Muestras por trama AAC-LC.
    public static let samplesPerFrame = 1024
    /// Tramas que espera la cola de salida (~1,4 s): más es latencia, no audio.
    public static let encodedQueueSlots = 64
    /// Sin búfer del micro durante este tiempo, en ms, el vigilante de AudioCapture
    /// rellena con silencio hasta «ahora» menos esto: el AAC del programa no se corta
    /// ni sin permiso, ni con el micro tomado por una llamada. Holgado sobre lo que tarda
    /// un búfer del micro en llegar (una trama más la latencia de la entrada).
    public static let micStallMs = 200.0
    /// Cada cuánto mira el vigilante, en ms.
    public static let silenceTickMs = 100
    /// Muestras por búfer de silencio: el relleno va en trozos, no en uno de un segundo.
    static let silenceChunk = 4096
    /// Muestras de holgura del búfer de salida al pasar otra frecuencia a 48 kHz: lo que el
    /// convertidor puede entregar de más en una llamada sobre la cuenta exacta.
    static let resampleSlackFrames: AVAudioFrameCount = 64
}

/// Lo que suena en el programa en lugar del micro (ADR 0027: el sonido de un vídeo).
/// El codificador le pide cada trozo de su eje ya corregido: `count` muestras en su
/// formato canónico (Float32 sin intercalar, 48 kHz, sus canales) cuya primera es del
/// instante `rigMs`. nil es «aquí suena el micro». Se llama con el cerrojo del
/// codificador tomado: tiene que contestar ya, con lo que tenga preparado.
public protocol ProgramAudioSubstitute: AnyObject {
    func samples(count: Int, atRigMs rigMs: Double, format: AVAudioFormat) -> AVAudioPCMBuffer?
}

/// Una trama AAC lista para el mux: ADTS + AAC crudo, y su instante.
public struct AacFrame: Sendable {
    public let adts: Data
    public let rigMs: Double
}

public final class AacEncoder {
    public enum EncoderError: Error, Equatable {
        case format
        case converter
        case encode(String)
    }

    /// Lo que el eje ha corregido desde el principio, para el informe del banco.
    public struct SyncStats: Equatable, Sendable {
        public let silenceSamples: Int
        public let droppedSamples: Int
        public let nudges: Int
        public let reanchors: Int
        /// La frecuencia del último búfer del micro (0, ninguno) y las veces que ha cambiado.
        public let inputRateHz: Double
        public let inputRateChanges: Int
    }

    public let channels: Int
    /// Muestras de cebado del codificador (2112 en el AAC de Apple).
    public let primingSamples: Int
    /// Todo entra al AAC en este formato: Float32 sin intercalar, 48 kHz, `channels`.
    private let canonical: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    /// Pasa el PCM del micro al canónico; se rehace si el formato de entrada cambia.
    private var normalizer: AVAudioConverter?
    private var inputRateHz: Double = 0
    private var inputRateChanges = 0
    private var timeline = AudioTimeline(sampleRate: AudioConstants.sampleRate)
    private var queue = BoundedQueue<AacFrame>(capacity: AudioConstants.encodedQueueSlots, policy: .dropOldest)
    private let lock = NSLock()
    /// Lo que entró y aún no se ha convertido (el convertidor pide de 1024 en 1024).
    private var pending: [AVAudioPCMBuffer] = []
    public private(set) var framesOut = 0
    /// Cada trozo de PCM según entra al eje, ya corregido (silencio, recortes, muestra a
    /// muestra), en el formato canónico y con el rigMs de su primera muestra: seguidos,
    /// sin huecos ni solapes. Es la pista de audio de la 4K (IOS-57): AVAssetWriter escribe
    /// las muestras seguidas sin mirar su PTS, así que con el PCM del micro tal cual la
    /// deriva se acumulaba (medido en el Mac: a 300 ppm, 51 ms a los 3 min). Se llama con
    /// el cerrojo tomado: rápido, y sin volver al codificador.
    public var onAligned: ((AVAudioPCMBuffer, Double) -> Void)?
    private weak var substitute: ProgramAudioSubstitute?

    /// Lo que suena en el programa en lugar del micro, o nil para el micro. Solo cambia el
    /// AAC: `onAligned` (la pista de la 4K) sigue con lo que oyó el micro.
    public func setSubstitute(_ s: ProgramAudioSubstitute?) {
        lock.lock()
        defer { lock.unlock() }
        substitute = s
    }

    public init(channels: Int = AudioConstants.programChannels, bitrateBps: Int = AudioConstants.aacBitrateBps) throws {
        guard let canon = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(channels), interleaved: false
        ) else { throw EncoderError.format }
        var desc = AudioStreamBasicDescription(
            mSampleRate: Double(AudioConstants.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioConstants.samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        guard let out = AVAudioFormat(streamDescription: &desc) else { throw EncoderError.format }
        guard let conv = AVAudioConverter(from: canon, to: out) else { throw EncoderError.converter }
        // Tasa constante: el relé y el TS esperan un caudal estable, no un AAC que baje
        // a la mitad en un silencio y suba de golpe con el gol.
        conv.bitRateStrategy = AVAudioBitRateStrategy_Constant
        conv.bitRate = bitrateBps
        self.channels = channels
        primingSamples = Int(conv.primeInfo.leadingFrames)
        canonical = canon
        output = out
        converter = conv
    }

    /// Mete PCM cuyo primer frame es del instante `rigMs` y codifica todo lo que pueda. Si
    /// el sello no cae donde el eje espera, AudioTimeline dice si se rellena, se recorta o
    /// se reancla. Otra frecuencia que no sea 48 kHz se convierte (Bug C).
    public func append(_ buffer: AVAudioPCMBuffer, rigMs: Double) throws {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let pcm = try normalized(buffer)
        let n = Int(pcm.frameLength)
        // El convertidor de frecuencia puede guardarse todo un búfer corto la primera vez.
        guard n > 0 else { return }
        switch timeline.place(rigMs: rigMs, frames: n) {
        case .asIs, .reanchored:
            feed(pcm)
        case .repeatFirst:
            feed(slice(pcm, from: 0, count: 1))
            feed(pcm)
        case .dropFirst:
            feed(slice(pcm, from: 1, count: n - 1))
        case let .silenceBefore(muestras):
            feedSilence(muestras)
            feed(pcm)
        case let .dropLeading(muestras):
            feed(slice(pcm, from: muestras, count: n - muestras))
        }
        try drain()
    }

    /// El vigilante: silencio hasta `rigMs` si el eje se ha quedado atrás (el micro calla).
    /// Sin audio todavía, fija ahí el principio del eje.
    public func appendSilence(untilRigMs rigMs: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        let muestras = timeline.silence(until: rigMs)
        guard muestras > 0 else { return }
        feedSilence(muestras)
        try drain()
    }

    /// La trama más vieja que espera, o nil.
    public func pop() -> AacFrame? {
        lock.lock()
        defer { lock.unlock() }
        return queue.pop()
    }

    /// La configuración del AAC (el ESDS, «magic cookie») y su formato, para escribirlo en
    /// un contenedor sin recodificar (ProgramRecorder, IOS-57).
    public var formatDescription: CMAudioFormatDescription? {
        var asbd = output.streamDescription.pointee
        let cookie = converter.magicCookie
        var desc: CMAudioFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                    magicCookieSize: cookie.count, magicCookie: raw.baseAddress, extensions: nil,
                    formatDescriptionOut: &desc
                )
            }
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &desc
            )
        }
        return status == noErr ? desc : nil
    }

    public var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.dropped
    }

    public var syncStats: SyncStats {
        lock.lock(); defer { lock.unlock() }
        return SyncStats(
            silenceSamples: timeline.silenceSamples, droppedSamples: timeline.droppedSamples,
            nudges: timeline.nudges, reanchors: timeline.reanchors,
            inputRateHz: inputRateHz, inputRateChanges: inputRateChanges
        )
    }

    // MARK: - Por dentro (con el cerrojo tomado)

    /// El búfer en el formato canónico. El mono va igual a los dos canales: es lo que hace
    /// AVAudioConverter por defecto (channelMap [0, 0]).
    ///
    /// Otra frecuencia se pasa a 48 kHz (Bug C, 2026-10-21). Antes se rechazaba con
    /// `.format`: si la entrada cambiaba de frecuencia (un micro Bluetooth va a 16 o 24 kHz),
    /// cada búfer fallaba y el vigilante llenaba el programa de ceros mientras durara.
    private func normalized(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let tasa = buffer.format.sampleRate
        if tasa != inputRateHz {
            if inputRateHz > 0 { inputRateChanges += 1 }
            inputRateHz = tasa
        }
        if buffer.format == canonical { return buffer }
        if normalizer?.inputFormat != buffer.format {
            let nuevo = AVAudioConverter(from: buffer.format, to: canonical)
            // Sin cebado: lo que sale cuenta desde la primera muestra, como el sello.
            nuevo?.primeMethod = .none
            normalizer = nuevo
        }
        guard let normalizer else { throw EncoderError.converter }
        if tasa == canonical.sampleRate {
            guard let salida = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: buffer.frameLength) else {
                throw EncoderError.format
            }
            do {
                try normalizer.convert(to: salida, from: buffer)
            } catch {
                throw EncoderError.encode(error.localizedDescription)
            }
            return salida
        }
        // Con cambio de frecuencia `convert(to:from:)` no sirve: hace falta el de bloque, que
        // guarda el estado del filtro entre búferes.
        let exactas = (Double(buffer.frameLength) * canonical.sampleRate / tasa).rounded(.up)
        guard let salida = AVAudioPCMBuffer(
            pcmFormat: canonical, frameCapacity: AVAudioFrameCount(exactas) + AudioConstants.resampleSlackFrames
        ) else { throw EncoderError.format }
        var entregado = false
        var error: NSError?
        let estado = normalizer.convert(to: salida, error: &error) { _, estadoEntrada in
            guard !entregado else {
                estadoEntrada.pointee = .noDataNow
                return nil
            }
            entregado = true
            estadoEntrada.pointee = .haveData
            return buffer
        }
        if estado == .error { throw EncoderError.encode(error?.localizedDescription ?? "frecuencia") }
        return salida
    }

    /// `count` muestras de un búfer canónico desde `from`, o nil si no queda ninguna.
    private func slice(_ pcm: AVAudioPCMBuffer, from inicio: Int, count: Int) -> AVAudioPCMBuffer? {
        guard count > 0 else { return nil }
        if inicio == 0, count == Int(pcm.frameLength) { return pcm }
        guard let trozo = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: AVAudioFrameCount(count)),
              let origen = pcm.floatChannelData, let destino = trozo.floatChannelData
        else { return nil }
        trozo.frameLength = AVAudioFrameCount(count)
        for c in 0..<channels {
            destino[c].update(from: origen[c] + inicio, count: count)
        }
        return trozo
    }

    private func feed(_ pcm: AVAudioPCMBuffer?) {
        guard let pcm, pcm.frameLength > 0 else { return }
        let ms = timeline.rigMs(ofSample: timeline.samples)
        if let onAligned, let ms { onAligned(pcm, ms) }
        // El trozo del eje es el mismo, venga del micro o del vídeo: el sustituto solo
        // cambia lo que suena, nunca cuántas muestras ni cuándo (ADR 0027).
        let n = Int(pcm.frameLength)
        if let ms, let otro = substitute?.samples(count: n, atRigMs: ms, format: canonical),
           otro.format == canonical, Int(otro.frameLength) == n {
            pending.append(otro)
        } else {
            pending.append(pcm)
        }
        timeline.advance(by: n)
    }

    private func feedSilence(_ muestras: Int) {
        var quedan = muestras
        while quedan > 0 {
            let n = min(quedan, AudioConstants.silenceChunk)
            guard let b = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: AVAudioFrameCount(n)),
                  let datos = b.floatChannelData
            else { return }
            b.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels {
                datos[c].update(repeating: 0, count: n)
            }
            feed(b)
            quedan -= n
        }
    }

    private func drain() throws {
        while true {
            let salida = AVAudioCompressedBuffer(
                format: output, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize
            )
            var error: NSError?
            let estado = converter.convert(to: salida, error: &error) { _, outStatus in
                guard !self.pending.isEmpty else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if let error { throw EncoderError.encode(error.localizedDescription) }
            guard estado == .haveData, salida.packetCount > 0 else { return }
            let bytes = Int(salida.byteLength)
            let crudo = Data(bytes: salida.data, count: bytes)
            let cabecera = try Adts.header(
                payloadLength: bytes, sampleRate: AudioConstants.sampleRate, channels: channels
            )
            // La primera muestra de esta trama en el eje: el cebado va delante de todo.
            let primera = framesOut * AudioConstants.samplesPerFrame - primingSamples
            let ms = timeline.rigMs(ofSample: primera) ?? 0
            timeline.prune(before: primera)
            framesOut += 1
            queue.push(AacFrame(adts: cabecera + crudo, rigMs: ms))
        }
    }
}
