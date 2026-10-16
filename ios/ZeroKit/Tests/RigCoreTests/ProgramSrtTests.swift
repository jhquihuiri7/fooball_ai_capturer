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
        // MediaMTX tarda 2 s en rechazar una clave mala: el timeout deja margen al RTT.
        XCTAssertGreaterThanOrEqual(ProgramSrt.connectTimeoutMs, 4000)
    }

    // MARK: - La latencia que sube (2026-10-15)

    func testLaEscaleraDeLatenciaEmpiezaEnLaDePartidaYSubeHastaCuatroSegundos() {
        XCTAssertEqual(ProgramSrt.latencyStepsMs, [1500, 2500, 4000])
        XCTAssertEqual(ProgramSrt.latencyStepsMs.first, ProgramSrt.latencyMs)
        XCTAssertEqual(ProgramSrt.latencyStepsMs, ProgramSrt.latencyStepsMs.sorted(), "estrictamente creciente")
        XCTAssertEqual(Set(ProgramSrt.latencyStepsMs).count, ProgramSrt.latencyStepsMs.count)
        XCTAssertEqual(ProgramSrt.latencyStepsMs.last, 4000, "el tope: ~4,25 s de cristal a VPS")
    }

    func testLaLatenciaSubeEscalonAEscalonYSeQuedaEnElTope() {
        var l = ProgramSrtLatency()
        XCTAssertEqual(l.ms, 1500)
        XCTAssertEqual(l.raises, 0)
        XCTAssertEqual(l.nextMs, 2500)
        XCTAssertTrue(l.canRaise)
        XCTAssertTrue(l.raise())
        XCTAssertEqual(l.ms, 2500)
        XCTAssertTrue(l.raise())
        XCTAssertEqual(l.ms, 4000)
        XCTAssertFalse(l.canRaise)
        XCTAssertFalse(l.raise(), "en el tope se queda")
        XCTAssertEqual(l.ms, 4000)
        XCTAssertEqual(l.raises, 2)
        // Las pruebas con eco local conectan con 120 ms: el escalón siguiente es el primero
        // de la escalera que la supera.
        var corta = ProgramSrtLatency(startMs: 120)
        XCTAssertTrue(corta.raise())
        XCTAssertEqual(corta.ms, 1500)
    }

    func testElUmbralDeRetencionEsLaMitadDeLaLatenciaEnUso() {
        var l = ProgramSrtLatency()
        XCTAssertEqual(l.congestionSendBufferMs, 750, "lo que era la constante")
        l.raise()
        XCTAssertEqual(l.congestionSendBufferMs, 1250)
        l.raise()
        XCTAssertEqual(l.congestionSendBufferMs, 2000)
        XCTAssertEqual(ProgramPublish.congestionSendBufferMs(latencyMs: 1500), 750)
    }

    func testUnaConexionPideMasLatenciaSiSuRttOSuBuferPasaronDeLaMitad() {
        let l = ProgramSrtLatency()
        XCTAssertFalse(l.sessionAsksForMore(rttMsMax: 750, sendBufferMsMax: 750), "justo la mitad, no")
        XCTAssertTrue(l.sessionAsksForMore(rttMsMax: 779, sendBufferMsMax: 0), "la sesión de las 20:52")
        XCTAssertTrue(l.sessionAsksForMore(rttMsMax: 142, sendBufferMsMax: 1520), "la de las 20:19")
        XCTAssertFalse(l.sessionAsksForMore(rttMsMax: 142, sendBufferMsMax: 300))
        var alta = ProgramSrtLatency()
        alta.raise()  // 2500: la mitad es 1250
        XCTAssertFalse(alta.sessionAsksForMore(rttMsMax: 1200, sendBufferMsMax: 1250))
        XCTAssertTrue(alta.sessionAsksForMore(rttMsMax: 1300, sendBufferMsMax: 0))
    }

    func testElTextoDeLaLatenciaParaLaPantallaYElLog() {
        XCTAssertEqual(ProgramSrtLatency.label(ms: 1500), "1,5 s")
        XCTAssertEqual(ProgramSrtLatency.label(ms: 2500), "2,5 s")
        XCTAssertEqual(ProgramSrtLatency.label(ms: 4000), "4 s")
        XCTAssertEqual(ProgramSrtLatency.label(ms: 120), "0,1 s")
        XCTAssertEqual("\(ProgramSrtLatency())", "latencia SRT 1,5 s")
    }
}
