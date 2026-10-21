import Network
import XCTest

import RigCore
@testable import RigNet

/// Lo que el móvil dice de su enlace en el latido y el informe (2026-10-15): en el plan B
/// de la cancha el esclavo no enlazó en 10 min y nada de lo que dejó decía por qué.
final class LinkDiagnosisTests: XCTestCase {
    private typealias D = LinkDiagnosis

    func testTheSentenceForEachWayOfNotHavingALink() {
        // El esclavo del plan B: nada a la vista en 10 min, con la suscripción rehecha.
        XCTAssertEqual(
            D(role: .searches, medium: "aware", state: .connecting, rendezvousReady: true, rendezvousOpened: 31,
              resubscribes: 30, withoutLinkS: 600).summary(),
            "no ve al otro en 600 s (31 citas, 30 rehechas)"
        )
        XCTAssertEqual(
            D(role: .searches, medium: "aware", state: .connecting, rendezvousOpened: 1, withoutLinkS: 20).summary(),
            "no ve al otro en 20 s (1 citas, 0 rehechas, la última sin estar lista)"
        )
        // La suscripción en espera (lo que Wi-Fi Aware da con la interfaz caída).
        XCTAssertEqual(
            D(role: .searches, medium: "aware", state: .connecting, waiting: "POSIXErrorCode(rawValue: 50): Network is down",
              rendezvousOpened: 2, resubscribes: 1).summary(),
            "la suscripción espera: POSIXErrorCode(rawValue: 50): Network is down (2 citas, 1 rehechas)"
        )
        // Lo ve, pero el datapath no sube (la pasada de las 08:39: tres intentos de 10 s).
        XCTAssertEqual(
            D(role: .searches, medium: "aware", state: .connecting, lastDrop: "sin respuesta en 10 s",
              announcements: 1, controlAttempts: 3).summary(),
            "ve al otro pero no conecta: 3 intentos; el último: sin respuesta en 10 s"
        )
        XCTAssertEqual(D(role: .searches, medium: "aware", state: .connecting, announcements: 1).summary(),
                       "ve al otro; conectando")
        // El maestro: publicando y sin nadie, o con conexiones que no siguen.
        XCTAssertEqual(
            D(role: .publishes, medium: "aware", state: .listening, rendezvousReady: true, rendezvousOpened: 21,
              republishes: 20, withoutLinkS: 600).summary(),
            "publicando; no ha llegado nadie en 600 s (21 citas, 20 rehechas)"
        )
        XCTAssertEqual(
            D(role: .publishes, medium: "aware", state: .listening, lastDrop: "silencio de 3.2 s", rendezvousReady: true,
              controlAttempts: 2).summary(),
            "llegaron 2 conexiones y no sigue ninguna; la última: silencio de 3.2 s"
        )
        XCTAssertEqual(
            D(role: .publishes, medium: "aware", state: .listening, waiting: "Device not configured",
              rendezvousOpened: 3, republishes: 2).summary(),
            "la cita no se publica: Device not configured (3 citas, 2 rehechas)"
        )
        XCTAssertEqual(D(role: .searches, medium: "aware", state: .failed("sin entitlement")).summary(),
                       "la cita falló: sin entitlement; se reintenta")
    }

    /// Bug B (2026-10-21): en la pausa del borrón, el que busca dice que es a propósito,
    /// cuánto le queda y por qué cayó lo último; el informe lleva las cifras.
    func testTheSearcherSaysItIsPausingOnPurpose() {
        let d = D(role: .searches, medium: "aware", state: .connecting, lastDrop: "sin respuesta en 10 s",
                  announcements: 0, controlAttempts: 3, failedAttempts: 0, searchResets: 1, quietS: 59.2)
        XCTAssertEqual(d.summary(),
                       "en pausa 60 s más para que Wi-Fi Aware suelte el enlace viejo (borrón 1; la última caída: sin respuesta en 10 s)")
        let r = d.report()
        XCTAssertEqual(r["search_resets"] as? Int, 1)
        XCTAssertEqual(r["failed_attempts"] as? Int, 0)
        XCTAssertEqual(r["quiet_s"] as? Double, 59.2)
        XCTAssertEqual(D(role: .searches, medium: "aware", state: .connecting).report()["quiet_s"] as? Double, -1)
        // Sin pausa, la frase de siempre.
        XCTAssertEqual(D(role: .searches, medium: "aware", state: .connecting, lastDrop: "sin respuesta en 10 s",
                         announcements: 1, controlAttempts: 2, failedAttempts: 2, searchResets: 1).summary(),
                       "ve al otro pero no conecta: 2 intentos; el último: sin respuesta en 10 s")
    }

    func testWithTheControlUpTheSessionSays() {
        let arriba = D(role: .publishes, medium: "aware", state: .connected, controlAttempts: 1)
        XCTAssertEqual(arriba.summary(), "enlace arriba")
        XCTAssertEqual(arriba.summary(session: .connected(peer: "iPhone")), "enlace arriba")
        XCTAssertEqual(arriba.summary(session: .rejected("tag inválido")), "control arriba, la sesión no: rechazada: tag inválido")
        XCTAssertEqual(arriba.summary(session: .authenticating), "control arriba, la sesión no: autenticando")
    }

    func testTheReportCarriesTheSentenceAndTheNumbers() {
        let d = D(role: .searches, medium: "aware", state: .connecting, waiting: nil, rendezvousOpened: 3,
                  resubscribes: 2, withoutLinkS: 45)
        let r = d.report(session: .searching)
        XCTAssertEqual(r["summary"] as? String, d.summary(session: .searching))
        XCTAssertEqual(r["role"] as? String, "busca")
        XCTAssertEqual(r["state"] as? String, "buscando")
        XCTAssertEqual(r["session"] as? String, "buscando")
        XCTAssertEqual(r["resubscribes"] as? Int, 2)
        XCTAssertEqual(r["without_link_s"] as? Double, 45)
        XCTAssertEqual(D(role: .publishes, medium: "wifi", state: .connected).report()["without_link_s"] as? Double, -1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
    }

    /// Del transporte de verdad, por el loopback: el que escucha solo dice que publica y
    /// que no ha llegado nadie; con el otro conectado, que el enlace está arriba, con un
    /// intento en cada lado.
    func testTheTransportFillsItIn() throws {
        let escucha = NWLinkTransport(mode: .listen(port: 0), interfaceType: nil)
        defer { escucha.stop() }
        let listo = expectation(description: "puerto")
        listo.assertForOverFulfill = false
        nonisolated(unsafe) var puerto: UInt16 = 0
        escucha.onReady = { p in
            puerto = p
            listo.fulfill()
        }
        escucha.start()
        wait(for: [listo], timeout: 10)
        let sola = escucha.diagnosis
        XCTAssertEqual(sola.role, .publishes)
        XCTAssertTrue(sola.rendezvousReady)
        XCTAssertEqual(sola.rendezvousOpened, 1)
        XCTAssertTrue(sola.summary().hasPrefix("publicando; no ha llegado nadie en"), sola.summary())

        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil)
        defer { conecta.stop() }
        let conectado = expectation(description: "conectado")
        conectado.assertForOverFulfill = false
        conecta.onState = { if $0 == .connected { conectado.fulfill() } }
        conecta.start()
        wait(for: [conectado], timeout: 10)
        let tope = Date().addingTimeInterval(10)
        while escucha.diagnosis.state != .connected, Date() < tope { usleep(10_000) }
        XCTAssertEqual(escucha.diagnosis.summary(), "enlace arriba")
        XCTAssertNil(escucha.diagnosis.withoutLinkS)
        XCTAssertEqual(escucha.diagnosis.controlAttempts, 1)
        XCTAssertEqual(conecta.diagnosis.role, .searches)
        XCTAssertEqual(conecta.diagnosis.controlAttempts, 1)
        XCTAssertTrue(escucha.events.contains { $0.contains("control: llega una conexión") })
    }
}
