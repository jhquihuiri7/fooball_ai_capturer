import Network
import XCTest

import RigCore
@testable import RigNet

/// El vigía de la suscripción del que busca (2026-10-15). En el plan B de la cancha
/// (`bench/partido-20261015-0902`) el esclavo no enlazó en 10 min mientras el maestro
/// volvía a publicar seis veces: su suscripción solo se rehacía al fallar un intento de
/// conexión o al caducar, y una de Wi-Fi Aware en espera («Network is down») o que no ve
/// nada no hace ninguna de las dos cosas. Se prueba en el Mac con browsers de Bonjour de un
/// tipo que nadie anuncia y un plazo corto.
final class SubscriptionWatchdogTests: XCTestCase {
    func testOnlyAStuckSearchIsRedone() {
        typealias T = NWLinkTransport
        XCTAssertTrue(T.subscriptionIsStuck(searching: true, attemptInFlight: false, ageS: 20, limitS: 20))
        XCTAssertFalse(T.subscriptionIsStuck(searching: true, attemptInFlight: false, ageS: 19.9, limitS: 20))
        // Con el enlace arriba, con un intento en marcha (cada uno que falla ya abre otra
        // suscripción) o sin plazo (Bonjour), nunca.
        XCTAssertFalse(T.subscriptionIsStuck(searching: false, attemptInFlight: false, ageS: 99, limitS: 20))
        XCTAssertFalse(T.subscriptionIsStuck(searching: true, attemptInFlight: true, ageS: 99, limitS: 20))
        XCTAssertFalse(T.subscriptionIsStuck(searching: true, attemptInFlight: false, ageS: 99, limitS: nil))
        XCTAssertFalse(T.subscriptionIsStuck(searching: true, attemptInFlight: false, ageS: nil, limitS: 20))
    }

    func testOnlyWiFiAwareRedoesItsSubscriptionAndWithMargin() {
        XCTAssertNil(BonjourRendezvous(interfaceType: .wiredEthernet).resubscribeAfterS)
        XCTAssertNil(BonjourRendezvous(interfaceType: .wifi).resubscribeAfterS)
        // Una suscripción viva ve el anuncio en ~0,5 s (2026-10-15) y ~1 s tras una caída
        // (2026-10-08): el plazo deja de sobra. Y es más corto que la caducidad de la cita
        // (~120 s), que hasta ahora era lo único que la cambiaba si no fallaba.
        let plazo = WiFiAwareTimings.resubscribeAfterS
        XCTAssertGreaterThanOrEqual(plazo, 10)
        XCTAssertLessThan(plazo, 60)
        XCTAssertGreaterThan(plazo, WiFiAwareTimings.connectTimeoutS)
    }

    /// Nadie anuncia: el que busca cambia sus dos suscripciones cada plazo, lo cuenta y lo
    /// apunta en la línea de tiempo. Antes se quedaba con las primeras toda la pasada.
    func testASearchThatFindsNobodyIsRedoneOnBothChannels() throws {
        let cita = NobodyRendezvous(resubscribeS: 0.4)
        let busca = NWLinkTransport(mode: .browse, rendezvous: cita)
        defer { busca.stop() }
        busca.start()
        try waitUntil(cita.browsers(.control) >= 3 && cita.browsers(.media) >= 3)
        XCTAssertGreaterThanOrEqual(busca.statsSnapshot.resubscribes, 4)
        XCTAssertTrue(busca.events.contains { $0.contains("control: la suscripción no ha dado con nadie") })
        XCTAssertTrue(busca.events.contains { $0.contains("medios: la suscripción no ha dado con nadie") })
        XCTAssertEqual(busca.state, .connecting)
    }

    /// Bonjour no tiene plazo: su suscripción no se toca aunque no vea a nadie.
    func testWithoutADeadlineTheSubscriptionIsKept() throws {
        let cita = NobodyRendezvous(resubscribeS: nil)
        let busca = NWLinkTransport(mode: .browse, rendezvous: cita)
        defer { busca.stop() }
        busca.start()
        usleep(1_200_000)
        XCTAssertEqual(cita.browsers(.control), 1)
        XCTAssertEqual(cita.browsers(.media), 1)
        XCTAssertEqual(busca.statsSnapshot.resubscribes, 0)
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

/// Una cita de prueba que busca un tipo de Bonjour que nadie anuncia (como una suscripción
/// de Wi-Fi Aware que no ve nada) y cuenta los browsers que se le piden por canal.
private final class NobodyRendezvous: LinkRendezvous {
    private let plazo: Double?
    private let cerrojo = NSLock()
    private var pedidos: [LinkChannel: Int] = [:]

    init(resubscribeS: Double?) { plazo = resubscribeS }

    func browsers(_ canal: LinkChannel) -> Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return pedidos[canal, default: 0]
    }

    var label: String { "nobody-test" }

    var resubscribeAfterS: Double? { plazo }

    func parameters(for channel: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: channel)
    }

    func makeListener(for _: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        throw WiFiAwareLinkError.unsupported
    }

    func makeBrowser(for channel: LinkChannel) throws -> NWBrowser {
        cerrojo.lock(); pedidos[channel, default: 0] += 1; cerrojo.unlock()
        let tipo = channel == .control ? "_zknadie._tcp" : "_zknadie._udp"
        return NWBrowser(for: .bonjour(type: tipo, domain: nil), using: parameters(for: channel))
    }
}
