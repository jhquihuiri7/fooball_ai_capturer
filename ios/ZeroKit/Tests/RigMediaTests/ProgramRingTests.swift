import CoreMedia
import XCTest

import RigCore
@testable import RigMedia

/// El anillo del programa (IOS-118, ADR 0034): empieza en un IDR, no pasa de sus topes, el tramo
/// sale desde el IDR anterior a la marca y un formato nuevo tira lo de antes.
final class ProgramRingTests: XCTestCase {
    private static let fps: Int64 = 30
    /// Un IDR cada 2 s, como `PROGRAM_GOP_S`.
    private static let gop = 60

    private func formato(ancho: Int32 = 16) throws -> CMFormatDescription {
        var fd: CMFormatDescription?
        let s = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: ancho, height: 16, extensions: nil,
            formatDescriptionOut: &fd
        )
        XCTAssertEqual(s, noErr)
        return try XCTUnwrap(fd)
    }

    private func fotograma(_ ms: Int64, clave: Bool, bytes: Int = 100, formato: CMFormatDescription) -> EncodedFrame {
        EncodedFrame(data: Data(count: bytes), isKeyframe: clave, rigMs: UInt64(ms), viewId: 0,
                     ptsNs: ms * 1_000_000, formatDescription: formato)
    }

    /// `segundos` de programa a 30 fps desde `desdeMs`, con su IDR cada 2 s.
    private func llena(_ ring: ProgramRing, segundos: Int, desdeMs: Int64 = 0, bytes: Int = 100,
                       formato: CMFormatDescription) {
        for i in 0..<(segundos * Int(Self.fps)) {
            let ms = desdeMs + Int64(i) * 1000 / Self.fps
            ring.append(fotograma(ms, clave: i % Self.gop == 0, bytes: bytes, formato: formato))
        }
    }

    private func anillo(_ segundos: Int64 = 90, bytes: Int = 1 << 30) -> ProgramRing {
        ProgramRing(maxDurationMs: segundos * 1000, maxBytes: bytes, frameDurationMs: 33)
    }

    func testEmpiezaSiempreEnUnIdr() throws {
        let fd = try formato()
        let ring = anillo()
        ring.append(fotograma(0, clave: false, formato: fd))
        ring.append(fotograma(33, clave: false, formato: fd))
        XCTAssertNil(ring.span, "sin IDR no se guarda nada")
        ring.append(fotograma(66, clave: true, formato: fd))
        ring.append(fotograma(100, clave: false, formato: fd))
        XCTAssertEqual(ring.span, ProgramRing.Span(oldestRigMs: 66, newestRigMs: 100))
        XCTAssertEqual(ring.count, 2)
    }

    func testNoPasaDeSuDuracionNiDeSusBytes() throws {
        let fd = try formato()
        let ring = anillo(10)
        llena(ring, segundos: 30, formato: fd)
        let s = try XCTUnwrap(ring.span)
        XCTAssertLessThanOrEqual(s.newestRigMs - s.oldestRigMs, 10_000)
        XCTAssertGreaterThan(s.newestRigMs - s.oldestRigMs, 8_000, "corta en un IDR: como mucho un GOP de menos")
        XCTAssertEqual(s.oldestRigMs % 2_000, 0, "el primero es un IDR")

        let porBytes = anillo(90, bytes: 300_000)
        llena(porBytes, segundos: 30, bytes: 1_000, formato: fd)
        XCTAssertLessThanOrEqual(porBytes.storedBytes, 300_000)
        XCTAssertGreaterThan(porBytes.storedBytes, 200_000)
    }

    func testCompactaSinPerderLaCuenta() throws {
        let fd = try formato()
        let ring = anillo(10)
        llena(ring, segundos: 120, formato: fd)
        let s = try XCTUnwrap(ring.span)
        let esperados = Int((s.newestRigMs - s.oldestRigMs) * Self.fps / 1000) + 1
        XCTAssertEqual(Double(ring.count), Double(esperados), accuracy: 1)
        XCTAssertEqual(ring.storedBytes, ring.count * 100)
    }

    func testElTramoEmpiezaEnElIdrAnteriorALaMarca() throws {
        let fd = try formato()
        let ring = anillo()
        llena(ring, segundos: 20, formato: fd)
        let tramo = try ring.clip(fromRigMs: 5_000, toRigMs: 15_000, minimumMs: 3_000)
        let primero = try XCTUnwrap(tramo.frames.first)
        XCTAssertTrue(primero.isKeyframe)
        XCTAssertEqual(primero.ptsNs / 1_000_000, 4_000, "el IDR de los 4 s")
        XCTAssertEqual(tramo.skipMs, 1_000)
        XCTAssertEqual(tramo.fromRigMs, 5_000)
        XCTAssertEqual(tramo.toRigMs, 15_000)
        XCTAssertLessThan(try XCTUnwrap(tramo.frames.last).ptsNs / 1_000_000, 15_000)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(tramo.frames.last).ptsNs / 1_000_000, 15_000 - 34)
    }

    func testRecortaALoGuardadoYNoBajaDelMinimo() throws {
        let fd = try formato()
        let ring = anillo(10)
        llena(ring, segundos: 20, formato: fd)
        let s = try XCTUnwrap(ring.span)
        let recortado = try ring.clip(fromRigMs: 0, toRigMs: s.oldestRigMs + 5_000, minimumMs: 3_000)
        XCTAssertEqual(recortado.fromRigMs, s.oldestRigMs, "lo de antes ya no está: empieza en lo guardado")
        XCTAssertEqual(recortado.skipMs, 0)
        XCTAssertThrowsError(try ring.clip(fromRigMs: 0, toRigMs: s.oldestRigMs + 1_000, minimumMs: 3_000)) {
            XCTAssertEqual($0 as? ProgramRing.RingError, .tooShort)
        }
        XCTAssertThrowsError(try ring.clip(fromRigMs: s.newestRigMs + 5_000, toRigMs: s.newestRigMs + 9_000,
                                           minimumMs: 3_000)) {
            XCTAssertEqual($0 as? ProgramRing.RingError, .notInMemory)
        }
        let hastaAhora = try ring.clip(fromRigMs: s.newestRigMs - 5_000, toRigMs: s.newestRigMs + 60_000,
                                       minimumMs: 3_000)
        XCTAssertEqual(hastaAhora.toRigMs, s.newestRigMs + ring.frameDurationMs, "hasta el último y su duración")
    }

    func testSinProgramaNoHayTramo() {
        XCTAssertThrowsError(try anillo().clip(fromRigMs: 0, toRigMs: 10_000, minimumMs: 3_000)) {
            XCTAssertEqual($0 as? ProgramRing.RingError, .empty)
        }
    }

    func testUnFormatoNuevoTiraLoDeAntes() throws {
        let (a, b) = (try formato(ancho: 16), try formato(ancho: 32))
        let ring = anillo()
        llena(ring, segundos: 4, formato: a)
        ring.append(fotograma(5_000, clave: false, formato: b))
        XCTAssertNil(ring.span, "con el formato nuevo, sin IDR no hay nada que guardar")
        ring.append(fotograma(5_033, clave: true, formato: b))
        XCTAssertEqual(ring.span?.oldestRigMs, 5_033)
        ring.reset()
        XCTAssertNil(ring.span)
        XCTAssertEqual(ring.storedBytes, 0)
    }
}
