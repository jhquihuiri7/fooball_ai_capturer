// La cancha desenfocada detrás de la tarjeta de entretiempo (ADR 0027, enmienda del
// 2026-10-16): el fondo pierde el detalle, el gráfico de encima sigue nítido, el borde del
// cuadro no se oscurece, y la composición solo desenfoca cuando la tarjeta lo pide.

import CoreVideo
import Foundation
import Metal
import RigCore
@testable import RigMedia
import XCTest

final class BackdropBlurTests: XCTestCase {
    private let ancho = 128
    private let alto = 64

    /// Franjas verticales de 4 px blancas y negras: todo detalle, nada de color medio.
    private func franjas() throws -> CVPixelBuffer {
        var bgr = [UInt8](repeating: 0, count: ancho * alto * 3)
        for y in 0..<alto {
            for x in 0..<ancho where (x / 4) % 2 == 0 {
                for c in 0..<3 { bgr[(y * ancho + x) * 3 + c] = 255 }
            }
        }
        return try nv12(bgr: bgr, ancho: ancho, alto: alto)
    }

    /// Un cuadrado rojo opaco de 16×16 en el centro; el resto, transparente.
    private func grafico(_ contexto: MetalContext) throws -> UploadTexture {
        var rgba = [UInt8](repeating: 0, count: ancho * alto * 4)
        for y in (alto / 2 - 8)..<(alto / 2 + 8) {
            for x in (ancho / 2 - 8)..<(ancho / 2 + 8) {
                rgba.replaceSubrange((y * ancho + x) * 4..<(y * ancho + x) * 4 + 4, with: [255, 0, 0, 255])
            }
        }
        let t = try XCTUnwrap(UploadTexture(device: contexto.device, width: ancho, height: alto))
        t.upload(rgba: rgba, generation: 0)
        return t
    }

    private func vista() throws -> RectilinearView {
        try RectilinearView(yawRad: 0, pitchRad: 0, hfovRad: 1.0, width: ancho, height: alto)
    }

    private func desviacion(_ v: [UInt8]) -> Double {
        let m = v.reduce(0.0) { $0 + Double($1) } / Double(v.count)
        return (v.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(v.count)).squareRoot()
    }

    /// La luma de una fila, lejos del cuadrado.
    private func fila(_ y: [UInt8], _ n: Int) -> [UInt8] { Array(y[(n * ancho)..<((n + 1) * ancho)]) }

    func testLaCanchaSeDesenfocaYElGraficoSigueNitido() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let kernel = try ComposeProgramKernel(context: contexto)
        let blur = try BackdropBlur(device: contexto.device, width: ancho, height: alto, sigmaPx: 4)
        let parte = try franjas()
        let g = try grafico(contexto)
        let nitido = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        let borroso = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
        try ejecutar(contexto) {
            try kernel.encode(
                master: parte, masterSide: .left, slave: nil, view: try vista(), seamYawRad: 0,
                graphic: g.texture, strip: nil, destination: nitido, commandBuffer: $0
            )
            try blur.encode(
                kernel: kernel, master: parte, masterSide: .left, slave: nil, view: try vista(),
                seamYawRad: 0, featherRad: RigConstants.panoramaFeatherRad,
                graphic: g.texture, destination: borroso, commandBuffer: $0
            )
        }
        let yNitido = planes(nv12: nitido).y, yBorroso = planes(nv12: borroso).y

        // Lejos del cuadrado, las franjas casi desaparecen.
        let antes = desviacion(fila(yNitido, 4)), despues = desviacion(fila(yBorroso, 4))
        XCTAssertGreaterThan(antes, 80, "las franjas nítidas")
        XCTAssertLessThan(despues, antes * 0.2, "desenfocadas")
        // Sin oscurecer el borde: con `.clamp`, fuera del cuadro se repite la primera
        // columna (aquí blanca, x 0-3), así que el borde sale igual o más claro que el gris
        // medio de las franjas; con relleno negro saldría mucho más oscuro.
        XCTAssertGreaterThan(Double(yBorroso[4 * ancho]), Double(yBorroso[4 * ancho + ancho / 2 - 20]) - 25)

        // El cuadrado rojo, encima y nítido: el mismo valor que sin desenfoque.
        let centro = (alto / 2) * ancho + ancho / 2
        XCTAssertEqual(Int(yBorroso[centro]), Int(yNitido[centro]), accuracy: 1)
        XCTAssertEqual(Int(yBorroso[centro]), 63, accuracy: 2, "Y del rojo puro en BT.709 limitado")
    }

    func testLaComposicionSoloDesenfocaSiLaTarjetaLoPide() throws {
        let contexto = try XCTUnwrap(MetalContext())
        let composer = try MetalProgramComposer(context: contexto, masterSide: .left, width: ancho, height: alto)
        let store = try XCTUnwrap(OverlayStore(device: contexto.device, width: ancho, height: alto))
        composer.overlay = store
        let parte = try franjas()
        let vista = ViewCommand(
            targetRigMs: 0, viewId: 1, yawRad: 0, pitchRad: 0, hfovRad: 1.0, sides: [.left],
            seamYawRad: 0, featherRad: 0.02, gains: .unity
        )
        func compone() throws -> [UInt8] {
            let destino = try nv12(bgr: [UInt8](repeating: 0, count: ancho * alto * 3), ancho: ancho, alto: alto)
            try composer.compose(master: parte, slave: nil, view: vista, atRigMs: 0, into: destino)
            return fila(planes(nv12: destino).y, 4)
        }
        XCTAssertFalse(store.backdropBlur, "sin tarjeta, la cancha nítida")
        let nitida = desviacion(try compone())
        store.backdropBlur = true
        let borrosa = desviacion(try compone())
        XCTAssertLessThan(borrosa, nitida * 0.5)
        store.backdropBlur = false
        XCTAssertEqual(desviacion(try compone()), nitida, accuracy: 1e-9, "y vuelve")
    }
}
