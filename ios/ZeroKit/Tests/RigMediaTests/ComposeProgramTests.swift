// La composición del programa en el maestro contra compose.json de REF-18 (IOS-41).
//
// compose.nv12 da el programa (BGR), el gráfico RGBA y, a veces, el anuncio; espera
// los planos Y, U y V. Aquí el programa entra como la parte NV12 del maestro (camino
// de una lente), así que su croma ya viene submuestreada. Dos comprobaciones:
// - la MATEMÁTICA: compose_reference, portada aquí, aplicada a la entrada tal como el
//   kernel la ve (decodificada del NV12), tiene que dar los mismos planos a ±1;
// - el PSNR ≥45 dB frente al dorado de REF que pide la tarjeta NO se puede medir con
//   estos casos: sus entradas son colores al azar píxel a píxel, croma que el 4:2:0
//   no lleva (ninguna sobrevive al NV12 a 45 dB). Hace falta un dorado con entrada
//   representable en NV12; hasta entonces manda la comparación de la matemática.

import CoreVideo
import Foundation
import Metal
import RigCore
@testable import RigMedia
import XCTest

final class ComposeProgramTests: XCTestCase {
    func testLosProgramasDoradosConGraficoYAnuncio() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ComposeProgramKernel(context: contexto)
        var corridos = 0
        for caso in try Self.casos() where caso.fn == "compose.nv12" {
            corridos += 1
            let e = caso.inputs
            let (alto, ancho) = (e.forma["bgr"]![0], e.forma["bgr"]![1])
            let parte = try nv12(bgr: e.bytes["bgr"]!, ancho: ancho, alto: alto)
            let grafico = try XCTUnwrap(UploadTexture(device: contexto.device, width: ancho, height: alto))
            grafico.upload(rgba: e.bytes["rgba"]!, generation: 0)
            let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
            try ejecutar(contexto) {
                try kernel.encode(
                    master: parte, masterSide: .left, slave: nil, view: Self.vista(ancho, alto),
                    seamYawRad: 0, graphic: grafico.texture,
                    strip: try Self.franja(e, contexto: contexto), destination: destino, commandBuffer: $0
                )
            }
            let (y, u, v) = planes(nv12: destino)

            let visto = bgr(nv12: parte)
            let ref = Self.composeReference(
                bgr: visto, rgba: e.bytes["rgba"]!, premul: e.bytes["premul"], inv: e.bytes["inv"],
                ancho: ancho, alto: alto
            )
            for (nombre, actual, esperado) in [("y", y, ref.y), ("u", u, ref.u), ("v", v, ref.v)] {
                let peor = zip(actual, esperado).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(peor, 1, "\(caso.nombre): plano \(nombre)")
            }
        }
        XCTAssertGreaterThanOrEqual(corridos, 9)
    }

    /// compose_reference de tools/golden/evaluate_compose.py, en Double.
    private static func composeReference(
        bgr: [UInt8], rgba: [UInt8], premul: [UInt8]?, inv: [UInt8]?, ancho: Int, alto: Int
    ) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        var mezcla = [Double](repeating: 0, count: ancho * alto * 3)  // RGB
        for i in 0..<(ancho * alto) {
            let a = Double(rgba[i * 4 + 3]) / 255
            for c in 0..<3 {
                let fondo = Double(bgr[i * 3 + (2 - c)])
                mezcla[i * 3 + c] = (Double(rgba[i * 4 + c]) * a + fondo * (1 - a)).rounded(.toNearestOrEven)
            }
        }
        if let premul, let inv {
            let filas = premul.count / (ancho * 3)
            for fila in (alto - filas)..<alto {
                for x in 0..<ancho {
                    let i = fila * ancho + x
                    let j = (fila - (alto - filas)) * ancho + x
                    for c in 0..<3 {
                        let k = 2 - c  // premul e inv son BGR
                        let v = (mezcla[i * 3 + c] * Double(inv[j * 3 + k]) / 255).rounded(.toNearestOrEven)
                        mezcla[i * 3 + c] = min(v + Double(premul[j * 3 + k]), 255)
                    }
                }
            }
        }
        func sat(_ v: Double) -> UInt8 { UInt8(min(max(v.rounded(.toNearestOrEven), 0), 255)) }
        var y = [UInt8](), u = [UInt8](), v = [UInt8]()
        for i in 0..<(ancho * alto) {
            let (r, g, b) = (mezcla[i * 3], mezcla[i * 3 + 1], mezcla[i * 3 + 2])
            y.append(sat(16 + 0.182586 * r + 0.614231 * g + 0.062007 * b))
        }
        for cy in 0..<(alto / 2) {
            for cx in 0..<(ancho / 2) {
                var (r, g, b) = (0.0, 0.0, 0.0)
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let i = (cy * 2 + dy) * ancho + cx * 2 + dx
                    r += mezcla[i * 3]; g += mezcla[i * 3 + 1]; b += mezcla[i * 3 + 2]
                }
                (r, g, b) = (r / 4, g / 4, b / 4)
                u.append(sat(128 - 0.100644 * r - 0.338572 * g + 0.439216 * b))
                v.append(sat(128 + 0.439216 * r - 0.398942 * g - 0.040274 * b))
            }
        }
        return (y, u, v)
    }

    func testLaFranjaComoStripBlender() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ComposeProgramKernel(context: contexto)
        var corridos = 0
        for caso in try Self.casos() where caso.fn == "compose.strip_blend" {
            corridos += 1
            let e = caso.inputs
            let (alto, ancho) = (e.forma["frame"]![0], e.forma["frame"]![1])
            let parte = try nv12(bgr: e.bytes["frame"]!, ancho: ancho, alto: alto)
            let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
            try ejecutar(contexto) {
                try kernel.encode(
                    master: parte, masterSide: .left, slave: nil, view: Self.vista(ancho, alto),
                    seamYawRad: 0, graphic: nil,
                    strip: try Self.franja(e, contexto: contexto), destination: destino, commandBuffer: $0
                )
            }
            // StripBlender sobre la entrada tal como el kernel la ve: la misma cuenta
            // que compose_reference con un gráfico transparente.
            let ref = Self.composeReference(
                bgr: bgr(nv12: parte), rgba: [UInt8](repeating: 0, count: ancho * alto * 4),
                premul: e.bytes["premul"], inv: e.bytes["inv"], ancho: ancho, alto: alto
            )
            let y = planes(nv12: destino).y
            let peor = zip(y, ref.y).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(peor, 1, caso.nombre)
        }
        XCTAssertGreaterThanOrEqual(corridos, 3)
    }

    func testLaCosturaMezclaLasDosPartes() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ComposeProgramKernel(context: contexto)
        let (ancho, alto) = (64, 32)
        // Izquierda roja (el maestro), derecha azul (el esclavo); la vista mira a la
        // costura, así que el borde izquierdo es del maestro y el derecho del esclavo.
        let rojo = try nv12(bgr: Array(repeating: [0, 0, 200] as [UInt8], count: ancho * alto).flatMap { $0 }, ancho: ancho, alto: alto)
        let azul = try nv12(bgr: Array(repeating: [200, 0, 0] as [UInt8], count: ancho * alto).flatMap { $0 }, ancho: ancho, alto: alto)
        let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        try ejecutar(contexto) {
            try kernel.encode(
                master: rojo, masterSide: .left, slave: azul, view: Self.vista(ancho, alto),
                seamYawRad: 0, featherRad: 0.2, graphic: nil, strip: nil,
                destination: destino, commandBuffer: $0
            )
        }
        let bgr = bgr(nv12: destino)
        func px(_ x: Int) -> [UInt8] { Array(bgr[((alto / 2) * ancho + x) * 3..<((alto / 2) * ancho + x) * 3 + 3]) }
        XCTAssertGreaterThan(Int(px(2)[2]), 180, "a la izquierda, el maestro")
        XCTAssertGreaterThan(Int(px(ancho - 3)[0]), 180, "a la derecha, el esclavo")
        let medio = px(ancho / 2)
        XCTAssertGreaterThan(Int(medio[0]), 40)
        XCTAssertGreaterThan(Int(medio[2]), 40, "en la costura, las dos")
    }

    func testUnaLenteSoloElEsclavoYElGrafico() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ComposeProgramKernel(context: contexto)
        let (ancho, alto) = (16, 8)
        let verde = try nv12(bgr: Array(repeating: [0, 180, 0] as [UInt8], count: ancho * alto).flatMap { $0 }, ancho: ancho, alto: alto)
        let grafico = try XCTUnwrap(UploadTexture(device: contexto.device, width: ancho, height: alto))
        // Gráfico blanco opaco en la mitad de arriba, transparente abajo.
        var rgba = [UInt8](repeating: 0, count: ancho * alto * 4)
        for i in 0..<(ancho * alto / 2) { rgba[i * 4..<i * 4 + 4] = [255, 255, 255, 255] }
        grafico.upload(rgba: rgba, generation: 1)
        let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        try ejecutar(contexto) {
            try kernel.encode(
                master: nil, masterSide: .left, slave: verde, view: Self.vista(ancho, alto),
                seamYawRad: 0, graphic: grafico.texture, strip: nil,
                destination: destino, commandBuffer: $0
            )
        }
        let y = planes(nv12: destino).y
        XCTAssertEqual(Int(y[0]), 235, accuracy: 1, "arriba, el gráfico blanco")
        XCTAssertEqual(Int(y[(alto - 1) * ancho]), Int((16 + 0.614231 * 180).rounded()), accuracy: 2, "abajo, el esclavo")
    }

    func testLaTexturaSoloSeSubeSiCambia() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let t = try XCTUnwrap(UploadTexture(device: contexto.device, width: 2, height: 1))
        t.upload(rgba: [1, 2, 3, 4, 5, 6, 7, 8], generation: 3)
        t.upload(rgba: [0, 0, 0, 0, 0, 0, 0, 0], generation: 3)  // misma generación: no sube
        var leido = [UInt8](repeating: 0, count: 8)
        t.texture.getBytes(&leido, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
        XCTAssertEqual(leido, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    // MARK: - Soporte

    private static func vista(_ ancho: Int, _ alto: Int) throws -> RectilinearView {
        try RectilinearView(yawRad: 0, pitchRad: 0, hfovRad: 1.0, width: ancho, height: alto)
    }

    /// premul e inv de la referencia son BGR: a las texturas van como RGB + alfa.
    private static func franja(_ e: Tensores, contexto: MetalContext) throws -> ComposeProgramKernel.Strip? {
        guard let premul = e.bytes["premul"], let inv = e.bytes["inv"], let forma = e.forma["premul"] else {
            return nil
        }
        let (alto, ancho) = (forma[0], forma[1])
        func textura(_ bgr: [UInt8]) throws -> MTLTexture {
            let t = try XCTUnwrap(UploadTexture(device: contexto.device, width: ancho, height: alto))
            var rgba = [UInt8](repeating: 255, count: ancho * alto * 4)
            for i in 0..<(ancho * alto) {
                rgba[i * 4] = bgr[i * 3 + 2]; rgba[i * 4 + 1] = bgr[i * 3 + 1]; rgba[i * 4 + 2] = bgr[i * 3]
            }
            t.upload(rgba: rgba, generation: 0)
            return t.texture
        }
        return ComposeProgramKernel.Strip(premul: try textura(premul), inverse: try textura(inv))
    }

    private struct Tensores {
        var bytes: [String: [UInt8]] = [:]
        var forma: [String: [Int]] = [:]
    }

    private struct Caso {
        let nombre: String
        let fn: String
        let inputs: Tensores
        let expected: Tensores
    }

    private static func casos() throws -> [Caso] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RigCoreTests/Golden/compose.json")
        let raiz = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func tensores(_ objeto: Any?) throws -> Tensores {
            var t = Tensores()
            for (clave, valor) in try XCTUnwrap(objeto as? [String: Any]) {
                guard let tensor = valor as? [String: Any], let b64 = tensor["b64"] as? String else { continue }
                t.bytes[clave] = [UInt8](try XCTUnwrap(Data(base64Encoded: b64)))
                t.forma[clave] = tensor["shape"] as? [Int]
            }
            return t
        }
        return try XCTUnwrap(raiz["cases"] as? [[String: Any]]).map {
            Caso(
                nombre: $0["name"] as? String ?? "",
                fn: $0["fn"] as? String ?? "",
                inputs: try tensores($0["inputs"]),
                expected: try tensores($0["expected"])
            )
        }
    }
}
