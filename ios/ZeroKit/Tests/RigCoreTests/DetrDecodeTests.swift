// El decodificador de jugadores (IOS-23) en lo que detectors.json no fija: la máscara del
// campo desde un PitchModel, el umbral en float32 como numpy, el recorte a la región y lo
// que no cuadra con la ficha. Los dorados de punta a punta están en PostprocessTests.

import Foundation
import RigCore
import XCTest

final class DetrDecodeTests: XCTestCase {
    private let nombres = ["goalkeeper", "player", "referee"]

    /// Un PitchModel cuya área jugable, a píxel entero, es justo el rectángulo
    /// [x0, x1) × [y0, y1): una homografía sin giro con el borde a ¼ de píxel por fuera
    /// de la primera y la última columna y fila, lejos de cualquier redondeo.
    private func pitchDelRectangulo(_ r: [Int]) throws -> PitchModel {
        let margen = RigConstants.pitchPlayableMarginM
        let (mx, my) = (RigConstants.pitchLengthM / 2 + margen, RigConstants.pitchWidthM / 2 + margen)
        let (hx, hy) = (Double(r[2] - r[0]) / 2 - 0.25, Double(r[3] - r[1]) / 2 - 0.25)
        let (cx, cy) = (Double(r[0] + r[2] - 1) / 2, Double(r[1] + r[3] - 1) / 2)
        return try PitchModel(homography: Mat3(rows: [hx / mx, 0, cx, 0, hy / my, cy, 0, 0, 1]))
    }

    /// La aceptación de la máscara: los casos de detectors.json con `pitch_mask` dan lo
    /// mismo con la máscara de un PitchModel que con la de mapa de bits de la referencia.
    func testLaMascaraDelPitchModelDaLosDorados() throws {
        let doc = try Golden.loadDocument(named: "detectors.json")
        var corridos = 0
        for caso in doc.cases where caso.fn == "PlayerDetector.detect" {
            let i = caso.inputs
            guard let rect = try PostprocessTests.rectMask(i),
                  case let .object(m) = try i.field("pitch_mask"), case let .array(dentro)? = m["inside"]
            else { continue }
            let r = dentro.compactMap(\.numberValue).map { Int($0) }
            let mascara = try FootMask(pitch: pitchDelRectangulo(r), width: rect.width, height: rect.height)
            // Las dos máscaras coinciden en los bordes del rectángulo y a los dos lados.
            for x in [0, 1, r[0], r[2] - 1, r[2], rect.width - 1] {
                for y in [0, r[1] - 1, r[1], r[1] + 1, r[3] - 1, rect.height - 1] {
                    let (fx, fy) = (Float(x) + 0.5, Float(y) + 0.5)
                    XCTAssertEqual(mascara.contains(footX: fx, footY: fy), rect.contains(footX: fx, footY: fy), "(\(x), \(y))")
                }
            }
            let layout = try BandGeometryTests.layout(i.field("layout"))
            let dets: [PlayerDetection]
            if let paso = try? i.number("heatmap_stride") {
                let dec = try PlayerDecoder(
                    classNames: try PostprocessTests.strings(i, "classes"), postprocess: .heatmap, boxFormat: .heatmapStride,
                    heatmapStride: Int(paso)
                )
                dets = try dec.decodeHeatmap(
                    heatmap: try PostprocessTests.mapa(i, "heatmap"), offset: try PostprocessTests.mapa(i, "offset"),
                    size: try PostprocessTests.mapa(i, "size"), layout: layout, footMask: mascara
                )
            } else {
                dets = try PlayerDecoder(classNames: try PostprocessTests.strings(i, "classes")).decode(
                    logits: try PostprocessTests.filas(i, "logits"), boxes: try PostprocessTests.filas(i, "boxes"),
                    layout: layout, footMask: mascara
                )
            }
            let actual: GoldenValue = .object([
                "boxes": .tensor(f64: dets.flatMap { [$0.x1, $0.y1, $0.x2, $0.y2] }, shape: [dets.count, 4]),
                "classes": .array(dets.map { .string($0.playerClass.rawValue) }),
                "scores": .tensor(f64: dets.map(\.score), shape: [dets.count]),
            ])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
            corridos += 1
        }
        XCTAssertGreaterThanOrEqual(corridos, 2, "los casos con máscara de campo")
    }

    func testLosPiesSeRecortanYSeTruncanComoNumpy() throws {
        let vistos = LockedPixels()
        let mascara = try FootMask(width: 100, height: 50) { x, y in
            vistos.append(x, y)
            return true
        }
        XCTAssertTrue(mascara.contains(footX: -3, footY: 7.99))
        XCTAssertTrue(mascara.contains(footX: 250.5, footY: 49.999))
        XCTAssertTrue(mascara.contains(footX: 12.7, footY: .infinity))
        XCTAssertFalse(mascara.contains(footX: .nan, footY: 3), "un pie NaN no pisa el campo")
        XCTAssertEqual(vistos.all, [[0, 7], [99, 49], [12, 49]])
        XCTAssertThrowsError(try FootMask(width: 0, height: 10) { _, _ in true })
    }

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

/// Los píxeles que pregunta una FootMask, para el test (la máscara pide un cierre Sendable).
private final class LockedPixels: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: [[Int]] = []
    func append(_ x: Int, _ y: Int) { lock.withLock { pixels.append([x, y]) } }
    var all: [[Int]] { lock.withLock { pixels } }
}
