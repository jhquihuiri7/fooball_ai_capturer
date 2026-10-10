import Network
import XCTest

import RigCore
@testable import RigNet

/// El canal de control por el loopback de macOS (IOS-11): conexión, tramas en los dos
/// sentidos, reconexión y la basura que cierra.
final class NWLinkTransportTests: XCTestCase {
    private let tag = Data(repeating: 1, count: LinkFrame.tagLength)

    private func frame(seq: UInt32, type: LinkFrameType = .heartbeat) -> LinkFrame {
        LinkFrame(type: type, session: 9, seq: seq, rigMs: 5, payload: Data([7]), tag: tag)
    }

    private func makePair() throws -> (NWLinkTransport, NWLinkTransport) {
        let escucha = NWLinkTransport(mode: .listen(port: 0), interfaceType: nil)
        let puertoListo = expectation(description: "puerto")
        puertoListo.assertForOverFulfill = false  // la escucha puede volver a estar lista
        var puerto: UInt16 = 0
        escucha.onReady = { asignado in
            puerto = asignado
            puertoListo.fulfill()
        }
        escucha.start()
        wait(for: [puertoListo], timeout: 10)

        let conecta = NWLinkTransport(
            mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil
        )
        return (escucha, conecta)
    }

    func testConnectsAndExchangesFramesBothWays() throws {
        let (escucha, conecta) = try makePair()
        defer {
            escucha.stop()
            conecta.stop()
        }

        let recibioEscucha = expectation(description: "escucha recibe")
        let recibioConecta = expectation(description: "conecta recibe")
        escucha.onFrame = { frame, canal in
            XCTAssertEqual(canal, .control)
            XCTAssertEqual(frame.seq, 1)
            recibioEscucha.fulfill()
        }
        conecta.onFrame = { frame, _ in
            XCTAssertEqual(frame.seq, 2)
            recibioConecta.fulfill()
        }
        let conectado = expectation(description: "conectado")
        conecta.onState = { estado in
            if estado == .connected { conectado.fulfill() }
        }
        conecta.start()
        wait(for: [conectado], timeout: 10)

        conecta.send(frame(seq: 1), on: .control)
        wait(for: [recibioEscucha], timeout: 10)
        // Para contestar, el que escucha tiene que haber adoptado ya la conexión.
        let tope = Date().addingTimeInterval(5)
        while escucha.state != .connected, Date() < tope { usleep(10_000) }
        escucha.send(frame(seq: 2), on: .control)
        wait(for: [recibioConecta], timeout: 10)

        XCTAssertGreaterThanOrEqual(conecta.stats.framesSent, 1)
        XCTAssertGreaterThanOrEqual(conecta.stats.framesReceived, 1)
    }

    func testReconnectsAfterTheConnectionDrops() throws {
        let (escucha, conecta) = try makePair()
        let puerto = escucha.localPort
        defer { conecta.stop() }

        nonisolated(unsafe) var conexiones = 0
        let reconectado = expectation(description: "reconectado")
        conecta.onState = { estado in
            if estado == .connected {
                conexiones += 1
                if conexiones == 2 { reconectado.fulfill() }
            }
        }
        conecta.start()

        // En cuanto los dos lados se ven, el que escucha se cae del todo y vuelve EN
        // EL MISMO PUERTO: el otro tiene que volver solo, con su espera de tope 2 s.
        let tope = Date().addingTimeInterval(10)
        while escucha.state != .connected, Date() < tope { usleep(10_000) }
        escucha.stop()
        usleep(200_000)
        let escucha2 = NWLinkTransport(mode: .listen(port: puerto), interfaceType: nil)
        escucha2.start()
        defer { escucha2.stop() }

        wait(for: [reconectado], timeout: 15)
        XCTAssertGreaterThanOrEqual(conecta.stats.reconnects, 1)
    }

    func testGarbageOnControlClosesTheConnection() throws {
        let escucha = NWLinkTransport(mode: .listen(port: 0), interfaceType: nil)
        let puertoListo = expectation(description: "puerto")
        puertoListo.assertForOverFulfill = false
        nonisolated(unsafe) var puerto: UInt16 = 0
        escucha.onReady = { p in
            puerto = p
            puertoListo.fulfill()
        }
        escucha.start()
        wait(for: [puertoListo], timeout: 10)
        defer { escucha.stop() }

        // Un socket a pelo que manda basura con pinta de nada.
        let basura = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: puerto)!, using: .tcp
        )
        basura.start(queue: .global())
        basura.send(
            content: Data([0xDE, 0xAD, 0xBE, 0xEF] + Array(repeating: 0, count: 30)),
            completion: .contentProcessed { _ in }
        )

        let tope = Date().addingTimeInterval(5)
        while escucha.stats.invalidFrames == 0, Date() < tope { usleep(10_000) }
        XCTAssertEqual(escucha.stats.invalidFrames, 1)
        basura.cancel()
    }

    func testReconnectBackoffIsCappedAtTwoSeconds() {
        XCTAssertEqual(NWLinkTransport.reconnectDelaysS.max(), 2.0)
    }

    /// La fuga del maestro (2026-10-10): 300 miniaturas de 30 KB por control. El búfer
    /// de control no pasa de una trama a medias y los bytes quedan contados. Antes
    /// guardaba los 9 MB.
    func testControlBufferKeepsAtMostOneFrameAndCountsTheBytes() throws {
        let (escucha, conecta) = try makePair()
        defer {
            escucha.stop()
            conecta.stop()
        }
        let miniaturas = 300
        let miniatura = LinkFrame(
            type: .thumb, session: 9, seq: 1, rigMs: 5, payload: Data(repeating: 0x5A, count: 30_000), tag: tag
        )
        let todas = expectation(description: "miniaturas")
        todas.expectedFulfillmentCount = miniaturas
        escucha.onFrame = { frame, canal in
            if canal == .control, frame.type == .thumb { todas.fulfill() }
        }
        let conectado = expectation(description: "conectado")
        conecta.onState = { estado in
            if estado == .connected { conectado.fulfill() }
        }
        conecta.start()
        wait(for: [conectado], timeout: 10)

        for _ in 0..<miniaturas {
            conecta.send(miniatura, on: .control)
        }
        wait(for: [todas], timeout: 20)

        let stats = escucha.statsSnapshot
        XCTAssertEqual(stats.controlBytesReceived, miniaturas * miniatura.encode().count)
        XCTAssertGreaterThan(stats.controlBufferPeakBytes, 0, "llegaron tramas cortadas")
        XCTAssertLessThan(stats.controlBufferPeakBytes, miniatura.encode().count)
    }
}

/// La huella del proceso, lo que mira jetsam: que el lector de control no la haga crecer.
final class ControlReaderFootprintTests: XCTestCase {
    private static func footprintMb() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// 100 MB de miniaturas por el lector, a trozos de 64 KB como los de NWConnection: la
    /// huella no se mueve. Con el `removeFirst` de antes subía esos 100 MB (medido en el
    /// Mac: 145 MB de huella tras 143 MB recibidos).
    func testAHundredMegabytesThroughTheReaderDoNotStay() {
        let tag = Data(repeating: 1, count: LinkFrame.tagLength)
        let una = LinkFrame(
            type: .thumb, session: 9, seq: 1, rigMs: 5, payload: Data(repeating: 0x5A, count: 30_000), tag: tag
        ).encode()
        let total = 100 * 1_048_576
        var lector = LinkStreamReader()
        var tramas = 0
        let antes = Self.footprintMb()
        var posicion = 0
        while posicion < total {
            let n = min(LinkConstants.controlReadChunkB, total - posicion)
            var trozo = Data(capacity: n)
            while trozo.count < n {
                let dentro = (posicion + trozo.count) % una.count
                trozo.append(una[dentro..<min(una.count, dentro + n - trozo.count)])
            }
            tramas += lector.push(trozo).frames.count
            posicion += n
        }
        let crecio = Self.footprintMb() - antes
        XCTAssertEqual(tramas, total / una.count)
        XCTAssertLessThan(crecio, 25, "la huella creció \(crecio) MB con 100 MB leídos")
    }
}
