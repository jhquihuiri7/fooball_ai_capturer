// La lente con dos cámaras (IOS-124, ADR 0035, enmienda del 2026-11-04): el solape contra el
// dorado overlap.json de REF-71, el fichero de la geometría de cada lente y los avisos.

import Foundation
import RigCore
import XCTest

final class RigLensTests: XCTestCase {
    func testElSolapeEsElDeLaReferencia() throws {
        let documento = try Golden.loadDocument(named: "overlap.json")
        XCTAssertEqual(documento.cases.count, 3)
        for caso in documento.cases {
            XCTAssertEqual(caso.fn, "RigModel.horizontal_overlap_rad")
            let rig = try RectilinearViewTests.rig(from: caso.inputs)
            let actual = GoldenValue.object(["overlap_rad": .number(rig.horizontalOverlapRad())])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
    }

    func testCadaLenteTieneSuFichero() {
        XCTAssertEqual(RigLens.ultraWide.rigFileName, "rig.json")
        XCTAssertEqual(RigLens(zoom: 1, hfovRad: 1.2).rigFileName, "rig-1x.json")
        XCTAssertEqual(RigLens(zoom: 2, hfovRad: 0.6).rigFileName, "rig-2x.json")
        XCTAssertEqual(RigLens(zoom: 1, hfovRad: 1.2).label, "1×")
        XCTAssertEqual(RigLens.ultraWide.label, "0,5×")
    }

    func testLosAvisos() throws {
        let documento = try Golden.loadDocument(named: "overlap.json")
        func rig(_ nombre: String) throws -> RigModel {
            try RectilinearViewTests.rig(from: XCTUnwrap(documento.cases.first { $0.name == nombre }).inputs)
        }
        let principal = RigLens(zoom: 1, hfovRad: 1.21)
        XCTAssertEqual(
            RigLensWarning.warnings(rig: try rig("ultra_a_40"), own: .ultraWide, peer: .ultraWide, calibrated: true), [],
            "la ultra a ±40°, calibrada, no avisa de nada"
        )
        let hueco = RigLensWarning.warnings(rig: try rig("principal_a_40_deja_hueco"), own: principal,
                                            peer: principal, calibrated: false)
        XCTAssertEqual(hueco.count, 2)
        XCTAssertTrue(hueco[0].contains("sin calibrar con la lente 1×"))
        XCTAssertTrue(hueco[1].contains("hueco de 10°"))
        // Cuánto juntarlos: hasta tocarse y lo que pide el cosido de más.
        XCTAssertTrue(hueco[1].contains("junta los móviles hasta unos"))
        XCTAssertTrue(hueco[1].contains("o usa 0,5×"))
        XCTAssertEqual(
            RigLensWarning.warnings(rig: try rig("principal_a_25_se_solapa"), own: principal, peer: principal,
                                    calibrated: true), [],
            "girados y calibrados con la principal, nada"
        )
        let distintas = RigLensWarning.warnings(rig: try rig("ultra_a_40"), own: .ultraWide, peer: principal,
                                                calibrated: true)
        XCTAssertEqual(distintas, ["los dos móviles llevan lentes distintas (0,5× y 1×): pon la misma en los dos"])
    }
}
