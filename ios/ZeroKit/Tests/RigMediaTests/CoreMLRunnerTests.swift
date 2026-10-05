import CoreML
import CoreVideo
import XCTest

@testable import RigMedia

/// El ejecutor Core ML (IOS-22) con el modelo mínimo (tools/make_test_model.py): el
/// manifiesto que cuadra y el que no, las salidas preasignadas y los carriles.
final class CoreMLRunnerTests: XCTestCase {
    private var url: URL {
        Bundle.module.url(forResource: "Fixtures/tiny-detr", withExtension: "mlpackage")!
    }

    private func manifiesto(clases: [String] = ["goalkeeper", "player", "referee"], ancho: Int = 64) throws
        -> ModelManifest.Entry
    {
        try ModelManifest.parse([
            "version": 1,
            "models": ["tiny": [
                "version": "0.0.1", "file": "tiny-detr.mlpackage", "sha256": String(repeating: "a", count: 64),
                "min_ios": 18, "classes": clases,
                "input": ["name": "image", "shape": [1, 3, 32, ancho], "color": "RGB", "scale": 255],
                "outputs": [
                    ["name": "logits", "shape": [1, 10, 3], "meaning": "logits"],
                    ["name": "boxes", "shape": [1, 10, 4], "meaning": "boxes_cxcywh_norm"],
                ],
            ]],
        ]).models["tiny"]!
    }

    private func gris(_ v: UInt8) throws -> MLFeatureProvider {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &b)
        let buf = try XCTUnwrap(b)
        CVPixelBufferLockBaseAddress(buf, [])
        memset(CVPixelBufferGetBaseAddress(buf), Int32(v), CVPixelBufferGetBytesPerRow(buf) * 32)
        CVPixelBufferUnlockBaseAddress(buf, [])
        return try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buf)])
    }

    func testElManifiestoQueNoCuadraSeRechazaConUnErrorLegible() async throws {
        XCTAssertThrowsError(try manifiesto(clases: ["player"])) {
            XCTAssertTrue("\($0)".contains("clases"), "\($0)")
        }
        do {
            _ = try await CoreMLRunner.load(url: url, entry: try manifiesto(ancho: 128), computeUnits: .cpuOnly)
            XCTFail("un manifiesto de otro tamaño no puede pasar")
        } catch {
            XCTAssertTrue("\(error)".contains("64×32"), "\(error)")
        }
        XCTAssertThrowsError(try ModelManifest.parse(["version": 2, "models": [:]]))
    }

    func testPrediceEnSusBuferesYLosCarrilesRespetanLaPrioridad() async throws {
        let r = try await CoreMLRunner.load(url: url, entry: try manifiesto(), computeUnits: .cpuOnly)
        XCTAssertGreaterThan(try r.warmUp(with: try gris(128)), 0)

        // Media 128/255: logits = 2·m + linspace(−3, 3, 30).
        let hecho = expectation(description: "predicción")
        nonisolated(unsafe) var salida: CoreMLRunner.Output?
        r.submit(try gris(128), lane: .players) { salida = try? $0.get(); hecho.fulfill() }
        await fulfillment(of: [hecho], timeout: 10)
        let logits = try XCTUnwrap(salida?.arrays["logits"])
        XCTAssertEqual(logits.shape, [1, 10, 3])
        XCTAssertEqual(logits[0].doubleValue, -3 + 2 * 128 / 255, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(salida?.arrays["boxes"])[2].doubleValue, 0.1, accuracy: 0.01)

        // Tres peticiones de jugadores mientras está ocupado: solo la última se sirve,
        // y el balón va por delante.
        let todas = expectation(description: "carriles")
        todas.expectedFulfillmentCount = 5
        let orden = NSMutableArray()
        for i in 0..<3 {
            r.submit(try gris(UInt8(10 * i)), lane: .players) {
                if case .success = $0 { orden.add("j\(i)") }
                todas.fulfill()
            }
        }
        r.submit(try gris(5), lane: .ball) { _ in orden.add("b"); todas.fulfill() }
        r.submit(try gris(6), lane: .ball) { _ in orden.add("b2"); todas.fulfill() }
        await fulfillment(of: [todas], timeout: 10)
        XCTAssertTrue((orden as? [String] ?? []).contains("j2"))
        XCTAssertGreaterThanOrEqual(r.dropped[.players] ?? 0, 1)
        XCTAssertGreaterThan(r.percentiles(.players).p50, 0)
    }
}
