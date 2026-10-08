// El banco del decodificador de jugadores (IOS-23): lo que cuesta pasar las salidas del
// modelo a cajas nativas en el iPhone, sin el modelo. La aceptación pide 300 queries en
// <0,2 ms; se mide también el camino heatmap del plan B (ADR 0020), que es el que corre
// hoy, con un mapa de partido y con uno saturado como el de los pesos sembrados.
//
// Las salidas se generan ANTES de medir y con una semilla fija: se mide solo
// PlayerDecoder, no la generación ni la copia desde MLMultiArray (`planes`, que va
// aparte en CoreMLPlayerDetector). Las muestras se guardan en crudo, como en
// director-bench: los cubos del histograma son gruesos por debajo del milisegundo.

import Foundation
import RigCore

enum DecoderBench {
    /// Las salidas de D-FINE-N (ADR 0020): 300 queries y 3 clases.
    static let queries = 300
    static let classes = ["goalkeeper", "player", "referee"]
    /// Lo que se ve en una cámara: 22 jugadores, 2 porteros y 1 árbitro.
    static let people = 25
    /// El paso del CenterNet-MNv4 del plan B, como DetectLoad del Runner.
    static let heatmapStride = 4
    static let defaultCalls = 2000
    /// La cámara de la que sale la franja: 4K apaisado, en píxeles.
    static let cameraWidth = 3840.0
    static let cameraHeight = 2160.0

    static func run(report: inout BenchReport, progress: BenchRunner.Progress?) throws {
        let llamadas = Int(report.params["calls"] ?? "") ?? defaultCalls
        let layout = try bandLayout()
        let detr = try PlayerDecoder(classNames: classes)
        let heat = try PlayerDecoder(
            classNames: classes, postprocess: .heatmap, boxFormat: .heatmapStride, heatmapStride: heatmapStride
        )
        let (logits, cajas) = detrOutputs()
        let partido = heatmapOutputs(saturated: false)
        let saturado = heatmapOutputs(saturated: true)

        var muestras = [Double](repeating: 0, count: llamadas)
        func medir(_ etapa: String, _ paso: Double, _ cuerpo: () throws -> Int) rethrows {
            var cajasPorLlamada = 0
            for i in 0..<llamadas {
                let t0 = DispatchTime.now().uptimeNanoseconds
                cajasPorLlamada = try cuerpo()
                muestras[i] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
            report.stagesMs[etapa] = DirectorBench.summary(muestras)
            report.counters["\(etapa)/detections"] = cajasPorLlamada
            progress?(paso, etapa)
        }
        try medir("decoder/detr300", 1 / 3) {
            try detr.decode(logits: logits, boxes: cajas, layout: layout).count
        }
        try medir("decoder/heatmap", 2 / 3) {
            try heat.decodeHeatmap(heatmap: partido.heatmap, offset: partido.offset, size: partido.size, layout: layout).count
        }
        try medir("decoder/heatmap_saturated", 1) {
            try heat.decodeHeatmap(heatmap: saturado.heatmap, offset: saturado.offset, size: saturado.size, layout: layout).count
        }
        report.counters["calls"] = llamadas
        report.params["calls"] = "\(llamadas)"
    }

    /// La franja de una cámara 4K a ×0,5: 1152 filas nativas en la entrada de 1920×576.
    static func bandLayout() throws -> InputLayout {
        let (w, h) = (DetectionSpec.playerInputWidth, DetectionSpec.playerInputHeight)
        let filas = Double(h) / DetectionSpec.playerBandScale
        return try InputLayout(regions: [InputRegion(
            dstX: 0, dstY: 0, dstW: w, dstH: h,
            srcX: 0, srcY: (cameraHeight - filas) / 2, srcW: cameraWidth, srcH: filas
        )])
    }

    /// Un generador fijo (SplitMix64) en [0, 1): mismas salidas en cada pasada.
    struct Semilla {
        var estado: UInt64
        mutating func next() -> Float {
            estado &+= 0x9E37_79B9_7F4A_7C15
            var z = estado
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
    }

    /// 300 queries: `people` sobre el umbral y el resto, fondo.
    static func detrOutputs() -> (logits: [[Float]], boxes: [[Float]]) {
        var s = Semilla(estado: 23)
        var logits: [[Float]] = [], cajas: [[Float]] = []
        for q in 0..<queries {
            var fila = (0..<classes.count).map { _ in -6 + 2 * s.next() }
            if q < people { fila[q < 2 ? 0 : (q == 2 ? 2 : 1)] = 0.5 + 3 * s.next() }
            logits.append(fila)
            cajas.append([s.next(), 0.2 + 0.6 * s.next(), 0.004 + 0.004 * s.next(), 0.05 + 0.1 * s.next()])
        }
        return (logits, cajas)
    }

    /// Las tres salidas de CenterNet [C][H][W] a la franja: un pico gaussiano por persona
    /// sobre fondo bajo, o (saturado) ruido uniforme, que pasa el umbral en casi todo el mapa.
    static func heatmapOutputs(saturated: Bool) -> (heatmap: [[[Float]]], offset: [[[Float]]], size: [[[Float]]]) {
        let (alto, ancho) = (DetectionSpec.playerInputHeight / heatmapStride, DetectionSpec.playerInputWidth / heatmapStride)
        var s = Semilla(estado: saturated ? 7 : 11)
        var mapa = (0..<classes.count).map { _ in (0..<alto).map { _ in (0..<ancho).map { _ in Float(0) } } }
        for c in 0..<classes.count {
            for y in 0..<alto {
                for x in 0..<ancho { mapa[c][y][x] = saturated ? s.next() : 0.05 * s.next() }
            }
        }
        if !saturated {
            for p in 0..<people {
                let c = p < 2 ? 0 : (p == 2 ? 2 : 1)
                let (cy, cx, pico) = (2 + s.next() * Float(alto - 4), 2 + s.next() * Float(ancho - 4), 0.4 + 0.5 * s.next())
                for y in max(0, Int(cy) - 3)...min(alto - 1, Int(cy) + 3) {
                    for x in max(0, Int(cx) - 3)...min(ancho - 1, Int(cx) + 3) {
                        let d2 = (Float(y) - cy) * (Float(y) - cy) + (Float(x) - cx) * (Float(x) - cx)
                        mapa[c][y][x] = max(mapa[c][y][x], pico * expf(-d2 / 3))
                    }
                }
            }
        }
        let plano = { (base: Float, rango: Float) in
            (0..<2).map { _ in (0..<alto).map { _ in (0..<ancho).map { _ in base + rango * s.next() } } }
        }
        return (mapa, plano(0, 1), plano(2, 10))
    }
}
