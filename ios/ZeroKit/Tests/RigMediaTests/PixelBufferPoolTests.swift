import CoreVideo
import XCTest

@testable import RigMedia

final class PixelBufferPoolTests: XCTestCase {
    func testTakeStopsAtCapacityInsteadOfAllocating() throws {
        let pool = try XCTUnwrap(
            PixelBufferPool(
                width: 640, height: 360,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                capacity: 3
            )
        )

        var retenidos: [CVPixelBuffer] = []
        for _ in 0..<3 {
            retenidos.append(try XCTUnwrap(pool.take()))
        }
        // El cuarto no se reserva: el tope es el tope.
        XCTAssertNil(pool.take())

        retenidos.removeLast()
        XCTAssertNotNil(pool.take())
    }

    func testTenThousandCyclesRecycleTheSameBuffers() throws {
        let pool = try XCTUnwrap(
            PixelBufferPool(
                width: 640, height: 360,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                capacity: 2
            )
        )
        // Tras el precalentamiento, tomar y soltar recicla las MISMAS IOSurface: si
        // apareciera una id nueva, el pool estaría reservando dentro del bucle.
        var vistas = Set<IOSurfaceID>()
        for _ in 0..<10_000 {
            let buffer = try XCTUnwrap(pool.take())
            let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
            vistas.insert(IOSurfaceGetID(surface))
        }
        XCTAssertLessThanOrEqual(vistas.count, 2, "el pool reservó superficies nuevas")
    }

    func testBuffersAreIOSurfaceBackedAndMetalTexturable() throws {
        let pool = try XCTUnwrap(
            PixelBufferPool(
                width: 640, height: 360,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                capacity: 1
            )
        )
        let buffer = try XCTUnwrap(pool.take())
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))

        let contexto = try XCTUnwrap(MetalContext())
        let luma = contexto.texture(from: buffer, plane: 0, format: .r8Unorm)
        let croma = contexto.texture(from: buffer, plane: 1, format: .rg8Unorm)
        XCTAssertEqual(luma?.width, 640)
        XCTAssertEqual(luma?.height, 360)
        XCTAssertEqual(croma?.width, 320)
        XCTAssertEqual(croma?.height, 180)
    }

    func testMetalContextAlwaysHasALibrary() throws {
        // Por CLI no hay default.metallib: tiene que caer a makeLibrary(source:).
        let contexto = try XCTUnwrap(MetalContext())
        XCTAssertFalse(contexto.library.functionNames.isEmpty)
    }
}
