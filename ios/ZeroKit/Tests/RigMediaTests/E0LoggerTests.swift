import XCTest

import RigCore
@testable import RigMedia

/// El escritor del N0 (IOS-75): cabecera una vez, vaciados por lotes y descartes contados.
final class E0LoggerTests: XCTestCase {
    func testCabeceraUnaVezYLasLineasEnOrden() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e0-\(UUID().uuidString)/partido.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cabecera = MatchLogRecord.header(matchId: "m", rigId: "r", clockDomain: "a3f9c2d8", appVersion: "1",
                                             models: [], rigSha: nil, pitchSha: nil, bandSha: nil)
        let log = try E0Logger(url: url, header: cabecera)
        for k in 0..<120 {
            log.log(.view(rigMs: Int64(k * 133), yawDeg: 1, pitchDeg: -7, hfovDeg: 40, shot: "medium"))
        }
        log.flush()
        // Reabrir el mismo partido no repite la cabecera.
        let otra = try E0Logger(url: url, header: cabecera)
        otra.log(.score(rigMs: 99_999, home: 1, away: 0))
        otra.flush()
        let lineas = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lineas.count, 1 + 120 + 1)
        XCTAssertTrue(lineas[0].contains("\"schema\": \"match-log-v1\""))
        XCTAssertTrue(lineas[1].contains("\"rig_ms\": 0,"))
        XCTAssertTrue(lineas[120].contains("\"rig_ms\": 15827,"))
        XCTAssertEqual(log.written, 120)
        XCTAssertEqual(log.dropped, 0)
    }

    func testUnDominioDeRelojQueElValidadorRechazaraNoSeEscribe() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e0-\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try E0Logger(url: url, header: .header(
            matchId: "m", rigId: "r", clockDomain: "host-left", appVersion: "1",
            models: [], rigSha: nil, pitchSha: nil, bandSha: nil
        )))
    }

    func testColaLlenaDescartaYCuenta() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e0-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try E0Logger(url: url, header: .header(matchId: "m", rigId: "r", clockDomain: "a3f9c2d8", appVersion: "1",
                                                         models: [], rigSha: nil, pitchSha: nil, bandSha: nil))
        // Muchas más que la cola, sin dar tiempo al disco: algo se descarta, nada se bloquea.
        for k in 0..<20_000 { log.log(.score(rigMs: Int64(k), home: 0, away: 0)) }
        log.flush()
        XCTAssertEqual(log.written + log.dropped, 20_000)
    }
}
