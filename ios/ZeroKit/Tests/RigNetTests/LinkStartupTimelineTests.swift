import Network
import XCTest

import RigCore
@testable import RigNet

/// Cuándo sube cada pieza del enlace (2026-10-11): en `bench/dos-moviles-20261010-1106`
/// el maestro no vio al esclavo hasta los 102 s y el informe no decía si tardó el control,
/// los medios o el esclavo en abrir su enlace.
final class LinkStartupTimelineTests: XCTestCase {
    private let tag = Data(repeating: 5, count: LinkFrame.tagLength)

    // MARK: - LinkEventLog

    func testTheEventLogKeepsTheStartAndTheEnd() {
        var log = LinkEventLog(headCount: 3, tailCount: 4)
        for i in 1...20 { log.append("e\(i)") }
        // El arranque entero, la marca de lo que falta y lo último.
        XCTAssertEqual(log.lines, ["e1", "e2", "e3", "… 13 sucesos sin guardar …", "e17", "e18", "e19", "e20"])
        XCTAssertEqual(log.skipped, 13)
    }

    func testAShortLogHasNoGapMark() {
        var log = LinkEventLog(headCount: 3, tailCount: 4)
        for i in 1...7 { log.append("e\(i)") }
        XCTAssertEqual(log.lines, ["e1", "e2", "e3", "e4", "e5", "e6", "e7"])
        XCTAssertEqual(log.skipped, 0)
    }

    /// El transporte guarda su arranque aunque luego pase de todo (un partido de 90 min).
    func testTheTransportLogKeepsItsStartupInALongRun() {
        XCTAssertGreaterThan(NWLinkTransport.maxStartEvents, 0)
        var log = LinkEventLog(headCount: NWLinkTransport.maxStartEvents, tailCount: NWLinkTransport.maxEvents)
        log.append("0.0 cita de control publicada")
        for i in 0..<1000 { log.append("\(i) control caído") }
        XCTAssertEqual(log.lines.first, "0.0 cita de control publicada")
        XCTAssertEqual(log.lines.last, "999 control caído")
        XCTAssertEqual(log.lines.count, NWLinkTransport.maxStartEvents + NWLinkTransport.maxEvents + 1)
    }

    // MARK: - LinkStartupTimeline

    func testOnlyTheFirstMarkCountsAndMissingOnesAreMinusOne() {
        let t = LinkStartupTimeline(startNs: 1_000_000_000)
        t.mark(.peerUp, atNs: 1_250_000_000)
        t.mark(.peerUp, atNs: 9_000_000_000)  // una segunda subida no mueve la primera
        t.mark(.firstPart, atNs: 1_400_400_000)
        let r = t.report()
        XCTAssertEqual(r["peer_up"], 250)
        XCTAssertEqual(r["first_part"], 400)
        XCTAssertEqual(r["control_up"], -1)
        XCTAssertEqual(r["first_view"], -1)
        XCTAssertEqual(Set(r.keys), Set(LinkStartupTimeline.Milestone.allCases.map(\.rawValue)))
    }

    func testTheTransportMilestonesComeFromItsCounters() {
        let t = LinkStartupTimeline(startNs: 5_000_000_000)
        var stats = LinkTransportStats()
        stats.firstControlUpNs = 5_002_000_000
        stats.firstPeerMediaNs = 107_500_000_000  // el esclavo de 1106: medios a los 102,5 s
        let r = t.report(transport: stats)
        XCTAssertEqual(r["control_up"], 2)
        XCTAssertEqual(r["media_rx"], 102_500)
        // Antes del arranque del banco (el transporte se crea un instante antes): negativo.
        XCTAssertEqual(t.msSinceStart(4_999_000_000), -1)
    }

    func testTheProcessStartIsKnownAndInThePast() throws {
        let inicio = try XCTUnwrap(LinkStartupTimeline.processStartUnixMs())
        let ahora = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThanOrEqual(inicio, ahora)
        XCTAssertGreaterThan(inicio, ahora - 24 * 3600 * 1000)
    }

    // MARK: - Por el loopback

    /// Con el enlace arriba y medios en los dos sentidos, los dos lados saben cuándo subió
    /// el control y cuándo llegó lo primero del otro por medios, y la línea de tiempo lo
    /// dice con el canal de medios incluido.
    func testBothSidesRecordWhenControlAndMediaCameUp() throws {
        let escucha = NWLinkTransport(mode: .listen(port: 0), interfaceType: nil)
        let listo = expectation(description: "puerto")
        listo.assertForOverFulfill = false
        nonisolated(unsafe) var puerto: UInt16 = 0
        escucha.onReady = { p in
            puerto = p
            listo.fulfill()
        }
        escucha.start()
        wait(for: [listo], timeout: 10)
        let conecta = NWLinkTransport(mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil)
        defer {
            escucha.stop()
            conecta.stop()
        }
        let timeline = LinkStartupTimeline(startNs: conecta.createdNs)
        conecta.start()
        try waitUntil(conecta.state == .connected && escucha.state == .connected)
        XCTAssertNil(conecta.statsSnapshot.firstPeerMediaNs)

        var seq: UInt32 = 0
        try waitUntil({
            seq += 1
            let latido = LinkFrame(type: .heartbeat, session: 1, seq: seq, rigMs: 0, payload: Data([1]), tag: tag)
            conecta.send(latido, on: .media)
            escucha.send(latido, on: .media)
            usleep(50_000)
            return conecta.statsSnapshot.mediaFramesReceived > 0 && escucha.statsSnapshot.mediaFramesReceived > 0
        }())

        for lado in [escucha, conecta] {
            let s = lado.statsSnapshot
            let control = try XCTUnwrap(s.firstControlUpNs)
            let medios = try XCTUnwrap(s.firstPeerMediaNs)
            XCTAssertGreaterThanOrEqual(control, lado.createdNs)
            XCTAssertGreaterThanOrEqual(medios, lado.createdNs)
            XCTAssertTrue(lado.events.contains { $0.hasSuffix(" control arriba") }, "\(lado.events)")
            XCTAssertTrue(lado.events.contains { $0.hasSuffix(" medios: primera trama del otro") }, "\(lado.events)")
        }
        XCTAssertTrue(escucha.events.contains { $0.hasSuffix(" medios: llega una conexión") }, "\(escucha.events)")
        XCTAssertTrue(conecta.events.contains { $0.hasSuffix(" medios: conexión lista") }, "\(conecta.events)")

        let r = timeline.report(transport: conecta.statsSnapshot)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r["control_up"]), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r["media_rx"]), try XCTUnwrap(r["control_up"]))
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

    private struct Timeout: Error {}
}
