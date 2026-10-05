import CoreVideo
import ImageIO
import XCTest

@testable import RigMedia

/// Las miniaturas del panel (IOS-64): un NV12 4K a un JPEG de 640×360 de unos KB.
final class ThumbnailTests: XCTestCase {
    func testUn4kAJpegDe640x360() throws {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        let fuente = try XCTUnwrap(b)
        CVPixelBufferLockBaseAddress(fuente, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(fuente, 0)!.assumingMemoryBound(to: UInt8.self)
        let sy = CVPixelBufferGetBytesPerRowOfPlane(fuente, 0)
        for fila in 0..<2160 { for x in 0..<3840 { y[fila * sy + x] = UInt8(16 + (x * 200 / 3840 + fila * 20 / 2160)) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(fuente, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(fuente, 1) * 1080)
        CVPixelBufferUnlockBaseAddress(fuente, [])

        let t = try XCTUnwrap(Thumbnailer())
        let inicio = Date()
        let jpeg = try XCTUnwrap(t.jpeg(from: fuente))
        let ms = Date().timeIntervalSince(inicio) * 1000
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 640)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 360)
        XCTAssertLessThan(jpeg.count, 60_000, "unos KB, no un MB")
        XCTAssertLessThan(ms, 500)
        // La segunda va del pool, sin reservar.
        XCTAssertNotNil(t.jpeg(from: fuente))
    }
}
