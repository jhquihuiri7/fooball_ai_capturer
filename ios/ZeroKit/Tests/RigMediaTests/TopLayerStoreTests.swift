import Metal
import XCTest

@testable import RigMedia

/// La capa de encima (IOS-118, ADR 0034): un parche se ve en la textura activa, las dos
/// texturas se quedan con todos los cambios y quitarla deja al kernel sin capa.
final class TopLayerStoreTests: XCTestCase {
    private func parche(_ ancho: Int, _ alto: Int, _ color: [UInt8]) -> [UInt8] {
        Array((0..<(ancho * alto)).map { _ in color }.joined())
    }

    private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        t.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return px
    }

    private func espera(_ hacer: (@escaping () -> Void) -> Void) {
        let hecho = expectation(description: "aplicado")
        hacer { hecho.fulfill() }
        wait(for: [hecho], timeout: 2)
    }

    func testDosParchesQuedanEnLaTexturaActivaYQuitarlaLaVacia() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let capa = try XCTUnwrap(TopLayerStore(device: device, width: 64, height: 32))
        XCTAssertNil(capa.beginFrame(), "vacía, el kernel no la lee")
        let rojo: [UInt8] = [255, 0, 0, 255]
        let azul: [UInt8] = [0, 0, 255, 128]
        espera { capa.set(rgba: parche(8, 4, rojo), rect: .init(x: 10, y: 5, width: 8, height: 4), generation: 1,
                          completion: $0) }
        espera { capa.set(rgba: parche(4, 4, azul), rect: .init(x: 40, y: 20, width: 4, height: 4), generation: 2,
                          completion: $0) }
        // Una generación vieja llega tarde y no pisa nada.
        espera { capa.set(rgba: parche(4, 4, azul), rect: .init(x: 10, y: 5, width: 4, height: 4), generation: 1,
                          completion: $0) }
        let t = try XCTUnwrap(capa.beginFrame())
        XCTAssertEqual(pixel(t, 12, 6), rojo, "el primero sigue en la textura que entró después")
        XCTAssertEqual(pixel(t, 41, 21), azul)
        XCTAssertEqual(pixel(t, 0, 0), [0, 0, 0, 0])
        capa.endFrame()
        XCTAssertEqual(capa.uploads, 2)

        espera { capa.clear(completion: $0) }
        XCTAssertNil(capa.beginFrame())
        XCTAssertFalse(capa.hasContent)
    }

    func testUnParcheQueSeSaleSeRecorta() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let capa = try XCTUnwrap(TopLayerStore(device: device, width: 16, height: 16))
        let verde: [UInt8] = [0, 255, 0, 255]
        espera { capa.set(rgba: parche(8, 8, verde), rect: .init(x: 12, y: 12, width: 8, height: 8), generation: 1,
                          completion: $0) }
        let t = try XCTUnwrap(capa.beginFrame())
        XCTAssertEqual(pixel(t, 15, 15), verde)
        XCTAssertEqual(pixel(t, 11, 11), [0, 0, 0, 0])
        capa.endFrame()
    }
}
