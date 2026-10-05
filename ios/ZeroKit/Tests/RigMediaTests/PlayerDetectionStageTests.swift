import CoreVideo
import XCTest

import RigCore
@testable import RigMedia

/// La etapa de detección (IOS-25) con un detector falso: la rejilla k/7,5 Hz, el mismo
/// instante en los dos móviles aunque sus fases difieran, y los descartes por ocupado.
final class PlayerDetectionStageTests: XCTestCase {
    private final class DetectorFalso: PlayerDetecting {
        var ms: Double = 5
        var pendientes: [(Result<([PlayerDetection], Double), Error>) -> Void] = []
        var inmediato = true
        func detect(_ frame: CVPixelBuffer, completion: @escaping (Result<([PlayerDetection], Double), Error>) -> Void) {
            if inmediato { completion(.success(([], ms))) } else { pendientes.append(completion) }
        }
    }

    func testLaRejillaEsLaDelReloj() {
        let c = DetectionCadence(hz: 7.5)
        XCTAssertEqual(c.periodMs, 133.333, accuracy: 0.001)
        XCTAssertEqual(c.next(after: 0), 133)
        XCTAssertEqual(c.next(after: 133), 267)
        XCTAssertEqual(c.instant(3), 400)
        XCTAssertEqual(c.index(nearest: 1050), 8)
    }

    /// Diez segundos de dos cámaras a 30 fps con fases que difieren 5 ms: las dos detectan
    /// en los mismos t_k, con fotogramas a ≤½ fotograma de él.
    func testLosDosMovilesDetectanEnLosMismosInstantes() throws {
        func corre(fase: Double) throws -> [CameraDetections] {
            let ring = try XCTUnwrap(FrameRing(slots: 4, width: 64, height: 32))
            let stage = PlayerDetectionStage(side: .left, ring: ring, detector: DetectorFalso())
            var salida: [CameraDetections] = []
            stage.onDetections = { salida.append($0) }
            for n in 0..<300 {
                let ms = Int64((1000 + fase + Double(n) * 1000 / 30).rounded())
                _ = ring.store(rigMs: ms) { _ in }
                stage.frameStored(rigMs: ms)
            }
            XCTAssertEqual(stage.stats.missingFrame, 0)
            return salida
        }
        let a = try corre(fase: 0), b = try corre(fase: 5)
        XCTAssertGreaterThanOrEqual(a.count, 73)
        XCTAssertEqual(a.map(\.targetRigMs), b.map(\.targetRigMs), "los mismos instantes sin hablarse")
        for (x, y) in zip(a, b) {
            XCTAssertLessThanOrEqual(abs(x.frameRigMs - x.targetRigMs), 17)
            XCTAssertLessThanOrEqual(abs(x.frameRigMs - y.frameRigMs), 6, "a la distancia de la fase")
        }
        // ~7,5 Hz.
        let hz = Double(a.count - 1) / (Double(a.last!.targetRigMs - a.first!.targetRigMs) / 1000)
        XCTAssertEqual(hz, 7.5, accuracy: 0.05)
    }

    func testConUnaDeteccionEnVueloLaSiguienteSeDescartaYSeCuenta() throws {
        let ring = try XCTUnwrap(FrameRing(slots: 4, width: 64, height: 32))
        let det = DetectorFalso()
        det.inmediato = false
        let stage = PlayerDetectionStage(side: .right, ring: ring, detector: det)
        for n in 0..<40 {
            let ms = Int64((1000 + Double(n) * 1000 / 30).rounded())
            _ = ring.store(rigMs: ms) { _ in }
            stage.frameStored(rigMs: ms)
        }
        XCTAssertEqual(det.pendientes.count, 1)
        XCTAssertGreaterThanOrEqual(stage.stats.droppedBusy, 8)
        det.pendientes[0](.success(([], 3)))
        XCTAssertEqual(stage.stats.detections, 1)
        stage.setCadence(DetectionCadence(hz: 5))
        XCTAssertEqual(stage.stats.failures, 0)
    }
}
