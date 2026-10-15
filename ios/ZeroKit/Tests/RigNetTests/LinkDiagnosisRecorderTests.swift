import XCTest

import RigCore
@testable import RigNet

/// El diagnóstico del enlace en un fichero desde que se abre (2026-10-15): en el EMITIR de las
/// 11:36 los dos pasaron 5 min buscando y no quedó nada que dijera por qué.
final class LinkDiagnosisRecorderTests: XCTestCase {
    func testWritesWhileSearchingOnceWhenLinkedAndAgainAfterADrop() throws {
        XCTAssertTrue(LinkDiagnosisRecorder.shouldWrite(linked: false, lastWrittenLinked: nil))
        XCTAssertTrue(LinkDiagnosisRecorder.shouldWrite(linked: false, lastWrittenLinked: true))
        XCTAssertTrue(LinkDiagnosisRecorder.shouldWrite(linked: true, lastWrittenLinked: false))
        XCTAssertFalse(LinkDiagnosisRecorder.shouldWrite(linked: true, lastWrittenLinked: true))
        XCTAssertEqual(LinkDiagnosisRecorder.fileName(side: "left", startUnixS: 1_792_085_800),
                       "link-diag-left-1792085800.json")
    }

    func testTheFileSaysWhyThereIsNoLinkAndWhenItCameUp() throws {
        var ahora: UInt64 = 0
        var sesion = RigLinkSession.State.searching
        var transporte = LinkTransportState.listening
        var escrito: [[String: Any]] = []
        var frases: [String] = []
        let r = LinkDiagnosisRecorder(
            side: "left", startUnixMs: 1_792_085_800_000,
            sample: {
                var stats = LinkTransportStats()
                stats.republishes = 2
                return .init(
                    diagnosis: LinkDiagnosis(role: .publishes, medium: "aware", state: transporte, rendezvousReady: true,
                                             rendezvousOpened: 3, republishes: 2, withoutLinkS: Double(ahora) / 1e9),
                    session: sesion, events: ["0.1 cita de control publicada"], stats: stats
                )
            },
            write: { datos in
                escrito.append((try? JSONSerialization.jsonObject(with: datos)) as? [String: Any] ?? [:])
            },
            nowNs: { ahora }
        )
        r.onSummary = { frases.append($0) }
        ahora = 10_000_000_000
        XCTAssertTrue(r.tick())
        ahora = 20_000_000_000
        XCTAssertTrue(r.tick())
        XCTAssertEqual(escrito.count, 2)
        let buscando = escrito[1]
        XCTAssertEqual(buscando["linked"] as? Bool, false)
        XCTAssertNil(buscando["linked_after_s"])
        XCTAssertEqual(buscando["summary"] as? String, "publicando; no ha llegado nadie en 20 s (3 citas, 2 rehechas)")
        XCTAssertEqual(buscando["transport_events"] as? [String], ["0.1 cita de control publicada"])
        XCTAssertEqual((buscando["stats"] as? [String: Any])?["republishes"] as? Int, 2)
        XCTAssertEqual((buscando["link"] as? [String: Any])?["role"] as? String, "publica")
        XCTAssertEqual(frases.last, "publicando; no ha llegado nadie en 20 s (3 citas, 2 rehechas)")

        // Enlaza: una escritura que lo dice, y ya no más mientras siga.
        ahora = 30_000_000_000
        sesion = .connected(peer: "derecho")
        transporte = .connected
        XCTAssertTrue(r.tick())
        ahora = 40_000_000_000
        XCTAssertFalse(r.tick())
        XCTAssertEqual(escrito.count, 3)
        XCTAssertEqual(escrito[2]["linked"] as? Bool, true)
        XCTAssertEqual(escrito[2]["linked_after_s"] as? Double, 30)
        XCTAssertEqual(escrito[2]["summary"] as? String, "enlace arriba")
        XCTAssertEqual(frases.count, 2, "con enlace no se pisa la fila Enlace")

        // Se cae: vuelve a escribir y cuenta la caída.
        ahora = 50_000_000_000
        sesion = .searching
        transporte = .listening
        XCTAssertTrue(r.tick())
        XCTAssertEqual(escrito.last?["drops_seen"] as? Int, 1)
        XCTAssertEqual(escrito.last?["linked_after_s"] as? Double, 30)
        // Al cerrar se escribe una última vez.
        r.stop()
        XCTAssertEqual(escrito.count, 5)
    }
}
