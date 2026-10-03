import XCTest

import RigCore
@testable import RigMedia

final class TelemetryWriterTests: XCTestCase {
    private func snapshot(rigMs: Int64) -> TelemetrySnapshot {
        TelemetrySnapshot(
            rigMs: rigMs, fps: 30, didDrop: 0, queueDrops: [:], stages: [:],
            inferMsByModel: [:], thermalState: "nominal", systemPressure: "nominal",
            ladderLevel: 0, batteryLevel: 1.0, charging: false,
            availableMemoryBytes: 1_000_000
        )
    }

    func testWritesOneJsonLinePerSnapshot() throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: carpeta) }
        let writer = try TelemetryWriter(directory: carpeta, drainsAutomatically: false)

        for segundo in 0..<5 {
            writer.append(snapshot(rigMs: Int64(segundo) * 1000))
        }
        writer.flush()

        let contenido = try String(contentsOf: writer.fileURL, encoding: .utf8)
        let lineas = contenido.split(separator: "\n")
        XCTAssertEqual(lineas.count, 5)
        for (indice, linea) in lineas.enumerated() {
            XCTAssertTrue(linea.contains("\"rig_ms\":\(indice * 1000)"))
        }
    }

    func testTheQueueDropsInsteadOfGrowing() throws {
        let carpeta = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: carpeta) }
        let writer = try TelemetryWriter(directory: carpeta, drainsAutomatically: false)

        // Mucho más que la capacidad, sin dejar drenar: lo viejo se tira y se cuenta,
        // y lo que sobrevive es lo más nuevo.
        for segundo in 0..<100 {
            writer.append(snapshot(rigMs: Int64(segundo)))
        }
        let escritas = writer.flush()

        XCTAssertEqual(escritas + writer.dropped, 100)
        XCTAssertEqual(writer.written, escritas)
        let contenido = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(contenido.contains("\"rig_ms\":99"))
    }
}
