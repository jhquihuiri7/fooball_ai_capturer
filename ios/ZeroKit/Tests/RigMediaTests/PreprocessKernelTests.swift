// La entrada del detector contra el dorado de REF-14 (IOS-21).
//
// compose_band_input viaja en BGRA, que es como lo ve Metal: la ruta BGRA del kernel
// tiene que dar el lienzo dorado a ≤1 nivel. La ruta NV12 (producción) se comprueba
// contra la cuenta de Python sobre la misma entrada: Nv12ToBgr de convert.py píxel a
// píxel y luego la media por área (INTER_AREA), con y sin el giro de 180°.

import CoreVideo
import Foundation
import Metal
import RigCore
@testable import RigMedia
import XCTest

final class PreprocessKernelTests: XCTestCase {
    func testElLienzoDoradoDeREF14() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RigCoreTests/Golden/band.json")
        let raiz = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var corridos = 0
        for caso in try XCTUnwrap(raiz["cases"] as? [[String: Any]]) where caso["fn"] as? String == "compose_band_input" {
            corridos += 1
            let entradas = try XCTUnwrap(caso["inputs"] as? [String: Any])
            let banda = try BandGeometry.fromDictionary(
                try XCTUnwrap(entradas["geometry"] as? [String: Any]), checkDetectorInput: false
            )
            let marco = try XCTUnwrap(entradas["frame_bgra"] as? [String: Any])
            let forma = try XCTUnwrap(marco["shape"] as? [Int])
            let fuente = try Self.bgraBuffer(Self.bytes(marco), ancho: forma[1], alto: forma[0])
            let builder = try DetectorInputBuilder(
                context: contexto, band: banda, sourceWidth: forma[1], sourceHeight: forma[0], upsideDown: false
            )
            let destino = try Self.bgraBuffer(
                [UInt8](repeating: 0, count: banda.inputWidth * banda.inputHeight * 4),
                ancho: banda.inputWidth, alto: banda.inputHeight
            )
            try ejecutar(contexto) { try builder.encode(bgra: fuente, into: destino, commandBuffer: $0) }

            let esperado = try Self.bytes(try XCTUnwrap((caso["expected"] as? [String: Any])?["input"] as? [String: Any]))
            let salida = Self.bgrBytes(destino)
            let peor = zip(salida, esperado).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(peor, 1, caso["name"] as? String ?? "")
        }
        XCTAssertGreaterThanOrEqual(corridos, 3)
    }

    func testLaRutaNV12ComoLaDePython() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let (ancho, alto) = (256, 144)
        // Un degradado suave: lo que cuenta aquí es la cuenta, no el submuestreo.
        var bgr = [UInt8](repeating: 0, count: ancho * alto * 3)
        for y in 0..<alto {
            for x in 0..<ancho {
                let i = (y * ancho + x) * 3
                bgr[i] = UInt8(x % 256); bgr[i + 1] = UInt8((y * 2) % 256); bgr[i + 2] = UInt8((x + y) / 2 % 256)
            }
        }
        let fuente = try nv12(bgr: bgr, ancho: ancho, alto: alto)
        let banda = try BandGeometry.fromDictionary([
            "version": 1, "side": "left", "rows": [16, 144], "input_size": [128, 48],
            "far_split_row": 80,
            "regions": [
                ["dst": [0, 0, 128, 32], "src": [0.0, 16.0, 256.0, 64.0]],
                ["dst": [0, 32, 64, 16], "src": [0.0, 80.0, 256.0, 64.0]],
            ],
        ], checkDetectorInput: false)
        let decodificado = Self.nv12ToBgrComoConvertPy(fuente)
        for girado in [false, true] {
            let builder = try DetectorInputBuilder(
                context: contexto, band: banda, sourceWidth: ancho, sourceHeight: alto, upsideDown: girado
            )
            let destino = try Self.bgraBuffer([UInt8](repeating: 0, count: 128 * 48 * 4), ancho: 128, alto: 48)
            try ejecutar(contexto) { try builder.encode(nv12: fuente, into: destino, commandBuffer: $0) }
            // La referencia: el BGR enderezado (girado si toca) y la media por área.
            let derecho = girado ? Self.girar180(decodificado, ancho: ancho, alto: alto) : decodificado
            let esperado = Self.composeBandInput(derecho, ancho: ancho, banda: banda)
            let peor = zip(Self.bgrBytes(destino), esperado).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(peor, 1, girado ? "girado" : "derecho")
        }
    }

    func testSinHuecoEnElPoolSeDescartaYSeCuenta() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let banda = try BandGeometry.fromDictionary([
            "version": 1, "side": "right", "rows": [0, 32], "input_size": [32, 16], "far_split_row": NSNull(),
            "regions": [["dst": [0, 0, 32, 16], "src": [0.0, 0.0, 64.0, 32.0]]],
        ], checkDetectorInput: false)
        let builder = try DetectorInputBuilder(
            context: contexto, band: banda, sourceWidth: 64, sourceHeight: 32, upsideDown: false, poolCapacity: 1
        )
        let fuente = try nv12(bgr: [UInt8](repeating: 90, count: 64 * 32 * 3), ancho: 64, alto: 32)
        let hecho = expectation(description: "la primera entrada llega")
        var retenido: CVPixelBuffer?
        try builder.build(from: fuente) { buffer in
            retenido = buffer
            hecho.fulfill()
        }
        wait(for: [hecho], timeout: 5)
        XCTAssertNotNil(retenido)
        // Con el único buffer retenido, la siguiente se descarta: nunca se encola.
        var segunda: CVPixelBuffer? = fuente
        try builder.build(from: fuente) { segunda = $0 }
        XCTAssertNil(segunda)
        XCTAssertEqual(builder.dropped, 1)
        withExtendedLifetime(retenido) {}
    }

    // MARK: - La cuenta de Python en la CPU

    /// Nv12ToBgr de convert.py: BT.709 de rango limitado, croma del vecino, redondeo.
    private static func nv12ToBgrComoConvertPy(_ buffer: CVPixelBuffer) -> [UInt8] {
        let (y, u, v) = planes(nv12: buffer)
        let ancho = CVPixelBufferGetWidth(buffer), alto = CVPixelBufferGetHeight(buffer)
        let kg = 1 - kr - kb
        let (rV, gU, gV, bU) = (2 * (1 - kr), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg, 2 * (1 - kb))
        func sat(_ x: Double) -> UInt8 { UInt8(min(max(x.rounded(.toNearestOrEven), 0), 255)) }
        var salida = [UInt8](repeating: 0, count: ancho * alto * 3)
        for fila in 0..<alto {
            for x in 0..<ancho {
                let l = (Double(y[fila * ancho + x]) - 16) * 255 / 219
                let c = (fila / 2) * (ancho / 2) + x / 2
                let cu = (Double(u[c]) - 128) * 255 / 224, cv = (Double(v[c]) - 128) * 255 / 224
                let i = (fila * ancho + x) * 3
                salida[i] = sat(l + bU * cu); salida[i + 1] = sat(l - gU * cu - gV * cv); salida[i + 2] = sat(l + rV * cv)
            }
        }
        return salida
    }

    private static func girar180(_ bgr: [UInt8], ancho: Int, alto: Int) -> [UInt8] {
        var salida = bgr
        for y in 0..<alto {
            for x in 0..<ancho {
                let o = ((alto - 1 - y) * ancho + (ancho - 1 - x)) * 3
                for c in 0..<3 { salida[(y * ancho + x) * 3 + c] = bgr[o + c] }
            }
        }
        return salida
    }

    /// compose_band_input con INTER_AREA: la media de lo que cubre cada píxel.
    private static func composeBandInput(_ bgr: [UInt8], ancho: Int, banda: BandGeometry) -> [UInt8] {
        var salida = [UInt8](repeating: 0, count: banda.inputWidth * banda.inputHeight * 3)
        for r in banda.layout.regions {
            let (x0s, y0s) = (r.srcX.rounded(.toNearestOrEven), r.srcY.rounded(.toNearestOrEven))
            let sx = r.srcW.rounded(.toNearestOrEven) / Double(r.dstW)
            let sy = r.srcH.rounded(.toNearestOrEven) / Double(r.dstH)
            for oy in 0..<r.dstH {
                for ox in 0..<r.dstW {
                    let (ax, ay) = (x0s + Double(ox) * sx, y0s + Double(oy) * sy)
                    var acc = [0.0, 0.0, 0.0]
                    var yy = Int(ay.rounded(.down))
                    while Double(yy) < ay + sy {
                        let wy = min(ay + sy, Double(yy + 1)) - max(ay, Double(yy))
                        var xx = Int(ax.rounded(.down))
                        while Double(xx) < ax + sx {
                            let wx = min(ax + sx, Double(xx + 1)) - max(ax, Double(xx))
                            for c in 0..<3 { acc[c] += wx * wy * Double(bgr[(yy * ancho + xx) * 3 + c]) }
                            xx += 1
                        }
                        yy += 1
                    }
                    let i = ((r.dstY + oy) * banda.inputWidth + r.dstX + ox) * 3
                    for c in 0..<3 {
                        salida[i + c] = UInt8(min(max((acc[c] / (sx * sy)).rounded(.toNearestOrEven), 0), 255))
                    }
                }
            }
        }
        return salida
    }

    // MARK: - Buffers BGRA

    private static func bgraBuffer(_ bgra: [UInt8], ancho: Int, alto: Int) throws -> CVPixelBuffer {
        let pool = try XCTUnwrap(PixelBufferPool(width: ancho, height: alto, pixelFormat: kCVPixelFormatType_32BGRA, capacity: 1))
        let buffer = try XCTUnwrap(pool.take())
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let paso = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<alto {
            for x in 0..<(ancho * 4) { ptr[y * paso + x] = bgra[y * ancho * 4 + x] }
        }
        return buffer
    }

    private static func bgrBytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let (ancho, alto) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let paso = CVPixelBufferGetBytesPerRow(buffer)
        var salida: [UInt8] = []
        for y in 0..<alto {
            for x in 0..<ancho {
                salida += [ptr[y * paso + x * 4], ptr[y * paso + x * 4 + 1], ptr[y * paso + x * 4 + 2]]
            }
        }
        return salida
    }

    private static func bytes(_ tensor: [String: Any]) throws -> [UInt8] {
        [UInt8](try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(tensor["b64"] as? String))))
    }
}
