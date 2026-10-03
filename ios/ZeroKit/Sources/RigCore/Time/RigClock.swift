// El reloj común del soporte, en nativo (IOS-13, ADR 0012 decisión 2; ADR 0023).
//
// Es el puerto fiel de lib/src/rig_clock.dart, que es donde la cuenta está probada:
// misma aritmética entera (división truncada hacia cero), mismo filtro y misma recta.
// Los casos compartidos de Tests/RigCoreTests/Fixtures/rig_clock_cases.json los leen
// el test de Dart y el de Swift: si divergen en un nanosegundo, falla uno de los dos.
//
// Dos cosas que este módulo hace y que una media de muestras no haría:
//
//   1. **Filtra por RTT mínimo.** El desfase se despeja suponiendo que la ida tarda lo
//      mismo que la vuelta. Eso solo vale si nadie encoló el paquete: las muestras
//      lentas no se promedian, se tiran.
//   2. **Ajusta una recta, no un punto.** Dos cristales derivan decenas de ppm, que en
//      90 minutos son más de 100 ms: tres frames. Un offset fijo medido al empezar
//      llega al descanso equivocado.
//
// A diferencia del Dart, aquí hay un cerrojo: el enlace añade muestras desde su cola y
// la cámara pregunta el desfase por fotograma desde la suya.

import Foundation

/// Una medida de desfase ya despejada, al estilo NTP.
public struct RigClockSample: Equatable, Sendable {
    /// Ida y vuelta de la medida, en ns. Decide si la muestra vale: con jitter de
    /// WiFi, solo las de RTT mínimo dan un offset creíble.
    public let roundTripNs: Int64
    /// Desfase estimado: cuánto sumar al reloj local para obtener el del maestro, en ns.
    public let offsetNs: Int64
    /// Cuándo se tomó, en el reloj monótono local, en ns.
    public let localMonotonicNs: Int64

    public init(roundTripNs: Int64, offsetNs: Int64, localMonotonicNs: Int64) {
        self.roundTripNs = roundTripNs
        self.offsetNs = offsetNs
        self.localMonotonicNs = localMonotonicNs
    }
}

/// El estado del reloj del soporte en un instante dado.
public struct RigClockEstimate: Equatable, Sendable {
    /// Desfase a sumar al reloj local, en el instante de la última muestra, en ns.
    public let offsetNs: Int64
    /// Deriva relativa entre los dos relojes, en partes por millón. Positiva si el
    /// reloj local va lento respecto al maestro. Vale 0 mientras las muestras no
    /// abarquen `RigClock.minDriftSpanSeconds`.
    public let driftPpm: Double
    /// Muestras que sobrevivieron al filtro de RTT.
    public let samples: Int
    /// El mejor RTT visto, en ns. La incertidumbre del desfase es del orden de su mitad.
    public let bestRoundTripNs: Int64

    /// Incertidumbre del desfase, en nanosegundos.
    public var uncertaintyNs: Int64 { bestRoundTripNs / 2 }

    public init(offsetNs: Int64, driftPpm: Double, samples: Int, bestRoundTripNs: Int64) {
        self.offsetNs = offsetNs
        self.driftPpm = driftPpm
        self.samples = samples
        self.bestRoundTripNs = bestRoundTripNs
    }
}

/// Acumula medidas de desfase y entrega el reloj del soporte.
public final class RigClock: @unchecked Sendable {
    /// Cuántas muestras se conservan. 240 a una cada 5 s son 20 minutos de historia.
    public static let maxSamplesDefault = 240
    /// Una muestra se tira si su RTT pasa de este múltiplo del mejor visto.
    public static let rttRejectFactorDefault = 3.0
    /// Mínimo de muestras supervivientes para atreverse con una estimación.
    public static let minSamplesDefault = 3
    /// Segundos que deben abarcar las muestras antes de creerse una deriva.
    public static let minDriftSpanSecondsDefault = 60

    private static let nsPerSecond: Int64 = 1_000_000_000

    private let maxSamples: Int
    private let rttRejectFactor: Double
    private let minSamples: Int
    private let minDriftSpanSeconds: Int

    private var stored: [RigClockSample] = []
    private let lock = NSLock()

    public init(
        maxSamples: Int = RigClock.maxSamplesDefault,
        rttRejectFactor: Double = RigClock.rttRejectFactorDefault,
        minSamples: Int = RigClock.minSamplesDefault,
        minDriftSpanSeconds: Int = RigClock.minDriftSpanSecondsDefault
    ) {
        self.maxSamples = maxSamples
        self.rttRejectFactor = rttRejectFactor
        self.minSamples = minSamples
        self.minDriftSpanSeconds = minDriftSpanSeconds
    }

    /// Muestras conservadas, de la más antigua a la más reciente.
    public var samples: [RigClockSample] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Incorpora una medida. Las muestras viejas se van por el extremo antiguo.
    public func add(_ sample: RigClockSample) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(sample)
        if stored.count > maxSamples {
            stored.removeFirst(stored.count - maxSamples)
        }
    }

    /// Estimación actual, o `nil` si todavía no hay muestras suficientes.
    ///
    /// Devolver `nil` y no un cero es deliberado: un desfase de cero es una afirmación
    /// —«los relojes coinciden»— y al arrancar no se sabe nada. Quien emite tiene que
    /// esperar a tener reloj antes de mandar el primer PTS.
    public var estimate: RigClockEstimate? {
        lock.lock()
        defer { lock.unlock() }
        let kept = keep()
        guard kept.count >= minSamples else { return nil }

        let bestRtt = kept.map(\.roundTripNs).min() ?? 0
        let spanNs = kept[kept.count - 1].localMonotonicNs - kept[0].localMonotonicNs

        if spanNs < Int64(minDriftSpanSeconds) * Self.nsPerSecond {
            let mean = kept.map(\.offsetNs).reduce(0, &+) / Int64(kept.count)
            return RigClockEstimate(
                offsetNs: mean, driftPpm: 0.0, samples: kept.count, bestRoundTripNs: bestRtt
            )
        }

        let line = fit(kept)
        return RigClockEstimate(
            offsetNs: Int64(line.at(kept[kept.count - 1].localMonotonicNs).rounded()),
            driftPpm: line.slope * 1e6,
            samples: kept.count,
            bestRoundTripNs: bestRtt
        )
    }

    /// Desfase a aplicar a un instante local concreto, extrapolando la deriva, en ns.
    ///
    /// Sin muestras devuelve 0, que es la única respuesta honesta: no se sabe nada, y
    /// quien llama tiene que haber comprobado `estimate` antes de emitir.
    public func offsetAt(ns localMonotonicNs: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let kept = keep()
        if kept.count < minSamples {
            return kept.last?.offsetNs ?? 0
        }
        let spanNs = kept[kept.count - 1].localMonotonicNs - kept[0].localMonotonicNs
        if spanNs < Int64(minDriftSpanSeconds) * Self.nsPerSecond {
            return kept.map(\.offsetNs).reduce(0, &+) / Int64(kept.count)
        }
        return Int64(fit(kept).at(localMonotonicNs).rounded())
    }

    /// Traduce un instante local al dominio de tiempo del soporte, en ns. Es lo que se
    /// escribe como PTS del stream y lo que el servidor compara entre las dos cámaras.
    public func toRigTimeNs(_ localMonotonicNs: Int64) -> Int64 {
        localMonotonicNs + offsetAt(ns: localMonotonicNs)
    }

    /// Muestras que sobreviven al filtro de RTT. Se llama con el cerrojo cogido.
    private func keep() -> [RigClockSample] {
        guard let best = stored.map(\.roundTripNs).min() else { return [] }
        let limit = Double(best) * rttRejectFactor
        return stored.filter { Double($0.roundTripNs) <= limit }
    }

    /// Mínimos cuadrados de `offset` contra `localMonotonicNs`.
    ///
    /// El tiempo se centra en la primera muestra antes de ajustar. Sin centrar, la `x`
    /// son nanosegundos desde el arranque del teléfono —del orden de 1e14— y sus
    /// cuadrados desbordan la precisión de un `Double` justo donde se calcula la
    /// pendiente, que es la magnitud que aquí importa.
    private func fit(_ kept: [RigClockSample]) -> Line {
        let origin = kept[0].localMonotonicNs
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var sxy = 0.0
        for sample in kept {
            let x = Double(sample.localMonotonicNs - origin)
            let y = Double(sample.offsetNs)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let n = Double(kept.count)
        let denominator = n * sxx - sx * sx
        if abs(denominator) < 1e-9 {
            return Line(origin: origin, intercept: sy / n, slope: 0.0)
        }
        let slope = (n * sxy - sx * sy) / denominator
        return Line(origin: origin, intercept: (sy - slope * sx) / n, slope: slope)
    }

    private struct Line {
        let origin: Int64
        let intercept: Double
        let slope: Double

        func at(_ localMonotonicNs: Int64) -> Double {
            intercept + slope * Double(localMonotonicNs - origin)
        }
    }
}

/// Despeja el desfase de una ida y vuelta, al estilo NTP.
///
/// `t1` es cuándo se envió la pregunta, `t2` y `t3` cuándo la recibió y contestó el
/// maestro (en su reloj) y `t4` cuándo llegó la respuesta. Todo en nanosegundos. La
/// división trunca hacia cero, como el `~/` de Dart: los casos compartidos lo vigilan.
public func solveClockSample(t1: Int64, t2: Int64, t3: Int64, t4: Int64) -> RigClockSample {
    let roundTrip = (t4 - t1) - (t3 - t2)
    let offset = ((t2 - t1) + (t3 - t4)) / 2
    return RigClockSample(
        roundTripNs: max(roundTrip, 0),
        offsetNs: offset,
        localMonotonicNs: t4
    )
}
