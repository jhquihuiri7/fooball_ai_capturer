// La fase entre las cámaras de los dos móviles, minuto a minuto (SPK-04, 2026-10-14),
// lógica pura.
//
// El ADR 0012 sortea la fase de exposición al arrancar (TASK A4) y supone que luego se
// queda: «un desfase constante dentro del intervalo de frame». En el ensayo de 90 min
// del 2026-10-14 no se quedó: la captura del maestro menos la de la parte fue de −1 ms
// en el minuto 0 a +16 en el 21 (+0,8 ms/min, ~13 ppm entre los dos sensores). Al pasar
// de medio fotograma el maestro ya no tiene un fotograma propio a ≤½ fotograma de la
// parte, y los 471 desgarros del ensayo son ese cruce (minutos 21-22). Esto lo mide en
// cualquier pasada, también en EMITIR, sin el fichero de vistas: la mediana con signo de
// cada minuto, los desgarros de cada minuto, la deriva y cuánto falta para el cruce.

import Foundation

public final class HalvesPhaseTracker {
    public struct Bucket: Equatable, Sendable {
        /// El minuto (o el cubo) desde el arranque.
        public let index: Int
        /// La mediana de captura del maestro − captura de la parte, en ms, con signo.
        public let medianMs: Double
        public let frames: Int
        public let torn: Int

        public init(index: Int, medianMs: Double, frames: Int, torn: Int) {
            self.index = index
            self.medianMs = medianMs
            self.frames = frames
            self.torn = torn
        }
    }

    private let startRigMs: Int64
    private let frameDurationMs: Double
    private let bucketMs: Int64
    private let maxBuckets: Int
    private var closed: [Bucket] = []
    private var currentIndex: Int?
    private var currentSkews: [Double] = []
    private var currentTorn = 0

    /// `bucketMs`: un minuto por defecto. `maxBuckets`: lo que se guarda como mucho (los
    /// más viejos salen); 600 son 10 h a un cubo por minuto.
    public init(startRigMs: Int64, frameDurationMs: Double, bucketMs: Int64 = HalvesPhaseTracker.minuteMs,
                maxBuckets: Int = HalvesPhaseTracker.defaultMaxBuckets) {
        precondition(bucketMs > 0 && maxBuckets > 0, "hacen falta cubos")
        self.startRigMs = startRigMs
        self.frameDurationMs = frameDurationMs
        self.bucketMs = bucketMs
        self.maxBuckets = maxBuckets
        currentSkews.reserveCapacity(Int(Double(bucketMs) / frameDurationMs) + 1)
    }

    /// Un fotograma de dos lentes: el instante del programa, la captura del maestro menos
    /// la de la parte (ms) y si TearCheck lo dio por desgarrado.
    public func record(atRigMs: Int64, skewMs: Double, torn: Bool) {
        let i = Int(max(0, atRigMs - startRigMs) / bucketMs)
        if let actual = currentIndex, i != actual { close() }
        currentIndex = i
        currentSkews.append(skewMs)
        if torn { currentTorn += 1 }
    }

    /// Los cubos con fotogramas de dos lentes, de más viejo a más nuevo (el abierto, el
    /// último).
    public var buckets: [Bucket] {
        guard let i = currentIndex, !currentSkews.isEmpty else { return closed }
        return closed + [Self.bucket(index: i, skews: currentSkews, torn: currentTorn)]
    }

    /// La deriva de la fase en ms por minuto: la recta de las medianas desenrolladas (la
    /// fase vive en ±½ fotograma: al cruzar, salta un fotograma entero, que se deshace).
    /// Solo con cubos de al menos `minFrames`; nil con menos de dos.
    public func driftMsPerMinute(minFrames: Int = HalvesPhaseTracker.minFramesForDrift) -> Double? {
        let usados = buckets.filter { $0.frames >= minFrames }
        guard usados.count >= 2 else { return nil }
        var desenrollada: [Double] = []
        for b in usados {
            guard let previa = desenrollada.last else {
                desenrollada.append(b.medianMs)
                continue
            }
            var v = b.medianMs
            while v - previa > frameDurationMs / 2 { v -= frameDurationMs }
            while previa - v > frameDurationMs / 2 { v += frameDurationMs }
            desenrollada.append(v)
        }
        let minutos = usados.map { Double($0.index) * Double(bucketMs) / Double(Self.minuteMs) }
        let n = Double(usados.count)
        let mx = minutos.reduce(0, +) / n, my = desenrollada.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(minutos, desenrollada) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Los minutos que faltan, a la deriva medida, para que la última fase llegue a ±½
    /// fotograma: el cruce donde salen los desgarros. nil sin deriva medible.
    public func minutesToHalfFrame(minFrames: Int = HalvesPhaseTracker.minFramesForDrift) -> Double? {
        guard let deriva = driftMsPerMinute(minFrames: minFrames), deriva != 0,
              let ultima = buckets.last(where: { $0.frames >= minFrames })
        else { return nil }
        let medio = frameDurationMs / 2
        return deriva > 0 ? (medio - ultima.medianMs) / deriva : (ultima.medianMs + medio) / -deriva
    }

    private func close() {
        guard let i = currentIndex, !currentSkews.isEmpty else { return }
        closed.append(Self.bucket(index: i, skews: currentSkews, torn: currentTorn))
        if closed.count > maxBuckets { closed.removeFirst(closed.count - maxBuckets) }
        currentSkews.removeAll(keepingCapacity: true)
        currentTorn = 0
    }

    private static func bucket(index: Int, skews: [Double], torn: Int) -> Bucket {
        let o = skews.sorted()
        return Bucket(index: index, medianMs: o[o.count / 2], frames: o.count, torn: torn)
    }

    public static let minuteMs: Int64 = 60_000
    public static let defaultMaxBuckets = 600
    /// Un cubo con menos fotogramas de dos lentes (≈1 s a 30 fps) no entra en la deriva:
    /// su mediana es ruido.
    public static let minFramesForDrift = 30
}
