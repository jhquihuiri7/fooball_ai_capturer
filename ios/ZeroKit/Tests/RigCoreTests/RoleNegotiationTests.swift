// Quién manda en el soporte (IOS-80, ADR 0023 §7): los casos del ADR y que los dos
// lados, cada uno por su cuenta, lleguen siempre al mismo resultado.

import Foundation
import RigCore
import XCTest

final class RoleNegotiationTests: XCTestCase {
    private func claim(_ side: CameraSide, _ role: RigRole, _ term: Int, _ match: String?, prefers: Bool = false) -> RoleClaim {
        RoleClaim(side: side, role: role, term: term, matchId: match, prefersMaster: prefers)
    }

    private func ambos(_ i: RoleClaim, _ d: RoleClaim) -> (RoleOutcome, RoleOutcome) {
        (RoleNegotiation.negotiate(mine: i, theirs: d), RoleNegotiation.negotiate(mine: d, theirs: i))
    }

    func testElTermMenorAdoptaElMayorYDejaDeMandar() {
        let (izq, der) = ambos(claim(.left, .master, 2, "m1"), claim(.right, .master, 3, "m1"))
        XCTAssertEqual(izq, .resolved(role: .slave, term: 3, matchId: "m1", error: nil))
        XCTAssertEqual(der, .resolved(role: .master, term: 3, matchId: "m1", error: nil))
    }

    func testElDerechoPuedeSerMaestro() {
        let (izq, der) = ambos(claim(.left, .slave, 1, "m1"), claim(.right, .master, 1, "m1"))
        XCTAssertEqual(izq, .resolved(role: .slave, term: 1, matchId: "m1", error: nil))
        XCTAssertEqual(der, .resolved(role: .master, term: 1, matchId: "m1", error: nil))
    }

    func testDosMaestrosConElMismoTermMandaElIzquierdoYSeRegistra() {
        let (izq, der) = ambos(claim(.left, .master, 4, "m1"), claim(.right, .master, 4, "m1"))
        guard case let .resolved(ri, ti, _, ei) = izq, case let .resolved(rd, td, _, ed) = der else {
            return XCTFail("tenía que resolverse")
        }
        XCTAssertEqual([ri, rd], [.master, .slave])
        XCTAssertEqual(ti, td)
        XCTAssertNotNil(ei)
        XCTAssertNotNil(ed)
    }

    func testSinMaestroDecideLaPreferenciaConMaxMasUno() {
        let (izq, der) = ambos(claim(.left, .slave, 2, "m1"), claim(.right, .slave, 2, "m1", prefers: true))
        XCTAssertEqual(izq, .resolved(role: .slave, term: 3, matchId: "m1", error: nil))
        XCTAssertEqual(der, .resolved(role: .master, term: 3, matchId: "m1", error: nil))
    }

    func testDosMaestrosDePartidosDistintosQuedanEnConflicto() {
        let (izq, der) = ambos(claim(.left, .master, 1, "m1"), claim(.right, .master, 5, "m2"))
        XCTAssertEqual(izq, .conflict)
        XCTAssertEqual(der, .conflict)
    }

    func testUnEsclavoSinPartidoAdoptaElDelMaestro() {
        let (izq, der) = ambos(claim(.left, .master, 7, "m9"), claim(.right, .slave, 0, nil, prefers: true))
        XCTAssertEqual(izq, .resolved(role: .master, term: 7, matchId: "m9", error: nil))
        XCTAssertEqual(der, .resolved(role: .slave, term: 7, matchId: "m9", error: nil))
    }

    func testAlEmpezarSinNadaMandaElIzquierdoPorDefecto() {
        let (izq, der) = ambos(claim(.left, .slave, 0, nil), claim(.right, .slave, 0, nil))
        XCTAssertEqual(izq, .resolved(role: .master, term: 1, matchId: nil, error: nil))
        XCTAssertEqual(der, .resolved(role: .slave, term: 1, matchId: nil, error: nil))
    }

    /// Todas las combinaciones: o conflicto en los dos, o exactamente un maestro y el
    /// mismo term y partido en los dos lados. Nunca dos maestros, nunca ninguno.
    func testSiempreUnSoloMaestroYElMismoTerm() {
        let partidos: [String?] = [nil, "m1", "m2"]
        var casos = 0
        for ri in [RigRole.master, .slave] {
            for rd in [RigRole.master, .slave] {
                for ti in 0...3 {
                    for td in 0...3 {
                        for mi in partidos {
                            for md in partidos {
                                for pi in [false, true] {
                                    for pd in [false, true] {
                                        let (a, b) = ambos(claim(.left, ri, ti, mi, prefers: pi), claim(.right, rd, td, md, prefers: pd))
                                        casos += 1
                                        if a == .conflict || b == .conflict {
                                            XCTAssertEqual(a, b, "uno en conflicto y el otro no")
                                            continue
                                        }
                                        guard case let .resolved(ra, ta, ma, _) = a, case let .resolved(rb, tb, mb, _) = b else { continue }
                                        XCTAssertNotEqual(ra, rb, "\(ri) \(ti) \(String(describing: mi)) / \(rd) \(td) \(String(describing: md))")
                                        XCTAssertEqual(ta, tb)
                                        XCTAssertEqual(ma, mb)
                                        // El term es por partido: dentro del mismo no baja nunca.
                                        if mi == md {
                                            XCTAssertGreaterThanOrEqual(ta, max(ti, td), "el term no baja dentro del partido")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(casos, 1000)
    }
}
