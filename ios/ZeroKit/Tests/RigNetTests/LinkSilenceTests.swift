import Network
import XCTest

import RigCore
@testable import RigNet

/// El vigía de silencio (IOS-14c): por Wi-Fi Aware, si el datapath muere nada avisa y el
/// TCP tarda decenas de segundos en rendirse. Con la cita que da plazo, un enlace arriba
/// cuyos medios callan se tira entero (control y medios) y se vuelve a montar. Sin plazo
/// (Bonjour) no cambia nada. Se prueba por el loopback con un plazo corto.
final class LinkSilenceTests: XCTestCase {
    private let tag = Data(repeating: 8, count: LinkFrame.tagLength)

    private func latido(_ seq: UInt32) -> LinkFrame {
        LinkFrame(type: .heartbeat, session: 3, seq: seq, rigMs: 0, payload: Data([1]), tag: tag)
    }

    func testTheWatchdogOnlyFiresOnALiveLinkThatWentSilent() {
        typealias T = NWLinkTransport
        XCTAssertTrue(T.linkIsDead(connected: true, peerMediaSinceConnect: true, silentS: 3.1, limitS: 3))
        XCTAssertFalse(T.linkIsDead(connected: true, peerMediaSinceConnect: true, silentS: 2.9, limitS: 3))
        // Sin plazo (Bonjour), sin conexión o sin medios desde que subió el control (el
        // apretón de manos, un conflicto de roles), nunca.
        XCTAssertFalse(T.linkIsDead(connected: true, peerMediaSinceConnect: true, silentS: 99, limitS: nil))
        XCTAssertFalse(T.linkIsDead(connected: false, peerMediaSinceConnect: true, silentS: 99, limitS: 3))
        XCTAssertFalse(T.linkIsDead(connected: true, peerMediaSinceConnect: false, silentS: 99, limitS: 3))
    }

    func testOnlyWiFiAwareHasAWatchdogAndALongerConnectTimeout() {
        let bonjour = BonjourRendezvous(interfaceType: .wiredEthernet)
        XCTAssertNil(bonjour.silenceTimeoutS)
        XCTAssertEqual(bonjour.connectTimeoutS, NWLinkTransport.controlConnectTimeoutS)
        // El control por Wi-Fi Aware tardó hasta 6,3 s en quedar listo (2026-10-08): el
        // plazo tiene que dejarle acabar.
        XCTAssertGreaterThan(WiFiAwareTimings.connectTimeoutS, 6.3)
        // El vigía no salta por un parón corto: al menos 10 latidos perdidos y más que
        // HEARTBEAT_LOSS_MS, y no más de 3 s (lo que se pide para volver en segundos).
        let silencio = WiFiAwareTimings.silenceTimeoutS
        XCTAssertGreaterThanOrEqual(silencio * LinkConstants.heartbeatHz, 10)
        XCTAssertGreaterThan(silencio * 1000, Double(LinkConstants.heartbeatLossMs))
        XCTAssertLessThanOrEqual(silencio, 3)
    }

    /// Los dos lados se oyen por medios y de pronto callan: el vigía tira el enlace, el
    /// que conecta vuelve solo y los medios vuelven a pasar por la conexión nueva.
    func testASilentLinkIsDroppedAndRebuilt() throws {
        let (escucha, conecta) = try makePair(silenceS: 0.5)
        defer {
            escucha.stop()
            conecta.stop()
        }
        let estados = Counter()
        let primera = expectation(description: "primera conexión")
        let segunda = expectation(description: "conexión rehecha")
        conecta.onState = { estado in
            guard estado == .connected else { return }
            switch estados.increment() {
            case 1: primera.fulfill()
            case 2: segunda.fulfill()
            default: break
            }
        }
        conecta.start()
        wait(for: [primera], timeout: 10)
        try waitUntil(escucha.state == .connected)

        // Medios en los dos sentidos hasta que los dos han oído al otro: el vigía se arma.
        var seq: UInt32 = 0
        try waitUntil({
            seq += 1
            conecta.send(latido(seq), on: .media)
            escucha.send(latido(seq), on: .media)
            usleep(50_000)
            return conecta.stats.mediaFramesReceived > 0 && escucha.stats.mediaFramesReceived > 0
        }())

        // Y callan: en ~0,5-0,7 s el vigía lo tira y el que conecta vuelve a conectar.
        wait(for: [segunda], timeout: 10)
        XCTAssertGreaterThanOrEqual(escucha.stats.silenceDrops + conecta.stats.silenceDrops, 1)
        XCTAssertGreaterThanOrEqual(conecta.stats.reconnects, 1)
        XCTAssertTrue((escucha.events + conecta.events).contains { $0.contains("silencio") })

        // Los medios se rehicieron con el control: lo que manda el que conecta llega.
        let antes = escucha.stats.mediaFramesReceived
        try waitUntil({
            seq += 1
            conecta.send(latido(seq), on: .media)
            usleep(50_000)
            return escucha.stats.mediaFramesReceived > antes
        }())
    }

    /// Sin medios desde que subió el control (el apretón de manos o un conflicto de
    /// roles), el vigía no tira nada aunque pase el plazo.
    func testNoMediaSinceConnectNeverTripsTheWatchdog() throws {
        let (escucha, conecta) = try makePair(silenceS: 0.3)
        defer {
            escucha.stop()
            conecta.stop()
        }
        let conectado = expectation(description: "conectado")
        conectado.assertForOverFulfill = false
        conecta.onState = { if $0 == .connected { conectado.fulfill() } }
        conecta.start()
        wait(for: [conectado], timeout: 10)
        try waitUntil(escucha.state == .connected)

        usleep(1_500_000)  // cinco plazos
        XCTAssertEqual(escucha.stats.silenceDrops + conecta.stats.silenceDrops, 0)
        XCTAssertEqual(conecta.stats.reconnects, 0)
        XCTAssertEqual(conecta.state, .connected)
    }

    // MARK: - Ayudas

    /// Uno que escucha en un puerto efímero del loopback (ya arrancado) y otro que
    /// conecta a él (sin arrancar), los dos con la cita de plazo corto.
    private func makePair(silenceS: Double) throws -> (NWLinkTransport, NWLinkTransport) {
        let cita = SilenceRendezvous(silenceS: silenceS)
        let escucha = NWLinkTransport(mode: .listen(port: 0), rendezvous: cita)
        let listo = expectation(description: "puerto")
        listo.assertForOverFulfill = false
        nonisolated(unsafe) var puerto: UInt16 = 0
        escucha.onReady = { p in
            puerto = p
            listo.fulfill()
        }
        escucha.start()
        wait(for: [listo], timeout: 10)
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), rendezvous: cita)
        return (escucha, conecta)
    }

    private func waitUntil(_ condicion: @autoclosure () -> Bool, timeoutS: Double = 10,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let tope = Date().addingTimeInterval(timeoutS)
        while !condicion() {
            guard Date() < tope else {
                XCTFail("no se cumplió en \(timeoutS) s", file: file, line: line)
                throw Timeout()
            }
            usleep(10_000)
        }
    }

    /// Sin la condición no tiene sentido seguir con el test.
    private struct Timeout: Error {}
}

/// Una cita de prueba por el loopback con vigía de silencio, como Wi-Fi Aware pero con un
/// plazo corto. En los modos `.listen` y `.connect` no se anuncia ni se busca nada.
private struct SilenceRendezvous: LinkRendezvous {
    let silenceS: Double

    var label: String { "silence-test" }

    var silenceTimeoutS: Double? { silenceS }

    func parameters(for channel: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: channel)
    }

    func makeListener(for _: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        throw WiFiAwareLinkError.unsupported
    }

    func makeBrowser(for _: LinkChannel) throws -> NWBrowser {
        throw WiFiAwareLinkError.unsupported
    }
}

/// Un contador para los estados, que llegan por la cola del transporte.
private final class Counter: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var n = 0

    func increment() -> Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        n += 1
        return n
    }
}
