import XCTest

@testable import RigMedia

/// El cierre de una pasada del programa (2026-10-15): el informe final se escribe siempre.
/// El esclavo del plan B de la cancha no se enlazó y no dejó informe, porque solo se
/// escribía en el maestro o con la parte montada; su latido se quedó en `finished: false`.
final class ProgramRunFilesTests: XCTestCase {
    private func carpeta() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("bench", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func lee(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Un esclavo que nunca enlazó: sin parte, sin programa, sin estadísticas de nadie. Deja
    /// los dos ficheros, con los nombres que busca la recogida, y el latido dice que acabó.
    func testASlaveThatNeverLinkedStillLeavesItsReport() throws {
        let bench = carpeta()
        let informe: [String: Any] = [
            "name": "program-split", "role": "slave", "side": "right", "slave_parts": 0,
            "link": ["summary": "no ve al otro en 600 s"],
        ]
        let latido: [String: Any] = ["name": "program-live", "finished": false, "elapsed_s": 600.0]
        let (r, l) = try ProgramRunFiles.writeFinal(
            report: informe, live: latido, directory: bench, side: "right",
            startUnixMs: 1_792_075_891_138, endUnixS: 1_792_076_491
        )
        XCTAssertEqual(r.lastPathComponent, "program-split-right-1792076491.json")
        XCTAssertEqual(l.lastPathComponent, "program-live-right-1792075891.json")
        XCTAssertEqual(try lee(r)["role"] as? String, "slave")
        XCTAssertEqual((try lee(r)["link"] as? [String: Any])?["summary"] as? String, "no ve al otro en 600 s")
        XCTAssertEqual(try lee(l)["finished"] as? Bool, true)
    }

    /// El latido final pisa el último latido de la pasada (el mismo nombre): no se queda
    /// el de `finished: false`.
    func testTheFinalHeartbeatReplacesTheLastOne() throws {
        let bench = carpeta()
        try FileManager.default.createDirectory(at: bench, withIntermediateDirectories: true)
        let nombre = ProgramRunFiles.liveName(side: "left", startUnixMs: 1_792_075_881_274)
        XCTAssertEqual(nombre, "program-live-left-1792075881.json")
        try ProgramRunFiles.encode(["finished": false, "elapsed_s": 570.0])
            .write(to: bench.appendingPathComponent(nombre))
        try ProgramRunFiles.writeFinal(
            report: ["role": "master"], live: ["elapsed_s": 600.0], directory: bench, side: "left",
            startUnixMs: 1_792_075_881_274, endUnixS: 1_792_076_481
        )
        let latido = try lee(bench.appendingPathComponent(nombre))
        XCTAssertEqual(latido["finished"] as? Bool, true)
        XCTAssertEqual(latido["elapsed_s"] as? Double, 600)
    }

    /// Un percentil desbordado (infinito o NaN) no tira la app al cerrar: pasa a -1.
    func testNonFiniteNumbersDoNotAbortTheReport() throws {
        let bench = carpeta()
        let (r, _) = try ProgramRunFiles.writeFinal(
            report: ["p95": Double.infinity, "lista": [Double.nan, 1.5], "dentro": ["x": Float.infinity]],
            live: [:], directory: bench, side: "left", startUnixMs: 0, endUnixS: 1
        )
        let informe = try lee(r)
        XCTAssertEqual(informe["p95"] as? Double, -1)
        XCTAssertEqual(informe["lista"] as? [Double], [-1, 1.5])
        XCTAssertEqual((informe["dentro"] as? [String: Any])?["x"] as? Double, -1)
    }
}
