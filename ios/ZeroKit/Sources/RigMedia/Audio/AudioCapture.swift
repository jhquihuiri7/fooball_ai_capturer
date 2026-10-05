// El micrófono en la misma sesión que la cámara (IOS-54).
//
// AVCaptureAudioDataOutput entrega CMSampleBuffer de PCM con su PTS en el reloj de host,
// el mismo de los fotogramas: `rigMsOf` le suma el desfase del soporte, así el audio y el
// vídeo comparten reloj y el desfase A/V es el de la captura, no uno inventado. Cada
// búfer se pasa a AVAudioPCMBuffer y entra al AacEncoder; las tramas salen por `onFrame`.
// Va en un objeto propio y no en el delegado del vídeo: los dos protocolos comparten
// selector, y el audio acabaría en el camino de los fotogramas.

import AVFoundation
import Foundation
import RigCore

public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let rigMsOf: (CMTime) -> Double
    private var encoder: AacEncoder?
    private let lock = NSLock()

    /// Una trama AAC con ADTS, lista para el mux o el fichero.
    public var onFrame: ((AacFrame) -> Void)?

    public private(set) var buffersIn = 0
    public private(set) var failures = 0
    /// Huecos de más de una trama entre dos búferes seguidos del micro.
    public private(set) var gaps = 0
    private var lastEndMs: Double?

    /// El formato del AAC (con su ESDS), cuando ya ha llegado audio.
    public var formatDescription: CMAudioFormatDescription? {
        lock.lock(); defer { lock.unlock() }
        return encoder?.formatDescription
    }

    public init(rigMsOf: @escaping (CMTime) -> Double) {
        self.rigMsOf = rigMsOf
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let pcm = Self.pcm(of: sampleBuffer) else {
            lock.lock(); failures += 1; lock.unlock()
            return
        }
        let ms = rigMsOf(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.lock()
        defer { lock.unlock() }
        buffersIn += 1
        let tramaMs = 1000 * Double(AudioConstants.samplesPerFrame) / Double(AudioConstants.sampleRate)
        if let fin = lastEndMs, ms - fin > tramaMs { gaps += 1 }
        lastEndMs = ms + 1000 * Double(pcm.frameLength) / pcm.format.sampleRate
        do {
            if encoder == nil { encoder = try AacEncoder(input: pcm.format) }
            try encoder?.append(pcm, rigMs: ms)
            while let f = encoder?.pop() { onFrame?(f) }
        } catch {
            failures += 1
        }
    }

    /// El PCM de un CMSampleBuffer de audio, copiado a un AVAudioPCMBuffer.
    static func pcm(of sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        var fmtDesc = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &fmtDesc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
