// El postproceso de los detectores en RigCore (IOS-23): réplica de libs/vision/
// postprocess.py (sigmoid, cajas por layout, NMS por clase, picos del heatmap y su
// refinado) congelada en postprocess.json. Bucles de Float, sin vDSP, para no sacar a
// RigCore de Foundation.
//
// Los desempates son los de la referencia, deterministas: a igual score gana el índice
// menor (NMS) y la menor clase, fila y columna (picos). Sin eso los dorados no cuadran.

import Foundation

public enum Postprocess {
    /// Logits → probabilidades, vía tanh como la referencia (no desborda con logits muy
    /// negativos) y en Float, como su `astype(np.float32)`.
    public static func sigmoid(_ x: Float) -> Float {
        Float(0.5) * (Float(1) + tanhf(x * Float(0.5)))
    }

    /// Cajas DETR cxcywh normalizadas → esquinas en píxeles de una región (en Float).
    public static func decodeBoxesToCorners(
        _ boxes: [[Float]], width: Float, height: Float, offsetX: Float = 0, offsetY: Float = 0
    ) -> [(x1: Float, y1: Float, x2: Float, y2: Float)] {
        boxes.map { b in
            let cx = b[0] * width + offsetX
            let cy = b[1] * height + offsetY
            let hw = b[2] * width * 0.5
            let hh = b[3] * height * 0.5
            return (cx - hw, cy - hh, cx + hw, cy + hh)
        }
    }

    /// Cada caja, a la región de su centro, recortada a ella y a nativo (`_corners_to_native`).
    /// Las cuentas en Double y la salida en Float, como la referencia.
    static func cornersToNative(
        _ layout: InputLayout, _ x1: [Double], _ y1: [Double], _ x2: [Double], _ y2: [Double]
    ) -> [(x1: Float, y1: Float, x2: Float, y2: Float)] {
        (0..<x1.count).map { i in
            let r = layout.regions[layout.regionIndex(xInput: (x1[i] + x2[i]) / 2, yInput: (y1[i] + y2[i]) / 2)]
            let left = max(x1[i], Double(r.dstX))
            let top = max(y1[i], Double(r.dstY))
            let right = max(min(x2[i], Double(r.dstX + r.dstW)), left)
            let bottom = max(min(y2[i], Double(r.dstY + r.dstH)), top)
            let a = r.toNative(xInput: left, yInput: top)
            let b = r.toNative(xInput: right, yInput: bottom)
            return (Float(a.x), Float(a.y), Float(b.x), Float(b.y))
        }
    }

    /// Cajas DETR cxcywh normalizadas sobre la entrada → esquinas nativas.
    public static func decodeCxcywhLayout(
        _ boxes: [[Float]], layout: InputLayout, inputW: Int, inputH: Int
    ) -> [(x1: Float, y1: Float, x2: Float, y2: Float)] {
        let w = Double(inputW), h = Double(inputH)
        let cx = boxes.map { Double($0[0]) * w }, cy = boxes.map { Double($0[1]) * h }
        let hw = boxes.map { Double($0[2]) * w * 0.5 }, hh = boxes.map { Double($0[3]) * h * 0.5 }
        return cornersToNative(
            layout,
            zip(cx, hw).map { $0 - $1 }, zip(cy, hh).map { $0 - $1 },
            zip(cx, hw).map { $0 + $1 }, zip(cy, hh).map { $0 + $1 }
        )
    }

    /// Cajas x1,y1,x2,y2 en píxeles de la entrada → nativo (las cabezas CNN).
    public static func decodeXyxyInputPx(
        _ boxes: [[Float]], layout: InputLayout
    ) -> [(x1: Float, y1: Float, x2: Float, y2: Float)] {
        cornersToNative(
            layout, boxes.map { Double($0[0]) }, boxes.map { Double($0[1]) },
            boxes.map { Double($0[2]) }, boxes.map { Double($0[3]) }
        )
    }

    /// NMS por clase con el truco del desplazamiento. Índices, por score descendente.
    public static func nms(
        boxes: [[Float]], scores: [Float], classes: [Int],
        iouThreshold: Double = DetectionSpec.nmsIouThreshold,
        maxDetections: Int,
        preTopk: Int = DetectionSpec.preNmsTopk
    ) -> [Int] {
        let n = scores.count
        guard n > 0, maxDetections > 0, preTopk > 0 else { return [] }
        // Orden por score descendente y el índice como desempate; el prefiltro topk se
        // queda con los preTopk primeros de ese orden.
        let order = Array((0..<n).sorted {
            Double(scores[$0]) != Double(scores[$1]) ? scores[$0] > scores[$1] : $0 < $1
        }.prefix(preTopk))
        var lo = Double.infinity, hi = -Double.infinity
        for i in order { for v in boxes[i] { lo = min(lo, Double(v)); hi = max(hi, Double(v)) } }
        let span = hi - lo + 1
        let sb = order.map { i in boxes[i].map { Double($0) + Double(classes[i]) * span } }
        let area = sb.map { max($0[2] - $0[0], 0) * max($0[3] - $0[1], 0) }

        var kept: [Int] = []
        var alive = Array(0..<order.count)
        while !alive.isEmpty, kept.count < maxDetections {
            let best = alive[0]
            kept.append(best)
            alive = alive.dropFirst().filter { r in
                let iw = min(sb[best][2], sb[r][2]) - max(sb[best][0], sb[r][0])
                let ih = min(sb[best][3], sb[r][3]) - max(sb[best][1], sb[r][1])
                let inter = max(iw, 0) * max(ih, 0)
                let union = area[best] + area[r] - inter
                let iou = union > 0 ? inter / max(union, 1e-12) : 0
                return iou <= iouThreshold
            }
        }
        return kept.map { order[$0] }
    }

    public struct Peak: Equatable, Sendable {
        public let klass: Int
        public let row: Int
        public let col: Int
        public let score: Float
    }

    /// Los `k` mejores máximos locales de un heatmap [C][H][W] (`heatmap_peaks`): máximo
    /// en la ventana kernel×kernel con el borde replicado, sobre el umbral; una meseta da
    /// un solo pico.
    public static func heatmapPeaks(
        _ heatmap: [[[Float]]], k: Int,
        threshold: Double = DetectionSpec.ballHeatmapThreshold,
        kernel: Int = DetectionSpec.heatmapPeakKernel
    ) -> [Peak] {
        guard k > 0, kernel >= 3, kernel % 2 == 1 else { return [] }
        let r = kernel / 2
        var candidatos: [Peak] = []
        for (c, mapa) in heatmap.enumerated() {
            let h = mapa.count
            guard h > 0 else { continue }
            let w = mapa[0].count
            for y in 0..<h {
                for x in 0..<w {
                    let v = mapa[y][x]
                    guard Double(v) > threshold else { continue }
                    var maximo = -Float.infinity
                    for dy in -r...r {
                        for dx in -r...r {
                            let yy = min(max(y + dy, 0), h - 1), xx = min(max(x + dx, 0), w - 1)
                            maximo = max(maximo, mapa[yy][xx])
                        }
                    }
                    if v >= maximo { candidatos.append(Peak(klass: c, row: y, col: x, score: v)) }
                }
            }
        }
        candidatos.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.klass != $1.klass { return $0.klass < $1.klass }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.col < $1.col
        }
        var elegidos: [Peak] = []
        for p in candidatos where elegidos.count < k {
            let meseta = elegidos.contains {
                $0.klass == p.klass && abs($0.row - p.row) < kernel && abs($0.col - p.col) < kernel
            }
            if !meseta { elegidos.append(p) }
        }
        return elegidos
    }

    /// De celda a píxeles de la entrada con el offset subpíxel [2][H][W] (CenterNet).
    public static func refineOffset(
        _ offset: [[[Float]]], rows: [Int], cols: [Int], stride: Int = DetectionSpec.ballHeatmapStride
    ) -> [(x: Double, y: Double)] {
        let paso = Double(stride)
        var salida: [(x: Double, y: Double)] = []
        for (r, c) in zip(rows, cols) {
            let x: Double = (Double(c) + Double(offset[0][r][c])) * paso
            let y: Double = (Double(r) + Double(offset[1][r][c])) * paso
            salida.append((x, y))
        }
        return salida
    }
}

/// El decodificador de jugadores (IOS-23): réplica de PlayerDetector.detect sin el
/// backend, congelada en detectors.json.
public struct PlayerDecoder: Sendable {
    public enum Postprocessing: String, Sendable { case detr, nms }
    public enum BoxFormat: String, Sendable { case cxcywhNorm = "cxcywh_norm", xyxyInputPx = "xyxy_input_px" }

    /// Las clases del modelo en su orden (la ficha), con nil para lo que no se emite.
    public let classes: [PlayerClass?]
    public let confThreshold: Double
    public let maxDetections: Int
    public let postprocess: Postprocessing
    public let boxFormat: BoxFormat
    public let nmsIou: Double?

    public init(
        classNames: [String], confThreshold: Double = DetectionSpec.playerConfThreshold,
        maxDetections: Int = DetectionSpec.playerMaxDetections, postprocess: Postprocessing = .detr,
        boxFormat: BoxFormat = .cxcywhNorm, nmsIou: Double? = nil
    ) throws {
        guard !classNames.isEmpty else {
            throw RigError.message("el decodificador necesita los nombres de clase del modelo")
        }
        guard (postprocess == .nms) == (nmsIou != nil) else {
            throw RigError.message("`nms_iou` es obligatorio con postprocess nms y solo con él")
        }
        // `person` es el jugador del modelo COCO provisional (ADR 0020, ML-16); el resto de
        // COCO se descarta. Igual que `_EMITTED` de la referencia.
        classes = classNames.map { $0 == "person" ? .player : PlayerClass(rawValue: $0) }
        self.confThreshold = confThreshold
        self.maxDetections = maxDetections
        self.postprocess = postprocess
        self.boxFormat = boxFormat
        self.nmsIou = nmsIou
    }

    /// `logits` [Q][C] y `boxes` [Q][4] tal cual salen del modelo; `onPitch` dice si un
    /// píxel nativo (x, y) de los pies está en el campo (nil: sin máscara).
    public func decode(
        logits: [[Float]], boxes: [[Float]], layout: InputLayout,
        onPitch: ((Int, Int) -> Bool)? = nil, pitchSize: (width: Int, height: Int)? = nil
    ) throws -> [PlayerDetection] {
        guard logits.first.map({ $0.count == classes.count }) ?? true else {
            throw RigError.message("el modelo declara \(logits.first!.count) clases y su ficha lista \(classes.count)")
        }
        // Sigmoid, argmax (el primero si empatan) y umbral, sin rescatar la segunda clase.
        var idx: [Int] = [], cls: [Int] = [], sc: [Float] = []
        for (q, fila) in logits.enumerated() {
            let p = fila.map(Postprocess.sigmoid)
            var mejor = 0
            for c in 1..<p.count where p[c] > p[mejor] { mejor = c }
            if Double(p[mejor]) >= confThreshold, classes[mejor] != nil {
                idx.append(q); cls.append(mejor); sc.append(p[mejor])
            }
        }
        guard !idx.isEmpty else { return [] }
        let elegidas = idx.map { boxes[$0] }
        let entrada = (
            w: layout.regions.map { $0.dstX + $0.dstW }.max()!,
            h: layout.regions.map { $0.dstY + $0.dstH }.max()!
        )
        var c = boxFormat == .cxcywhNorm
            ? Postprocess.decodeCxcywhLayout(elegidas, layout: layout, inputW: entrada.w, inputH: entrada.h)
            : Postprocess.decodeXyxyInputPx(elegidas, layout: layout)
        if layout.regions.count > 1 {
            (c, sc, cls) = Self.mergeSeam(layout, c, sc, cls)
        }
        if let onPitch, let tam = pitchSize {
            var keep: [Int] = []
            for (i, b) in c.enumerated() {
                let fx = min(max((b.x1 + b.x2) * 0.5, 0), Float(tam.width - 1))
                let fy = min(max(b.y2, 0), Float(tam.height - 1))
                if onPitch(Int(fx), Int(fy)) { keep.append(i) }
            }
            c = keep.map { c[$0] }; sc = keep.map { sc[$0] }; cls = keep.map { cls[$0] }
        }
        guard !c.isEmpty else { return [] }
        let orden: [Int]
        if postprocess == .nms {
            orden = Postprocess.nms(
                boxes: c.map { [$0.x1, $0.y1, $0.x2, $0.y2] }, scores: sc, classes: cls,
                iouThreshold: nmsIou!, maxDetections: maxDetections
            )
        } else {
            orden = Array((0..<sc.count).sorted { sc[$0] != sc[$1] ? sc[$0] > sc[$1] : $0 < $1 }.prefix(maxDetections))
        }
        return orden.map { i in
            PlayerDetection(
                x1: Double(c[i].x1), y1: Double(c[i].y1), x2: Double(c[i].x2), y2: Double(c[i].y2),
                playerClass: classes[cls[i]]!, score: Double(sc[i])
            )
        }
    }

    /// Las juntas del mosaico en y nativa (`_native_seams`).
    static func seams(_ layout: InputLayout) -> [Double] {
        var juntas: [Double] = []
        for a in layout.regions {
            let fin = a.srcY + a.srcH
            for b in layout.regions where b != a && abs(b.srcY - fin) <= DetectionSpec.playerSeamEpsPx {
                juntas.append(b.srcY)
            }
        }
        return juntas
    }

    /// Une las medias cajas de un jugador partido por la junta (`_merge_seam`): misma
    /// clase, tocando la junta por lados opuestos y con solape horizontal. La unión queda
    /// en la de abajo, con sus pies.
    static func mergeSeam(
        _ layout: InputLayout, _ cajas: [(x1: Float, y1: Float, x2: Float, y2: Float)], _ scores: [Float], _ clases: [Int]
    ) -> ([(x1: Float, y1: Float, x2: Float, y2: Float)], [Float], [Int]) {
        let juntas = seams(layout)
        guard !juntas.isEmpty else { return (cajas, scores, clases) }
        var c = cajas, s = scores
        var vivos = Array(repeating: true, count: c.count)
        let eps = DetectionSpec.playerSeamEpsPx
        for junta in juntas {
            let arriba = c.indices.filter { vivos[$0] && abs(Double(c[$0].y2) - junta) <= eps }
            let abajo = c.indices.filter { vivos[$0] && abs(Double(c[$0].y1) - junta) <= eps }
            for i in arriba where vivos[i] {
                for j in abajo where vivos[j] && clases[i] == clases[j] {
                    let solape = Double(min(c[i].x2, c[j].x2)) - Double(max(c[i].x1, c[j].x1))
                    let menor = min(Double(c[i].x2 - c[i].x1), Double(c[j].x2 - c[j].x1))
                    if menor <= 0 || solape / menor < DetectionSpec.playerSeamMinXOverlap { continue }
                    c[j] = (min(c[i].x1, c[j].x1), min(c[i].y1, c[j].y1), max(c[i].x2, c[j].x2), c[j].y2)
                    s[j] = max(s[i], s[j])
                    vivos[i] = false
                    break
                }
            }
        }
        let quedan = c.indices.filter { vivos[$0] }
        return (quedan.map { c[$0] }, quedan.map { s[$0] }, quedan.map { clases[$0] })
    }
}
