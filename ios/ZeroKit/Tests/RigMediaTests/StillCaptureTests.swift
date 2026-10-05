import CoreVideo
import ImageIO
import XCTest

import RigCore
@testable import RigMedia

/// Los fotogramas de calibración (IOS-70): qué fotograma del anillo se usa, el JPEG 4K
/// q95 bajo el tope y el JSON con sus intrínsecas.
final class StillCaptureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("calib-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Un anillo 4K con fotogramas en `instantes`, con un degradado con textura (como una
    /// escena, no un plano liso que comprima a nada).
    private func anillo(_ instantes: [Int64]) throws -> FrameRing {
        let ring = try XCTUnwrap(FrameRing(slots: 4, width: 3840, height: 2160))
        for t in instantes {
            _ = ring.store(rigMs: t) { b in
                CVPixelBufferLockBaseAddress(b, [])
                defer { CVPixelBufferUnlockBaseAddress(b, []) }
                for plano in 0..<2 {
                    let base = CVPixelBufferGetBaseAddressOfPlane(b, plano)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plano)
                    let alto = CVPixelBufferGetHeightOfPlane(b, plano)
                    for y in 0..<alto {
                        for x in 0..<stride {
                            base[y * stride + x] = plano == 0 ? UInt8((x / 8 + y / 8 + Int(t)) & 0xFF) ^ UInt8((x * y) & 0x1F) : 128
                        }
                    }
                }
            }
        }
        return ring
    }

    func testEligeElDeLaToleranciaYGuardaJpegYJson() throws {
        let ring = try anillo([1000, 1033, 1067])
        let k: [Float] = [2000, 0, 1920, 0, 2000, 1080, 0, 0, 1]
        let cap = CalibrationStillCapture(
            side: .left, ring: ring, intrinsics: { $0 == 1033 ? k : nil }, mountedUpsideDown: true,
            directory: dir, extraMeta: { ["ios": "26.0"] }
        )
        let hecho = expectation(description: "captura")
        nonisolated(unsafe) var resultado: Result<[CalibrationStillCapture.Still], CalibrationStillCapture.CaptureError>?
        cap.capture(targets: [1040], nowRigMs: { 1100 }) { resultado = $0; hecho.fulfill() }
        wait(for: [hecho], timeout: 30)
        let fotos = try XCTUnwrap(try resultado?.get())
        XCTAssertEqual(fotos.map(\.rigMs), [1033])
        XCTAssertEqual(fotos[0].deltaMs, -7)
        XCTAssertTrue(fotos[0].hasIntrinsics)
        XCTAssertLessThanOrEqual(fotos[0].bytes, RigConstants.rigCalibJpegMaxBytes)
        XCTAssertGreaterThan(fotos[0].bytes, 100_000, "un 4K con textura no es un JPEG vacío")

        let fuente = try XCTUnwrap(CGImageSourceCreateWithURL(fotos[0].jpeg as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(fuente, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 3840)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 2160)

        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fotos[0].json)) as? [String: Any])
        XCTAssertEqual(meta["side"] as? String, "left")
        XCTAssertEqual(meta["rig_ms"] as? Int, 1033)
        XCTAssertEqual(meta["target_rig_ms"] as? Int, 1040)
        XCTAssertEqual(meta["mount_flip"] as? Bool, true)
        XCTAssertEqual((meta["intrinsics"] as? [Double])?.count, 9)
        XCTAssertEqual(meta["ios"] as? String, "26.0")
    }

    func testSinFotogramaALaAlturaDelDestinoSeAgotaElPlazo() throws {
        let ring = try anillo([1000])
        let cap = CalibrationStillCapture(
            side: .right, ring: ring, intrinsics: { _ in nil }, mountedUpsideDown: false, directory: dir
        )
        let hecho = expectation(description: "plazo")
        nonisolated(unsafe) var error: CalibrationStillCapture.CaptureError?
        cap.capture(targets: [5000], nowRigMs: { 7000 }) {
            if case let .failure(e) = $0 { error = e }
            hecho.fulfill()
        }
        wait(for: [hecho], timeout: 5)
        XCTAssertEqual(error, .timeout(target: 5000))
    }
}
