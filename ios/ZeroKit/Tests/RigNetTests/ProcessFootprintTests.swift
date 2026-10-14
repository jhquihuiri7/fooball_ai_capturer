// La huella del proceso para la línea de tiempo del enlace (2026-10-14).

import Foundation
import RigNet
import XCTest

final class ProcessFootprintTests: XCTestCase {
    /// 64 MB tocados se ven en la huella. Hasta tres intentos: en la pasada entera, lo que
    /// sueltan a destiempo los tests de antes (VideoToolbox, Network) baja la huella a la
    /// vez y se come parte de la subida.
    func testLaHuellaCreceConLoQueSeReservaYSeToca() throws {
        let bytes = 64 << 20
        var subidas: [Double] = []
        for _ in 0..<3 {
            // Páginas nuevas del sistema (no las que malloc ya tenía) y al azar (unas
            // páginas iguales las comprime el sistema y no cuentan enteras).
            let bloque = try XCTUnwrap(mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))
            XCTAssertNotEqual(bloque, MAP_FAILED)
            let antes = try XCTUnwrap(ProcessFootprint.megabytes())
            XCTAssertGreaterThan(antes, 0)
            arc4random_buf(bloque, bytes)
            subidas.append(try XCTUnwrap(ProcessFootprint.megabytes()) - antes)
            munmap(bloque, bytes)
            if subidas.last! > 48 { break }
        }
        XCTAssertGreaterThan(subidas.max() ?? 0, 48, "64 MB tocados se ven: \(subidas)")
    }
}
