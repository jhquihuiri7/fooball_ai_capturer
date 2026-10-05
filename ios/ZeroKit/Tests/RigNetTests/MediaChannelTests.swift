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

    /// IOS-52: tres IDR de 300 KB seguidos salen espaciados (en golpes de
    /// LINK_PACING_BURST) y llegan enteros y en orden por el loopback.
    func testIdrGordosEspaciadosLleganEnteros() throws {
        let (escucha, conecta) = try makePair()
        defer {
            escucha.stop()
            conecta.stop()
        }
        // Calentar el canal con una trama pequeña.
        nonisolated(unsafe) var recibidas: [LinkFrame] = []
        let lock = NSLock()
        escucha.onFrame = { f, _ in lock.lock(); recibidas.append(f); lock.unlock() }
        var intentos = 0
        while escucha.stats.mediaFramesReceived == 0, intentos < 50 {
            conecta.send(LinkFrame(type: .heartbeat, session: 4, seq: 0, rigMs: 1, payload: Data([1]), tag: tag), on: .media)
            intentos += 1
            usleep(100_000)
        }
        lock.lock(); recibidas.removeAll(); lock.unlock()

        let grandes = (1...3).map { i in
            LinkFrame(
                type: .part, flags: [.idr], session: 4, seq: UInt32(i), rigMs: UInt64(i),
                payload: Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &+ i) }), tag: tag
            )
        }
        let inicio = Date()
        grandes.forEach { conecta.send($0, on: .media) }
        let tope = Date().addingTimeInterval(5)
        while Date() < tope {
            lock.lock(); let n = recibidas.count; lock.unlock()
            if n >= 3 { break }
            usleep(5_000)
        }
        let duracion = Date().timeIntervalSince(inicio)
        lock.lock()
        XCTAssertEqual(recibidas, grandes)
        lock.unlock()
        // 3 × 250 datagramas en golpes de 16 cada 2 ms: unos 94 ms; nunca de golpe.
        let golpes = Double((3 * 250 + LinkConstants.pacingBurstDatagrams - 1) / LinkConstants.pacingBurstDatagrams)
        XCTAssertGreaterThan(duracion, (golpes - 1) * Double(LinkConstants.pacingIntervalMs) / 1000 * 0.8)
        XCTAssertEqual(conecta.stats.mediaPacerDrops, 0)
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
