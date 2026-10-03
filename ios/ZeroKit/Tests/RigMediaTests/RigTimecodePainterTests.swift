import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// El pintado sobre el buffer de la cámara: las celdas tienen que quedar donde el
/// lector del servidor las va a buscar. Corre también en el Mac: CoreVideo existe en
/// las dos plataformas, y un CVPixelBuffer 4:2:0 de 3840×2160 se crea igual.
final class RigTimecodePainterTests: XCTestCase {
    func testWritesIntoLumaPlaneAndReadsBack() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let value: UInt64 = 123_456_789_012

        XCTAssertTrue(RigTimecode.write(valueMs: value, into: pixels))

        XCTAssertEqual(readBack(pixels), value)
    }

    func testRejectsBuffersWithoutLumaPlane() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_32BGRA)

        XCTAssertFalse(RigTimecode.write(valueMs: 1, into: pixels))
    }

    func testRejectsValuesThatDoNotFit() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        XCTAssertFalse(RigTimecode.write(valueMs: RigTimecode.payloadMax + 1, into: pixels))
    }

    private func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, format, nil, &buffer)
        return try XCTUnwrap(buffer)
    }

    /// Lector mínimo: el centro de cada celda contra el umbral medio. El lector de
    /// verdad es el del servidor; este solo comprueba que las celdas están donde toca.
    private func readBack(_ pixels: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let side = RigTimecode.cellSide(width: CVPixelBufferGetWidthOfPlane(pixels, 0))
        let threshold = (Int(RigTimecode.lumaOne) + Int(RigTimecode.lumaZero)) / 2

        var word: UInt64 = 0
        for index in 0..<RigTimecode.bits {
            let sample = luma[(side / 2) * stride + index * side + side / 2]
            word = (word << 1) | (Int(sample) > threshold ? 1 : 0)
        }
        guard word >> 56 == RigTimecode.preamble else { return nil }
        let value = (word >> 8) & RigTimecode.payloadMax
        return RigTimecode.word(valueMs: value) == word ? value : nil
    }
}
