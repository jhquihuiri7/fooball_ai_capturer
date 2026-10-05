import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// La media del solape (IOS-38): dónde cae en cada cámara y que la medida de un NV12
/// liso da su color.
final class OverlapMeansTests: XCTestCase {
    private func rig(width: Int, height: Int) throws -> RigModel {
        let intr = try CameraIntrinsics.fromHfov(width: width, height: height, hfovRad: 106 * .pi / 180)
        let yaw = RigConstants.defaultRigYawDeg * .pi / 180
        return RigModel(
            left: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: -yaw, pitchRad: -0.14)),
            right: RigCamera(intrinsics: intr, pose: CameraPose(yawRad: yaw, pitchRad: -0.14))
        )
    }

    private func liso(_ w: Int, _ h: Int, y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &b)
        let buf = try XCTUnwrap(b)
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(buf, 0), Int32(y),
               CVPixelBufferGetBytesPerRowOfPlane(buf, 0) * h)
        let c = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        for i in Swift.stride(from: 0, to: CVPixelBufferGetBytesPerRowOfPlane(buf, 1) * h / 2, by: 2) {
            c[i] = cb
            c[i + 1] = cr
        }
        return buf
    }

    func testElSolapeCaeHaciaElCentroDelSoporte() throws {
        let r = try rig(width: 1280, height: 720)
        let izq = OverlapMeans(rig: r, side: .left, width: 1280, height: 720, mountedUpsideDown: false)
        let der = OverlapMeans(rig: r, side: .right, width: 1280, height: 720, mountedUpsideDown: false)
        XCTAssertTrue(izq.measurable && der.measurable)
        let mediaX = { (m: OverlapMeans) in Double(m.samples.map(\.x).reduce(0, +)) / Double(m.samples.count) }
        XCTAssertGreaterThan(mediaX(izq), 640, "la izquierda ve el solape a su derecha")
        XCTAssertLessThan(mediaX(der), 640, "y la derecha, a su izquierda")
        // Girado 180°, las mismas muestras quedan reflejadas.
        let girada = OverlapMeans(rig: r, side: .left, width: 1280, height: 720, mountedUpsideDown: true)
        XCTAssertLessThan(mediaX(girada), 640)
        XCTAssertEqual(girada.samples.count, izq.samples.count, accuracy: izq.samples.count / 50)
    }

    func testLaMediaDeUnNv12LisoEsSuColor() throws {
        let r = try rig(width: 1280, height: 720)
        let m = OverlapMeans(rig: r, side: .left, width: 1280, height: 720, mountedUpsideDown: false)
        // Gris medio: Y 126, croma neutra → RGB ~128.
        let gris = try XCTUnwrap(m.measure(try liso(1280, 720, y: 126, cb: 128, cr: 128)))
        for c in gris { XCTAssertEqual(c, 128, accuracy: 1.5) }
        // Rojizo: Cr alto sube R y baja G; B casi igual.
        let rojo = try XCTUnwrap(m.measure(try liso(1280, 720, y: 126, cb: 128, cr: 170)))
        XCTAssertGreaterThan(rojo[2], gris[2] + 30)
        XCTAssertLessThan(rojo[1], gris[1] - 10)
        XCTAssertNil(m.measure(try liso(640, 360, y: 126, cb: 128, cr: 128)), "otro tamaño: nada")
    }
}
