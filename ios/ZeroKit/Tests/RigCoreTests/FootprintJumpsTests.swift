// Los saltos de la huella (2026-10-14): el del ensayo de 90 min, con su instante.

import Foundation
import RigCore
import XCTest

final class FootprintJumpsTests: XCTestCase {
    func testElSaltoDelEnsayoConSuInstante() {
        var f = FootprintJumps()
        var saltos: [FootprintJumps.Jump] = []
        // Cada 5 s: plano en ~306 MB, salta a ~487 en el segundo 2685 y sigue plano.
        for k in 0..<1080 {
            let s = Double(k) * 5
            let mb = (s < 2685 ? 306 : 487) + Double(k % 3)
            if let j = f.sample(mb: mb, atS: s) { saltos.append(j) }
        }
        XCTAssertEqual(saltos.count, 1)
        XCTAssertEqual(saltos.first?.atS, 2685)
        XCTAssertEqual(saltos.first?.fromMb ?? 0, 306, accuracy: 3)
        XCTAssertEqual(saltos.first?.toMb ?? 0, 487, accuracy: 3)
        XCTAssertEqual(f.jumps, saltos)
    }

    func testUnaBajadaOUnaSubidaPequenaNoCuentan() {
        var f = FootprintJumps(thresholdMb: 20)
        XCTAssertNil(f.sample(mb: 300, atS: 0), "la primera no tiene con qué compararse")
        XCTAssertNil(f.sample(mb: 319, atS: 5))
        XCTAssertNil(f.sample(mb: 250, atS: 10))
        XCTAssertNotNil(f.sample(mb: 270, atS: 15))
    }

    func testAcotado() {
        var f = FootprintJumps(thresholdMb: 10, maxEvents: 2)
        for k in 0..<5 { f.sample(mb: Double(k) * 100, atS: Double(k)) }
        XCTAssertEqual(f.jumps.map(\.atS), [1, 2], "se quedan los primeros")
        XCTAssertEqual(f.dropped, 2)
    }
}
