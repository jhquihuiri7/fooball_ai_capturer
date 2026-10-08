import Network
import XCTest

import RigCore
@testable import RigNet

/// Wi-Fi Aware como plan B (IOS-14), en lo que se puede probar en el Mac: los nombres de
/// los servicios (uno inválido cierra la app al arrancar), que el Info.plist y el
/// entitlement los declaran, y que el transporte anuncia los dos canales por la cita que
/// se le da. Que dos iPhone enlacen sin router se prueba con el banco link-bench.
final class WiFiAwareLinkTests: XCTestCase {
    private let tag = Data(repeating: 5, count: LinkFrame.tagLength)

    /// ios/Runner, desde este fichero.
    private var runner: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RigNetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ZeroKit
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("Runner")
    }

    private func plist(_ nombre: String) throws -> [String: Any] {
        let datos = try Data(contentsOf: runner.appendingPathComponent(nombre))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: datos, format: nil) as? [String: Any])
    }

    func testServiceNamesFollowRfc6335() {
        for nombre in WiFiAwareServices.all {
            XCTAssertTrue(WiFiAwareServices.isValidServiceName(nombre), nombre)
        }
        XCTAssertEqual(WiFiAwareServices.name(for: .control), WiFiAwareServices.control)
        XCTAssertEqual(WiFiAwareServices.name(for: .media), WiFiAwareServices.media)
        XCTAssertTrue(WiFiAwareServices.control.hasSuffix("._tcp"))
        XCTAssertTrue(WiFiAwareServices.media.hasSuffix("._udp"))
    }

    func testInvalidServiceNamesAreCaught() {
        // El de medios de Bonjour tiene 16 caracteres: por Wi-Fi Aware no vale.
        XCTAssertFalse(WiFiAwareServices.isValidServiceName(BonjourRendezvous.mediaServiceType))
        for malo in ["footballai-rig._tcp", "_footballai-rig._sctp", "_-rig._tcp", "_rig-._tcp",
                     "_a--b._tcp", "_Rig._tcp", "_123._udp", "_._tcp", "_rig._tcp.local"] {
            XCTAssertFalse(WiFiAwareServices.isValidServiceName(malo), malo)
        }
    }

    func testInfoPlistDeclaresBothServicesBothWays() throws {
        let info = try plist("Info.plist")
        let servicios = try XCTUnwrap(info["WiFiAwareServices"] as? [String: [String: Any]])
        for nombre in WiFiAwareServices.all {
            let config = try XCTUnwrap(servicios[nombre], "\(nombre) no está en WiFiAwareServices")
            // Publica el izquierdo y se suscribe el derecho: la misma app hace los dos.
            XCTAssertNotNil(config["Publishable"], nombre)
            XCTAssertNotNil(config["Subscribable"], nombre)
        }
        for nombre in servicios.keys {
            XCTAssertTrue(WiFiAwareServices.isValidServiceName(nombre), "nombre inválido en el Info.plist: \(nombre)")
        }
        // Bonjour sigue declarado: Wi-Fi Aware es el plan B, no el sustituto.
        let bonjour = try XCTUnwrap(info["NSBonjourServices"] as? [String])
        XCTAssertTrue(bonjour.contains(BonjourRendezvous.controlServiceType))
        XCTAssertTrue(bonjour.contains(BonjourRendezvous.mediaServiceType))
    }

    func testEntitlementAllowsPublishAndSubscribe() throws {
        let derechos = try plist("Runner.entitlements")
        let modos = try XCTUnwrap(derechos["com.apple.developer.wifi-aware"] as? [String])
        XCTAssertEqual(Set(modos), ["Publish", "Subscribe"])
    }

    func testBonjourRendezvousKeepsTheInterfaceAndTheServiceTypes() throws {
        let cita = BonjourRendezvous(interfaceType: .wifi)
        XCTAssertEqual(cita.label, "wifi")
        XCTAssertEqual(BonjourRendezvous(interfaceType: .wiredEthernet).label, "ethernet")
        for canal in [LinkChannel.control, .media] {
            let params = cita.parameters(for: canal)
            XCTAssertEqual(params.requiredInterfaceType, .wifi)
            XCTAssertFalse(params.includePeerToPeer)
        }
        let control = try cita.makeListener(for: .control, name: "izq", txt: ["side": "left"])
        let medios = try cita.makeListener(for: .media, name: "izq", txt: ["side": "left"])
        XCTAssertEqual(control.service?.type, BonjourRendezvous.controlServiceType)
        XCTAssertEqual(medios.service?.type, BonjourRendezvous.mediaServiceType)
        XCTAssertEqual(control.service?.name, "izq")
    }

    /// El que anuncia pide a la cita un listener por canal, con el nombre y la TXT; con
    /// una cita que escucha en el loopback, el otro conecta y pasan tramas por los dos.
    func testAdvertiseAnnouncesBothChannelsThroughTheRendezvous() throws {
        let puerto = UInt16.random(in: 42000...48000) & ~1
        let cita = LoopbackRendezvous(port: puerto)
        let anuncia = NWLinkTransport(
            mode: .advertise(name: "izq", txt: ["side": "left"]), rendezvous: cita
        )
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil)
        defer {
            anuncia.stop()
            conecta.stop()
        }
        let control = expectation(description: "control")
        let medios = expectation(description: "medios")
        medios.assertForOverFulfill = false
        anuncia.onFrame = { _, canal in
            canal == .control ? control.fulfill() : medios.fulfill()
        }
        let conectado = expectation(description: "conectado")
        conectado.assertForOverFulfill = false
        conecta.onState = { if $0 == .connected { conectado.fulfill() } }
        anuncia.start()
        conecta.start()
        wait(for: [conectado], timeout: 10)

        conecta.send(LinkFrame(type: .heartbeat, session: 1, seq: 1, rigMs: 0, payload: Data([1]), tag: tag), on: .control)
        wait(for: [control], timeout: 10)
        // El UDP del que conecta tarda un instante en estar listo: se insiste.
        var seq: UInt32 = 0
        while anuncia.stats.mediaFramesReceived == 0, seq < 50 {
            seq += 1
            conecta.send(LinkFrame(type: .heartbeat, session: 1, seq: seq, rigMs: 0, payload: Data([2]), tag: tag), on: .media)
            usleep(100_000)
        }
        wait(for: [medios], timeout: 10)

        XCTAssertEqual(cita.pedidos.map(\.canal), [.control, .media])
        XCTAssertTrue(cita.pedidos.allSatisfy { $0.nombre == "izq" && $0.txt == ["side": "left"] })
        XCTAssertEqual(anuncia.rendezvous.label, "loopback-test")
    }
}

/// Una cita de prueba: anuncia en el loopback, el control en `port` y los medios en
/// `port + 1` (como el modo `.connect` de los tests), y apunta lo que se le pide.
private final class LoopbackRendezvous: LinkRendezvous {
    private let port: UInt16
    private let cerrojo = NSLock()
    private var _pedidos: [(canal: LinkChannel, nombre: String, txt: [String: String])] = []

    var pedidos: [(canal: LinkChannel, nombre: String, txt: [String: String])] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return _pedidos
    }

    init(port: UInt16) { self.port = port }

    var label: String { "loopback-test" }

    func parameters(for channel: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: channel)
    }

    func makeListener(for channel: LinkChannel, name: String, txt: [String: String]) throws -> NWListener {
        cerrojo.lock(); _pedidos.append((channel, name, txt)); cerrojo.unlock()
        let p = channel == .control ? port : port + 1
        return try NWListener(using: parameters(for: channel), on: NWEndpoint.Port(rawValue: p)!)
    }

    func makeBrowser(for channel: LinkChannel) throws -> NWBrowser {
        throw WiFiAwareLinkError.unsupported
    }
}

/// El fin de una cita (IOS-14): por Wi-Fi Aware, el listener y el browser caducan a los
/// ~2 min de conectar (`publisherTimeout`, `subscriberTimeout`) y la conexión sigue. Ni
/// eso es un fallo del transporte ni un listener que falla se queda sin sustituto.
final class RendezvousEndTests: XCTestCase {
    private let tag = Data(repeating: 6, count: LinkFrame.tagLength)

    func testALiveConnectionSurvivesTheEndOfItsRendezvous() {
        typealias T = NWLinkTransport
        // Con la conexión arriba nunca es un fallo: el que busca la guarda hasta que caiga
        // y el que anuncia vuelve a publicar al rato.
        for caduca in [true, false] {
            XCTAssertEqual(T.rendezvousEndAction(publishing: false, connected: true, expired: caduca), .keepUntilDrop)
            XCTAssertEqual(T.rendezvousEndAction(publishing: true, connected: true, expired: caduca), .renewLater)
        }
        // Sin conexión: si caducó se abre otra sin más; si falló, `.failed` y otra con espera.
        for publica in [true, false] {
            XCTAssertEqual(T.rendezvousEndAction(publishing: publica, connected: false, expired: true), .reopen)
            XCTAssertEqual(T.rendezvousEndAction(publishing: publica, connected: false, expired: false), .fail)
        }
        XCTAssertGreaterThan(T.rendezvousRenewS, T.rendezvousRetryS)
    }

    func testBonjourNeverExpires() {
        let cita = BonjourRendezvous(interfaceType: nil)
        XCTAssertFalse(cita.isExpiry(.posix(.ETIMEDOUT)))
        XCTAssertFalse(cita.isExpiry(.posix(.EADDRINUSE)))
    }

    /// Un listener que falla se cambia por otro. Antes se quedaba el muerto y
    /// scheduleReopen, que solo abre si no hay listener, no lo sustituía nunca.
    func testAFailedListenerIsReplaced() throws {
        let (anuncia, conecta, cita, estados) = try connectThroughAFailingListener(expires: false)
        defer {
            anuncia.stop()
            conecta.stop()
        }
        XCTAssertEqual(cita.controlListeners, 2)
        XCTAssertTrue(estados.values.contains { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(anuncia.stats.rendezvousEnds, 0)
    }

    /// Una cita que caduca sin conexión se abre otra sin pasar por `.failed`, y queda
    /// apuntado para el banco.
    func testAnExpiredRendezvousReopensWithoutFailing() throws {
        let (anuncia, conecta, cita, estados) = try connectThroughAFailingListener(expires: true)
        defer {
            anuncia.stop()
            conecta.stop()
        }
        XCTAssertEqual(cita.controlListeners, 2)
        XCTAssertFalse(estados.values.contains { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(anuncia.stats.rendezvousEnds, 1)
        XCTAssertNotNil(anuncia.lastRendezvousEnd)
    }

    /// El primer listener de control de la cita choca con un puerto ocupado y falla; el
    /// segundo escucha donde conecta el otro, y pasan tramas.
    private func connectThroughAFailingListener(
        expires: Bool
    ) throws -> (NWLinkTransport, NWLinkTransport, BusyFirstRendezvous, StateLog) {
        let ocupado = try NWListener(using: .tcp)
        let listo = expectation(description: "puerto ocupado")
        ocupado.stateUpdateHandler = { if case .ready = $0 { listo.fulfill() } }
        ocupado.newConnectionHandler = { $0.cancel() }
        ocupado.start(queue: .global())
        wait(for: [listo], timeout: 10)
        addTeardownBlock { ocupado.cancel() }
        let puertoOcupado = try XCTUnwrap(ocupado.port?.rawValue)

        let puerto = UInt16.random(in: 42000...48000) & ~1
        let cita = BusyFirstRendezvous(busyPort: puertoOcupado, port: puerto, expires: expires)
        let anuncia = NWLinkTransport(mode: .advertise(name: "izq", txt: [:]), rendezvous: cita)
        let estados = StateLog()
        anuncia.onState = { estados.append($0) }
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil)
        let conectado = expectation(description: "conectado")
        conectado.assertForOverFulfill = false
        conecta.onState = { if $0 == .connected { conectado.fulfill() } }
        let recibido = expectation(description: "trama")
        recibido.assertForOverFulfill = false
        anuncia.onFrame = { _, canal in if canal == .control { recibido.fulfill() } }
        anuncia.start()
        conecta.start()
        wait(for: [conectado], timeout: 15)
        conecta.send(LinkFrame(type: .heartbeat, session: 1, seq: 1, rigMs: 0, payload: Data([1]), tag: tag), on: .control)
        wait(for: [recibido], timeout: 10)
        return (anuncia, conecta, cita, estados)
    }
}

/// Los estados del transporte, desde su cola.
private final class StateLog: @unchecked Sendable {
    private let cerrojo = NSLock()
    private var _values: [LinkTransportState] = []

    var values: [LinkTransportState] {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return _values
    }

    func append(_ estado: LinkTransportState) {
        cerrojo.lock(); _values.append(estado); cerrojo.unlock()
    }
}

/// Una cita de prueba cuyo primer listener de control escucha en un puerto ocupado (y
/// falla con EADDRINUSE); los siguientes, en `port`, y los medios en `port + 1`. Con
/// `expires`, ese fallo cuenta como caducidad, como `publisherTimeout` por Wi-Fi Aware.
private final class BusyFirstRendezvous: LinkRendezvous {
    private let busyPort: UInt16
    private let port: UInt16
    private let expires: Bool
    private let cerrojo = NSLock()
    private var _controlListeners = 0

    var controlListeners: Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return _controlListeners
    }

    init(busyPort: UInt16, port: UInt16, expires: Bool) {
        self.busyPort = busyPort
        self.port = port
        self.expires = expires
    }

    var label: String { "busy-first-test" }

    func parameters(for channel: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: channel)
    }

    func makeListener(for channel: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        var p = port + 1
        if channel == .control {
            cerrojo.lock()
            _controlListeners += 1
            p = _controlListeners == 1 ? busyPort : port
            cerrojo.unlock()
        }
        return try NWListener(using: parameters(for: channel), on: NWEndpoint.Port(rawValue: p)!)
    }

    func makeBrowser(for _: LinkChannel) throws -> NWBrowser {
        throw WiFiAwareLinkError.unsupported
    }

    func isExpiry(_ error: NWError) -> Bool {
        expires && error == .posix(.EADDRINUSE)
    }
}
