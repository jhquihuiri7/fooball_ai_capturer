import Network
import XCTest

import RigCore
@testable import RigNet

/// El canal de medios por el loopback (IOS-16): fragmentación de ida y vuelta,
/// huecos de `seq` contados y parones de más de 100 ms.
final class MediaChannelTests: XCTestCase {
    private let tag = Data(repeating: 3, count: LinkFrame.tagLength)

    private func makePair() throws -> (NWLinkTransport, NWLinkTransport) {
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
        // El UDP de los tests escucha en el puerto TCP + 1; se espera a que esté.
        let tope = Date().addingTimeInterval(5)
        while escucha.mediaLocalPort == 0, Date() < tope { usleep(10_000) }
        XCTAssertEqual(escucha.mediaLocalPort, puerto + 1)

        let conecta = NWLinkTransport(
            mode: .connect(host: "127.0.0.1", port: puerto), interfaceType: nil
        )
        conecta.start()
        return (escucha, conecta)
    }

    func testABigFrameTravelsFragmentedAndWhole() throws {
        let (escucha, conecta) = try makePair()
        defer {
            escucha.stop()
            conecta.stop()
        }

        // Más grande que un datagrama: viaja en varios y llega entera.
        let payload = Data((0..<(LinkConstants.datagramPayloadB * 2 + 100)).map {
            UInt8(truncatingIfNeeded: $0)
        })
        let frame = LinkFrame(
            type: .part, flags: [.idr], session: 4, seq: 0, rigMs: 77,
            payload: payload, tag: tag
        )
        let llegada = expectation(description: "media llega")
        escucha.onFrame = { recibido, canal in
            XCTAssertEqual(canal, .media)
            XCTAssertEqual(recibido, frame)
            llegada.fulfill()
        }

        // El UDP del conectante tarda un instante en estar listo: se insiste.
        var intentos = 0
        while escucha.stats.mediaFramesReceived == 0, intentos < 50 {
            conecta.send(frame, on: .media)
            intentos += 1
            usleep(100_000)
        }
        wait(for: [llegada], timeout: 5)
    }

    func testSeqGapsAndStallsAreCounted() throws {
        let (escucha, conecta) = try makePair()
        defer {
            escucha.stop()
            conecta.stop()
        }
        escucha.onFrame = { _, _ in }

        func media(_ seq: UInt32) -> LinkFrame {
            LinkFrame(type: .heartbeat, session: 4, seq: seq, rigMs: 1, payload: Data([9]), tag: tag)
        }

        // Primero uno, para que el canal esté caliente.
        var intentos = 0
        while escucha.stats.mediaFramesReceived == 0, intentos < 50 {
            conecta.send(media(1), on: .media)
            intentos += 1
            usleep(100_000)
        }
        let base = escucha.stats.mediaFramesReceived

        // Un parón de más de 100 ms, y detrás un salto del seq de la trama (el canal
        // cuenta por el seq del fragmentador, que crece 1 por send: el hueco se simula
        // con la trama que no se manda).
        usleep(200_000)
        conecta.send(media(2), on: .media)
        let tope = Date().addingTimeInterval(5)
        while escucha.stats.mediaFramesReceived < base + 1, Date() < tope { usleep(10_000) }

        XCTAssertGreaterThanOrEqual(escucha.stats.mediaStallsOver100Ms, 1)
        XCTAssertEqual(escucha.stats.invalidFrames, 0)
    }
}
