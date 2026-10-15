import Foundation
import XCTest

import RigCore
@testable import RigNet

/// «Una cámara (sin pareja)», 2026-10-15: la sesión que dirige sola, sin transporte.
final class SoloLinkTests: XCTestCase {
    /// Un transporte que cuenta lo que se le pide, para ver que la sesión sola no lo toca.
    final class SpyTransport: LinkTransport {
        var onFrame: ((LinkFrame, LinkChannel) -> Void)?
        var onState: ((LinkTransportState) -> Void)?
        var onPath: ((String) -> Void)?
        let state: LinkTransportState = .idle
        let stats = LinkTransportStats()
        private(set) var starts = 0
        private(set) var sent = 0

        func start() { starts += 1 }
        func stop() {}
        func send(_: LinkFrame, on _: LinkChannel) { sent += 1 }
    }

    /// Espera a que la cola de la sesión haya hecho lo que tenía pendiente.
    private func drain(_ queue: DispatchQueue) {
        queue.sync {}
    }

    func testElDerechoSoloDirigeDesdeElPrimerInstante() {
        let sesion = RigLinkSession.alone(side: .right, deviceId: "iPhone", appVersion: "1")
        let rol = expectation(description: "rol")
        var visto: (RigRole, Int, String?)?
        sesion.onRole = { r, t, p in
            visto = (r, t, p)
            rol.fulfill()
        }
        XCTAssertFalse(sesion.isMaster, "el derecho, antes de arrancar, sería esclavo")
        sesion.startAlone()
        wait(for: [rol], timeout: 2)
        XCTAssertEqual(visto?.0, .master)
        XCTAssertEqual(visto?.1, 0)
        XCTAssertNil(visto?.2)
        XCTAssertTrue(sesion.isMaster)
        XCTAssertEqual(sesion.state, .off, "no busca a nadie")
        XCTAssertEqual(sesion.clock.offsetAt(ns: 123_456_789), 0, "su reloj es el del soporte")
    }

    func testNoAbreElTransporteNiMandaNada() {
        let cola = DispatchQueue(label: "solo")
        let espia = SpyTransport()
        let sesion = RigLinkSession(transport: espia, secret: Data(), side: .left, deviceId: "iPhone",
                                    appVersion: "1", queue: cola)
        sesion.startAlone()
        drain(cola)
        let vista = ViewCommand(
            targetRigMs: 0, viewId: 0, yawRad: 0, pitchRad: 0, hfovRad: 1, sides: [.left], seamYawRad: 0,
            featherRad: 0, gains: .unity
        )
        sesion.send(views: [vista])
        sesion.send(command: .record)
        sesion.send(cadence: CadenceCommand(level: .l1))
        sesion.send(replica: Data("{}".utf8))
        drain(cola)
        XCTAssertEqual(espia.starts, 0, "ni escucha ni conecta")
        XCTAssertEqual(espia.sent, 0, "sin sesión conectada no sale nada")
        XCTAssertTrue(sesion.isMaster)
        sesion.stop()
        drain(cola)
        XCTAssertEqual(sesion.state, .off)
    }

    func testElTransporteVacioNoHaceNada() {
        let t = NoLinkTransport()
        var estados: [LinkTransportState] = []
        t.onState = { estados.append($0) }
        t.start()
        t.send(LinkFrame(type: .heartbeat, session: 0, seq: 1, rigMs: 0, payload: Data()), on: .media)
        t.stop()
        XCTAssertEqual(t.state, .idle)
        XCTAssertEqual(t.stats, LinkTransportStats())
        XCTAssertTrue(estados.isEmpty)
    }
}
