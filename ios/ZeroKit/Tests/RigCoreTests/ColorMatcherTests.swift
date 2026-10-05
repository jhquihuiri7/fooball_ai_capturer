// El igualado de color contra los dorados de color.json (IOS-38, REF-15):
// PanoramaStitcher.observe_color, observación a observación.

import Foundation
import RigCore
import XCTest

final class ColorMatcherTests: XCTestCase {
    func testLosDoradosDeObserveColor() throws {
        let documento = try Golden.loadDocument(named: "color.json")
        var corridas = 0
        for caso in documento.cases where caso.fn == "PanoramaStitcher.observe_color" {
            corridas += 1
            let igualador = ColorMatcher()
            let obs = try XCTUnwrap(caso.inputs.jsonObject() as? [String: Any])["observations"] as? [[String: Any]]
            for o in try XCTUnwrap(obs) {
                // Los números del JSON llegan como NSNumber (96.0 puede leerse entero).
                func bgr(_ k: String) throws -> [Double] {
                    try XCTUnwrap(o[k] as? [Any]).map { try XCTUnwrap(($0 as? NSNumber)?.doubleValue) }
                }
                igualador.observe(meanLeft: try bgr("mean_left"), meanRight: try bgr("mean_right"))
            }
            let actual = GoldenValue.object([
                "gain_left": .tensor(f64: igualador.gains.left, shape: [3]),
                "gain_right": .tensor(f64: igualador.gains.right, shape: [3]),
            ])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridas, 3)
    }

    func testOscuroNoMueveNadaYElTopeSeRespeta() {
        let m = ColorMatcher(smoothing: 1)
        m.observe(meanLeft: [5, 100, 100], meanRight: [100, 100, 100])
        XCTAssertEqual(m.gains, .unity)
        m.observe(meanLeft: [20, 100, 100], meanRight: [200, 100, 100])
        XCTAssertEqual(m.gains.left[0], RigConstants.panoramaColorMatchMaxGain, accuracy: 1e-12)
    }
}
