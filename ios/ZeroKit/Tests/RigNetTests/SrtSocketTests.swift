import Foundation
import XCTest

import RigCore
import RigNet

/// SrtSocket contra un eco SRT local (IOS-55): `srt-live-transmit` en escucha, con
/// passphrase, que escribe lo que recibe en un fichero. Se salta si no está instalado
/// (`brew install srt`).
final class SrtSocketTests: XCTestCase {
    private let frase = "frase-de-paso-del-banco"

    /// Arranca el eco y devuelve su puerto, el fichero donde deja lo recibido y el proceso.
    private func eco(passphrase: String) throws -> (UInt16, URL, Process) {
        guard let slt = SrtTestSupport.tool("srt-live-transmit") else {
            throw XCTSkip("sin srt-live-transmit en este Mac (brew install srt)")
        }
        let puerto = SrtTestSupport.freeUdpPort()
        let salida = try SrtTestSupport.tempDir(self).appendingPathComponent("eco.ts")
        let p = try SrtTestSupport.launch(slt, ["-q", "srt://127.0.0.1:\(puerto)?mode=listener&passphrase=\(passphrase)",
                                                "file://con"], stdout: salida, in: self)
        return (puerto, salida, p)
    }

    func testPublicaConPassphraseYLlegaIgual() throws {
        let (puerto, salida, proceso) = try eco(passphrase: frase)
        let socket = SrtSocket()
        defer { socket.close() }
        try SrtTestSupport.connect(socket) {
            try $0.connect(host: "127.0.0.1", port: puerto, streamId: "publish:programa", passphrase: self.frase,
                           latencyMs: 120, timeoutMs: 300)
        }
        XCTAssertTrue(socket.isConnected)

        // 1 MB en trozos de 70 paquetes TS, 10 veces por segundo: unos 8 Mbit/s.
        let datos = SrtTestSupport.nullTsPackets(5600)
        let trozo = 70 * TsFormat.packetSize
        for inicio in stride(from: 0, to: datos.count, by: trozo) {
            let parte = datos[inicio..<min(inicio + trozo, datos.count)]
            XCTAssertEqual(try socket.send(Data(parte)), parte.count, "el búfer de SRT no debería llenarse")
            Thread.sleep(forTimeInterval: 0.01)
        }
        let stats = try socket.stats()
        XCTAssertEqual(stats.packetsSent - Int64(stats.packetsRetransmitted), Int64(datos.count / ProgramSrt.payloadBytes))
        XCTAssertGreaterThanOrEqual(stats.bytesSent, UInt64(datos.count))
        XCTAssertEqual(stats.packetsDropped, 0)
        XCTAssertFalse(stats.description.isEmpty)

        // Llega pasada la latencia (120 ms) de TSBPD. El eco vacía su stdout al salir.
        Thread.sleep(forTimeInterval: 1)
        socket.close()
        proceso.interrupt()
        proceso.waitUntilExit()
        let recibido = try Data(contentsOf: salida)
        XCTAssertEqual(recibido.count, datos.count)
        XCTAssertTrue(recibido == datos, "el eco devuelve otros bytes")
    }

    func testUnaPassphraseErroneaSeRechaza() throws {
        let (puerto, _, _) = try eco(passphrase: frase)
        let socket = SrtSocket()
        XCTAssertThrowsError(try SrtTestSupport.connect(socket) {
            try $0.connect(host: "127.0.0.1", port: puerto, streamId: "publish:programa",
                           passphrase: "otra-frase-de-paso", latencyMs: 120, timeoutMs: 300)
        }) { XCTAssertEqual($0 as? SrtError, .rejected(SrtError.rejectBadSecret)) }
        XCTAssertFalse(socket.isConnected)

        XCTAssertThrowsError(try SrtTestSupport.connect(socket) {
            try $0.connect(host: "127.0.0.1", port: puerto, streamId: "publish:programa",
                           passphrase: nil, latencyMs: 120, timeoutMs: 300)
        }) { XCTAssertEqual($0 as? SrtError, .rejected(SrtError.rejectUnsecure), "sin cifrar tampoco entra") }
    }

    func testElStreamidYLaPassphraseSeCompruebanAntesDeSalir() {
        // Sin red: ni siquiera se resuelve el host.
        let socket = SrtSocket()
        XCTAssertThrowsError(try socket.connect(host: "no.existe.invalid", port: 1, streamId: "publish:a:b:c:d:e",
                                                passphrase: nil)) {
            XCTAssertEqual($0 as? SrtError, .invalid(.badPartCount(6)))
        }
        XCTAssertThrowsError(try socket.connect(host: "no.existe.invalid", port: 1, streamId: "publish:programa",
                                                passphrase: "corta")) {
            XCTAssertEqual($0 as? SrtError, .invalid(.badPassphraseLength(5)))
        }
        let destino = ProgramSrtTarget(host: "no.existe.invalid", port: 1, user: "ma:estro", pass: "clave",
                                       passphrase: frase)
        XCTAssertThrowsError(try socket.connect(to: destino)) {
            XCTAssertEqual($0 as? SrtError, .invalid(.badCharacter(field: "user")))
        }
        XCTAssertThrowsError(try socket.send(Data([0x47]))) { XCTAssertEqual($0 as? SrtError, .notConnected) }
        XCTAssertThrowsError(try socket.stats()) { XCTAssertEqual($0 as? SrtError, .notConnected) }
    }

    func testLosErroresNoLlevanSecretos() {
        let destino = ProgramSrtTarget(host: "no.existe.invalid", port: 1, user: "maestro", pass: "secreta:9",
                                       passphrase: "frase:secreta-9")
        XCTAssertThrowsError(try SrtSocket().connect(to: destino)) { XCTAssertFalse("\($0)".contains("secreta")) }
        XCTAssertTrue(SrtError.rejected(SrtError.rejectBadSecret).description.hasSuffix("(10)"))
        XCTAssertEqual([SrtError.rejectPeer, SrtError.rejectBadSecret, SrtError.rejectUnsecure], [2, 10, 11])
    }
}
