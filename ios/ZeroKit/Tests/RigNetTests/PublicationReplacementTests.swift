import Network
import XCTest

import RigCore
@testable import RigNet

/// Bug B (2026-10-21): el que publica no deja nunca dos citas vivas del mismo canal. Con el
/// control arriba y los medios sin llegar, el vigía de la publicación cambiaba la cita de
/// medios guardando la vieja sin cancelar, y por Wi-Fi Aware la nueva caía con
/// `serviceAlreadyPublishing` cada 5 s (16 Pro, 20-oct, 20:59). En el Mac lo mismo se ve con
/// listeners en puertos fijos: dos vivos en el mismo puerto chocan con `EADDRINUSE`.
final class PublicationReplacementTests: XCTestCase {
    private let tag = Data(repeating: 5, count: LinkFrame.tagLength)

    /// Control arriba, los medios del otro no llegan nunca (su UDP va a otro puerto): el vigía
    /// cambia la cita de medios una y otra vez, y cada nueva se publica sin chocar con la
    /// vieja. Antes, la segunda caía y se reintentaba cada 5 s.
    func testRepublishingMediaWithTheControlUpNeverKeepsTwoPublications() throws {
        let puerto = UInt16.random(in: 42000...47000) & ~3
        let cita = FixedPortsRendezvous(controlPort: puerto, mediaPort: puerto + 2, republishS: 0.4)
        let publica = NWLinkTransport(mode: .advertise(name: "izq", txt: [:]), rendezvous: cita)
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil)
        defer {
            conecta.stop()
            publica.stop()
        }
        publica.start()
        try waitUntil(publica.events.contains { $0.contains("cita de control publicada") })
        conecta.start()
        try waitUntil(publica.state == .connected)

        try waitUntil(publica.events.filter { $0.contains("cita de medios publicada") }.count >= 3)
        XCTAssertEqual(publica.state, .connected, "cambiar la cita de medios no toca el control")
        XCTAssertFalse(publica.events.contains { $0.contains("cita de medios acabada") }, "\(publica.events)")
        XCTAssertGreaterThanOrEqual(cita.listeners(.media), 3)
    }

    /// El enlace cae por silencio: el que publica suelta la conexión de medios del par que se
    /// fue y abre las dos citas nuevas, sin que convivan con las viejas; el otro vuelve a
    /// conectar a ellas. Antes guardaba la conexión de medios vieja hasta que llegara otra.
    func testWhenTheLinkFallsThePublisherLetsGoOfTheOldPeerAndPublishesAnew() throws {
        let puerto = UInt16.random(in: 42000...47000) & ~3
        let cita = FixedPortsRendezvous(controlPort: puerto, mediaPort: puerto + 1, republishS: nil, silenceS: 0.5)
        let publica = NWLinkTransport(mode: .advertise(name: "izq", txt: [:]), rendezvous: cita)
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), rendezvous: cita)
        defer {
            conecta.stop()
            publica.stop()
        }
        let subidas = Counter()
        conecta.onState = { if $0 == .connected { subidas.increment() } }
        publica.start()
        try waitUntil(publica.events.contains { $0.contains("cita de medios publicada") })
        conecta.start()
        try waitUntil(publica.state == .connected && subidas.value == 1)

        // Medios en los dos sentidos hasta que los dos se han oído: el vigía de silencio se arma.
        var seq: UInt32 = 0
        try waitUntil({
            seq += 1
            conecta.send(latido(seq), on: .media)
            publica.send(latido(seq), on: .media)
            usleep(50_000)
            return conecta.stats.mediaFramesReceived > 0 && publica.stats.mediaFramesReceived > 0
        }())

        // Y callan: el vigía tira el enlace y el que publica rehace sus citas.
        try waitUntil(publica.events.contains { $0.contains("citas nuevas") })
        XCTAssertTrue(publica.events.contains { $0.contains("medios: se descarta la conexión (el enlace cayó)") })
        try waitUntil(cita.listeners(.control) >= 2 && cita.listeners(.media) >= 2)
        try waitUntil(subidas.value >= 2, timeoutS: 15)
        XCTAssertFalse(publica.events.contains { $0.contains("acabada") }, "\(publica.events)")
    }

    private func latido(_ seq: UInt32) -> LinkFrame {
        LinkFrame(type: .heartbeat, session: 3, seq: seq, rigMs: 0, payload: Data([1]), tag: tag)
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

/// Una cita de prueba que publica cada canal en un puerto fijo del loopback, como un servicio
/// de Wi-Fi Aware: si dos listeners del mismo canal están vivos a la vez, el segundo falla
/// (`EADDRINUSE`, el `serviceAlreadyPublishing` del Mac).
private final class FixedPortsRendezvous: LinkRendezvous {
    private let controlPort: UInt16
    private let mediaPort: UInt16
    private let republish: Double?
    private let silence: Double?
    private let cerrojo = NSLock()
    private var pedidos: [LinkChannel: Int] = [:]

    init(controlPort: UInt16, mediaPort: UInt16, republishS: Double?, silenceS: Double? = nil) {
        self.controlPort = controlPort
        self.mediaPort = mediaPort
        republish = republishS
        silence = silenceS
    }

    func listeners(_ canal: LinkChannel) -> Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return pedidos[canal, default: 0]
    }

    var label: String { "fixed-ports-test" }

    var republishAfterS: Double? { republish }

    var silenceTimeoutS: Double? { silence }

    func parameters(for channel: LinkChannel) -> NWParameters {
        let params = BonjourRendezvous(interfaceType: nil).parameters(for: channel)
        // El control vuelve a escuchar en su puerto con la conexión de antes en TIME_WAIT:
        // eso no es convivir con otra cita. Los medios (UDP) no lo necesitan, y así el
        // choque de dos listeners vivos se ve.
        if channel == .control { params.allowLocalEndpointReuse = true }
        return params
    }

    func makeListener(for channel: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        cerrojo.lock(); pedidos[channel, default: 0] += 1; cerrojo.unlock()
        let puerto = channel == .control ? controlPort : mediaPort
        return try NWListener(using: parameters(for: channel), on: NWEndpoint.Port(rawValue: puerto)!)
    }

    func makeBrowser(for _: LinkChannel) throws -> NWBrowser {
        throw WiFiAwareLinkError.unsupported
    }
}

/// Un contador para los estados, que llegan por la cola del transporte.
private final class Counter: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var n = 0

    var value: Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return n
    }

    func increment() {
        cerrojo.lock(); n += 1; cerrojo.unlock()
    }
}
