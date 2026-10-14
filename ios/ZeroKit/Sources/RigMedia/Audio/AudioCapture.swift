// El micrófono en la misma sesión que la cámara (IOS-54).
//
// AVCaptureAudioDataOutput entrega CMSampleBuffer de PCM con su PTS en el reloj de la
// sesión: `rigMsOf` lo pasa al host y le suma el desfase del soporte, así el audio y el
// vídeo comparten reloj y el desfase A/V es el de la captura, no uno inventado. Cada
// búfer se pasa a AVAudioPCMBuffer y entra al AacEncoder; las tramas salen por `onFrame`.
// Va en un objeto propio y no en el delegado del vídeo: los dos protocolos comparten
// selector, y el audio acabaría en el camino de los fotogramas.
//
// El codificador existe desde el principio, haya micro o no: el programa lleva siempre su
// AAC (el relé lo copia, ADR 0011) y `keepAlive` lo rellena de silencio mientras el micro
// calla (sin permiso, tomado por una llamada, parado).

import AVFoundation
import Foundation
import RigCore

public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let rigMsOf: (CMTime) -> Double
    private let encoder: AacEncoder
    private let lock = NSLock()

    /// Una trama AAC con ADTS, lista para el mux o el fichero.
    public var onFrame: ((AacFrame) -> Void)?
    /// El búfer tal cual llega del micro, con su PTS de la sesión.
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// El PCM en el eje del AAC (ver `AacEncoder.onAligned`): la pista de audio de la 4K.
    /// Incluye el silencio del vigilante. Se fija antes de que llegue audio.
    public var onAlignedPcm: ((AVAudioPCMBuffer, Double) -> Void)? {
        get { encoder.onAligned }
        set { encoder.onAligned = newValue }
    }
    /// El PCM del micro con el rigMs de su primera muestra: la derivación para el DSP del
    /// silbato (IOS-76). Sin el silencio del vigilante: solo lo que oyó el micro.
    public var onPcm: ((AVAudioPCMBuffer, Double) -> Void)?

    public private(set) var buffersIn = 0
    public private(set) var failures = 0
    /// Huecos de más de una trama entre dos búferes seguidos del micro.
    public private(set) var gaps = 0
    /// Veces que el vigilante metió silencio (el micro llevaba `micStallMs` callado).
    public private(set) var silenceTicks = 0
    private var lastEndMs: Double?

    /// El formato del AAC (con su ESDS), desde el principio.
    public var formatDescription: CMAudioFormatDescription? { encoder.formatDescription }

    /// Lo que el eje del AAC ha corregido: silencio, recortes, muestra a muestra y saltos.
    public var syncStats: AacEncoder.SyncStats { encoder.syncStats }

    public init(rigMsOf: @escaping (CMTime) -> Double) throws {
        self.rigMsOf = rigMsOf
        encoder = try AacEncoder()
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        receive(sampleBuffer)
    }

    /// Un búfer del micro: a la 4K, al DSP y al AAC. Aparte del delegado para probarlo.
    func receive(_ sampleBuffer: CMSampleBuffer) {
        onSampleBuffer?(sampleBuffer)
        guard let pcm = Self.pcm(of: sampleBuffer) else {
            lock.lock(); failures += 1; lock.unlock()
            return
        }
        let ms = rigMsOf(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onPcm?(pcm, ms)
        lock.lock()
        defer { lock.unlock() }
        buffersIn += 1
        let tramaMs = 1000 * Double(AudioConstants.samplesPerFrame) / Double(AudioConstants.sampleRate)
        if let fin = lastEndMs, ms - fin > tramaMs { gaps += 1 }
        lastEndMs = ms + 1000 * Double(pcm.frameLength) / pcm.format.sampleRate
        do {
            try encoder.append(pcm, rigMs: ms)
            while let f = encoder.pop() { onFrame?(f) }
        } catch {
            failures += 1
        }
    }

    /// El vigilante: lo llama quien tiene el reloj (CaptureEngine, cada `silenceTickMs`)
    /// con «ahora» en ms del soporte. Si el micro lleva más de `micStallMs` sin entregar,
    /// el AAC sigue con silencio hasta `nowRigMs − micStallMs`; cuando el micro vuelve, el
    /// eje rellena lo que falte hasta su sello o recorta lo que sobre.
    public func keepAlive(nowRigMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        let antes = encoder.syncStats.silenceSamples
        do {
            try encoder.appendSilence(untilRigMs: nowRigMs - AudioConstants.micStallMs)
            while let f = encoder.pop() { onFrame?(f) }
        } catch {
            failures += 1
        }
        if encoder.syncStats.silenceSamples > antes { silenceTicks += 1 }
    }

    /// Un AVAudioPCMBuffer como CMSampleBuffer sellado en `ptsNs`, para un AVAssetWriter.
    public static func sampleBuffer(_ pcm: AVAudioPCMBuffer, ptsNs: Int64) -> CMSampleBuffer? {
        var asbd = pcm.format.streamDescription.pointee
        var formato: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formato
        ) == noErr else { return nil }
        var tiempo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: CMTime(value: ptsNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var muestra: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formato, sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &tiempo, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &muestra
        ) == noErr, let muestra else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            muestra, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pcm.audioBufferList
        ) == noErr else { return nil }
        return muestra
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
