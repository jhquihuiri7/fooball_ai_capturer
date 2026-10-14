import Foundation
import RigCore
import XCTest

/// El streamid y el destino del programa por SRT (ADR 0022; IOS-55).
final class ProgramSrtTests: XCTestCase {
    private let destino = ProgramSrtTarget(host: "vps.example.org", port: 8890, user: "maestro",
                                           pass: "c1av3-Larga_9.x", passphrase: "frase-de-paso-larga")

    func testElStreamidDelVps() throws {
        XCTAssertEqual(try destino.streamId(), "publish:programa:maestro:c1av3-Larga_9.x")
        XCTAssertEqual(try destino.streamId(query: "term=3&dev=AB12-cd"),
                       "publish:programa:maestro:c1av3-Larga_9.x:term=3&dev=AB12-cd")
    }

    func testSinCredencialesEsElDelBanco() throws {
        XCTAssertEqual(try ProgramSrtStreamId.publish(path: "programa"), "publish:programa")
        XCTAssertEqual(try ProgramSrtStreamId.publish(path: "rig/izquierda"), "publish:rig/izquierda")
    }

    func testDosPuntosOAlfabetoMaloNoSalen() {
        let casos: [(String?, String?, String?, ProgramSrtError)] = [
            ("ma:estro", "clave", nil, .badCharacter(field: "user")),
            ("maestro", "cla:ve", nil, .badCharacter(field: "pass")),
            ("maestro", "cla~ve", nil, .badCharacter(field: "pass")),  // el authInternal lo rechaza
            ("maestro", "clave con espacio", nil, .badCharacter(field: "pass")),
            ("maestro", "", nil, .emptyField("pass")),
            ("maestro", nil, nil, .emptyField("pass")),
            ("maestro", "clave", "term=1:dev=x", .badCharacter(field: "query")),
        ]
        for (user, pass, query, esperado) in casos {
            XCTAssertThrowsError(try ProgramSrtStreamId.publish(path: "programa", user: user, pass: pass, query: query)) {
                XCTAssertEqual($0 as? ProgramSrtError, esperado)
            }
        }
        XCTAssertThrowsError(try ProgramSrtStreamId.publish(path: "pro:grama")) {
            XCTAssertEqual($0 as? ProgramSrtError, .badCharacter(field: "path"))
        }
    }

    func testCincoPartesY512CaracteresComoMucho() throws {
        let id = try destino.streamId(query: "q")
        XCTAssertEqual(id.split(separator: ":").count, 5)
        let cabe = String(repeating: "x", count: 512 - "publish:programa:maestro:c1av3-Larga_9.x:".count)
        XCTAssertEqual(try destino.streamId(query: cabe).count, 512)
        XCTAssertThrowsError(try destino.streamId(query: cabe + "x")) {
            XCTAssertEqual($0 as? ProgramSrtError, .tooLong(513))
        }
    }

    func testValidarCualquierStreamid() throws {
        try ProgramSrtStreamId.validate("publish:programa")
        try ProgramSrtStreamId.validate("read:programa:u:p:q")
        try ProgramSrtStreamId.validate(try destino.streamId(query: "term=1"))
        for (id, error) in [("publish", ProgramSrtError.badPartCount(1)),
                            ("publish:a:b:c:d:e", .badPartCount(6)),
                            ("publish::u:p", .emptyField("streamid")),
                            ("publish:pro grama", .badCharacter(field: "streamid")),
                            ("publish:" + String(repeating: "x", count: 505), .tooLong(513))] {
            XCTAssertThrowsError(try ProgramSrtStreamId.validate(id)) { XCTAssertEqual($0 as? ProgramSrtError, error) }
        }
    }

    func testLaPassphrase() throws {
        XCTAssertEqual(try destino.checkedPassphrase(), "frase-de-paso-larga")
        for (frase, error) in [("corta", ProgramSrtError.badPassphraseLength(5)),
                               (String(repeating: "a", count: 80), .badPassphraseLength(80)),
                               ("frase:de:paso", .badCharacter(field: "passphrase"))] {
            let malo = ProgramSrtTarget(host: "h", port: 1, user: "u", pass: "p", passphrase: frase)
            XCTAssertThrowsError(try malo.checkedPassphrase()) { XCTAssertEqual($0 as? ProgramSrtError, error) }
        }
    }

    func testElBloqueSrtDelQrYSinSecretosEnElLog() throws {
        // El bloque `srt` de support_payload (tools/nube/pairing.py, NUBE-16).
        let json = #"{"host":"vps.example.org","port":8890,"path":"programa","user":"maestro","pass":"c1av3-Larga_9.x","passphrase":"frase-de-paso-larga"}"#
        let leido = try JSONDecoder().decode(ProgramSrtTarget.self, from: Data(json.utf8))
        XCTAssertEqual(leido, destino)
        XCTAssertEqual("\(leido)", "srt://vps.example.org:8890 publish:programa:maestro:***")
        XCTAssertFalse(String(reflecting: leido).contains("c1av3"))
    }

    func testLasConstantesDelContrato() {
        // tools/program_contract.py: PROGRAM_SRT_PATH y PROGRAM_SRT_LATENCY_MS.
        XCTAssertEqual(ProgramSrt.path, "programa")
        XCTAssertEqual(ProgramSrt.latencyMs, 1500)
        XCTAssertEqual(ProgramSrt.payloadBytes, 7 * TsFormat.packetSize)
    }
}
