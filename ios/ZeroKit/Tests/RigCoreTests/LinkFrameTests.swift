import XCTest

@testable import RigCore

final class LinkFrameTests: XCTestCase {
    private let tag = Data(repeating: 0xAB, count: LinkFrame.tagLength)

    func testEveryTypeRoundTrips() {
        for type in LinkFrameType.allCases {
            let frame = LinkFrame(
                type: type,
                flags: [.idr],
                session: type.preSession ? 0 : 7,
                seq: 42,
                rigMs: 1_234_567,
                payload: Data("hola \(type.rawValue)".utf8),
                tag: type.preSession ? Data() : tag
            )
            guard case let .frame(vuelta, consumed) = LinkFrame.decode(from: frame.encode()) else {
                return XCTFail("\(type) no decodificó")
            }
            XCTAssertEqual(vuelta, frame, "\(type)")
            XCTAssertEqual(consumed, frame.encode().count, "\(type)")
        }
    }

    func testTheCatalogCodesAreTheContract() {
        // Los códigos no se reutilizan: si esto cambia, cambió el cable, no un detalle.
        XCTAssertEqual(LinkFrameType.hello.rawValue, 1)
        XCTAssertEqual(LinkFrameType.legacy.rawValue, 16)
        XCTAssertEqual(LinkFrameType.heartbeat.rawValue, 17)
        XCTAssertEqual(LinkFrameType.colorMeans.rawValue, 24)
        XCTAssertEqual(LinkFrameType.allCases.count, 24)
    }

    func testChannelsFollowTheAdr() {
        XCTAssertEqual(LinkFrameType.command.channel, .control)
        XCTAssertEqual(LinkFrameType.thumb.channel, .control)
        XCTAssertEqual(LinkFrameType.detections.channel, .media)
        XCTAssertEqual(LinkFrameType.view.channel, .media)
        XCTAssertTrue(LinkFrameType.hello.preSession)
        XCTAssertTrue(LinkFrameType.auth.preSession)
        XCTAssertFalse(LinkFrameType.command.preSession)
    }

    func testAStreamWithTwoFramesSeparatesByLength() {
        let a = LinkFrame(type: .heartbeat, session: 1, seq: 0, rigMs: 10, payload: Data([1]), tag: tag)
        let b = LinkFrame(type: .command, session: 1, seq: 1, rigMs: 20, payload: Data([2, 3]), tag: tag)
        var stream = a.encode()
        stream.append(b.encode())

        guard case let .frame(primera, consumed) = LinkFrame.decode(from: stream) else {
            return XCTFail("la primera no salió")
        }
        XCTAssertEqual(primera, a)
        guard case let .frame(segunda, _) = LinkFrame.decode(from: stream.dropFirst(consumed)) else {
            return XCTFail("la segunda no salió")
        }
        XCTAssertEqual(segunda, b)
    }

    func testTenThousandRandomOrTruncatedFramesNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        var validas = 0
        for intento in 0..<10_000 {
            var data: Data
            if intento % 3 == 0 {
                // Una trama buena, truncada por un punto cualquiera.
                let frame = LinkFrame(
                    type: .detections, session: 5, seq: UInt32(intento), rigMs: 1,
                    payload: Data((0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }),
                    tag: tag
                )
                let entera = frame.encode()
                data = Data(entera.prefix(Int.random(in: 0..<entera.count, using: &rng)))
            } else {
                data = Data((0..<Int.random(in: 0...96, using: &rng)).map { _ in
                    UInt8.random(in: 0...255, using: &rng)
                })
            }
            switch LinkFrame.decode(from: data) {
            case .frame: validas += 1
            case .needsMoreData, .invalid: break
            }
        }
        // El fuzzing casi nunca fabrica una trama válida; lo que se exige es no reventar.
        XCTAssertLessThan(validas, 100)
    }

    func testAnAbsurdLengthIsInvalidNotAnAllocation() {
        var data = Data()
        data.appendBigEndian(LinkFrame.magic)
        data.append(LinkFrame.version)
        data.append(LinkFrameType.part.rawValue)
        data.append(0)
        data.appendBigEndian(UInt32(1))
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(UInt64(0))
        data.appendBigEndian(UInt32(50_000_000))  // 50 MB: mentira

        guard case .invalid(let campo) = LinkFrame.decode(from: data) else {
            return XCTFail("tenía que ser inválida")
        }
        XCTAssertEqual(campo, "length")
    }

    func testThirtyDetectionsFitInThreeHundredBytes() {
        let cajas = (0..<30).map { indice in
            WireDetection(
                x1: UInt16(indice * 10), y1: 100, x2: UInt16(indice * 10 + 17), y2: 140,
                classId: 2, score: 230
            )
        }
        let payload = DetectionsPayload.encode(inferMs: 12, detections: cajas)

        XCTAssertLessThanOrEqual(payload.count - 4, 300)  // 10 B por caja
        let (inferMs, vuelta) = DetectionsPayload.decode(payload)!
        XCTAssertEqual(inferMs, 12)
        XCTAssertEqual(vuelta, cajas)
    }
}
