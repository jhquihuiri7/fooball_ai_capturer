import AVFoundation
import XCTest

import RigCore
@testable import RigMedia

/// La repetición al aire (IOS-118, ADR 0034), con H.264 de verdad: el tramo sale del anillo a
/// un .mov, se lee desde la marca y tapa el programa desde el corte hasta la vuelta.
final class ProgramReplayHubTests: XCTestCase {
    private static let ancho = 320
    private static let alto = 180

    /// Un anillo con `segundos` de programa a 30 fps, codificado como el del maestro.
    private func anillo(segundos: Int) throws -> ProgramRing {
        let enc = try VideoEncoder(width: Self.ancho, height: Self.alto, bitrateBps: 1_000_000, viewId: 0)
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.ancho, Self.alto, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        let px = try XCTUnwrap(b)
        let ring = ProgramRing(maxDurationMs: 90_000, maxBytes: 1 << 30, frameDurationMs: 33)
        for i in 0..<(segundos * 30) {
            let ms = Int64(i) * 1000 / 30
            enc.encode(px, ptsNs: ms * 1_000_000, rigMs: UInt64(ms))
            while let f = enc.pop() { ring.append(f) }
        }
        enc.flush()
        while let f = enc.pop() { ring.append(f) }
        return ring
    }

    private func carpeta() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("repeticion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Lo que tarda el reproductor en tener su primer fotograma.
    private func dejaQueDecodifique() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testTapaElProgramaDesdeElCorteHastaLaVuelta() async throws {
        let ring = try anillo(segundos: 6)
        let dir = try carpeta()
        let hub = ProgramReplayHub(ring: ring, directory: dir, width: Self.ancho, height: Self.alto,
                                   minimumMs: 1_000)
        let a = try await hub.prepare(id: 1, fromRigMs: 2_500, toRigMs: 5_000, leadMs: 800, now: { 100_000 })
        XCTAssertEqual(a, ProgramReplayHub.Armed(id: 1, fromRigMs: 2_500, toRigMs: 5_000, cutRigMs: 100_800))
        XCTAssertEqual(hub.activeId, 1)
        XCTAssertNil(hub.frame(atRigMs: a.cutRigMs - 1), "antes del corte va el directo")
        try await dejaQueDecodifique()
        let primero = try XCTUnwrap(hub.frame(atRigMs: a.cutRigMs))
        XCTAssertEqual(CVPixelBufferGetWidth(primero), Self.ancho)
        XCTAssertNotNil(hub.frame(atRigMs: a.cutRigMs + 1_000))
        XCTAssertNotNil(hub.frame(atRigMs: a.cutRigMs + 2_400))
        XCTAssertNil(hub.frame(atRigMs: a.cutRigMs + 2_500), "pasado el tramo vuelve el directo")
        XCTAssertNil(hub.activeId)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "el .mov del tramo se borra al acabar")
    }

    func testVolverAlDirectoAntesLaCorta() async throws {
        let hub = ProgramReplayHub(ring: try anillo(segundos: 6), directory: try carpeta(),
                                   width: Self.ancho, height: Self.alto, minimumMs: 1_000)
        let a = try await hub.prepare(id: 2, fromRigMs: 1_000, toRigMs: 5_000, leadMs: 800, now: { 0 })
        hub.stop(id: 2, atRigMs: a.cutRigMs + 1_000)
        try await dejaQueDecodifique()
        XCTAssertNotNil(hub.frame(atRigMs: a.cutRigMs + 500))
        XCTAssertNil(hub.frame(atRigMs: a.cutRigMs + 1_000))
    }

    func testUnaALaVezYSinProgramaNoHay() async throws {
        let vacio = ProgramReplayHub(ring: ProgramRing(maxDurationMs: 90_000, maxBytes: 1 << 30),
                                     directory: try carpeta(), width: Self.ancho, height: Self.alto)
        do {
            _ = try await vacio.prepare(id: 3, fromRigMs: 0, toRigMs: 10_000, leadMs: 800, now: { 0 })
            XCTFail("sin programa no hay repetición")
        } catch {
            XCTAssertEqual(error as? ProgramReplayHub.ReplayError, .ring(.empty))
        }
        XCTAssertNil(vacio.activeId, "un fallo no deja nada en marcha")

        let hub = ProgramReplayHub(ring: try anillo(segundos: 6), directory: try carpeta(),
                                   width: Self.ancho, height: Self.alto, minimumMs: 1_000)
        _ = try await hub.prepare(id: 4, fromRigMs: 1_000, toRigMs: 5_000, leadMs: 800, now: { 0 })
        do {
            _ = try await hub.prepare(id: 5, fromRigMs: 1_000, toRigMs: 5_000, leadMs: 800, now: { 0 })
            XCTFail("dos a la vez no")
        } catch {
            XCTAssertEqual(error as? ProgramReplayHub.ReplayError, .busy)
        }
        hub.reset()
        XCTAssertNil(hub.activeId)
        XCTAssertNil(hub.ring.span, "al acabar la pasada el anillo se vacía")
    }
}
