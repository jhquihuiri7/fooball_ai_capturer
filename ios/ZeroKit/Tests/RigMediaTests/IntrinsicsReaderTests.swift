// Las intrínsecas por fotograma frente a rig.json (IOS-72): la deriva, los umbrales y
// que queden en la telemetría.

import Foundation
import RigCore
@testable import RigMedia
import XCTest

final class IntrinsicsReaderTests: XCTestCase {
    /// rig.json a 4K; el búfer, a 1080p (la mitad): la matriz llega en ese búfer.
    private let referencia = try! CameraIntrinsics(fx: 1446.8, fy: 1446.8, cx: 1919.5, cy: 1079.5, width: 3840, height: 2160)

    private func matriz(fx: Double, fy: Double, cx: Double, cy: Double) -> [Float] {
        [Float(fx), 0, Float(cx), 0, Float(fy), Float(cy), 0, 0, 1]
    }

    func testSinDerivaNoAvisa() throws {
        let enBufer = try referencia.scaled(0.5)
        let d = try XCTUnwrap(IntrinsicsReader.drift(
            matrix: matriz(fx: enBufer.fx, fy: enBufer.fy, cx: enBufer.cx, cy: enBufer.cy),
            bufferWidth: 1920, reference: referencia
        ))
        XCTAssertEqual(d.focalRelDelta, 0, accuracy: 1e-6)
        XCTAssertEqual(d.centerDeltaPx, 0, accuracy: 1e-3)
        XCTAssertFalse(d.suggestsRecalibration)
    }

    func testUnaFocalDistintaAvisa() throws {
        let enBufer = try referencia.scaled(0.5)
        let d = try XCTUnwrap(IntrinsicsReader.drift(
            matrix: matriz(fx: enBufer.fx * 1.02, fy: enBufer.fy * 1.02, cx: enBufer.cx, cy: enBufer.cy),
            bufferWidth: 1920, reference: referencia
        ))
        XCTAssertEqual(d.focalRelDelta, 0.02, accuracy: 1e-5)
        XCTAssertTrue(d.suggestsRecalibration)
    }

    func testElCentroSeMideEnPixelesNativos() throws {
        let enBufer = try referencia.scaled(0.5)
        // 5 px del búfer de 1080p son 10 nativos: por encima del umbral de 8.
        let d = try XCTUnwrap(IntrinsicsReader.drift(
            matrix: matriz(fx: enBufer.fx, fy: enBufer.fy, cx: enBufer.cx + 5, cy: enBufer.cy),
            bufferWidth: 1920, reference: referencia
        ))
        XCTAssertEqual(d.centerDeltaPx, 10, accuracy: 1e-3)
        XCTAssertTrue(d.suggestsRecalibration)
    }

    func testUnaMatrizQueNoEsIntrinsecaSeIgnora() {
        XCTAssertNil(IntrinsicsReader.drift(matrix: nil, bufferWidth: 1920, reference: referencia))
        XCTAssertNil(IntrinsicsReader.drift(matrix: [1, 2, 3], bufferWidth: 1920, reference: referencia))
        XCTAssertNil(IntrinsicsReader.drift(
            matrix: [700, 0, 960, 0, 700, 540, 0.1, 0, 1], bufferWidth: 1920, reference: referencia
        ))
    }

    func testQuedaEnLaTelemetria() throws {
        var foto = TelemetrySnapshot(
            rigMs: 1, fps: 30, didDrop: 0, queueDrops: [:], stages: [:], inferMsByModel: [:],
            thermalState: "nominal", systemPressure: "nominal", ladderLevel: 0,
            batteryLevel: 1, charging: true, availableMemoryBytes: 1
        )
        let sinNada = String(decoding: try foto.jsonLine(), as: UTF8.self)
        XCTAssertFalse(sinNada.contains("intrinsics"), "opcional: sin dato, no aparece")
        foto.intrinsics = IntrinsicsDrift(
            fxPx: 723.4, fyPx: 723.4, cxPx: 959.75, cyPx: 539.75, focalRelDelta: 0, centerDeltaPx: 0
        )
        foto.seamMedianRad = 0.002
        let linea = String(decoding: try foto.jsonLine(), as: UTF8.self)
        XCTAssertTrue(linea.contains("\"intrinsics\":{"))
        XCTAssertTrue(linea.contains("\"focal_rel_delta\":0"))
        XCTAssertTrue(linea.contains("\"seam_median_rad\":0.002"))
    }
}
