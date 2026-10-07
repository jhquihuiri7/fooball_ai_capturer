// La NMS por clase (IOS-23): el truco del desplazamiento da lo mismo que una NMS por
// cada clase por separado, también con coordenadas negativas y cajas que se pisan entre
// clases. Los dorados de postprocess.json (topk, empates, tope) están en PostprocessTests.

import Foundation
import RigCore
import XCTest

final class NmsTests: XCTestCase {
    /// Una NMS voraz por clase, sin desplazar, y la unión por score (a igualdad, el índice).
    private func porClase(_ boxes: [[Float]], _ scores: [Float], _ classes: [Int], iou: Double, max: Int) -> [Int] {
        let orden = scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        func solape(_ a: [Float], _ b: [Float]) -> Double {
            let (a, b) = (a.map(Double.init), b.map(Double.init))
            let inter = Swift.max(Swift.min(a[2], b[2]) - Swift.max(a[0], b[0]), 0)
                * Swift.max(Swift.min(a[3], b[3]) - Swift.max(a[1], b[1]), 0)
            let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
            return union > 0 ? inter / union : 0
        }
        var kept: [Int] = []
        for i in orden where !kept.contains(where: { classes[$0] == classes[i] && solape(boxes[$0], boxes[i]) > iou }) {
            kept.append(i)
        }
        return Array(kept.prefix(max))
    }

    func testElDesplazamientoEsUnaNmsPorClase() {
        var estado: UInt64 = 7
        func azar() -> Float {
            estado = estado &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(estado >> 40) / Float(1 << 24)
        }
        for caso in 0..<200 {
            let n = 1 + Int(azar() * 40)
            var boxes: [[Float]] = [], scores: [Float] = [], classes: [Int] = []
            for _ in 0..<n {
                // Cajas apiñadas en un rincón que cruza el cero: se pisan dentro y entre clases.
                let (x, y) = (azar() * 200 - 100, azar() * 120 - 60)
                boxes.append([x, y, x + 10 + azar() * 60, y + 20 + azar() * 80])
                scores.append(Float(Int(azar() * 8)) / 8)
                classes.append(Int(azar() * 3))
            }
            let iou = [0.3, 0.5, 0.7][caso % 3]
            let tope = [3, 64][caso % 2]
            XCTAssertEqual(
                Postprocess.nms(boxes: boxes, scores: scores, classes: classes, iouThreshold: iou, maxDetections: tope, preTopk: 300),
                porClase(boxes, scores, classes, iou: iou, max: tope),
                "caso \(caso)"
            )
        }
    }

    func testCajasIgualesDeClasesDistintasSobreviven() {
        let caja: [Float] = [-50, -20, 10, 40]
        let keep = Postprocess.nms(
            boxes: [caja, caja, caja], scores: [0.9, 0.8, 0.7], classes: [1, 0, 1], maxDetections: 10
        )
        XCTAssertEqual(keep, [0, 1])
    }
}
