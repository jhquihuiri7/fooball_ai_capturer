import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

import RigCore
@testable import RigMedia

/// Los anuncios de la franja (IOS-48): carga como load_ad, tope de memoria y la
/// rotación por el reloj del soporte.
final class AdStoreTests: XCTestCase {
    private let w = 16
    private let h = 4

    private func store(budget: Int = AdStoreConstants.budgetBytes) throws -> AdStore {
        AdStore(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), width: w, height: h, budgetBytes: budget)
    }

    private func frame(_ rgba: [UInt8]) -> [UInt8] {
        Array((0..<(w * h)).map { _ in rgba }.joined())
    }

    private func pixel(_ t: MTLTexture) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return p
    }

    func testDeduplicaYPremultiplicaComoLaReferencia() throws {
        let s = try store()
        let a = frame([200, 100, 50, 128])
        let b = frame([10, 20, 30, 0])
        let clip = try s.load(name: "gol", frames: [a, a, b, a], fps: 30)
        XCTAssertEqual(clip.frames, 4)
        XCTAssertEqual(s.usedBytes, 2 * w * h * 4 * 2, "dos fotogramas distintos")
        let t = try XCTUnwrap(s.strip(for: AdCue(ad: clip, frame: 0)))
        // (200·128 + 127) / 255 = 100, (100·128 + 127)/255 = 50, (50·128 + 127)/255 = 25.
        XCTAssertEqual(pixel(t.premul), [100, 50, 25, 128])
        XCTAssertEqual(pixel(t.inverse), [127, 127, 127, 255])
        XCTAssertEqual(pixel(try XCTUnwrap(s.strip(for: AdCue(ad: clip, frame: 2))).inverse), [255, 255, 255, 255])
    }

    func testRechazaOpacoCadenciaTamanoYPresupuesto() throws {
        let s = try store(budget: 3 * 16 * 4 * 4 * 2)
        XCTAssertThrowsError(try s.load(name: "opaco", frames: [frame([1, 2, 3, 255])], fps: 30))
        XCTAssertThrowsError(try s.load(name: "24", frames: [frame([1, 2, 3, 9])], fps: 24))
        XCTAssertThrowsError(try s.load(name: "mal", frames: [[0, 0, 0, 0]], fps: 30))
        try s.load(name: "uno", frames: [frame([1, 2, 3, 9]), frame([1, 2, 3, 8])], fps: 25)
        XCTAssertThrowsError(try s.load(name: "dos", frames: [frame([5, 5, 5, 9]), frame([5, 5, 5, 8])], fps: 30)) {
            XCTAssertTrue("\($0)".contains("aligerar"))
        }
        // Sustituir el mismo nombre no cuenta dos veces.
        XCTAssertNoThrow(try s.load(name: "uno", frames: [frame([7, 7, 7, 9]), frame([7, 7, 7, 8])], fps: 25))
    }

    func testDirectorioDePng() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, alfa) in [255, 0].enumerated() {
            var px = frame([255, 0, 0, UInt8(alfa)])
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(
                dir.appendingPathComponent("f\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        let s = try store()
        let clip = try s.loadDirectory(dir, name: "png", fps: 30)
        XCTAssertEqual(clip.frames, 2)
        XCTAssertEqual(pixel(try XCTUnwrap(s.strip(for: AdCue(ad: clip, frame: 0))).premul), [255, 0, 0, 255])
    }

    func testLaRotacionPorElRelojDelSoporte() throws {
        let s = try store()
        let a = try s.load(name: "a", frames: (0..<10).map { frame([UInt8($0), 0, 0, 100]) }, fps: 30)
        let b = try s.load(name: "b", frames: [frame([0, 0, 9, 100])], fps: 30)
        let r = AdRotation(store: s)
        XCTAssertNil(r.strip(atRigMs: 0), "sin lista no hay franja")
        r.set(playlist: AdPlaylist(slots: [try AdSlot(ad: a), try AdSlot(ad: b, loops: 3)]), atRigMs: 10_000)
        XCTAssertEqual(r.strip(atRigMs: 10_000)?.1, AdCue(ad: a, frame: 0))
        XCTAssertEqual(r.strip(atRigMs: 10_100)?.1, AdCue(ad: a, frame: 3))
        XCTAssertEqual(r.strip(atRigMs: 10_340)?.1.ad, b)
        r.set(override: b, atRigMs: 10_050)
        XCTAssertEqual(r.strip(atRigMs: 10_060)?.1.ad, b, "el override manda mientras dura")
        XCTAssertEqual(r.strip(atRigMs: 10_090)?.1.ad, a, "y suelta")
    }
}
