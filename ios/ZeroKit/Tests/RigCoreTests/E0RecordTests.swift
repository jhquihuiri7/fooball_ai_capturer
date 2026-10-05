// El registro N0 (IOS-75) contra la muestra dorada de EV-02: cada registro que el móvil
// escribe sale con los mismos bytes que match_log.py.

import Foundation
import RigCore
import XCTest

final class E0RecordTests: XCTestCase {
    private func muestra() throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "match_log_sample", withExtension: "jsonl", subdirectory: "Golden"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testLosRegistrosQueEscribeElMovilSonLosDeLaMuestra() throws {
        let lineas = try muestra()
        let esperados: [String: MatchLogRecord] = [
            "header": .header(
                matchId: "demo-2026-10-03", rigId: "rig-01", clockDomain: "a3f9c2d8e1b74560", appVersion: "0.9.0",
                models: [.init(name: "dfine-n-band", version: "0.1.0", sha256: String(repeating: "ab", count: 32))],
                rigSha: String(repeating: "12", count: 32), pitchSha: nil, bandSha: String(repeating: "34", count: 32)
            ),
            "det": .det(rigMs: 1000, side: .left, model: "dfine-n-band", boxes: [
                .init(box: [100, 220, 140, 320], cls: "player", score: 0.91, feetDeg: [-12.5, -6.25], feetM: [18.5, 32]),
                .init(box: [900, 210, 936, 302], cls: "player", score: 0.84, feetDeg: nil, feetM: nil),
            ]),
            "view": .view(rigMs: 1266, yawDeg: 4.5, pitchDeg: -7, hfovDeg: 34, shot: "medium"),
            "mark": .mark(rigMs: 61000, kind: "goal", source: "operator", by: nil, confidence: nil),
            "mark2": .mark(rigMs: 61050, kind: "kickoff", source: "rules", by: "game_state@1", confidence: 0.85),
            "score": .score(rigMs: 61100, home: 1, away: 0),
            "clock": .clock(rigMs: 61100, running: true, startedRigMs: 1000, baseS: 0),
            "audio": .audio(rigMs: 60400, kind: "whistle", durationMs: 640, confidence: 0.92),
            "clip": .clip(rigMs: 61200, id: "clip-0001", kind: "goal", t0RigMs: 53000, t1RigMs: 68000),
        ]
        var comprobados = 0
        for (clave, registro) in esperados {
            let linea = registro.line
            XCTAssertTrue(lineas.contains(linea), "\(clave): \(linea)")
            comprobados += 1
        }
        XCTAssertEqual(comprobados, 9)
    }

    func testDecimalesComoPython() {
        XCTAssertEqual(PyJSON.double(100).text, "100.0")
        XCTAssertEqual(PyJSON.double(0.1 + 0.2).text, "0.30000000000000004")
        XCTAssertEqual(PyJSON.double(1e-5).text, "1e-05")
        XCTAssertEqual(PyJSON.double(1e16).text, "1e+16")
        XCTAssertEqual(PyJSON.string("Ñandú \"x\"").text, "\"Ñandú \\\"x\\\"\"")
    }
}
