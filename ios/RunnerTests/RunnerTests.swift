import CoreVideo
import XCTest

@testable import Runner

/// El código de tiempo tiene que ser bit a bit el del servidor
/// (`tests/unit/test_timecode.py` en `football-ai`). Estos tests fijan lo que no puede
/// cambiar por un lado solo.
final class RigTimecodeTests: XCTestCase {
    func testCrcKnownAnswer() {
        // CRC-8/SMBUS de "123456789": la misma comprobación que hace el servidor.
        XCTAssertEqual(RigTimecode.crc8(Array("123456789".utf8)), 0xF4)
    }

    func testWordLayout() {
        let word = RigTimecode.word(valueMs: 1)
        XCTAssertEqual(word >> 56, 0xB2)
        XCTAssertEqual((word >> 8) & RigTimecode.payloadMax, 1)
        XCTAssertEqual(word & 0xFF, UInt64(RigTimecode.crc8([0, 0, 0, 0, 0, 1])))
    }

    func testCellSideMatchesServer() {
        XCTAssertEqual(RigTimecode.cellSide(width: 3840), 16)
        XCTAssertEqual(RigTimecode.cellSide(width: 1920), 8)
        XCTAssertEqual(RigTimecode.cellSide(width: 640), 4)
        XCTAssertEqual(RigTimecode.cellSide(width: 3000), 12)
    }

    func testWritesIntoLumaPlaneAndReadsBack() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let value: UInt64 = 123_456_789_012

        XCTAssertTrue(RigTimecode.write(valueMs: value, into: pixels))

        XCTAssertEqual(readBack(pixels), value)
    }

    func testRejectsBuffersWithoutLumaPlane() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_32BGRA)

        XCTAssertFalse(RigTimecode.write(valueMs: 1, into: pixels))
    }

    func testRejectsValuesThatDoNotFit() throws {
        let pixels = try makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        XCTAssertFalse(RigTimecode.write(valueMs: RigTimecode.payloadMax + 1, into: pixels))
    }

    private func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, format, nil, &buffer)
        return try XCTUnwrap(buffer)
    }

    /// Lector mínimo: el centro de cada celda contra el umbral medio. El lector de
    /// verdad es el del servidor; este solo comprueba que las celdas están donde toca.
    private func readBack(_ pixels: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let side = RigTimecode.cellSide(width: CVPixelBufferGetWidthOfPlane(pixels, 0))
        let threshold = (Int(RigTimecode.lumaOne) + Int(RigTimecode.lumaZero)) / 2

        var word: UInt64 = 0
        for index in 0..<RigTimecode.bits {
            let sample = luma[(side / 2) * stride + index * side + side / 2]
            word = (word << 1) | (Int(sample) > threshold ? 1 : 0)
        }
        guard word >> 56 == RigTimecode.preamble else { return nil }
        let value = (word >> 8) & RigTimecode.payloadMax
        return RigTimecode.word(valueMs: value) == word ? value : nil
    }
}

/// Robustez de campo (TASK A7 y A9): lo que no puede cambiar sin que se note en la cancha.
final class FieldRobustnessTests: XCTestCase {
    func testSegmentNamesKeepTheSideAndNumberTheCuts() {
        XCTAssertEqual(CaptureEngine.segmentName(role: .left, epochSeconds: 1_700_000_000, segment: 1), "left-1700000000.mov")
        XCTAssertEqual(CaptureEngine.segmentName(role: .right, epochSeconds: 1_700_000_000, segment: 3), "right-1700000000-3.mov")
    }

    func testBitrateStepsDownWithHeatAndNeverToZero() {
        XCTAssertEqual(CaptureEngine.bitrateFraction(for: .nominal), 1.0)
        XCTAssertEqual(CaptureEngine.bitrateFraction(for: .fair), 1.0)
        XCTAssertLessThan(CaptureEngine.bitrateFraction(for: .serious), 1.0)
        XCTAssertLessThan(CaptureEngine.bitrateFraction(for: .critical), CaptureEngine.bitrateFraction(for: .serious))
        XCTAssertGreaterThan(CaptureEngine.bitrateFraction(for: .critical), 0.0)
    }
}

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

    func testServiceTypeFitsMultipeerLimit() {
        // Multipeer exige de 1 a 15 caracteres en minúsculas, números y guiones.
        XCTAssertLessThanOrEqual(RigLink.serviceType.count, 15)
        XCTAssertNil(RigLink.serviceType.range(of: "[^a-z0-9-]", options: .regularExpression))
    }
}
