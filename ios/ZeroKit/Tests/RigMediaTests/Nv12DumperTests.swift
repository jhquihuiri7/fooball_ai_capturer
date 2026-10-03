import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// El volcado NV12 (IOS-15): el fichero con cabecera + planos sin stride, el
/// intervalo respetado y el color en la cabecera. El formato lo lee ML-18.
final class Nv12DumperTests: XCTestCase {
    private let ancho = 64
    private let alto = 32

    private func makeBuffer() throws -> CVPixelBuffer {
        var creado: CVPixelBuffer?
        // Sin IOSurface el stride queda redondeado por CoreVideo igualmente; lo que
        // importa es que el volcado lo quite.
        CVPixelBufferCreate(
            nil, ancho, alto, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &creado
        )
        let buffer = try XCTUnwrap(creado)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        for plano in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plano)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plano)
            let filas = CVPixelBufferGetHeightOfPlane(buffer, plano)
            for y in 0..<filas {
                let fila = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(plano == 0 ? ancho : ancho) {
                    // Valores deterministas y distintos por plano, fila y columna.
                    fila[x] = UInt8((plano * 100 + y * 3 + x) % 256)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testTheFileCarriesHeaderAndBarePlanes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nv12-test-\(UUID().uuidString)")
        let dumper = Nv12Dumper(directory: dir, side: "left", intervalS: 10)
        let buffer = try makeBuffer()

        XCTAssertTrue(dumper.maybeDump(buffer, rigMs: 5000))
        dumper.drain()
        XCTAssertEqual(dumper.written, 1)
        XCTAssertEqual(dumper.failures, 0)

        let datos = try Data(contentsOf: dir.appendingPathComponent("left-5000.nv12"))
        var reader = BigEndianReader(data: datos.prefix(4))
        let headerLen = Int(try XCTUnwrap(reader.read(UInt32.self)))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(
            with: datos.subdata(in: 4..<(4 + headerLen))
        ) as? [String: Any])
        XCTAssertEqual(header["rig_ms"] as? UInt64, 5000)
        XCTAssertEqual(header["side"] as? String, "left")
        XCTAssertEqual(header["width"] as? Int, ancho)
        XCTAssertEqual(header["height"] as? Int, alto)
        XCTAssertEqual(header["pixel_format"] as? String, "420v")
        let color = try XCTUnwrap(header["color"] as? [String: Any])
        XCTAssertEqual(color["matrix"] as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)

        // Los planos, sin el relleno del stride: Y de ancho×alto y CbCr de la mitad.
        let payload = datos.suffix(from: 4 + headerLen)
        XCTAssertEqual(payload.count, ancho * alto * 3 / 2)
        let y0 = payload[payload.startIndex]  // plano 0, fila 0, columna 0
        XCTAssertEqual(y0, 0)
        let segundaFila = payload[payload.startIndex + ancho]  // fila 1, columna 0
        XCTAssertEqual(segundaFila, 3)
        let croma0 = payload[payload.startIndex + ancho * alto]  // plano 1, fila 0
        XCTAssertEqual(croma0, 100)

        try? FileManager.default.removeItem(at: dir)
    }

    func testTheIntervalIsHonoredByRigTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nv12-test-\(UUID().uuidString)")
        let dumper = Nv12Dumper(directory: dir, side: "right", intervalS: 10)
        let buffer = try makeBuffer()

        XCTAssertTrue(dumper.maybeDump(buffer, rigMs: 1000))
        XCTAssertFalse(dumper.maybeDump(buffer, rigMs: 5000), "a 4 s del último: aún no")
        XCTAssertFalse(dumper.maybeDump(buffer, rigMs: 10_999))
        XCTAssertTrue(dumper.maybeDump(buffer, rigMs: 11_000), "a 10 s ya toca")
        dumper.drain()

        XCTAssertEqual(dumper.written, 2)
        let ficheros = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(ficheros, ["right-1000.nv12", "right-11000.nv12"])
        try? FileManager.default.removeItem(at: dir)
    }
}
