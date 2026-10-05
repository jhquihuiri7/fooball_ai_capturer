// La salud del otro móvil (IOS-81): líneas temporales puras.

import Foundation
import RigCore
import XCTest

final class PeerHealthTests: XCTestCase {
    private func hb(_ seq: UInt32) -> Heartbeat {
        Heartbeat(isMaster: false, term: 3, ladderLevel: 1, cameraOk: true, recording: true, sendingParts: false,
                  lastHeardSeq: seq)
    }

    /// Dos móviles a 10 Hz: arriba en ≤1 latido; se corta a los 2 s; caído a 500 ms.
    func testCaidaYVueltaEnLosTiemposDelAdr() {
        let h = PeerHealth()
        var cambios: [(Int64, PeerState)] = []
        var ahora: Int64 = 0
        h.onChange = { cambios.append((ahora, $0)) }
        var seq: UInt32 = 0
        for t in stride(from: Int64(0), through: 5000, by: 100) {
            ahora = t
            seq += 1
            h.sent(seq: seq, nowMs: t)
            let cortado = t >= 2000 && t < 3500
            if !cortado { h.heard(hb(seq), nowMs: t + 5) }  // el otro oyó mi último
            h.tick(nowMs: t + 50)
        }
        XCTAssertEqual(cambios.first?.1, .up)
        let caida = cambios.first { $0.1 == .down }!.0
        XCTAssertLessThanOrEqual(caida - 1900, 600, "caído a ≤500 ms del último latido bueno (+ un periodo)")
        XCTAssertTrue(cambios.contains { $0.1 == .suspect })
        let vuelta = cambios.last { $0.1 == .up }!.0
        XCTAssertLessThanOrEqual(vuelta - 3500, 100)
    }

    func testSoloEnUnSentidoNoEstaArriba() {
        let h = PeerHealth()
        // Oigo al otro, pero él dice que ha oído un seq mío viejo (o ninguno).
        for t in stride(from: Int64(0), to: 2000, by: 100) {
            h.sent(seq: UInt32(t / 100 + 1), nowMs: t)
            h.heard(hb(0), nowMs: t)
        }
        XCTAssertEqual(h.state, .down)
        h.sent(seq: 999, nowMs: 2000)
        h.heard(hb(999), nowMs: 2010)
        XCTAssertEqual(h.state, .up)
        h.controlClosed()
        XCTAssertEqual(h.state, .down)
    }

    func testElLatidoVaYVuelve() {
        let x = Heartbeat(isMaster: true, term: 7, ladderLevel: 2, cameraOk: true, recording: false,
                          sendingParts: true, lastHeardSeq: 0xABCD_1234)
        XCTAssertEqual(Heartbeat.decode(x.encode()), x)
        XCTAssertNil(Heartbeat.decode(Data([9])))
    }
}
