import Network
import XCTest

import RigCore
@testable import RigNet

/// Bug B (2026-10-21): con el maestro (el que publica) cerrado y vuelto a abrir, el esclavo
/// (el que busca) seguía viéndolo y cada intento de control se quedaba «sin respuesta en
/// 10 s», diez seguidos, con una conexión de medios lista 85 s sobre un datapath viejo. Solo
/// lo curaba matar la app. Ahora el que busca hace borrón: al perder el control o tras N
/// intentos sin subir lo suelta todo y deja un rato sin nada abierto antes de suscribirse de
/// cero. Se prueba por el loopback con plazos cortos y, el camino del que busca entero, con
/// Bonjour en el Mac.
final class SearchResetTests: XCTestCase {
    private let tag = Data(repeating: 9, count: LinkFrame.tagLength)

    func testTheResetPolicyAndItsPauses() {
        typealias T = NWLinkTransport
        XCTAssertTrue(T.searchNeedsReset(failedAttempts: 3, limit: 3))
        XCTAssertTrue(T.searchNeedsReset(failedAttempts: 4, limit: 3))
        XCTAssertFalse(T.searchNeedsReset(failedAttempts: 2, limit: 3))
        // Sin tope (Bonjour) o con un tope sin sentido, nunca.
        XCTAssertFalse(T.searchNeedsReset(failedAttempts: 99, limit: nil))
        XCTAssertFalse(T.searchNeedsReset(failedAttempts: 99, limit: 0))
        // Mientras iOS puede retener el datapath viejo (v11, 21-oct 10:50), ningún borrón por
        // intentos: se sigue intentando. Pasado el plazo, el tope de siempre.
        XCTAssertFalse(T.searchNeedsReset(failedAttempts: 9, limit: 3, withoutLinkS: 104, graceS: 150))
        XCTAssertTrue(T.searchNeedsReset(failedAttempts: 9, limit: 3, withoutLinkS: 151, graceS: 150))
        XCTAssertFalse(T.searchNeedsReset(failedAttempts: 2, limit: 3, withoutLinkS: 151, graceS: 150))
        XCTAssertTrue(T.searchNeedsReset(failedAttempts: 3, limit: 3, withoutLinkS: 0, graceS: nil))
        // Cada borrón seguido, la pausa de su turno; después, la última.
        XCTAssertEqual(T.resetQuietS(previous: 0, schedule: [60, 120]), 60)
        XCTAssertEqual(T.resetQuietS(previous: 1, schedule: [60, 120]), 120)
        XCTAssertEqual(T.resetQuietS(previous: 7, schedule: [60, 120]), 120)
        XCTAssertEqual(T.resetQuietS(previous: 0, schedule: []), 0)
    }

    func testOnlyWiFiAwareResetsAndWithPausesLongEnough() {
        for bonjour in [BonjourRendezvous(interfaceType: .wiredEthernet), BonjourRendezvous(interfaceType: .wifi)] {
            XCTAssertNil(bonjour.failedAttemptsBeforeReset)
            XCTAssertNil(bonjour.settleAfterDropS)
            XCTAssertTrue(bonjour.resetQuietS.isEmpty)
            XCTAssertNil(bonjour.staleDatapathS)
            XCTAssertFalse(bonjour.mediaAfterControl)
        }
        // El plazo del datapath viejo cubre los ~2 min que tarda iOS (FB23509767; 139 s en la
        // v11) y no se va mucho más allá: pasado, vuelve el borrón con sus pausas.
        XCTAssertGreaterThanOrEqual(WiFiAwareTimings.staleDatapathS, 140)
        XCTAssertLessThanOrEqual(WiFiAwareTimings.staleDatapathS, 180)
        // Las pasadas buenas suben al primer intento o al segundo: el tope deja margen, y
        // llega antes de un minuto de intentos (con 10 s cada uno).
        let tope = WiFiAwareTimings.failedAttemptsBeforeReset
        XCTAssertGreaterThanOrEqual(tope, 3)
        XCTAssertLessThan(Double(tope) * WiFiAwareTimings.connectTimeoutS, 60)
        // 14 s sin conexiones no bastaron (21-oct); 1 min con la app cerrada sí (15-oct); Apple:
        // «un par de minutos» (FB23509767). Y nunca menos de lo que ya se probó.
        let pausas = WiFiAwareTimings.resetQuietS
        XCTAssertGreaterThanOrEqual(pausas.first ?? 0, 60)
        XCTAssertGreaterThanOrEqual(pausas.last ?? 0, 120)
        XCTAssertEqual(pausas, pausas.sorted())
        // Perder el control no cuesta más que unos segundos: un parón de la radio se cura solo.
        XCTAssertLessThanOrEqual(WiFiAwareTimings.settleAfterDropS, 3)
    }

    /// Intentos que no suben (nadie escucha en el puerto): a los dos, borrón; en la pausa no
    /// se intenta nada y el diagnóstico lo dice; después se vuelve a intentar y, cuando el otro
    /// aparece, sube y la cuenta vuelve a cero.
    func testAttemptsThatNeverComeUpEndInAResetWithAQuietPause() throws {
        let puerto = UInt16.random(in: 42000...47000) & ~3
        let cita = ResetRendezvous(failedAttempts: 2, quiet: [0.8])
        let busca = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), rendezvous: cita)
        defer { busca.stop() }
        busca.start()
        try waitUntil(busca.events.contains { $0.contains("borrón (2 intentos seguidos sin subir") })
        // Cada intento que cae dice su ruta, y el último queda en el diagnóstico.
        XCTAssertTrue(busca.events.contains { $0.contains("control caído (en espera") && $0.contains(" · ruta ") },
                      "\(busca.events)")
        let d = busca.diagnosis
        XCTAssertTrue(d.lastAttempt?.hasPrefix("a 127.0.0.1:\(puerto) · ruta ") == true, d.lastAttempt ?? "nil")
        XCTAssertEqual(d.liveConnections, 0, "en la pausa no queda nada abierto")
        XCTAssertEqual(d.subscriptions, 0)
        XCTAssertNotNil(d.quietS)
        XCTAssertEqual(d.searchResets, 1)
        XCTAssertTrue(d.summary().hasPrefix("en pausa"), d.summary())
        XCTAssertEqual(d.report()["search_resets"] as? Int, 1)
        try waitUntil(busca.events.contains { $0.contains("fin de la pausa") })

        // En la pausa, ningún intento.
        let sucesos = busca.events
        let borron = try XCTUnwrap(sucesos.firstIndex { $0.contains("borrón") })
        let fin = try XCTUnwrap(sucesos.firstIndex { $0.contains("fin de la pausa") })
        XCTAssertFalse(sucesos[borron..<fin].contains { $0.contains("se conecta a") }, "\(sucesos)")
        XCTAssertGreaterThanOrEqual(seconds(sucesos[fin]) - seconds(sucesos[borron]), 0.7)

        // El otro aparece: el siguiente intento sube y la cuenta se pone a cero.
        let escucha = NWLinkTransport(mode: .listen(port: puerto), interfaceType: nil)
        defer { escucha.stop() }
        escucha.start()
        try waitUntil(busca.state == .connected, timeoutS: 15)
        XCTAssertEqual(busca.diagnosis.failedAttempts, 0)
        XCTAssertNil(busca.diagnosis.quietS)
        XCTAssertEqual(busca.statsSnapshot.searchResets, busca.events.filter { $0.contains(" borrón (") }.count)
    }

    /// Un enlace arriba calla: el que conecta suelta todo, espera sin nada abierto y vuelve a
    /// conectar de cero, con los medios rehechos. La lectura que acaba de la conexión tirada
    /// no cuenta como otra caída (antes eran dos «control caído» y dos suscripciones).
    func testLosingAControlThatWasUpPausesThenSearchesAgainFromScratch() throws {
        let cita = ResetRendezvous(settle: 0.5, silence: 0.5)
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
        defer {
            conecta.stop()
            escucha.stop()
        }
        conecta.start()
        try waitUntil(conecta.state == .connected && escucha.state == .connected)
        var seq: UInt32 = 0
        try waitUntil({
            seq += 1
            conecta.send(latido(seq), on: .media)
            escucha.send(latido(seq), on: .media)
            usleep(50_000)
            return conecta.stats.mediaFramesReceived > 0 && escucha.stats.mediaFramesReceived > 0
        }())

        // Callan: borrón por la caída, pausa y otra vez arriba.
        try waitUntil(conecta.events.contains { $0.contains("borrón (el control cayó") })
        try waitUntil(conecta.events.contains { $0.contains("fin de la pausa") } && conecta.state == .connected)
        let sucesos = conecta.events
        let caida = try XCTUnwrap(sucesos.firstIndex { $0.contains("control caído") })
        let vuelta = try XCTUnwrap(sucesos[caida...].firstIndex { $0.contains("control arriba") })
        XCTAssertEqual(sucesos[caida..<vuelta].filter { $0.contains("control caído") }.count, 1, "\(sucesos)")
        XCTAssertEqual(conecta.statsSnapshot.reconnects, 1)

        // Los medios se rehicieron con el control: lo que manda el que conecta llega.
        let antes = escucha.stats.mediaFramesReceived
        try waitUntil({
            seq += 1
            conecta.send(latido(seq), on: .media)
            usleep(50_000)
            return escucha.stats.mediaFramesReceived > antes
        }())
    }

    /// El camino del que busca entero, con Bonjour en el Mac: con medios tras el control, la
    /// conexión de medios sale cuando el control sube, no antes (Bug B).
    func testWithMediaAfterControlTheSearcherConnectsMediaOnlyOnceTheControlIsUp() throws {
        let tipo = BrowseRendezvous.uniqueType()
        let publica = NWLinkTransport(mode: .advertise(name: "izq-\(tipo)", txt: [:]),
                                      rendezvous: BrowseRendezvous(type: tipo))
        let busca = NWLinkTransport(mode: .browse, rendezvous: BrowseRendezvous(type: tipo, mediaAfterControl: true))
        defer {
            busca.stop()
            publica.stop()
        }
        publica.start()
        busca.start()
        try bonjourOrSkip(busca.state == .connected && publica.state == .connected, busca)
        var seq: UInt32 = 0
        try waitUntil({
            seq += 1
            busca.send(latido(seq), on: .media)
            usleep(50_000)
            return publica.stats.mediaFramesReceived > 0
        }())
        let sucesos = busca.events
        let arriba = try XCTUnwrap(sucesos.firstIndex { $0.contains("control arriba") })
        let medios = try XCTUnwrap(sucesos.firstIndex { $0.contains("medios: se conecta") })
        XCTAssertGreaterThan(medios, arriba, "\(sucesos)")
    }

    /// Intentos que no suben con el otro a la vista (la conexión del que busca no tiene ruta):
    /// el borrón suelta también las suscripciones, y después de la pausa se abren otras.
    func testAResetAlsoLetsGoOfTheSubscriptions() throws {
        let tipo = BrowseRendezvous.uniqueType()
        let publica = NWLinkTransport(mode: .advertise(name: "izq-\(tipo)", txt: [:]),
                                      rendezvous: BrowseRendezvous(type: tipo))
        let cita = BrowseRendezvous(type: tipo, failedAttempts: 2, quiet: [0.8], blockConnections: true)
        let busca = NWLinkTransport(mode: .browse, rendezvous: cita)
        defer {
            busca.stop()
            publica.stop()
        }
        publica.start()
        busca.start()
        try bonjourOrSkip(busca.events.contains { $0.contains("borrón") }, busca)
        XCTAssertEqual(busca.diagnosis.announcements, 0, "el borrón olvida lo que veía")
        try waitUntil(busca.events.contains { $0.contains("fin de la pausa") })
        try waitUntil(cita.browsers(.control) >= 2 && cita.browsers(.media) >= 2)
        let sucesos = busca.events
        let borron = try XCTUnwrap(sucesos.firstIndex { $0.contains("borrón") })
        let fin = try XCTUnwrap(sucesos.firstIndex { $0.contains("fin de la pausa") })
        XCTAssertFalse(sucesos[borron..<fin].contains { $0.contains("anuncios") || $0.contains("se conecta") },
                       "\(sucesos)")
    }

    // MARK: - Ayudas

    private func latido(_ seq: UInt32) -> LinkFrame {
        LinkFrame(type: .heartbeat, session: 3, seq: seq, rigMs: 0, payload: Data([1]), tag: tag)
    }

    /// Los segundos de un suceso de la línea de tiempo («12.3 [400 MB] texto»).
    private func seconds(_ suceso: String) -> Double {
        Double(suceso.prefix { $0 != " " }) ?? -1
    }

    /// Bonjour en el Mac puede no estar (sin red local, sin permiso): entonces se salta.
    private func bonjourOrSkip(_ condicion: @autoclosure () -> Bool, _ busca: NWLinkTransport) throws {
        let tope = Date().addingTimeInterval(10)
        while !condicion() {
            if Date() > tope {
                guard busca.events.contains(where: { $0.contains("anuncios") }) else {
                    throw XCTSkip("Bonjour no encuentra el anuncio en este Mac")
                }
                XCTFail("se ve el anuncio pero no se cumplió: \(busca.events)")
                return
            }
            usleep(20_000)
        }
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

/// Una cita de prueba por el loopback con el borrón del que busca y plazos cortos.
private struct ResetRendezvous: LinkRendezvous {
    var failedAttempts: Int?
    var quiet: [Double] = []
    var settle: Double?
    var silence: Double?

    var label: String { "reset-test" }

    var failedAttemptsBeforeReset: Int? { failedAttempts }
    var resetQuietS: [Double] { quiet }
    var settleAfterDropS: Double? { settle }
    var silenceTimeoutS: Double? { silence }

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

/// Una cita de prueba con Bonjour en el Mac y un tipo de servicio propio de cada test. Con
/// `blockConnections`, las conexiones del que busca no tienen ruta (prohibidas todas las
/// interfaces): ve el anuncio y no conecta.
private final class BrowseRendezvous: LinkRendezvous {
    private let type: String
    private let failed: Int?
    private let quiet: [Double]
    private let mediaAfter: Bool
    private let block: Bool
    private let cerrojo = NSLock()
    private var pedidos: [LinkChannel: Int] = [:]

    static func uniqueType() -> String {
        "zk" + String(UInt32.random(in: 0...UInt32.max), radix: 36)
    }

    init(type: String, failedAttempts: Int? = nil, quiet: [Double] = [], mediaAfterControl: Bool = false,
         blockConnections: Bool = false) {
        self.type = type
        failed = failedAttempts
        self.quiet = quiet
        mediaAfter = mediaAfterControl
        block = blockConnections
    }

    func browsers(_ canal: LinkChannel) -> Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return pedidos[canal, default: 0]
    }

    var label: String { "browse-test" }

    var connectTimeoutS: Double { 1 }
    var failedAttemptsBeforeReset: Int? { failed }
    var resetQuietS: [Double] { quiet }
    var mediaAfterControl: Bool { mediaAfter }

    private func serviceType(_ canal: LinkChannel) -> String {
        "_\(type).\(canal == .control ? "_tcp" : "_udp")"
    }

    private func plainParameters(_ canal: LinkChannel) -> NWParameters {
        BonjourRendezvous(interfaceType: nil).parameters(for: canal)
    }

    func parameters(for channel: LinkChannel) -> NWParameters {
        let params = plainParameters(channel)
        if block { params.prohibitedInterfaceTypes = [.loopback, .wifi, .wiredEthernet, .cellular, .other] }
        return params
    }

    func makeListener(for channel: LinkChannel, name: String, txt _: [String: String]) throws -> NWListener {
        let listener = try NWListener(using: plainParameters(channel))
        listener.service = NWListener.Service(name: name, type: serviceType(channel))
        return listener
    }

    func makeBrowser(for channel: LinkChannel) throws -> NWBrowser {
        cerrojo.lock(); pedidos[channel, default: 0] += 1; cerrojo.unlock()
        return NWBrowser(for: .bonjour(type: serviceType(channel), domain: nil), using: plainParameters(channel))
    }
}
