// La copia local del programa (IOS-57): el H.264 y el AAC tal cual salen hacia el VPS,
// en un .mov sin recodificar (AVAssetWriter en passthrough: outputSettings nil y la
// descripción de formato como pista). Así lo que queda en el móvil es exactamente lo
// emitido, y no cuesta ni GPU ni batería de más.

import AVFoundation
import CoreMedia
import Foundation
import RigCore

public final class ProgramRecorder {
    public enum RecorderError: Error, Equatable {
        case cannotAdd(String)
        case sample(OSStatus)
        case notStarted
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

    public init(url: URL, videoFormat: CMFormatDescription, audioFormat: CMAudioFormatDescription?) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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

    /// Cierra el fichero; `completion` cuando está escrito.
    public func finish(completion: @escaping (Bool) -> Void) {
        lock.lock()
        guard started else {
            lock.unlock()
            writer.cancelWriting()
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
