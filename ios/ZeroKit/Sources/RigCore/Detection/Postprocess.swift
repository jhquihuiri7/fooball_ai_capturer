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

    /// Un umbral de la referencia tal como lo compara numpy contra un tensor float32: el
    /// `float` de Python es un escalar débil (NEP 50) y se redondea a float32 antes de
    /// comparar. Compararlo en Double no es lo mismo justo en el umbral: un score igual a
    /// `Float(0.3)` (0,30000001) no pasa `> 0.3` en numpy y en Double sí.
    static func float32Threshold(_ t: Double) -> Float { Float(t) }

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

        public init(klass: Int, row: Int, col: Int, score: Float) {
            self.klass = klass
            self.row = row
            self.col = col
            self.score = score
        }
    }

    /// Los `k` mejores máximos locales de un heatmap [C][H][W] (`heatmap_peaks`): máximo
    /// en la ventana kernel×kernel con el borde replicado, sobre el umbral; una meseta da
    /// un solo pico.
    ///
    /// Corre en cada ciclo del detector, así que ahorra lo que no cambia el resultado
    /// (HeatmapPeaksTests lo compara con la versión directa en mapas al azar):
    /// - el borde replicado solo repite celdas que ya están en la ventana, así que basta
    ///   recortarla al mapa, y una celda deja de ser candidata con el primer vecino mayor;
    /// - cada pico elegido descarta por la meseta como mucho (2·kernel − 1)² − 1 vecinos
    ///   de su clase, así que los `k` picos salen siempre de los k·(2·kernel − 1)²
    ///   mejores candidatos: solo esos se ordenan.
    public static func heatmapPeaks(
        _ heatmap: [[[Float]]], k: Int,
        threshold: Double = DetectionSpec.ballHeatmapThreshold,
        kernel: Int = DetectionSpec.heatmapPeakKernel
    ) -> [Peak] {
        guard k > 0, kernel >= 3, kernel % 2 == 1 else { return [] }
        let r = kernel / 2
        let umbral = float32Threshold(threshold)
        var candidatos: [Peak] = []
        for (c, mapa) in heatmap.enumerated() {
            let h = mapa.count
            guard h > 0 else { continue }
            let w = mapa[0].count
            for y in 0..<h {
                let fila = mapa[y]
                let filas = max(y - r, 0)...min(y + r, h - 1)
                for x in 0..<w {
                    let v = fila[x]
                    guard v > umbral else { continue }
                    // Primero la propia fila, que ya está a mano y descarta casi todo.
                    let columnas = max(x - r, 0)...min(x + r, w - 1)
                    guard !columnas.contains(where: { fila[$0] > v }),
                          !filas.contains(where: { yy in yy != y && columnas.contains { mapa[yy][$0] > v } })
                    else { continue }
                    candidatos.append(Peak(klass: c, row: y, col: x, score: v))
                }
            }
        }
        let lado = 2 * kernel - 1
        let (tope, desborda) = k.multipliedReportingOverflow(by: lado * lado)
        let ordenados = desborda ? candidatos.sorted(by: precede) : mejores(candidatos, tope)
        var elegidos: [Peak] = []
        for p in ordenados {
            let meseta = elegidos.contains {
                $0.klass == p.klass && abs($0.row - p.row) < kernel && abs($0.col - p.col) < kernel
            }
            if !meseta {
                elegidos.append(p)
                if elegidos.count == k { break }
            }
        }
        return elegidos
    }

    /// El orden de los picos: score descendente y, a igualdad, la menor clase, fila y
    /// columna, como la referencia.
    private static func precede(_ a: Peak, _ b: Peak) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.klass != b.klass { return a.klass < b.klass }
        if a.row != b.row { return a.row < b.row }
        return a.col < b.col
    }

    /// Los `m` primeros de `todos` en el orden de `precede`, ya ordenados, sin ordenar el
    /// resto: un montículo de los `m` mejores (la raíz, el peor de ellos).
    private static func mejores(_ todos: [Peak], _ m: Int) -> [Peak] {
        guard todos.count > m else { return todos.sorted(by: precede) }
        var monticulo = Array(todos.prefix(m))
        // Montículo en el que cada padre va DETRÁS de sus hijos en el orden de `precede`.
        func hundir(_ desde: Int) {
            var i = desde
            while true {
                let (a, b) = (2 * i + 1, 2 * i + 2)
                var peor = i
                if a < m, precede(monticulo[peor], monticulo[a]) { peor = a }
                if b < m, precede(monticulo[peor], monticulo[b]) { peor = b }
                if peor == i { return }
                monticulo.swapAt(i, peor)
                i = peor
            }
        }
        for i in stride(from: m / 2 - 1, through: 0, by: -1) { hundir(i) }
        for p in todos[m...] where precede(p, monticulo[0]) {
            monticulo[0] = p
            hundir(0)
        }
        return monticulo.sorted(by: precede)
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
/// backend, congelada en detectors.json. Tres caminos, como la referencia: `detr`
/// (logits y cajas), `nms` (lo mismo y NMS por clase) y `heatmap` (CenterNet-MNv4, el
/// plan B medido del ADR 0020: picos del mapa, offset y tamaño a `heatmapStride`).
public struct PlayerDecoder: Sendable {
    public enum Postprocessing: String, Sendable { case detr, nms, heatmap }
    public enum BoxFormat: String, Sendable {
        case cxcywhNorm = "cxcywh_norm", xyxyInputPx = "xyxy_input_px", heatmapStride = "heatmap_stride"
    }

    /// Las clases del modelo en su orden (la ficha), con nil para lo que no se emite.
    public let classes: [PlayerClass?]
    public let confThreshold: Double
    public let maxDetections: Int
    public let postprocess: Postprocessing
    public let boxFormat: BoxFormat
    public let nmsIou: Double?
    /// Celdas → píxeles de la entrada del camino heatmap (la ficha); nil en los demás.
    public let heatmapStride: Int?

    public init(
        classNames: [String], confThreshold: Double = DetectionSpec.playerConfThreshold,
        maxDetections: Int = DetectionSpec.playerMaxDetections, postprocess: Postprocessing = .detr,
        boxFormat: BoxFormat = .cxcywhNorm, nmsIou: Double? = nil, heatmapStride: Int? = nil
    ) throws {
        guard !classNames.isEmpty else {
            throw RigError.message("el decodificador necesita los nombres de clase del modelo")
        }
        guard (postprocess == .nms) == (nmsIou != nil) else {
            throw RigError.message("`nms_iou` es obligatorio con postprocess nms y solo con él")
        }
        guard (postprocess == .heatmap) == (boxFormat == .heatmapStride) else {
            throw RigError.message("box_format `heatmap_stride` va con postprocess heatmap y solo con él")
        }
        guard (postprocess == .heatmap) == (heatmapStride != nil) else {
            throw RigError.message("`heatmap_stride` es obligatorio con postprocess heatmap y solo con él")
        }
        if let heatmapStride, heatmapStride <= 0 {
            throw RigError.message("`heatmap_stride` tiene que ser un entero positivo y es \(heatmapStride)")
        }
        // `person` es el jugador del modelo COCO provisional (ADR 0020, ML-16); el resto de
        // COCO se descarta. Igual que `_EMITTED` de la referencia.
        classes = classNames.map { $0 == "person" ? .player : PlayerClass(rawValue: $0) }
        self.confThreshold = confThreshold
        self.maxDetections = maxDetections
        self.postprocess = postprocess
        self.boxFormat = boxFormat
        self.nmsIou = nmsIou
        self.heatmapStride = heatmapStride
    }

    /// `logits` [Q][C] y `boxes` [Q][4] tal cual salen del modelo; `onPitch` dice si un
    /// píxel nativo (x, y) de los pies está en el campo (nil: sin máscara).
    public func decode(
        logits: [[Float]], boxes: [[Float]], layout: InputLayout,
        onPitch: ((Int, Int) -> Bool)? = nil, pitchSize: (width: Int, height: Int)? = nil
    ) throws -> [PlayerDetection] {
        guard postprocess != .heatmap else {
            throw RigError.message("postprocess heatmap: las salidas van por decodeHeatmap")
        }
        guard logits.first.map({ $0.count == classes.count }) ?? true else {
            throw RigError.message("el modelo declara \(logits.first!.count) clases y su ficha lista \(classes.count)")
        }
        // Sigmoid, argmax (el primero si empatan) y umbral en float32, sin rescatar la
        // segunda clase.
        let umbral = Postprocess.float32Threshold(confThreshold)
        var idx: [Int] = [], cls: [Int] = [], sc: [Float] = []
        for (q, fila) in logits.enumerated() {
            let p = fila.map(Postprocess.sigmoid)
            var mejor = 0
            for c in 1..<p.count where p[c] > p[mejor] { mejor = c }
            if p[mejor] >= umbral, classes[mejor] != nil {
                idx.append(q); cls.append(mejor); sc.append(p[mejor])
            }
        }
        guard !idx.isEmpty else { return [] }
        let elegidas = idx.map { boxes[$0] }
        let entrada = (
            w: layout.regions.map { $0.dstX + $0.dstW }.max()!,
            h: layout.regions.map { $0.dstY + $0.dstH }.max()!
        )
        let c = boxFormat == .cxcywhNorm
            ? Postprocess.decodeCxcywhLayout(elegidas, layout: layout, inputW: entrada.w, inputH: entrada.h)
            : Postprocess.decodeXyxyInputPx(elegidas, layout: layout)
        return finish(c, sc, cls, layout: layout, onPitch: onPitch, pitchSize: pitchSize)
    }

    /// El camino CenterNet (`_detect_heatmap`): `heatmap` [C][H][W] ya activado por clase,
    /// `offset` [2][H][W] con dx, dy en fracciones de celda y `size` [2][H][W] con ancho y
    /// alto en celdas (el lote ya quitado). Los `maxDetections` mejores picos sobre el
    /// umbral (estricto, la regla de los picos) y después fuera las clases que no se
    /// emiten; las cajas, a float en píxeles de la entrada como una cabeza xyxy_input_px.
    public func decodeHeatmap(
        heatmap: [[[Float]]], offset: [[[Float]]], size: [[[Float]]], layout: InputLayout,
        onPitch: ((Int, Int) -> Bool)? = nil, pitchSize: (width: Int, height: Int)? = nil
    ) throws -> [PlayerDetection] {
        guard postprocess == .heatmap, let paso = heatmapStride else {
            throw RigError.message("decodeHeatmap pide postprocess heatmap")
        }
        guard heatmap.count == classes.count else {
            throw RigError.message("el heatmap trae \(heatmap.count) clases en sus canales y la ficha lista \(classes.count)")
        }
        let picos = Postprocess.heatmapPeaks(heatmap, k: maxDetections, threshold: confThreshold)
            .filter { classes[$0.klass] != nil }
        guard !picos.isEmpty else { return [] }
        let centros = Postprocess.refineOffset(offset, rows: picos.map(\.row), cols: picos.map(\.col), stride: paso)
        let cajas: [[Float]] = zip(picos, centros).map { p, ctr in
            let hw = Double(size[0][p.row][p.col]) * Double(paso) * 0.5
            let hh = Double(size[1][p.row][p.col]) * Double(paso) * 0.5
            return [Float(ctr.x - hw), Float(ctr.y - hh), Float(ctr.x + hw), Float(ctr.y + hh)]
        }
        return finish(
            Postprocess.decodeXyxyInputPx(cajas, layout: layout), picos.map(\.score), picos.map(\.klass),
            layout: layout, onPitch: onPitch, pitchSize: pitchSize
        )
    }

    /// Lo común a los tres caminos, ya en nativo (`_finish`): la junta del mosaico, la
    /// máscara por los pies y el orden (o la NMS) con el tope.
    private func finish(
        _ cajas: [(x1: Float, y1: Float, x2: Float, y2: Float)], _ scores: [Float], _ clases: [Int],
        layout: InputLayout, onPitch: ((Int, Int) -> Bool)?, pitchSize: (width: Int, height: Int)?
    ) -> [PlayerDetection] {
        var c = cajas, sc = scores, cls = clases
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
        let eps = Postprocess.float32Threshold(DetectionSpec.playerSeamEpsPx)
        for junta in juntas.map(Float.init) {
            // En float32 como la referencia: `y2 - junta` con la junta de escalar débil.
            let arriba = c.indices.filter { vivos[$0] && abs(c[$0].y2 - junta) <= eps }
            let abajo = c.indices.filter { vivos[$0] && abs(c[$0].y1 - junta) <= eps }
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
