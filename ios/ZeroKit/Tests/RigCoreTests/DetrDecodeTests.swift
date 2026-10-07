// El decodificador de jugadores (IOS-23) en lo que detectors.json no fija: el umbral en
// float32 como numpy, el recorte a la región y lo que no cuadra con la ficha. Los dorados
// de punta a punta están en PostprocessTests.

import Foundation
import RigCore
import XCTest

final class DetrDecodeTests: XCTestCase {
    private let nombres = ["goalkeeper", "player", "referee"]

    /// numpy compara `scores >= 0.7` en float32 (NEP 50): un score igual a Float(0.7),
    /// que es MENOR que 0,7 en Double, pasa el umbral. En Double no pasaría.
    func testElUmbralDeConfianzaSeComparaEnFloat32() throws {
        let umbral = Float(0.7)
        XCTAssertLessThan(Double(umbral), 0.7)
        var x = Float(log(0.7 / 0.3)).nextDown.nextDown
        for _ in 0..<4000 where Postprocess.sigmoid(x) != umbral { x = x.nextUp }
        try XCTSkipUnless(Postprocess.sigmoid(x) == umbral, "ningún logit da exactamente Float(0.7)")
        let dec = try PlayerDecoder(classNames: nombres, confThreshold: 0.7)
        let layout = try InputLayout(regions: [InputRegion(dstX: 0, dstY: 0, dstW: 640, dstH: 640, srcX: 0, srcY: 0, srcW: 640, srcH: 640)])
        let dets = try dec.decode(logits: [[-9, x, -9]], boxes: [[0.5, 0.5, 0.1, 0.2]], layout: layout)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets.first?.score, Double(umbral))
    }

    /// Las cajas que se salen de la franja se recortan a su región antes de volver a
    /// nativo: nunca caen fuera de las filas que vio el modelo.
    func testLasCajasSeRecortanALaRegion() throws {
        let dec = try PlayerDecoder(classNames: nombres)
        let layout = try InputLayout(regions: [InputRegion(
            dstX: 0, dstY: 0, dstW: 1920, dstH: 576, srcX: 0, srcY: 504, srcW: 3840, srcH: 1152
        )])
        let dets = try dec.decode(
            logits: [[-9, 4, -9], [-9, 3, -9]], boxes: [[0.001, 0.5, 0.01, 0.1], [0.5, 0.99, 0.01, 0.1]], layout: layout
        )
        XCTAssertEqual(dets.count, 2)
        XCTAssertEqual(dets[0].x1, 0, "por la izquierda, al borde del fotograma")
        XCTAssertEqual(dets[1].y2, 504 + 1152, "por abajo, a la última fila de la franja")
    }

    func testLoQueNoCuadraConLaFichaSeRechaza() throws {
        let layout = try InputLayout(regions: [InputRegion(dstX: 0, dstY: 0, dstW: 64, dstH: 64, srcX: 0, srcY: 0, srcW: 64, srcH: 64)])
        let detr = try PlayerDecoder(classNames: nombres)
        XCTAssertThrowsError(try detr.decode(logits: [[0, 0, 0, 0]], boxes: [[0.5, 0.5, 0.1, 0.1]], layout: layout))
        let plano = [[[Float]]](repeating: [[Float]](repeating: [0, 0], count: 2), count: 2)
        XCTAssertThrowsError(try detr.decodeHeatmap(heatmap: plano, offset: plano, size: plano, layout: layout))
        let heat = try PlayerDecoder(classNames: nombres, postprocess: .heatmap, boxFormat: .heatmapStride, heatmapStride: 4)
        XCTAssertThrowsError(try heat.decode(logits: [[0, 0, 0]], boxes: [[0.5, 0.5, 0.1, 0.1]], layout: layout))
        XCTAssertThrowsError(try heat.decodeHeatmap(heatmap: plano, offset: plano, size: plano, layout: layout),
                             "2 canales de heatmap y 3 clases en la ficha")
    }
}
