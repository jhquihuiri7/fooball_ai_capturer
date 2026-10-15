// RIG_PURGE_BENCH=1: lo de antes de hoy de bench/, bench4k/ y nv12/, y nada más (2026-10-15).

import Foundation
import XCTest
@testable import RigMedia

final class BenchPurgeTests: XCTestCase {
    private var docs: URL!
    private let fm = FileManager.default
    private let ahora = Date(timeIntervalSince1970: 1_792_081_800)  // 2026-10-15 10:30 en Ciudad de México
    private var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return c
    }

    private var ayer: Date { ahora.addingTimeInterval(-86_400) }
    private var hoy: Date { ahora.addingTimeInterval(-60) }

    override func setUpWithError() throws {
        docs = fm.temporaryDirectory.appendingPathComponent("purge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: docs)
    }

    private func pon(_ ruta: String, bytes: Int = 10, fecha: Date) throws {
        let url = docs.appendingPathComponent(ruta)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try fm.setAttributes([.modificationDate: fecha], ofItemAtPath: url.path)
    }

    private func hay(_ ruta: String) -> Bool {
        fm.fileExists(atPath: docs.appendingPathComponent(ruta).path)
    }

    func testTheCutoffIsTheStartOfTodayInThePhoneCalendar() {
        let corte = BenchPurge.cutoff(now: ahora, calendar: calendario)
        XCTAssertEqual(corte, Date(timeIntervalSince1970: 1_792_044_000))  // 2026-10-15 00:00 en México
    }

    func testWithoutTheVariableItTouchesNothing() throws {
        try pon("bench/program-split-1.ts", fecha: ayer)
        XCTAssertNil(BenchPurge.purgeIfAsked(environment: ["RIG_PURGE_BENCH": "0"], documents: docs, now: ahora,
                                             calendar: calendario))
        XCTAssertTrue(hay("bench/program-split-1.ts"))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("bench").path + "/purge-1792081800.json"))
    }

    func testItRemovesOnlyTheOldTestsAndNeverTheCalibrationModelsOrProgramCopies() throws {
        // Lo de antes de hoy en las tres carpetas: se va.
        try pon("bench/program-split-1791000000.ts", bytes: 1000, fecha: ayer)
        try pon("bench/program-split-left-1791000600.json", bytes: 100, fecha: ayer)
        try pon("bench4k/1791000000/left-1791000000.mov", bytes: 5000, fecha: ayer)
        try pon("nv12/left-17.nv12", bytes: 300, fecha: ayer)
        // Lo de hoy en las tres: se queda.
        try pon("bench/program-live-left-1792150000.json", fecha: hoy)
        try pon("bench4k/1792150000/left-1792150000.mov", fecha: hoy)
        try pon("nv12/left-18.nv12", fecha: hoy)
        // Lo viejo de fuera: nunca.
        let fuera = ["rig.json", "bench-resources/players-centernet-mnv4.mlpackage/Manifest.json",
                     "program-m_f50b97dd8d1a-1792076844.mov", "calib/687731642/left-687731642.jpg",
                     "n0/zero-1792076844-left.jsonl", "left-1791160494.mov", "bench.json"]
        for ruta in fuera { try pon(ruta, fecha: ayer) }
        // Un enlace simbólico dentro de nv12 hacia rig.json: ni se sigue ni se borra.
        try fm.createSymbolicLink(at: docs.appendingPathComponent("nv12/rig-enlace.json"),
                                  withDestinationURL: docs.appendingPathComponent("rig.json"))

        let r = try XCTUnwrap(BenchPurge.purgeIfAsked(environment: ["RIG_PURGE_BENCH": "1"], documents: docs,
                                                      now: ahora, calendar: calendario))

        XCTAssertEqual(r.removedFiles, 4)
        XCTAssertEqual(r.removedBytes, 6400)
        XCTAssertEqual(r.byFolder["bench"], BenchPurge.FolderResult(removedFiles: 2, removedBytes: 1100, keptFiles: 1))
        XCTAssertEqual(r.byFolder["bench4k"]?.removedFiles, 1)
        XCTAssertEqual(r.byFolder["nv12"], BenchPurge.FolderResult(removedFiles: 1, removedBytes: 300, keptFiles: 2))
        XCTAssertEqual(r.failures, [])
        for ruta in ["bench/program-split-1791000000.ts", "bench/program-split-left-1791000600.json",
                     "bench4k/1791000000", "nv12/left-17.nv12"] {
            XCTAssertFalse(hay(ruta), ruta)
        }
        for ruta in fuera + ["bench/program-live-left-1792150000.json", "bench4k/1792150000/left-1792150000.mov",
                             "nv12/left-18.nv12", "nv12/rig-enlace.json"] {
            XCTAssertTrue(hay(ruta), ruta)
        }
        // Las tres carpetas siguen ahí para los bancos de después, y el informe dice lo borrado.
        for folder in BenchPurge.folders { XCTAssertTrue(hay(folder), folder) }
        let informe = try JSONSerialization.jsonObject(
            with: Data(contentsOf: docs.appendingPathComponent("bench/purge-1792081800.json"))
        ) as? [String: Any]
        XCTAssertEqual(informe?["removed_files"] as? Int, 4)
        XCTAssertEqual(informe?["removed_bytes"] as? Int, 6400)
        XCTAssertEqual(informe?["cutoff_unix_s"] as? Int, 1_792_044_000)
    }

    func testWithoutTheFoldersThereIsNothingToDo() throws {
        let r = BenchPurge.run(documents: docs, cutoff: ahora)
        XCTAssertEqual(r.removedFiles, 0)
        XCTAssertEqual(r.byFolder.count, BenchPurge.folders.count)
    }
}
