// La rotación de la franja contra los dorados de ad_strip.json (IOS-48, REF-36).

import Foundation
import RigCore
import XCTest

final class AdPlaylistTests: XCTestCase {
    func testLosDoradosDeLaRotacion() throws {
        let documento = try Golden.loadDocument(named: "ad_strip.json")
        var corridas = 0
        for caso in documento.cases where caso.fn == "ad_strip.rotation" {
            corridas += 1
            let entrada = try XCTUnwrap(caso.inputs.jsonObject() as? [String: Any])
            func clip(_ i: Int, _ d: [String: Any]) throws -> AdClip {
                AdClip(name: "ad\(i)", frames: try XCTUnwrap((d["frames"] as? NSNumber)?.intValue),
                       fps: try XCTUnwrap((d["fps"] as? NSNumber)?.intValue))
            }
            let crudos = entrada["slots"] as? [[String: Any]] ?? []
            var clips = try crudos.enumerated().map { try clip($0.offset, $0.element) }
            let lista = AdPlaylist(slots: try zip(clips, crudos).map {
                try AdSlot(ad: $0, loops: ($1["loops"] as? NSNumber)?.intValue ?? 1)
            })
            var override: AdOverride?
            if let o = entrada["override"] as? [String: Any] {
                let c = try clip(clips.count, o)
                clips.append(c)
                override = AdOverride(ad: c, startNs: try XCTUnwrap((o["start_ns"] as? NSNumber)?.int64Value),
                                      loops: (o["loops"] as? NSNumber)?.intValue ?? 1)
            }
            var quien: [Int32] = []
            var cual: [Int32] = []
            for e in try XCTUnwrap(entrada["elapsed_ns"] as? [NSNumber]) {
                let cue = lista.cue(atElapsedNs: e.int64Value, override: override)
                quien.append(cue.map { c in Int32(clips.firstIndex(of: c.ad)!) } ?? -1)
                cual.append(cue.map { Int32($0.frame) } ?? -1)
            }
            let actual = GoldenValue.object([
                "cycle_ns": .number(Double(lista.cycleNs)),
                "ad": .tensor(i32: quien, shape: [quien.count]),
                "frame": .tensor(i32: cual, shape: [cual.count]),
            ])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertEqual(corridas, 12)
    }

    func testCeroVueltasEsUnError() {
        XCTAssertThrowsError(try AdSlot(ad: AdClip(name: "x", frames: 1, fps: 30), loops: 0))
    }
}
