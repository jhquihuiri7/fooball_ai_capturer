// El planificador de ROIs del balón (IOS-28): las reglas de la referencia que un dorado
// no nombra solas. Las ROIs de las secuencias de ball.json llegan con el tracker (IOS-28b).

import Foundation
import RigCore
import XCTest

final class RoiPlannerTests: XCTestCase {
    private let (ancho, alto) = (3840, 2160)

    func testElLadoConExportMasCercanoYAEmpateElMayor() {
        XCTAssertEqual(BallRoiPlanner.heatmapSide(100), DetectionSpec.ballRoiSide)
        XCTAssertEqual(BallRoiPlanner.heatmapSide(287.9, sides: [256, 320]), 256)
        XCTAssertEqual(BallRoiPlanner.heatmapSide(288, sides: [256, 320]), 320)
        XCTAssertEqual(BallRoiPlanner.heatmapSide(288, sides: [320, 256]), 320)
        XCTAssertEqual(BallRoiPlanner.heatmapSide(5000, sides: [256, 320]), 320)
        XCTAssertNil(BallRoiPlanner.heatmapSide(256, sides: []))
    }

    /// x = ⌊cx − lado/2 + 0,5⌋: 872,5 va a 873, donde el `round` de Python daría 872.
    func testElCentradoRedondeaHaciaArribaNoAlPar() {
        let roi = BallRoiPlanner.roi(
            centeredAt: 1000.5, 1000.5, side: 256, source: .predictive, width: ancho, height: alto
        )
        XCTAssertEqual(roi, BallRoi(x: 873, y: 873, side: 256, source: .predictive))
    }

    /// Se desplaza dentro del frame y no se recorta; si no cabe ni así, se encoge.
    func testLaRoiSeDesplazaDentroDelFrame() {
        XCTAssertEqual(
            BallRoi(x: -40, y: 2100, side: 256, source: .sweep).clamped(width: ancho, height: alto),
            BallRoi(x: 0, y: 1904, side: 256, source: .sweep)
        )
        XCTAssertEqual(
            BallRoi(x: 50, y: -3, side: 320, source: .sweep).clamped(width: 400, height: 200),
            BallRoi(x: 50, y: 0, side: 200, source: .sweep)
        )
        let roi = BallRoi(x: 10, y: 20, side: 256, source: .sweep)
        XCTAssertTrue(roi.contains(x: 10, y: 20))
        XCTAssertFalse(roi.contains(x: 266, y: 100))  // el píxel 266 ya no es de la ROI
    }

    /// La segunda hipótesis es el grupo más cercano a la predicción que no cae en la
    /// primera ROI; a igual distancia, el primero en el orden de quien llama.
    func testLaSegundaHipotesisEsElGrupoMasCercanoFueraDeLaPrimera() {
        let prediccion = (x: 2000.0, y: 1000.0, sigmaPx: 2.0)
        let grupos: [(x: Double, y: Double)] = [(2050, 1010), (2600, 1000), (1400, 1000), (2000, 300)]
        let rois = BallRoiPlanner.plan(
            prediction: prediccion, groups: grupos, sides: [256], maxRois: 2, width: ancho, height: alto
        )
        XCTAssertEqual(rois, [
            BallRoi(x: 1872, y: 872, side: 256, source: .predictive),
            BallRoi(x: 2472, y: 872, side: 256, source: .playerGuided),
        ])
        // Con una sola plaza o sin grupos fuera, solo la predicción.
        XCTAssertEqual(
            BallRoiPlanner.plan(
                prediction: prediccion, groups: grupos, sides: [256], maxRois: 1, width: ancho, height: alto
            ).count, 1
        )
        XCTAssertEqual(
            BallRoiPlanner.plan(
                prediction: prediccion, groups: [(2050, 1010)], sides: [256], maxRois: 2, width: ancho, height: alto
            ).map(\.source), [.predictive]
        )
    }

    /// El lado lo pide la incertidumbre: 6σ + 64 px, al export más cercano.
    func testElLadoCreceConLaIncertidumbre() {
        let lados = [256, 320]
        let quieta = BallRoiPlanner.plan(
            prediction: (x: 2000, y: 1000, sigmaPx: 10), groups: [], sides: lados, maxRois: 2,
            width: ancho, height: alto
        )
        XCTAssertEqual(quieta.map(\.side), [256])
        let incierta = BallRoiPlanner.plan(
            prediction: (x: 2000, y: 1000, sigmaPx: 40), groups: [(100, 100)], sides: lados, maxRois: 2,
            width: ancho, height: alto
        )
        XCTAssertEqual(incierta.map(\.side), [320, 320])  // las dos del mismo lado: un lote
    }

    /// Sin filtro, los primeros grupos en el orden de quien llama, con el lado mayor.
    func testSinPrediccionLosPrimerosGruposConElLadoMayor() {
        let rois = BallRoiPlanner.plan(
            prediction: nil, groups: [(3800, 2150), (100, 100), (1900, 1000)], sides: [256, 320], maxRois: 2,
            width: ancho, height: alto
        )
        XCTAssertEqual(rois, [
            BallRoi(x: 3520, y: 1840, side: 320, source: .playerGuided),
            BallRoi(x: 0, y: 0, side: 320, source: .playerGuided),
        ])
        XCTAssertEqual(
            BallRoiPlanner.plan(prediction: nil, groups: [], sides: [256], maxRois: 2, width: ancho, height: alto), []
        )
    }
}
