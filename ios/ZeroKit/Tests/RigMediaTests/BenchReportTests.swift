import XCTest

@testable import RigMedia

final class BenchReportTests: XCTestCase {
    func testNoopWritesAReportWithTheMachineAndTheThermalLine() throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: carpeta) }

        let url = try BenchRunner.run(name: "noop", paramsJson: #"{"hz": 7.5}"#, directory: carpeta)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("noop-"))
        let report = try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(report.name, "noop")
        XCTAssertFalse(report.device.isEmpty)
        XCTAssertFalse(report.systemVersion.isEmpty)
        XCTAssertEqual(report.counters["noop"], 1)
        XCTAssertEqual(report.params["hz"], "7.5")
        XCTAssertEqual(report.thermal.count, 2)  // al empezar y al acabar
        XCTAssertGreaterThanOrEqual(report.durationS, 0)
    }

    func testAnUnknownBenchIsAnError() {
        XCTAssertThrowsError(try BenchRunner.run(name: "no-existe", paramsJson: "{}")) { error in
            XCTAssertTrue("\(error)".contains("no-existe"))
        }
    }

    func testTheReportKeysAreTheContractOfBenchSummary() throws {
        // Las claves que lee tools/bench_summary.dart, carácter a carácter.
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: carpeta) }
        let url = try BenchRunner.run(name: "noop", paramsJson: "{}", directory: carpeta)

        let crudo = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let claves = Set(crudo?.keys ?? [:].keys)
        XCTAssertEqual(
            claves,
            ["name", "device", "system_version", "started_epoch_s", "duration_s",
             "params", "thermal", "stages_ms", "counters"]
        )
    }
}
