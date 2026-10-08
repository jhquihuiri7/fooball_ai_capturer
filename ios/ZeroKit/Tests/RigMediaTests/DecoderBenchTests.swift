// El banco del decodificador (IOS-23) corre en el Mac y deja un informe con sentido; en
// el iPhone lo lanza `--dart-define=BENCH=decoder-bench`.

import Foundation
import RigCore
@testable import RigMedia
import XCTest

final class DecoderBenchTests: XCTestCase {
    func testElBancoDelDecodificadorDejaSuInforme() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = try BenchRunner.run(name: "decoder-bench", paramsJson: #"{"calls": 3}"#, directory: dir)
        let report = try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(report.counters["calls"], 3)
        for etapa in ["decoder/detr300", "decoder/heatmap", "decoder/heatmap_saturated"] {
            let s = try XCTUnwrap(report.stagesMs[etapa], etapa)
            XCTAssertGreaterThan(s.p50Ms, 0, etapa)
            XCTAssertLessThanOrEqual(s.p50Ms, s.p99Ms, etapa)
        }
        // Las personas del guion salen todas; el mapa saturado llega al tope.
        XCTAssertEqual(report.counters["decoder/detr300/detections"], DecoderBench.people)
        XCTAssertEqual(report.counters["decoder/heatmap/detections"], DecoderBench.people)
        XCTAssertEqual(report.counters["decoder/heatmap_saturated/detections"], DetectionSpec.playerMaxDetections)
    }
}
