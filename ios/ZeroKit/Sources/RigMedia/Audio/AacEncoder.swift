// El codificador AAC del programa (IOS-54).
//
// PCM de 48 kHz (Float32 o Int16, intercalado o no) → AVAudioConverter → AAC-LC a
// 128 kbit/s → tramas con su cabecera ADTS en una BoundedQueue con descarte de lo viejo.
// Cada trama son 1024 muestras (21,33 ms a 48 kHz) y lleva su rigMs: el de la primera
// muestra que entró más las muestras ya codificadas, en el reloj del vídeo. Así el
// desfase A/V se mide contra el mismo reloj y un hueco del micro se nota como un salto.

import AVFoundation
import Foundation
import RigCore

public enum AudioConstants {
    /// Frecuencia del programa, en Hz (la del micro del iPhone y la del relé).
    public static let sampleRate = 48_000
    /// AAC-LC a 128 kbit/s: estéreo del estadio con margen, un 2 % del programa.
    public static let aacBitrateBps = 128_000
    /// Muestras por trama AAC-LC.
    public static let samplesPerFrame = 1024
    /// Tramas que espera la cola de salida (~1,4 s): más es latencia, no audio.
    public static let encodedQueueSlots = 64
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

    public let channels: Int
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private var queue = BoundedQueue<AacFrame>(capacity: AudioConstants.encodedQueueSlots, policy: .dropOldest)
    private let lock = NSLock()
    /// rigMs de la primera muestra de la sesión y muestras ya codificadas.
    private var originMs: Double?
    private var encodedSamples = 0
    /// Lo que entró y aún no se ha convertido (el convertidor pide de 1024 en 1024).
    private var pending: [AVAudioPCMBuffer] = []
    public private(set) var framesOut = 0

    /// `input`: el formato del micro (AVCaptureAudioDataOutput da Int16 o Float32).
    public init(input: AVAudioFormat, bitrateBps: Int = AudioConstants.aacBitrateBps) throws {
        guard input.sampleRate == Double(AudioConstants.sampleRate) else { throw EncoderError.format }
        channels = Int(input.channelCount)
        var desc = AudioStreamBasicDescription(
            mSampleRate: input.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioConstants.samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: input.channelCount, mBitsPerChannel: 0, mReserved: 0
        )
        guard let out = AVAudioFormat(streamDescription: &desc) else { throw EncoderError.format }
        guard let conv = AVAudioConverter(from: input, to: out) else { throw EncoderError.converter }
        // Tasa constante: el relé y el TS esperan un caudal estable, no un AAC que baje
        // a la mitad en un silencio y suba de golpe con el gol.
        conv.bitRateStrategy = AVAudioBitRateStrategy_Constant
        conv.bitRate = bitrateBps
        self.input = input
        output = out
        converter = conv
    }

    /// Mete PCM cuyo primer frame es del instante `rigMs`. Codifica todo lo que pueda.
    public func append(_ buffer: AVAudioPCMBuffer, rigMs: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        if originMs == nil { originMs = rigMs }
        pending.append(buffer)
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
            let ms = (originMs ?? 0) + Double(encodedSamples) * 1000 / Double(AudioConstants.sampleRate)
            encodedSamples += AudioConstants.samplesPerFrame
            framesOut += 1
            queue.push(AacFrame(adts: cabecera + crudo, rigMs: ms))
        }
    }
}
