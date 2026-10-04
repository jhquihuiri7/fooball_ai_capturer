// El emparejador de metadatos contra las secuencias doradas del FramePairer
// (IOS-32): mismos resultados y MISMAS estadísticas que la referencia.

import Foundation
import RigCore
import XCTest

final class DetectionPairerTests: XCTestCase {
    func testLasSecuenciasDoradasDelPairer() throws {
        let documento = try Golden.loadDocument(named: "sync.json")
        var corridas = 0
        for caso in documento.cases where caso.fn == "FramePairer.run" {
            corridas += 1
            let actual = try Self.replay(inputs: caso.inputs)
            if let fallo = Golden.mismatch(
                actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name
            ) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridas, 3)
    }

    func testElHuecoAcotadoDescartaLoMasViejo() {
        let pairer = DetectionPairer<String>(toleranceNs: 1_000, bufferFrames: 2)
        pairer.push(.left, ptsNs: 0, payload: "a")
        pairer.push(.left, ptsNs: 10, payload: "b")
        pairer.push(.left, ptsNs: 20, payload: "c")  // desborda: "a" fuera, sin encolar

        XCTAssertEqual(pairer.stats.droppedLeft, 1)
        XCTAssertEqual(pairer.pending(.left), 2)
        XCTAssertEqual(pairer.pop(force: true)?.left?.payload, "b")
    }

    func testLaCargaViajaConSuLado() {
        let pairer = DetectionPairer<[Int]>(toleranceNs: 5, bufferFrames: 3)
        pairer.push(.left, ptsNs: 100, payload: [1, 2])
        pairer.push(.right, ptsNs: 103, payload: [3])

        let pareja = pairer.pop()
        XCTAssertEqual(pareja?.left?.payload, [1, 2])
        XCTAssertEqual(pareja?.right?.payload, [3])
        XCTAssertEqual(pareja?.skewNs, -3)
        XCTAssertEqual(pareja?.ptsNs, 101)  // el punto medio reparte el desfase
    }

    // MARK: - La repetición de una secuencia dorada

    private static func replay(inputs: GoldenValue) throws -> GoldenValue {
        let pairer = DetectionPairer<Int>(
            toleranceNs: Int(try inputs.number("tolerance_ns")),
            bufferFrames: Int(try inputs.number("buffer_frames"))
        )
        guard case let .array(eventos)? = try? inputs.field("events") else {
            throw GoldenError.message("events no es una lista")
        }
        var resultados: [GoldenValue] = []
        var contador = 0
        for evento in eventos {
            if try evento.string("op") == "push" {
                let lado = CameraSide(rawValue: try evento.string("side"))!
                pairer.push(lado, ptsNs: Int(try evento.number("pts_ns")), payload: contador)
                contador += 1
                continue
            }
            let fuerza = (try? evento.field("force").boolValue) ?? false
            guard let pareja = pairer.pop(force: fuerza ?? false) else {
                resultados.append(.null)
                continue
            }
            resultados.append(.object([
                "left_pts_ns": pareja.left.map { .number(Double($0.ptsNs)) } ?? .null,
                "right_pts_ns": pareja.right.map { .number(Double($0.ptsNs)) } ?? .null,
                "seq": .number(Double(pareja.seq)),
                "skew_ns": .number(Double(pareja.skewNs)),
                "pts_ns": .number(Double(pareja.ptsNs)),
                "complete": .bool(pareja.complete),
            ]))
        }
        let stats = pairer.stats
        return .object([
            "results": .array(resultados),
            "stats": .object([
                "complete": .number(Double(stats.complete)),
                "orphan_left": .number(Double(stats.orphanLeft)),
                "orphan_right": .number(Double(stats.orphanRight)),
                "dropped_left": .number(Double(stats.droppedLeft)),
                "dropped_right": .number(Double(stats.droppedRight)),
                "max_abs_skew_ns": .number(Double(stats.maxAbsSkewNs)),
                "mean_abs_skew_ns": .number(Double(stats.meanAbsSkewNs)),
                "completeness": .number(stats.completeness),
                "synchronized": .bool(stats.synchronized),
            ]),
            "pending_left": .number(Double(pairer.pending(.left))),
            "pending_right": .number(Double(pairer.pending(.right))),
        ])
    }
}
