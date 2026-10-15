// El spike de la duración de fotograma (2026-10-15), lógica pura. Solo para bancos.
//
// La fase entre las capturas de los dos iPhone deriva ~0,8 ms/min (~13 ppm entre los dos
// sensores) y cruza ½ fotograma cada ~42 min: ahí el maestro desgarra (ensayo de 90 min
// del 2026-10-14, 467 fotogramas en un minuto). El arreglo que propone el ADR 0024 de
// football-ai mantiene la fase alargando un ~0,1 % la duración de fotograma del móvil que
// va adelantado durante unos segundos (a 30 fps el formato solo deja alargar). Antes hay
// que saber en el iPhone si el sensor cumple duraciones así de finas, cuánto tarda en
// aplicarlas y si rompe algo. Esto es lo que se puede probar sin cámara:
//
// - `FrameDuration`: una duración exacta, valor/escala como un CMTime (RigCore no ve
//   CoreMedia), y su lectura del entorno.
// - `FrameDurationSpikePlan`: qué duración, a qué lado y cuándo (RIG_SPIKE_FRAME_*). Las
//   ventanas van sobre la rejilla del reloj del soporte, como el guion de SPK-04: los dos
//   móviles las ven en los mismos instantes y el maestro sabe cuándo se alargó el otro.
// - `FrameCadenceTracker`: lo que da la cámara de verdad, en cubos de 10 s de esa rejilla.
// - `FrameDurationEffect`: cuánto tarda en notarse un cambio pedido.
//
// Sin RIG_SPIKE_FRAME_US en el entorno no se arma nada.

import Foundation

/// Una duración de fotograma exacta: `value / timescale` s, como un CMTime. La nominal es
/// 1/30; 1001/30000 y 33367/1000000 son un ~0,1 % más largas.
public struct FrameDuration: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int32

    /// nil si no es positiva.
    public init?(value: Int64, timescale: Int32) {
        guard value > 0, timescale > 0 else { return nil }
        self.value = value
        self.timescale = timescale
    }

    /// La nominal de `fps` fotogramas por segundo, 1/fps: la que fija `lockSettings`.
    public static func nominal(fps: Int) -> FrameDuration {
        precondition(fps > 0, "fotogramas por segundo positivos")
        return FrameDuration(value: 1, timescale: Int32(fps))!
    }

    public var microseconds: Double { Double(value) * Self.usPerS / Double(timescale) }

    /// "33367" (µs) o "1001/30000" (valor/escala, la forma exacta de un CMTime); nil si no
    /// se entiende o no es positiva.
    public static func parse(_ texto: String) -> FrameDuration? {
        let partes = texto.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        switch partes.count {
        case 1:
            return Int64(partes[0]).flatMap { FrameDuration(value: $0, timescale: Self.usTimescale) }
        case 2:
            guard let v = Int64(partes[0]), let e = Int32(partes[1]) else { return nil }
            return FrameDuration(value: v, timescale: e)
        default:
            return nil
        }
    }

    /// "33367/1000000": lo que se pidió, sin redondear, para el informe.
    public var description: String { "\(value)/\(timescale)" }

    static let usPerS = 1_000_000.0
    /// La escala de una duración dada en µs: un millón por segundo.
    static let usTimescale: Int32 = 1_000_000
}

/// Qué duración, a qué lado y cuándo. Las ventanas duran `onMs` y empiezan en cada múltiplo
/// de `everyMs` del reloj del soporte, sin instante de arranque (como Spk04Script): con
/// 20 s cada 120 s, de 0 a 20 s de cada 120. Una ventana solo cuenta si empezó con la
/// pasada de este móvil ya `afterS` en marcha: antes no hay fase que comparar.
public struct FrameDurationSpikePlan: Equatable, Sendable {
    /// A quién se alarga: siempre al mismo lado, o uno y otro por turnos (la ventana par al
    /// derecho, la impar al izquierdo).
    public enum Sides: String, Sendable {
        case left
        case right
        case alternate
    }

    /// Una ventana del plan, en el reloj del soporte.
    public struct Window: Equatable, Sendable {
        /// El número de la ventana: empieza en `index · everyMs`.
        public let index: Int64
        public let startRigMs: Int64
        public let endRigMs: Int64
        public let side: CameraSide
        public let duration: FrameDuration

        public init(index: Int64, startRigMs: Int64, endRigMs: Int64, side: CameraSide, duration: FrameDuration) {
            self.index = index
            self.startRigMs = startRigMs
            self.endRigMs = endRigMs
            self.side = side
            self.duration = duration
        }
    }

    /// Las duraciones, una por ventana y por turnos (la ventana k usa la k mod n).
    public let durations: [FrameDuration]
    public let sides: Sides
    public let onMs: Int64
    public let everyMs: Int64
    public let afterS: Double

    public init(durations: [FrameDuration], sides: Sides, onMs: Int64, everyMs: Int64, afterS: Double) {
        precondition(!durations.isEmpty && onMs > 0 && everyMs > onMs && afterS >= 0, "un plan con ventanas")
        self.durations = durations
        self.sides = sides
        self.onMs = onMs
        self.everyMs = everyMs
        self.afterS = afterS
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// El plan del entorno, nil sin RIG_SPIKE_FRAME_US:
    ///   RIG_SPIKE_FRAME_US       la duración alargada: µs ("33367") o valor/escala
    ///                            ("1001/30000"); varias con comas, una por ventana
    ///   RIG_SPIKE_FRAME_SIDE     left | right | alternate (obligatorio: BANCO_EXTRA llega igual
    ///                            a los dos móviles)
    ///   RIG_SPIKE_FRAME_ON_S     lo que dura cada ventana (20)
    ///   RIG_SPIKE_FRAME_EVERY_S  cada cuánto empieza una (120)
    ///   RIG_SPIKE_FRAME_AFTER_S  la primera, no antes de estos s de pasada (60)
    public static func parse(environment env: [String: String]) throws -> FrameDurationSpikePlan? {
        guard let lista = env["RIG_SPIKE_FRAME_US"] else { return nil }
        var duraciones: [FrameDuration] = []
        for trozo in lista.split(separator: ",") {
            guard let d = FrameDuration.parse(String(trozo)) else {
                throw ParseError(description: "RIG_SPIKE_FRAME_US: «\(trozo)» no es una duración")
            }
            guard d.microseconds <= maxSpikeUs else {
                throw ParseError(description: "RIG_SPIKE_FRAME_US: \(d) pasa de \(Int(maxSpikeUs)) µs")
            }
            duraciones.append(d)
        }
        guard !duraciones.isEmpty else { throw ParseError(description: "RIG_SPIKE_FRAME_US vacío") }
        guard let lado = env["RIG_SPIKE_FRAME_SIDE"].flatMap(Sides.init(rawValue:)) else {
            throw ParseError(description: "RIG_SPIKE_FRAME_SIDE: left, right o alternate")
        }
        func segundos(_ clave: String, _ porDefecto: Double) throws -> Double {
            guard let texto = env[clave] else { return porDefecto }
            guard let s = Double(texto), s >= 0, s.isFinite else {
                throw ParseError(description: "\(clave): «\(texto)» no son segundos")
            }
            return s
        }
        let on = try segundos("RIG_SPIKE_FRAME_ON_S", defaultOnS)
        let every = try segundos("RIG_SPIKE_FRAME_EVERY_S", defaultEveryS)
        let after = try segundos("RIG_SPIKE_FRAME_AFTER_S", defaultAfterS)
        let onMs = Int64((on * msPerS).rounded()), everyMs = Int64((every * msPerS).rounded())
        guard onMs > 0, everyMs > onMs else {
            throw ParseError(description: "RIG_SPIKE_FRAME_ON_S tiene que ser positivo y menor que RIG_SPIKE_FRAME_EVERY_S")
        }
        return FrameDurationSpikePlan(durations: duraciones, sides: lado, onMs: onMs, everyMs: everyMs, afterS: after)
    }

    /// La ventana del instante `rigMs`, si la hay y empezó con la pasada de este móvil ya
    /// `afterS` en marcha (`benchS`: lo que lleva).
    public func window(atRigMs rigMs: Int64, benchS: Double) -> Window? {
        let dentro = Self.positiveModulo(rigMs, everyMs)
        guard dentro < onMs else { return nil }
        let w = window(index: (rigMs - dentro) / everyMs)
        // Cuándo empezó la ventana, en s de la pasada de este móvil.
        let empezoEnS = benchS - Double(dentro) / Self.msPerS
        return empezoEnS >= afterS ? w : nil
    }

    /// Lo que pide el plan a `side` en `rigMs`: la duración alargada, o nil (la nominal).
    public func duration(for side: CameraSide, atRigMs rigMs: Int64, benchS: Double) -> FrameDuration? {
        guard let w = window(atRigMs: rigMs, benchS: benchS), w.side == side else { return nil }
        return w.duration
    }

    /// Las ventanas que empiezan en [fromRigMs, toRigMs), para el informe.
    public func windows(fromRigMs: Int64, toRigMs: Int64) -> [Window] {
        guard toRigMs > fromRigMs else { return [] }
        var k = Self.ceilDiv(fromRigMs, everyMs)
        var salen: [Window] = []
        while k * everyMs < toRigMs, salen.count < Self.maxReportedWindows {
            salen.append(window(index: k))
            k += 1
        }
        return salen
    }

    /// Lo que se retrasa el lado alargado en una ventana, en ms, frente al otro a la nominal:
    /// en `onMs` caben onMs/d fotogramas, cada uno d − nominal más largo. 33 367 µs frente a
    /// 1/30 durante 20 s: ~20 ms.
    public func predictedShiftMs(_ d: FrameDuration, nominal: FrameDuration) -> Double {
        Double(onMs) * (1 - nominal.microseconds / d.microseconds)
    }

    /// Lo que se movió la fase del maestro con una ventana, en ms: de la mediana del cubo de
    /// antes de la ventana a la del cubo de después, desenrollada cubo a cubo. La fase vive
    /// en ±½ fotograma y una ventana la mueve ~20 ms, más de ½ fotograma: la diferencia de
    /// los dos extremos no se puede desplegar, pero cada paso de cubo a cubo (~10 ms) sí.
    /// `phases`: [inicio del cubo en el reloj del soporte, mediana], los cubos de
    /// `bucketMs`. nil si falta el cubo de antes o el de después.
    public static func measuredShiftMs(phases: [(startRigMs: Int64, medianMs: Double)], window: Window,
                                       bucketMs: Int64, frameDurationMs: Double) -> Double? {
        let tramo = phases.filter { $0.startRigMs >= window.startRigMs - bucketMs && $0.startRigMs <= window.endRigMs }
            .sorted { $0.startRigMs < $1.startRigMs }
        guard let primero = tramo.first, primero.startRigMs == window.startRigMs - bucketMs,
              let ultimo = tramo.last, ultimo.startRigMs == window.endRigMs
        else { return nil }
        var movida = 0.0
        for (a, b) in zip(tramo, tramo.dropFirst()) {
            var paso = b.medianMs - a.medianMs
            while paso > frameDurationMs / 2 { paso -= frameDurationMs }
            while paso <= -frameDurationMs / 2 { paso += frameDurationMs }
            movida += paso
        }
        return movida
    }

    /// Los parámetros, para el informe.
    public var report: [String: Any] {
        ["durations": durations.map(\.description), "durations_us": durations.map(\.microseconds),
         "sides": sides.rawValue, "on_s": Double(onMs) / Self.msPerS, "every_s": Double(everyMs) / Self.msPerS,
         "after_s": afterS]
    }

    private func window(index k: Int64) -> Window {
        let lado: CameraSide
        switch sides {
        case .left: lado = .left
        case .right: lado = .right
        case .alternate: lado = Self.positiveModulo(k, 2) == 0 ? .right : .left
        }
        let d = durations[Int(Self.positiveModulo(k, Int64(durations.count)))]
        return Window(index: k, startRigMs: k * everyMs, endRigMs: k * everyMs + onMs, side: lado, duration: d)
    }

    static func positiveModulo(_ a: Int64, _ m: Int64) -> Int64 {
        let r = a % m
        return r < 0 ? r + m : r
    }

    private static func ceilDiv(_ a: Int64, _ m: Int64) -> Int64 {
        let q = a / m
        return a % m > 0 ? q + 1 : q
    }

    static let msPerS = 1000.0
    /// Lo que dura una ventana si el entorno no dice otra cosa, en s: con 33 367 µs mueve
    /// la fase ~20 ms, más que su ruido y menos de un fotograma.
    public static let defaultOnS = 20.0
    /// Cada cuánto empieza una ventana, en s: 100 s a la nominal entre dos dejan ver la
    /// deriva natural (~0,8 ms/min) y que la fase se queda donde la dejó la ventana.
    public static let defaultEveryS = 120.0
    /// La primera ventana, no antes de estos s de pasada: el enlace, la parte y la
    /// calibración (a los 30 s) ya están y hay fase de base.
    public static let defaultAfterS = 60.0
    /// La duración más larga que se acepta, en µs (20 fps): lo de más es una errata (un
    /// cero de más) y no un alargamiento fino.
    public static let maxSpikeUs = 50_000.0
    /// Las ventanas que lista el informe como mucho (8 h a una cada 120 s).
    static let maxReportedWindows = 240
}

/// Lo que da la cámara de verdad, en cubos de `bucketMs` de la rejilla del reloj del soporte
/// (los cubos de los dos móviles caen en los mismos instantes, y las ventanas del plan,
/// múltiplos de 10 s, también). El periodo sale del reloj del host, que no salta cuando el
/// reloj del soporte se reestima: un intervalo de n fotogramas (n ≥ 2: alguno se perdió)
/// cuenta como n periodos de intervalo/n.
public final class FrameCadenceTracker {
    public struct Bucket: Equatable, Sendable {
        public let startRigMs: Int64
        /// Intervalos medidos (los fotogramas del cubo, menos ninguno si hubo uno antes).
        public let intervals: Int
        /// El periodo medio, en µs: lo que suman los intervalos entre los fotogramas que
        /// abarcan. Es la cifra fina: no la mueve el jitter de cada sello.
        public let meanUs: Double
        public let p50Us: Double
        public let p99Us: Double
        /// Intervalos de dos fotogramas o más: se perdió alguno por el camino.
        public let gaps: Int
        /// Descartes de la cámara (didDrop) durante el cubo.
        public let drops: Int
        /// Fotogramas que entraron a la 4K durante el cubo.
        public let recorded: Int64
        /// Lo pedido con el último fotograma del cubo, en µs (0: la nominal).
        public let requestedUs: Double
    }

    private let nominalUs: Double
    private let bucketMs: Int64
    private let maxBuckets: Int
    private var closed: [Bucket] = []
    private var currentStart: Int64?
    private var periods: [Double] = []
    private var sumUs = 0.0
    private var frames = 0
    private var gaps = 0
    private var drops = 0
    private var recordedAtStart: Int64 = 0
    private var recordedLast: Int64 = 0
    private var requestedUs = 0.0
    private var bucketRequestedUs = 0.0
    private var lastHostNs: Int64?

    public init(nominalUs: Double, bucketMs: Int64 = FrameCadenceTracker.defaultBucketMs,
                maxBuckets: Int = FrameCadenceTracker.defaultMaxBuckets) {
        precondition(nominalUs > 0 && bucketMs > 0 && maxBuckets > 0, "hacen falta cubos")
        self.nominalUs = nominalUs
        self.bucketMs = bucketMs
        self.maxBuckets = maxBuckets
        periods.reserveCapacity(Int(Double(bucketMs) * Self.usPerMs / nominalUs) + 1)
    }

    /// Un fotograma entregado: su sello en el host (ns), su instante en el reloj del soporte
    /// y los fotogramas que lleva la 4K antes de él. Sin instante (el esclavo aún sin reloj
    /// del soporte) solo se guarda el sello, para que el primer intervalo con reloj no
    /// parezca un hueco. Devuelve el periodo de este fotograma en µs (nil si no lo hay).
    @discardableResult
    public func record(frameHostNs: Int64, rigMs: Int64?, recordedTotal: Int64) -> Double? {
        guard let rigMs else {
            lastHostNs = frameHostNs
            return nil
        }
        let inicio = rigMs - FrameDurationSpikePlan.positiveModulo(rigMs, bucketMs)
        if let actual = currentStart, actual != inicio {
            recordedLast = recordedTotal
            close()
        }
        if currentStart == nil {
            currentStart = inicio
            recordedAtStart = recordedTotal
        }
        recordedLast = recordedTotal
        bucketRequestedUs = requestedUs
        defer { lastHostNs = frameHostNs }
        guard let previo = lastHostNs, frameHostNs > previo else { return nil }
        let intervaloUs = Double(frameHostNs - previo) / Self.nsPerUs
        let n = max(1, Int((intervaloUs / nominalUs).rounded()))
        if n > 1 { gaps += 1 }
        let periodo = intervaloUs / Double(n)
        periods.append(periodo)
        sumUs += intervaloUs
        frames += n
        return periodo
    }

    /// Un descarte de la cámara (didDrop), en el cubo abierto.
    public func recordDrop() {
        drops += 1
    }

    /// Lo pedido desde ahora, en µs; nil vuelve a la nominal.
    public func setRequested(us: Double?) {
        requestedUs = us ?? 0
    }

    /// Los cubos, de más viejo a más nuevo (el abierto, el último).
    public var buckets: [Bucket] {
        guard let abierto = currentBucket() else { return closed }
        return closed + [abierto]
    }

    private func currentBucket() -> Bucket? {
        guard let inicio = currentStart else { return nil }
        let o = periods.sorted()
        func pct(_ q: Double) -> Double { o.isEmpty ? 0 : o[min(o.count - 1, Int(q * Double(o.count)))] }
        return Bucket(startRigMs: inicio, intervals: periods.count, meanUs: frames > 0 ? sumUs / Double(frames) : 0,
                      p50Us: pct(Self.p50), p99Us: pct(Self.p99), gaps: gaps, drops: drops,
                      recorded: recordedLast - recordedAtStart, requestedUs: bucketRequestedUs)
    }

    private func close() {
        if let b = currentBucket() { closed.append(b) }
        if closed.count > maxBuckets { closed.removeFirst(closed.count - maxBuckets) }
        currentStart = nil
        periods.removeAll(keepingCapacity: true)
        sumUs = 0
        frames = 0
        gaps = 0
        drops = 0
    }

    /// Cubos de 10 s: 300 fotogramas, y la ventana del plan (20 s) son dos.
    public static let defaultBucketMs: Int64 = 10_000
    /// 2 h a un cubo cada 10 s.
    public static let defaultMaxBuckets = 720
    static let nsPerUs = 1000.0
    static let usPerMs = 1000.0
    static let p50 = 0.5
    static let p99 = 0.99
}

/// Cuánto tarda la cámara en dar la duración pedida: los periodos de los primeros
/// fotogramas tras la petición y el primero de `confirmFrames` seguidos que caen del lado
/// de lo pedido (pasada la mitad entre lo de antes y lo pedido).
public struct FrameDurationEffect: Equatable, Sendable {
    public let fromUs: Double
    public let toUs: Double
    public let requestedAtHostNs: Int64
    /// Los periodos de los primeros `capacity` fotogramas, en µs.
    public private(set) var periodsUs: [Double] = []
    /// El número (desde 1) del primer fotograma de los `confirmFrames` seguidos con lo
    /// pedido; nil mientras no los haya.
    public private(set) var framesToEffect: Int?
    /// Del momento de la petición a ese fotograma, en ms (su sello en el host).
    public private(set) var msToEffect: Double?
    private var seguidos = 0
    private var primeroHostNs: Int64 = 0

    public init(fromUs: Double, toUs: Double, requestedAtHostNs: Int64) {
        self.fromUs = fromUs
        self.toUs = toUs
        self.requestedAtHostNs = requestedAtHostNs
        periodsUs.reserveCapacity(Self.capacity)
    }

    /// Ya tiene sus `capacity` periodos.
    public var isComplete: Bool { periodsUs.count >= Self.capacity }

    /// El periodo del siguiente fotograma tras la petición y su sello en el host (ns).
    public mutating func observe(periodUs: Double, frameHostNs: Int64) {
        guard !isComplete else { return }
        periodsUs.append(periodUs)
        guard framesToEffect == nil, toUs != fromUs else { return }
        let mitad = (fromUs + toUs) / 2
        let conLoPedido = toUs > fromUs ? periodUs > mitad : periodUs < mitad
        if !conLoPedido {
            seguidos = 0
            return
        }
        if seguidos == 0 { primeroHostNs = frameHostNs }
        seguidos += 1
        if seguidos == Self.confirmFrames {
            framesToEffect = periodsUs.count - Self.confirmFrames + 1
            msToEffect = Double(primeroHostNs - requestedAtHostNs) / Self.nsPerMs
        }
    }

    /// Los periodos que se guardan tras cada petición: 3 s a 30 fps.
    public static let capacity = 90
    /// Fotogramas seguidos con lo pedido para darlo por aplicado: uno suelto puede ser jitter.
    public static let confirmFrames = 3
    static let nsPerMs = 1e6
}
