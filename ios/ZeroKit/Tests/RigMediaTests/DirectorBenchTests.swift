// El banco del director (IOS-37) corre en el Mac y deja un informe con sentido; en el
// iPhone lo lanza `--dart-define=BENCH=director-bench`.

import Foundation
@testable import RigMedia
import XCTest

final class DirectorBenchTests: XCTestCase {
    func testElBancoDelDirectorDejaSuInforme() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = try BenchRunner.run(name: "director-bench", paramsJson: #"{"repetitions": 1}"#, directory: dir)
        let report = try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(report.counters["frames"], DirectorBench.frames)
        XCTAssertGreaterThan(report.counters["detection_cycles"] ?? 0, 800)
        let frame = try XCTUnwrap(report.stagesMs["director/frame"])
        XCTAssertGreaterThan(frame.p50Ms, 0)
        XCTAssertLessThanOrEqual(frame.p50Ms, frame.p99Ms)
        // Cada ciclo ve jugadores de las dos cámaras: la fusión trabaja de verdad.
        let ciclos = try DirectorBench.partido(DirectorBench.nominalRig())
        XCTAssertTrue(ciclos.contains { ($0?.left.isEmpty == false) && ($0?.right.isEmpty == false) })
    }

    func testLosPercentilesSonExactos() {
        let s = DirectorBench.summary((1...100).map(Double.init))
        XCTAssertEqual(s.p50Ms, 51)
        XCTAssertEqual(s.p99Ms, 100)
    }
}
