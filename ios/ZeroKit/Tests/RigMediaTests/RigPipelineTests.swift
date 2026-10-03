import CoreMedia
import CoreVideo
import XCTest

@testable import RigMedia

final class RigPipelineTests: XCTestCase {
    private func makeSample(width: Int = 640, height: Int = 360, stamp: UInt8 = 7) throws -> CMSampleBuffer {
        let pool = try XCTUnwrap(PixelBufferPool(
            width: width, height: height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, capacity: 1
        ))
        let pixels = try XCTUnwrap(pool.take())
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
            base.assumingMemoryBound(to: UInt8.self)[0] = stamp
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var formato: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &formato
        )
        var tiempo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 12_345, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(formato), sampleTiming: &tiempo, sampleBufferOut: &sample
        )
        return try XCTUnwrap(sample)
    }

    func testIngestCopiesTheFrameIntoTheRingAndReportsMeta() throws {
        let pipeline = try XCTUnwrap(RigPipeline(width: 640, height: 360))
        let listo = expectation(description: "onFrame")
        var meta: RigPipeline.FrameMeta?
        pipeline.onFrame = { recibido in
            meta = recibido
            listo.fulfill()
        }

        pipeline.ingest(try makeSample(stamp: 42), rigNs: 100_000_000)
        wait(for: [listo], timeout: 5)

        XCTAssertEqual(meta?.rigNs, 100_000_000)
        XCTAssertEqual(meta?.index, 0)
        XCTAssertEqual(pipeline.stored, 1)

        let lease = try XCTUnwrap(pipeline.ring.acquire(nearest: 100, maxDistanceMs: 0))
        CVPixelBufferLockBaseAddress(lease.buffer, .readOnly)
        let luma = CVPixelBufferGetBaseAddressOfPlane(lease.buffer, 0)!
            .assumingMemoryBound(to: UInt8.self)[0]
        CVPixelBufferUnlockBaseAddress(lease.buffer, .readOnly)
        XCTAssertEqual(luma, 42, "el blit tiene que copiar la luma de verdad")
        pipeline.ring.release(lease)
    }

    func testASecondFrameWhileOneIsInFlightIsDroppedNotRetained() throws {
        let pipeline = try XCTUnwrap(RigPipeline(width: 640, height: 360))
        let frena = DispatchSemaphore(value: 0)
        let dentro = expectation(description: "el primero entró en la cola")
        pipeline.beforeStoreForTesting = {
            dentro.fulfill()
            frena.wait()
        }

        pipeline.ingest(try makeSample(), rigNs: 0)
        wait(for: [dentro], timeout: 5)
        // Con el primero parado dentro, todo lo que llegue se descarta sin retener.
        pipeline.ingest(try makeSample(), rigNs: 33_000_000)
        pipeline.ingest(try makeSample(), rigNs: 66_000_000)
        XCTAssertEqual(pipeline.dropped, 2)
        frena.signal()

        let tope = Date().addingTimeInterval(5)
        while pipeline.stored < 1, Date() < tope {
            usleep(500)
        }
        XCTAssertEqual(pipeline.stored, 1)
        XCTAssertEqual(pipeline.dropped, 2)
    }

    func testTheOrderOfIndexesSurvivesDrops() throws {
        let pipeline = try XCTUnwrap(RigPipeline(width: 640, height: 360))
        var indices: [Int] = []
        let lock = NSLock()
        pipeline.onFrame = { meta in
            lock.lock()
            indices.append(meta.index)
            lock.unlock()
        }
        for i in 0..<5 {
            pipeline.ingest(try makeSample(), rigNs: Int64(i) * 33_000_000)
            let tope = Date().addingTimeInterval(2)
            while pipeline.stored + pipeline.dropped <= i, Date() < tope {
                usleep(200)
            }
        }
        let tope = Date().addingTimeInterval(2)
        while indices.count < pipeline.stored, Date() < tope {
            usleep(200)
        }
        XCTAssertEqual(indices, indices.sorted(), "los índices entregados van en orden")
    }
}
