import XCTest

@testable import RigCore

final class LatencyHistogramTests: XCTestCase {
    func testPercentilesLandInTheRightBucket() {
        var histograma = LatencyHistogram()
        // 99 medidas de 10 ms (cubo «12») y una de 200 ms (cubo «250»).
        for _ in 0..<99 { histograma.record(ms: 10) }
        histograma.record(ms: 200)

        XCTAssertEqual(histograma.p50Ms, 12)
        XCTAssertEqual(histograma.p90Ms, 12)
        XCTAssertEqual(histograma.p99Ms, 12)
        XCTAssertEqual(histograma.percentile(1.0), 250)
        XCTAssertEqual(histograma.total, 100)
    }

    func testTheLastBucketCatchesTheOutliers() {
        var histograma = LatencyHistogram(boundsMs: [1, 10])
        histograma.record(ms: 500)

        XCTAssertEqual(histograma.percentile(1.0), .infinity)
    }

    func testEmptyHistogramReportsZero() {
        let histograma = LatencyHistogram()
        XCTAssertEqual(histograma.p99Ms, 0)
    }

    func testResetClearsCountsButKeepsBuckets() {
        var histograma = LatencyHistogram(boundsMs: [5, 50])
        histograma.record(ms: 3)
        histograma.reset()

        XCTAssertEqual(histograma.total, 0)
        XCTAssertEqual(histograma.p50Ms, 0)
        histograma.record(ms: 30)
        XCTAssertEqual(histograma.p50Ms, 50)
    }
}
