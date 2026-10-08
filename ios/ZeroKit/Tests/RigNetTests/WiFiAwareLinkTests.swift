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
