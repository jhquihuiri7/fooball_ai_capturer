// Cambiar el sello de un CMSampleBuffer al tiempo del soporte (IOS-57).
//
// El vídeo trae una sola entrada de tiempos, pero el audio puede traer varias: se
// desplazan todas por el mismo desfase, así audio y vídeo comparten el eje del archivo.

import CoreMedia
import Foundation

public enum SampleRetime {
    /// Una copia del búfer con todos sus instantes desplazados `offsetNs`.
    public static func shifted(_ buffer: CMSampleBuffer, byNs offsetNs: Int64) -> CMSampleBuffer? {
        var cuantos: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &cuantos
        ) == noErr, cuantos > 0 else { return nil }
        var tiempos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: cuantos)
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: cuantos, arrayToFill: &tiempos, entriesNeededOut: &cuantos
        ) == noErr else { return nil }
        let desfase = CMTime(value: offsetNs, timescale: 1_000_000_000)
        for i in tiempos.indices {
            tiempos[i].presentationTimeStamp = CMTimeAdd(tiempos[i].presentationTimeStamp, desfase)
            if tiempos[i].decodeTimeStamp.isValid {
                tiempos[i].decodeTimeStamp = CMTimeAdd(tiempos[i].decodeTimeStamp, desfase)
            }
        }
        var copia: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer, sampleTimingEntryCount: cuantos,
            sampleTimingArray: &tiempos, sampleBufferOut: &copia
        )
        return status == noErr ? copia : nil
    }
}
