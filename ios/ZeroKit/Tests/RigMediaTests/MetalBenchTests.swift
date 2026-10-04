// El banco de los kernels Metal (IOS-40/41/21) corre en el Mac y deja un informe con
// las tres pasadas y el total del maestro.

import Foundation
@testable import RigMedia
import XCTest

final class MetalBenchTests: XCTestCase {
    func testElBancoDeLosKernelsDejaSuInforme() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = try BenchRunner.run(name: "metal-bench", paramsJson: #"{"iterations": 5}"#, directory: dir)
        let report = try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: url))
        for etapa in ["gpu/reproject", "gpu/compose", "gpu/preprocess", "gpu/master_total"] {
            let s = try XCTUnwrap(report.stagesMs[etapa], etapa)
            XCTAssertGreaterThan(s.p50Ms, 0, etapa)
        }
    }
}
