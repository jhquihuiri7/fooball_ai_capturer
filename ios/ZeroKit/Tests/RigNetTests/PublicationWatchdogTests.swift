import Network
import XCTest

import RigCore
@testable import RigNet

/// El vigía de la publicación del que publica (2026-10-15). En el EMITIR de las 11:36 los dos
/// iPhone pasaron 5 min buscando: el listener de Wi-Fi Aware en espera no falla ni caduca, y
/// uno publicado al que nadie llega solo se renovaba al caducar (~2 min). Se prueba en el Mac
/// con listeners sin anuncio a los que nadie llega y un plazo corto.
final class PublicationWatchdogTests: XCTestCase {
    func testOnlyAPublicationNobodyReachesIsRedone() {
        typealias T = NWLinkTransport
        XCTAssertTrue(T.publicationIsStuck(inUse: false, arrived: false, ageS: 30, limitS: 30))
        XCTAssertFalse(T.publicationIsStuck(inUse: false, arrived: false, ageS: 29.9, limitS: 30))
        // En uso, con alguien que ya llegó (su conexión manda) o sin plazo (Bonjour), nunca.
        XCTAssertFalse(T.publicationIsStuck(inUse: true, arrived: false, ageS: 99, limitS: 30))
        XCTAssertFalse(T.publicationIsStuck(inUse: false, arrived: true, ageS: 99, limitS: 30))
        XCTAssertFalse(T.publicationIsStuck(inUse: false, arrived: false, ageS: 99, limitS: nil))
        XCTAssertFalse(T.publicationIsStuck(inUse: false, arrived: false, ageS: nil, limitS: 30))
    }

    func testOnlyWiFiAwareRedoesItsPublicationAndWithMargin() {
        XCTAssertNil(BonjourRendezvous(interfaceType: .wiredEthernet).republishAfterS)
        XCTAssertNil(BonjourRendezvous(interfaceType: .wifi).republishAfterS)
        let plazo = WiFiAwareTimings.republishAfterS
        // Más que lo que tarda en llegar el que busca a una cita viva (2,4-6,3 s, y el plazo
        // de su intento), menos que la caducidad (~120 s), y no al ritmo de las suscripciones.
        XCTAssertGreaterThan(plazo, WiFiAwareTimings.connectTimeoutS * 2)
        XCTAssertLessThan(plazo, 60)
        XCTAssertNotEqual(plazo.truncatingRemainder(dividingBy: WiFiAwareTimings.resubscribeAfterS), 0)
    }

    /// Nadie llega: el que publica cambia sus dos citas cada plazo, lo cuenta, lo apunta y el
    /// diagnóstico lo dice. Antes se quedaba con las primeras hasta que caducaran.
    func testAPublicationNobodyReachesIsRedoneOnBothChannels() throws {
        let cita = EmptyRoomRendezvous(republishS: 0.4)
        let publica = NWLinkTransport(mode: .advertise(name: "test", txt: [:]), rendezvous: cita)
        defer { publica.stop() }
        publica.start()
        try waitUntil(cita.listeners(.control) >= 3 && cita.listeners(.media) >= 3)
        XCTAssertGreaterThanOrEqual(publica.statsSnapshot.republishes, 4)
        XCTAssertTrue(publica.events.contains { $0.contains("control: no ha llegado nadie a la cita") })
        XCTAssertTrue(publica.events.contains { $0.contains("medios: no ha llegado nadie a la cita") })
        let d = publica.diagnosis
        XCTAssertEqual(d.role, .publishes)
        XCTAssertGreaterThanOrEqual(d.republishes, 4)
        XCTAssertGreaterThanOrEqual(d.rendezvousOpened, 3)
        XCTAssertEqual(d.report()["republishes"] as? Int, d.republishes)
    }

    /// Bonjour no tiene plazo: su cita no se toca aunque no llegue nadie.
    func testWithoutADeadlineThePublicationIsKept() throws {
        let cita = EmptyRoomRendezvous(republishS: nil)
        let publica = NWLinkTransport(mode: .advertise(name: "test", txt: [:]), rendezvous: cita)
        defer { publica.stop() }
        publica.start()
        usleep(1_200_000)
        XCTAssertEqual(cita.listeners(.control), 1)
        XCTAssertEqual(cita.listeners(.media), 1)
        XCTAssertEqual(publica.statsSnapshot.republishes, 0)
    }

    /// Un listener de medios que no se puede crear se reintenta, aunque la cita no dé plazo
    /// (antes se quedaba sin medios toda la pasada).
    func testAMediaListenerThatCouldNotBeCreatedIsRetried() throws {
        let cita = EmptyRoomRendezvous(republishS: nil, failMediaTimes: 1)
        let publica = NWLinkTransport(mode: .advertise(name: "test", txt: [:]), rendezvous: cita)
        defer { publica.stop() }
        publica.start()
        try waitUntil(cita.listeners(.media) >= 2)
        XCTAssertTrue(publica.events.contains { $0.contains("medios sin listener") })
    }

    private func waitUntil(_ condicion: @autoclosure () -> Bool, timeoutS: Double = 10,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let tope = Date().addingTimeInterval(timeoutS)
        while !condicion() {
            guard Date() < tope else {
                XCTFail("no se cumplió en \(timeoutS) s", file: file, line: line)
                throw Timeout()
            }
            usleep(20_000)
        }
    }

    private struct Timeout: Error {}
}

/// Una cita de prueba que publica listeners sin anuncio en el loopback, a los que nadie llega
/// (como una cita de Wi-Fi Aware que nadie ve), y cuenta los que se le piden por canal.
private final class EmptyRoomRendezvous: LinkRendezvous {
    private let plazo: Double?
    private let cerrojo = NSLock()
    private var pedidos: [LinkChannel: Int] = [:]
    private var fallosMedios: Int

    init(republishS: Double?, failMediaTimes: Int = 0) {
        plazo = republishS
        fallosMedios = failMediaTimes
    }

    func listeners(_ canal: LinkChannel) -> Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return pedidos[canal, default: 0]
    }

    var label: String { "empty-room-test" }
    var staleDatapathS: Double? { nil }

    var republishAfterS: Double? { plazo }

    func parameters(for channel: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: channel)
    }

    func makeListener(for channel: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        cerrojo.lock(); pedidos[channel, default: 0] += 1
        let falla = channel == .media && fallosMedios > 0
        if falla { fallosMedios -= 1 }
        cerrojo.unlock()
        if falla { throw WiFiAwareLinkError.unsupported }
        return try NWListener(using: parameters(for: channel))
    }

    func makeBrowser(for _: LinkChannel) throws -> NWBrowser {
        throw WiFiAwareLinkError.unsupported
    }
}
