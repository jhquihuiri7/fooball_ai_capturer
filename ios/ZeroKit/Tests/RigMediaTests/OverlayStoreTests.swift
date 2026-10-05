import Metal
import XCTest

@testable import RigMedia

/// El gráfico de Dart en Metal (IOS-47): capas apiladas, generaciones, borrado y las dos
/// texturas siempre coherentes.
final class OverlayStoreTests: XCTestCase {
    private func store() throws -> OverlayStore {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(OverlayStore(device: device, width: 64, height: 32))
    }

    private func sync(_ f: (@escaping () -> Void) -> Void) {
        let e = expectation(description: "aplicado")
        f { e.fulfill() }
        wait(for: [e], timeout: 5)
    }

    private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        t.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return p
    }

    private func liso(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> [UInt8] {
        Array((0..<(w * h)).map { _ in rgba }.joined())
    }

    func testCapasApiladasGeneracionesYBorrado() throws {
        let s = try store()
        XCTAssertNil(s.beginFrame(), "sin capas no hay gráfico")
        sync { s.set(.scoreboard, rgba: liso(4, 2, [255, 0, 0, 255]), rect: .init(x: 10, y: 5, width: 4, height: 2),
                     generation: 1, completion: $0) }
        var t = try XCTUnwrap(s.beginFrame())
        XCTAssertEqual(pixel(t, 10, 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(t, 9, 5), [0, 0, 0, 0])
        s.endFrame()

        // La alineación, encima y a medio alfa: «over» sin premultiplicar.
        sync { s.set(.lineup, rgba: liso(2, 1, [0, 0, 255, 128]), rect: .init(x: 12, y: 5, width: 2, height: 1),
                     generation: 1, completion: $0) }
        t = try XCTUnwrap(s.beginFrame())
        let mezcla = pixel(t, 12, 5)
        XCTAssertEqual(mezcla[3], 255)
        XCTAssertEqual(Int(mezcla[0]), 127, accuracy: 1)
        XCTAssertEqual(Int(mezcla[2]), 128, accuracy: 1)
        XCTAssertEqual(pixel(t, 10, 5), [255, 0, 0, 255], "lo que no tocó, sigue (en la otra textura también)")
        s.endFrame()

        // Una generación vieja no pisa.
        sync { s.set(.scoreboard, rgba: liso(4, 2, [0, 255, 0, 255]), rect: .init(x: 10, y: 5, width: 4, height: 2),
                     generation: 1, completion: $0) }
        t = try XCTUnwrap(s.beginFrame())
        XCTAssertEqual(pixel(t, 10, 5), [255, 0, 0, 255])
        s.endFrame()

        // Un parche transparente borra lo que había en su caja (lo que manda Dart cuando
        // algo desaparece), y uno nuevo pinta en otra parte.
        sync { s.set(.scoreboard, rgba: liso(4, 2, [0, 0, 0, 0]), rect: .init(x: 10, y: 5, width: 4, height: 2),
                     generation: 2, completion: $0) }
        sync { s.set(.scoreboard, rgba: liso(4, 2, [0, 255, 0, 255]), rect: .init(x: 40, y: 20, width: 4, height: 2),
                     generation: 3, completion: $0) }
        t = try XCTUnwrap(s.beginFrame())
        XCTAssertEqual(pixel(t, 10, 5), [0, 0, 0, 0])
        XCTAssertEqual(pixel(t, 40, 20), [0, 255, 0, 255])
        XCTAssertEqual(pixel(t, 12, 5)[2], 255, "la alineación queda sola donde estaba el marcador")
        s.endFrame()

        sync { s.clear(.lineup, completion: $0) }
        sync { s.clear(.scoreboard, completion: $0) }
        XCTAssertNil(s.beginFrame())
        XCTAssertEqual(s.uploads, 6, "la generación vieja no sube")
    }

    func testSinSenalEstaOcultaHastaQueSeEnsena() throws {
        let s = try store()
        sync { s.set(.slate, rgba: liso(2, 2, [1, 2, 3, 255]), rect: .init(x: 0, y: 0, width: 2, height: 2),
                     generation: 1, completion: $0) }
        XCTAssertNil(s.beginFrame(), "cargada pero oculta")
        sync { s.setVisible(.slate, true, completion: $0) }
        let t = try XCTUnwrap(s.beginFrame())
        XCTAssertEqual(pixel(t, 0, 0), [1, 2, 3, 255])
        s.endFrame()
        // El marcador va ENCIMA de SIN SEÑAL.
        sync { s.set(.scoreboard, rgba: liso(1, 1, [9, 9, 9, 255]), rect: .init(x: 0, y: 0, width: 1, height: 1),
                     generation: 1, completion: $0) }
        let t2 = try XCTUnwrap(s.beginFrame())
        XCTAssertEqual(pixel(t2, 0, 0), [9, 9, 9, 255])
        s.endFrame()
        sync { s.clear(.scoreboard, completion: $0) }
        sync { s.setVisible(.slate, false, completion: $0) }
        XCTAssertNil(s.beginFrame())
    }

    func testLaTexturaEnUsoNoSeCambiaHastaQueSeSuelta() throws {
        let s = try store()
        sync { s.set(.scoreboard, rgba: liso(1, 1, [9, 9, 9, 255]), rect: .init(x: 0, y: 0, width: 1, height: 1),
                     generation: 1, completion: $0) }
        let enUso = try XCTUnwrap(s.beginFrame())
        let hecho = expectation(description: "cambio")
        s.set(.scoreboard, rgba: liso(1, 1, [7, 7, 7, 255]), rect: .init(x: 0, y: 0, width: 1, height: 1),
              generation: 2) { hecho.fulfill() }
        usleep(20_000)
        XCTAssertEqual(pixel(enUso, 0, 0), [9, 9, 9, 255], "la que se está leyendo no se toca")
        s.endFrame()
        wait(for: [hecho], timeout: 5)
        let nueva = try XCTUnwrap(s.beginFrame())
        XCTAssertFalse(nueva === enUso)
        XCTAssertEqual(pixel(nueva, 0, 0), [7, 7, 7, 255])
        s.endFrame()
    }
}
