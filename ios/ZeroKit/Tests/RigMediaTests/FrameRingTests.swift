import CoreVideo
import XCTest

@testable import RigMedia

final class FrameRingTests: XCTestCase {
    private func makeRing(slots: Int = 3) throws -> FrameRing {
        try XCTUnwrap(FrameRing(slots: slots, width: 640, height: 360))
    }

    private func sello(_ ring: FrameRing, _ rigMs: Int64) {
        ring.store(rigMs: rigMs) { buffer in
            // El «blit» de los tests: la primera luma lleva el sello, para poder
            // comprobar después que el fotograma entregado es el que dice ser.
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                base.assumingMemoryBound(to: UInt8.self)[0] = UInt8(truncatingIfNeeded: rigMs)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
    }

    private func primeraLuma(_ buffer: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        return base.assumingMemoryBound(to: UInt8.self)[0]
    }

    func testNearestSearchFindsTheRightFrame() throws {
        let ring = try makeRing()
        sello(ring, 100)
        sello(ring, 133)
        sello(ring, 166)

        let lease = try XCTUnwrap(ring.acquire(nearest: 140))
        XCTAssertEqual(lease.rigMs, 133)
        XCTAssertEqual(primeraLuma(lease.buffer), 133)
        ring.release(lease)

        XCTAssertNil(ring.acquire(nearest: 500, maxDistanceMs: 100))
    }

    func testAReferencedFrameIsNeverOverwritten() throws {
        let ring = try makeRing(slots: 2)
        sello(ring, 10)
        sello(ring, 20)
        let lease = try XCTUnwrap(ring.acquire(nearest: 10))

        // Con el de 10 referenciado, todos los stores siguientes reciclan el otro
        // hueco, las veces que haga falta, y el referenciado queda intacto.
        sello(ring, 30)
        sello(ring, 40)
        sello(ring, 50)

        XCTAssertEqual(lease.rigMs, 10)
        XCTAssertEqual(primeraLuma(lease.buffer), 10)
        let otra = try XCTUnwrap(ring.acquire(nearest: 50, maxDistanceMs: 0))
        XCTAssertEqual(primeraLuma(otra.buffer), 50)
        ring.release(otra)
        ring.release(lease)
        XCTAssertEqual(ring.dropped, 0)
    }

    func testALateReleaseOfAnOldLeaseCannotFreeTheNewOccupant() throws {
        let ring = try makeRing(slots: 1)
        sello(ring, 10)
        let viejo = try XCTUnwrap(ring.acquire(nearest: 10))
        ring.release(viejo)

        // El hueco se reutiliza: generación nueva.
        sello(ring, 20)
        let nuevo = try XCTUnwrap(ring.acquire(nearest: 20))

        // La liberación tardía (doble) del lease viejo no toca al ocupante nuevo.
        ring.release(viejo)
        XCTAssertFalse(ring.store(rigMs: 30) { _ in XCTFail("el hueco sigue referenciado") })

        ring.release(nuevo)
        XCTAssertTrue(ring.store(rigMs: 30) { _ in })
    }

    func testDroppingWhenAllSlotsAreReferenced() throws {
        let ring = try makeRing(slots: 2)
        sello(ring, 1)
        sello(ring, 2)
        let a = try XCTUnwrap(ring.acquire(nearest: 1))
        let b = try XCTUnwrap(ring.acquire(nearest: 2))

        XCTAssertFalse(ring.store(rigMs: 3) { _ in })
        XCTAssertEqual(ring.dropped, 1)

        ring.release(a)
        ring.release(b)
    }
}
