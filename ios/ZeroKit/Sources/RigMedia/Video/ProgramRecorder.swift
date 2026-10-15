// La copia local del programa (IOS-57): el H.264 y el AAC tal cual salen hacia el VPS,
// en un .mov sin recodificar (AVAssetWriter en passthrough: outputSettings nil y la
// descripción de formato como pista). Así lo que queda en el móvil es exactamente lo
// emitido, y no cuesta ni GPU ni batería de más.
//
// 2026-10-14, antes de la primera cancha: en fragmentos de película
// (RecordingPolicy.movieFragmentIntervalS). Sin ellos, una app que muere a mitad del partido
// (batería, jetsam, disco lleno) dejaba un .mov sin índice que no abre nadie. Y nunca pisa
// un fichero que ya exista: el que llama elige otro nombre (el siguiente segmento).

import AVFoundation
import CoreMedia
import Foundation
import RigCore

public final class ProgramRecorder {
    public enum RecorderError: Error, Equatable {
        case cannotAdd(String)
        case sample(OSStatus)
        case notStarted
        /// Ya hay un fichero ahí: no se borra (era la copia de un tramo anterior).
        case exists
    }

    public let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let audioFormat: CMAudioFormatDescription?
    private var started = false
    private var originNs: Int64?
    private let lock = NSLock()
    public private(set) var videoFrames = 0
    public private(set) var audioFrames = 0
    public private(set) var dropped = 0

    /// `fragmentIntervalS`: cada cuánto se escribe un fragmento, en s; nil, sin fragmentos
    /// (solo las pruebas, para ver qué se perdía).
    public init(url: URL, videoFormat: CMFormatDescription, audioFormat: CMAudioFormatDescription?,
                fragmentIntervalS: Double? = RecordingPolicy.movieFragmentIntervalS) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RecorderError.exists }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let intervalo = fragmentIntervalS {
            writer.movieFragmentInterval = CMTime(seconds: intervalo, preferredTimescale: Self.timescale)
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError.cannotAdd("vídeo") }
        writer.add(video)
        if let audioFormat {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            a.expectsMediaDataInRealTime = true
            guard writer.canAdd(a) else { throw RecorderError.cannotAdd("audio") }
            writer.add(a)
            audio = a
        } else {
            audio = nil
        }
        self.audioFormat = audioFormat
        self.url = url
    }

    /// El escritor dejó de aceptar muestras (disco lleno, la app en segundo plano): lo
    /// escrito hasta el último fragmento se puede leer, y lo que siga va en otro fichero.
    public var failed: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer.status == .failed
    }

    /// Por qué falló, sin rutas: para el informe.
    public var failureDescription: String? {
        lock.lock(); defer { lock.unlock() }
        guard writer.status == .failed else { return nil }
        return (writer.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "?"
    }

    /// Un fotograma codificado del programa (AVCC con sus SPS/PPS en el formato).
    public func append(video frame: EncodedFrame) throws {
        lock.lock(); defer { lock.unlock() }
        guard let fd = frame.formatDescription else { return }
        let pts = try begin(at: frame.ptsNs)
        let sample = try Self.sample(frame.data, format: fd, ptsNs: pts, durationNs: nil, sync: frame.isKeyframe)
        if video.isReadyForMoreMediaData, video.append(sample) {
            videoFrames += 1
        } else {
            dropped += 1
        }
    }

    /// Una trama AAC (con su ADTS, que aquí se quita: el .mov la quiere cruda).
    public func append(audio frame: AacFrame) throws {
        lock.lock(); defer { lock.unlock() }
        guard let audio, let fmt = audioFormat, started else { return }
        let crudo = frame.adts.dropFirst(Adts.headerLength)
        let ptsNs = Int64(frame.rigMs * 1_000_000) - (originNs ?? 0)
        let durNs = Int64(AudioConstants.samplesPerFrame) * 1_000_000_000 / Int64(AudioConstants.sampleRate)
        let sample = try Self.sample(Data(crudo), format: fmt, ptsNs: ptsNs, durationNs: durNs, sync: true,
                                     audioPacket: true)
        if audio.isReadyForMoreMediaData, audio.append(sample) {
            audioFrames += 1
        } else {
            dropped += 1
        }
    }

    /// Cierra el fichero; `completion` cuando está escrito. Uno que falló ya no se cierra:
    /// queda lo de sus fragmentos.
    public func finish(completion: @escaping (Bool) -> Void) {
        lock.lock()
        guard started, writer.status == .writing else {
            // Sin empezar no hay fichero (y cancelar con el estado desconocido aborta).
            lock.unlock()
            completion(false)
            return
        }
        video.markAsFinished()
        audio?.markAsFinished()
        lock.unlock()
        writer.finishWriting { [writer] in completion(writer.status == .completed) }
    }

    /// El primer fotograma abre la sesión: los instantes del fichero cuentan desde él.
    private func begin(at ptsNs: Int64) throws -> Int64 {
        if !started {
            guard writer.startWriting() else { throw RecorderError.notStarted }
            writer.startSession(atSourceTime: .zero)
            originNs = ptsNs
            started = true
        }
        return ptsNs - (originNs ?? ptsNs)
    }

    /// La escala de los instantes del fragmento, en tics por segundo.
    private static let timescale: CMTimeScale = 600

    private static func sample(
        _ data: Data, format: CMFormatDescription, ptsNs: Int64, durationNs: Int64?, sync: Bool,
        audioPacket: Bool = false
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw RecorderError.sample(status) }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo(
            duration: durationNs.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? .invalid,
            presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var size = data.count
        var sample: CMSampleBuffer?
        if audioPacket {
            var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                      mDataByteSize: UInt32(data.count))
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                presentationTimeStamp: timing.presentationTimeStamp, packetDescriptions: &packet,
                sampleBufferOut: &sample
            )
        } else {
            status = CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample
            )
        }
        guard status == noErr, let sample else { throw RecorderError.sample(status) }
        if !sync, let adjuntos = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(adjuntos) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(adjuntos, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
