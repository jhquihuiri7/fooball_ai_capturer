import CoreMedia
import RigMedia
import XCTest

final class SampleRetimeTests: XCTestCase {
    /// Un búfer de audio con dos entradas de tiempos: se desplazan las dos.
    func testDesplazaTodasLasEntradasDeTiempos() throws {
        let paso = CMTime(value: 1, timescale: 48_000)
        var tiempos = [
            CMSampleTimingInfo(duration: paso, presentationTimeStamp: CMTime(value: 1_000, timescale: 48_000),
                               decodeTimeStamp: .invalid),
            CMSampleTimingInfo(duration: paso, presentationTimeStamp: CMTime(value: 1_001, timescale: 48_000),
                               decodeTimeStamp: .invalid),
        ]
        var tamanos = [2, 2]
        var bloque: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &bloque
        ), noErr)
        var buf: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bloque, formatDescription: nil, sampleCount: 2,
            sampleTimingEntryCount: 2, sampleTimingArray: &tiempos, sampleSizeEntryCount: 2,
            sampleSizeArray: &tamanos, sampleBufferOut: &buf
        ), noErr)
        let copia = try XCTUnwrap(SampleRetime.shifted(try XCTUnwrap(buf), byNs: 2_500_000_000))
        var n: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(copia, entryCount: 0, arrayToFill: nil, entriesNeededOut: &n)
        XCTAssertEqual(n, 2)
        var salida = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: n)
        CMSampleBufferGetSampleTimingInfoArray(copia, entryCount: n, arrayToFill: &salida, entriesNeededOut: &n)
        XCTAssertEqual(CMTimeGetSeconds(salida[0].presentationTimeStamp), 1_000.0 / 48_000 + 2.5, accuracy: 1e-9)
        XCTAssertEqual(CMTimeGetSeconds(salida[1].presentationTimeStamp), 1_001.0 / 48_000 + 2.5, accuracy: 1e-9)
        XCTAssertEqual(salida[1].duration, paso)
    }
}
