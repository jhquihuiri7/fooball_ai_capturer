import XCTest

@testable import RigCore

/// Los mensajes del enlace entre móviles (TASK A3): lo que sale tiene que volver igual,
/// y lo que no es nuestro o llega cortado se ignora sin reventar.
final class RigMessageTests: XCTestCase {
    func testEveryMessageRoundTrips() {
        let messages: [RigMessage] = [
            .ping(seq: 1, t1: 550_889_603_000_000),
            .pong(seq: 7, t1: -5, t2: Int64.max, t3: Int64.min),
            .ptsRequest(seq: UInt32.max),
            .ptsReply(seq: 9, pts: []),
            .ptsReply(seq: 10, pts: [0, 33_333_333, 66_666_666]),
            .lookRequest(seq: 11),
            .look(seq: 12, look: CameraLook(exposureNs: 10_000_000, iso: 412.5, aperture: 2.2, kelvin: 5234, tint: -3.5)),
            .command(seq: 13, command: .recordAndSave),
        ]
        for message in messages {
            XCTAssertEqual(RigMessage.decode(message.encode()), message)
        }
    }

    func testPingIsSmallAndFixedSize() {
        // Tipo, secuencia y un sello: cabe de sobra en un datagrama.
        XCTAssertEqual(RigMessage.ping(seq: 1, t1: 2).encode().count, 13)
        XCTAssertEqual(RigMessage.pong(seq: 1, t1: 2, t2: 3, t3: 4).encode().count, 29)
    }

    func testTruncatedOrForeignPacketsAreIgnored() {
        XCTAssertNil(RigMessage.decode(Data()))
        XCTAssertNil(RigMessage.decode(Data([99, 0, 0, 0, 1])))
        let pong = RigMessage.pong(seq: 1, t1: 2, t2: 3, t3: 4).encode()
        XCTAssertNil(RigMessage.decode(pong.dropLast(3)))
    }

    func testAnUnknownCommandByteIsIgnoredWhole() {
        // Una orden de una versión futura de la app: mejor no grabar que adivinar.
        var data = RigMessage.command(seq: 1, command: .stop).encode()
        data[data.count - 1] = 250
        XCTAssertNil(RigMessage.decode(data))
    }

    func testACorruptLookNeverReachesTheCamera() {
        // Un ISO que no es un número lanzaría una excepción dentro de AVFoundation.
        let bad = CameraLook(exposureNs: 10_000_000, iso: .nan, aperture: 2.2, kelvin: 5000, tint: 0)
        XCTAssertNil(RigMessage.decode(RigMessage.look(seq: 1, look: bad).encode()))
        let frozen = CameraLook(exposureNs: 0, iso: 100, aperture: 2.2, kelvin: 5000, tint: 0)
        XCTAssertNil(RigMessage.decode(RigMessage.look(seq: 1, look: frozen).encode()))
    }

    func testIsoFollowsTheApertureSoBothPhonesGetTheSameLight() {
        let look = CameraLook(exposureNs: 10_000_000, iso: 100, aperture: 2.2, kelvin: 5000, tint: 0)
        XCTAssertEqual(look.iso(forAperture: 2.2), 100, accuracy: 0.01)
        // f/1.8 deja pasar más luz que f/2.2: hace falta menos ISO.
        XCTAssertEqual(look.iso(forAperture: 1.8), 100 * (1.8 * 1.8) / (2.2 * 2.2), accuracy: 0.01)
        XCTAssertEqual(CameraLook(exposureNs: 1, iso: 100, aperture: 0, kelvin: 0, tint: 0).iso(forAperture: 1.8), 100)
    }
}
