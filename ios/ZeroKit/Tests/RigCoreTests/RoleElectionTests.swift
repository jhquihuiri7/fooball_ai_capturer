// La elección de roles con terms (IOS-83): líneas temporales y particiones simuladas.

import Foundation
import RigCore
import XCTest

final class RoleElectionTests: XCTestCase {
    func testElEsclavoSePromueveConLasTresCondiciones() {
        let e = RoleElection(role: .slave, term: 3)
        func s(_ t: Int64, welcome: Bool = true, lost: Int64? = 0) -> RoleElection.Situation {
            .init(nowMs: t, linkDownSinceMs: 0, tunnelWelcome: welcome, masterLostSinceMs: lost)
        }
        XCTAssertFalse(e.evaluate(s(1999)), "enlace caído <2 s")
        XCTAssertFalse(e.evaluate(s(6000, welcome: false)), "sin túnel no hay promoción automática")
        XCTAssertFalse(e.evaluate(s(6000, lost: nil)), "el hub no dice que el maestro se perdió")
        XCTAssertFalse(e.evaluate(s(4999)), "el hub lo dice desde hace <5 s")
        XCTAssertTrue(e.evaluate(s(5000)))
        XCTAssertEqual(e.role, .master); XCTAssertEqual(e.term, 4)
        XCTAssertFalse(e.evaluate(s(9000)), "ya es maestro")
    }

    func testElOperadorFuerzaSinVps() {
        let e = RoleElection(role: .slave, term: 1)
        XCTAssertTrue(e.evaluate(.init(nowMs: 10, linkDownSinceMs: nil, tunnelWelcome: false,
                                       masterLostSinceMs: nil, operatorForce: true)))
        XCTAssertEqual(e.term, 2)
    }

    func testElAntiguoMaestroVeElTermMayorYSeDegrada() {
        let viejo = RoleElection(role: .master, term: 4)
        XCTAssertFalse(viejo.observe(peerTerm: 4, peerIsMaster: true))
        XCTAssertTrue(viejo.observe(peerTerm: 5, peerIsMaster: true))
        XCTAssertEqual(viejo.role, .slave); XCTAssertEqual(viejo.term, 5)
        let otro = RoleElection(role: .master, term: 2)
        otro.evicted(byTerm: 3)
        XCTAssertEqual(otro.role, .slave); XCTAssertEqual(otro.term, 3)
    }

    func testElCercadoDelSrt() {
        let m = RoleElection(role: .master, term: 1)
        XCTAssertTrue(m.mayPublish(nowMs: 10_000, linkDownSinceMs: nil, hadSlave: true, welcomeAtMs: nil))
        XCTAssertTrue(m.mayPublish(nowMs: 10_000, linkDownSinceMs: 9500, hadSlave: true, welcomeAtMs: nil),
                      "caído <LINK_FENCE_MS: sin más")
        XCTAssertFalse(m.mayPublish(nowMs: 10_000, linkDownSinceMs: 8000, hadSlave: true, welcomeAtMs: 7000),
                       "el welcome es de antes de la caída")
        XCTAssertTrue(m.mayPublish(nowMs: 10_000, linkDownSinceMs: 8000, hadSlave: true, welcomeAtMs: 8500))
        XCTAssertTrue(m.mayPublish(nowMs: 10_000, linkDownSinceMs: 8000, hadSlave: false, welcomeAtMs: nil),
                      "sin esclavo en el partido no hay a quién temer")
    }

    /// Particiones al azar entre maestro, esclavo y hub durante 10 min: en ningún instante
    /// hay dos publicadores con el mismo term, y quien publica tiene el term más alto que
    /// el hub ha aceptado.
    func testEnTodasLasParticionesComoMuchoUnPublicadorPorTerm() {
        var azar = SplitMix(seed: 83)
        var promociones = 0
        for _ in 0..<200 {
            let a = RoleElection(role: .master, term: 1)
            let b = RoleElection(role: .slave, term: 1)
            var hubTerm = 1  // el term que el hub acepta (el último que se le presentó)
            var enlaceCaidoDesde: Int64?
            var aConHubDesde: Int64? = 0, bConHubDesde: Int64? = 0
            var aWelcome: Int64? = 0
            var maestroPerdidoDesde: Int64?
            for paso in 0..<600 {
                let t = Int64(paso) * 1000
                // Cada segundo, con cierta probabilidad, cambia la red.
                if azar.unit() < 0.05 { enlaceCaidoDesde = enlaceCaidoDesde == nil ? t : nil }
                if azar.unit() < 0.03 { aConHubDesde = aConHubDesde == nil ? t : nil; if aConHubDesde != nil { aWelcome = t } }
                if azar.unit() < 0.03 { bConHubDesde = bConHubDesde == nil ? t : nil }
                // El hub pierde al maestro A si A no tiene túnel.
                if aConHubDesde == nil, a.role == .master { maestroPerdidoDesde = maestroPerdidoDesde ?? t } else { maestroPerdidoDesde = nil }
                // Con enlace, se ven los terms.
                if enlaceCaidoDesde == nil {
                    a.observe(peerTerm: b.term, peerIsMaster: b.role == .master)
                    b.observe(peerTerm: a.term, peerIsMaster: a.role == .master)
                }
                // B decide.
                if b.evaluate(.init(nowMs: t, linkDownSinceMs: enlaceCaidoDesde, tunnelWelcome: bConHubDesde != nil,
                                    masterLostSinceMs: maestroPerdidoDesde)) {
                    promociones += 1
                    if bConHubDesde != nil { hubTerm = max(hubTerm, b.term) }
                }
                // El hub echa al maestro de term menor que se presente.
                if aConHubDesde != nil, a.role == .master, a.term < hubTerm { a.evicted(byTerm: hubTerm) }
                // Quién publica: el maestro que el cercado deja y con túnel (el SRT va al VPS).
                var publicadores: [Int] = []
                if aConHubDesde != nil, a.mayPublish(nowMs: t, linkDownSinceMs: enlaceCaidoDesde, hadSlave: true, welcomeAtMs: aWelcome) {
                    publicadores.append(a.term)
                }
                if bConHubDesde != nil, b.mayPublish(nowMs: t, linkDownSinceMs: enlaceCaidoDesde, hadSlave: true, welcomeAtMs: bConHubDesde) {
                    publicadores.append(b.term)
                }
                XCTAssertEqual(Set(publicadores).count, publicadores.count, "dos publicadores con el mismo term")
                if publicadores.count == 2 {
                    // Dos a la vez solo con terms distintos, y el hub se queda con el mayor:
                    // el de menor term recibe 4409 en este mismo paso.
                    XCTAssertEqual(publicadores.max(), hubTerm)
                }
            }
        }
        XCTAssertGreaterThan(promociones, 20, "la simulación tiene que promover de verdad")
    }
}
