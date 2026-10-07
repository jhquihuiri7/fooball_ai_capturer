// El postproceso de los detectores contra los dorados (IOS-23): postprocess.json pieza a
// pieza y detectors.json de punta a punta (PlayerDetector.detect con salidas fijas).

import Foundation
import RigCore
import XCTest

final class PostprocessTests: XCTestCase {
    static func t(_ v: GoldenValue, _ k: String) throws -> GoldenTensor {
        guard case let .tensor(x) = try v.field(k) else { throw GoldenError.message("\(k) no es un tensor") }
        return x
    }

    static func f32(_ v: GoldenValue, _ k: String) throws -> [Float] { try Self.t(v, k).doubles().map(Float.init) }

    static func filas(_ v: GoldenValue, _ k: String) throws -> [[Float]] {
        let x = try Self.t(v, k)
        let ancho = x.shape.count > 1 ? x.shape[1] : 1
        let d = try x.doubles().map(Float.init)
        return x.shape[0] == 0 ? [] : stride(from: 0, to: d.count, by: ancho).map { Array(d[$0..<($0 + ancho)]) }
    }

    /// Un tensor [1][C][H][W] (o [C][H][W]) como [C][H][W]: el lote, si lo hay, es 1.
    static func mapa(_ v: GoldenValue, _ k: String) throws -> [[[Float]]] {
        let x = try Self.t(v, k)
        let forma = Array(x.shape.suffix(3))
        let d = try x.doubles().map(Float.init)
        let (cc, hh, ww) = (forma[0], forma[1], forma[2])
        return (0..<cc).map { c in (0..<hh).map { y in Array(d[((c * hh + y) * ww)..<((c * hh + y) * ww + ww)]) } }
    }

    /// Una lista de cadenas del caso (los nombres de clase).
    static func strings(_ v: GoldenValue, _ k: String) throws -> [String] {
        guard case let .array(xs) = try v.field(k) else { throw GoldenError.message("\(k) no es una lista") }
        return xs.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
    }

    private func esquinas(_ c: [(x1: Float, y1: Float, x2: Float, y2: Float)]) -> GoldenValue {
        .object([
            "x1": .tensor(f32: c.map(\.x1), shape: [c.count]), "y1": .tensor(f32: c.map(\.y1), shape: [c.count]),
            "x2": .tensor(f32: c.map(\.x2), shape: [c.count]), "y2": .tensor(f32: c.map(\.y2), shape: [c.count]),
        ])
    }

    func testPostprocessPiezaAPieza() throws {
        let doc = try Golden.loadDocument(named: "postprocess.json")
        var corridos: [String: Int] = [:]
        for caso in doc.cases {
            let i = caso.inputs
            let actual: GoldenValue
            switch caso.fn {
            case "sigmoid":
                let x = try Self.t(i, "x")
                actual = .object(["scores": .tensor(f32: try Self.f32(i, "x").map(Postprocess.sigmoid), shape: x.shape)])
            case "decode_boxes_to_corners":
                func num(_ k: String) -> Float { Float((try? i.number(k)) ?? 0) }
                actual = esquinas(Postprocess.decodeBoxesToCorners(
                    try Self.filas(i, "boxes"), width: num("width"), height: num("height"),
                    offsetX: num("offset_x"), offsetY: num("offset_y")
                ))
            case "decode_cxcywh_layout":
                actual = esquinas(Postprocess.decodeCxcywhLayout(
                    try Self.filas(i, "boxes"), layout: try BandGeometryTests.layout(i.field("layout")),
                    inputW: Int(try i.number("input_w")), inputH: Int(try i.number("input_h"))
                ))
            case "decode_xyxy_input_px":
                actual = esquinas(Postprocess.decodeXyxyInputPx(
                    try Self.filas(i, "boxes"), layout: try BandGeometryTests.layout(i.field("layout"))
                ))
            case "nms":
                let keep = Postprocess.nms(
                    boxes: try Self.filas(i, "boxes"), scores: try Self.f32(i, "scores"),
                    classes: try Self.t(i, "classes").doubles().map { Int($0) },
                    iouThreshold: try i.number("iou_threshold"), maxDetections: Int(try i.number("max_detections")),
                    preTopk: Int(try i.number("pre_topk"))
                )
                actual = .object(["keep": .tensor(i32: keep.map(Int32.init), shape: [keep.count])])
            case "heatmap_peaks":
                let h = try Self.t(i, "heatmap")
                let d = try h.doubles().map(Float.init)
                let (cc, hh, ww) = (h.shape[0], h.shape[1], h.shape[2])
                let mapa = (0..<cc).map { c in (0..<hh).map { y in Array(d[((c * hh + y) * ww)..<((c * hh + y) * ww + ww)]) } }
                let p = Postprocess.heatmapPeaks(
                    mapa, k: Int(try i.number("k")), threshold: try i.number("threshold"), kernel: Int(try i.number("kernel"))
                )
                actual = .object([
                    "klass": .tensor(i32: p.map { Int32($0.klass) }, shape: [p.count]),
                    "row": .tensor(i32: p.map { Int32($0.row) }, shape: [p.count]),
                    "col": .tensor(i32: p.map { Int32($0.col) }, shape: [p.count]),
                    "score": .tensor(f32: p.map(\.score), shape: [p.count]),
                ])
            case "refine_offset":
                let o = try Self.t(i, "offset")
                let d = try o.doubles().map(Float.init)
                let (hh, ww) = (o.shape[1], o.shape[2])
                let off = (0..<2).map { c in (0..<hh).map { y in Array(d[((c * hh + y) * ww)..<((c * hh + y) * ww + ww)]) } }
                let r = Postprocess.refineOffset(
                    off, rows: try Self.t(i, "rows").doubles().map { Int($0) }, cols: try Self.t(i, "cols").doubles().map { Int($0) },
                    stride: Int(try i.number("stride"))
                )
                actual = .object([
                    "x_px": .tensor(f64: r.map(\.x), shape: [r.count]), "y_px": .tensor(f64: r.map(\.y), shape: [r.count]),
                ])
            default:
                continue
            }
            corridos[caso.fn, default: 0] += 1
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertEqual(corridos.count, 7, "\(corridos)")
    }

    func testElDetectorDePuntaAPunta() throws {
        let doc = try Golden.loadDocument(named: "detectors.json")
        var corridos = 0, heatmaps = 0
        for caso in doc.cases where caso.fn == "PlayerDetector.detect" {
            corridos += 1
            let i = caso.inputs
            let iou = try? i.number("nms_iou")
            let paso = (try? i.number("heatmap_stride")).map { Int($0) }
            let dec = try PlayerDecoder(
                classNames: try Self.strings(i, "classes"),
                confThreshold: (try? i.number("conf_threshold")) ?? DetectionSpec.playerConfThreshold,
                maxDetections: (try? i.number("max_detections")).map { Int($0) } ?? DetectionSpec.playerMaxDetections,
                postprocess: paso != nil ? .heatmap : iou == nil ? .detr : .nms,
                boxFormat: PlayerDecoder.BoxFormat(rawValue: try i.string("box_format"))!,
                nmsIou: iou, heatmapStride: paso
            )
            let mascara = try Self.rectMask(i)
            let layout = try BandGeometryTests.layout(i.field("layout"))
            let dets: [PlayerDetection]
            if paso != nil {
                heatmaps += 1
                dets = try dec.decodeHeatmap(
                    heatmap: try Self.mapa(i, "heatmap"), offset: try Self.mapa(i, "offset"), size: try Self.mapa(i, "size"),
                    layout: layout, footMask: mascara
                )
            } else {
                dets = try dec.decode(
                    logits: try Self.filas(i, "logits"), boxes: try Self.filas(i, "boxes"),
                    layout: layout, footMask: mascara
                )
            }
            let actual: GoldenValue = .object([
                "boxes": .tensor(f64: dets.flatMap { [$0.x1, $0.y1, $0.x2, $0.y2] }, shape: [dets.count, 4]),
                "classes": .array(dets.map { .string($0.playerClass.rawValue) }),
                "scores": .tensor(f64: dets.map(\.score), shape: [dets.count]),
            ])
            if let fallo = Golden.mismatch(actual: actual, expected: caso.expected, tol: caso.tol, path: caso.name) {
                XCTFail(fallo)
            }
        }
        XCTAssertGreaterThanOrEqual(corridos, 15)
        XCTAssertGreaterThanOrEqual(heatmaps, 3, "los casos del plan B CenterNet (ADR 0020)")
    }

    /// La `pitch_mask` de un caso de detectors.json: un rectángulo `inside` [x0, y0, x1, y1)
    /// dentro de un fotograma `width`×`height`. nil si el caso no la lleva.
    static func rectMask(_ i: GoldenValue) throws -> FootMask? {
        guard case let .object(m)? = try? i.field("pitch_mask"), case let .array(dentro)? = m["inside"] else {
            return nil
        }
        let r = dentro.compactMap(\.numberValue).map { Int($0) }
        return try FootMask(width: Int(m["width"]!.numberValue!), height: Int(m["height"]!.numberValue!)) { x, y in
            x >= r[0] && x < r[2] && y >= r[1] && y < r[3]
        }
    }

    func testElHeatmapExigeSuPasoYSuFormato() {
        let nombres = ["goalkeeper", "player", "referee"]
        XCTAssertThrowsError(try PlayerDecoder(classNames: nombres, postprocess: .heatmap, boxFormat: .heatmapStride))
        XCTAssertThrowsError(try PlayerDecoder(
            classNames: nombres, postprocess: .heatmap, boxFormat: .heatmapStride, heatmapStride: 0
        ))
        XCTAssertThrowsError(try PlayerDecoder(classNames: nombres, postprocess: .heatmap, heatmapStride: 4))
        XCTAssertThrowsError(try PlayerDecoder(classNames: nombres, boxFormat: .heatmapStride))
        XCTAssertThrowsError(try PlayerDecoder(classNames: nombres, heatmapStride: 4))
        XCTAssertNoThrow(try PlayerDecoder(
            classNames: nombres, postprocess: .heatmap, boxFormat: .heatmapStride, heatmapStride: 4
        ))
    }

    func testTrescientasQueriesSonBaratas() throws {
        // 300 queries vacías y 20 jugadores: la cuenta de la aceptación (<0,2 ms en el
        // iPhone) la da `decoder-bench`; aquí, que no crece con nada raro.
        var logits = Array(repeating: [Float(-9), -9, -9], count: 300)
        var cajas = Array(repeating: [Float(0.5), 0.5, 0.01, 0.02], count: 300)
        for q in 0..<20 { logits[q][1] = 3; cajas[q] = [Float(q) / 20 + 0.02, 0.5, 0.01, 0.05] }
        let dec = try PlayerDecoder(classNames: ["goalkeeper", "player", "referee"])
        let layout = try InputLayout(regions: [try InputRegion(
            dstX: 0, dstY: 0, dstW: 1920, dstH: 576, srcX: 0, srcY: 400, srcW: 3840, srcH: 1152
        )])
        let inicio = Date()
        for _ in 0..<100 { _ = try dec.decode(logits: logits, boxes: cajas, layout: layout) }
        XCTAssertEqual(try dec.decode(logits: logits, boxes: cajas, layout: layout).count, 20)
        XCTAssertLessThan(Date().timeIntervalSince(inicio) / 100, 0.01, "menos de 10 ms por pasada en depuración")
    }
}
