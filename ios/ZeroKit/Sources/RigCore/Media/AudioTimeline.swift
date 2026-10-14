// El eje de tiempos del AAC del programa, anclado al reloj del soporte (IOS-54).
//
// Un AAC se sella contando muestras: la trama k empieza 1024·k muestras después de la
// primera. Pero las muestras del micro van al ritmo del reloj de SU dispositivo, que se
// separa del host (y del soporte, que cuelga del host) unos 45 ppm: medido el 2026-10-14
// sobre el programa de 30 min del 2026-10-07, el audio contado se adelanta al vídeo
// 2,67 ms por minuto, 240 ms a los 90 min. Y un hueco del micro (una llamada, un búfer
// perdido) lo descuadra de golpe y para siempre.
//
// El eje compara cada búfer con su sello (el PTS del micro, ya en el soporte) y dice
// cómo meterlo para que cada muestra caiga en su instante:
//   - hasta `toleranceMs`, tal cual;
//   - hasta `hardResyncMs`, UNA muestra por búfer: se repite o se quita, y no se oye
//     (la deriva pide unas 2 por segundo y el micro da ~47 búferes);
//   - más, de golpe: silencio delante si falta audio, recorte si sobra;
//   - más de `maxFillMs`, se reancla: el eje salta al sello del búfer (el reloj del
//     soporte saltó, o nadie rellenó un corte largo).
// Swift puro: lo prueban los tests de RigCore sin AVFoundation.

import Foundation

/// Los umbrales del eje del audio.
public enum AudioSync {
    /// Diferencia entre el eje y el sello que se da por buena, en ms: el temblor del PTS
    /// del micro al pasarlo al reloj del host es de microsegundos.
    public static let toleranceMs = 1.0
    /// Hasta aquí, en ms, se corrige muestra a muestra; más es un hueco o un solape de
    /// verdad y va de golpe. Media trama AAC (10,7 ms): dentro del ±20 ms del A/V.
    public static let hardResyncMs = 10.0
    /// El silencio más largo que se mete de golpe, en ms. Tiene que caber en la cola de
    /// salida del codificador (64 tramas, 1,37 s) o se tirarían sus primeras tramas; más
    /// es un corte largo que nadie rellenó, y se reancla.
    public static let maxFillMs = 1000.0
}

public struct AudioTimeline: Sendable, Equatable {
    /// Cómo entra un búfer en el eje.
    public enum Placement: Equatable, Sendable {
        /// Tal cual.
        case asIs
        /// Falta una muestra (deriva): se repite la primera del búfer.
        case repeatFirst
        /// Sobra una muestra (deriva): se quita la primera del búfer.
        case dropFirst
        /// Un hueco: `n` muestras de silencio delante del búfer.
        case silenceBefore(Int)
        /// Un solape: se tiran las `n` primeras muestras (todas, si el búfer es más corto).
        case dropLeading(Int)
        /// El eje saltó al sello del búfer, que entra tal cual.
        case reanchored
    }

    /// Una muestra del eje y su instante en el reloj del soporte.
    struct Anchor: Equatable, Sendable {
        let sample: Int
        let ms: Double
    }

    public let sampleRate: Double
    private let toleranceSamples: Int
    private let hardSamples: Int
    private let maxFillSamples: Int
    private var anchors: [Anchor] = []

    /// Muestras que ya están en el eje: la siguiente va en la posición `samples`.
    public private(set) var samples = 0
    /// Lo que el eje ha corregido, para el informe del banco.
    public private(set) var silenceSamples = 0
    public private(set) var droppedSamples = 0
    public private(set) var nudges = 0
    public private(set) var reanchors = 0

    public init(
        sampleRate: Int,
        toleranceMs: Double = AudioSync.toleranceMs,
        hardResyncMs: Double = AudioSync.hardResyncMs,
        maxFillMs: Double = AudioSync.maxFillMs
    ) {
        self.sampleRate = Double(sampleRate)
        toleranceSamples = Int((toleranceMs * Double(sampleRate) / 1000).rounded())
        hardSamples = Int((hardResyncMs * Double(sampleRate) / 1000).rounded())
        maxFillSamples = Int((maxFillMs * Double(sampleRate) / 1000).rounded())
    }

    /// Si ya tiene instante: el primer búfer o el primer silencio lo fija.
    public var isAnchored: Bool { !anchors.isEmpty }

    /// El instante de la muestra `index` del eje, en ms del soporte. Puede ser negativa:
    /// el cebado del codificador AAC va delante de la primera muestra.
    public func rigMs(ofSample index: Int) -> Double? {
        guard let primera = anchors.first else { return nil }
        let ancla = anchors.last { $0.sample <= index } ?? primera
        return ancla.ms + Double(index - ancla.sample) * 1000 / sampleRate
    }

    /// Dónde va un búfer de `frames` muestras cuya primera se sella en `rigMs`. Lo que
    /// devuelve ya está anotado en los contadores; las muestras que entren de verdad se
    /// apuntan después con `advance(by:)`.
    public mutating func place(rigMs: Double, frames: Int) -> Placement {
        guard let esperado = self.rigMs(ofSample: samples) else {
            anchors = [Anchor(sample: samples, ms: rigMs)]
            return .asIs
        }
        let d = Int(((rigMs - esperado) * sampleRate / 1000).rounded())
        let distancia = abs(d)
        if distancia <= toleranceSamples { return .asIs }
        if distancia > maxFillSamples {
            anchors.append(Anchor(sample: samples, ms: rigMs))
            reanchors += 1
            return .reanchored
        }
        if distancia > hardSamples {
            if d > 0 {
                silenceSamples += d
                return .silenceBefore(d)
            }
            let tirar = min(distancia, frames)
            droppedSamples += tirar
            return .dropLeading(tirar)
        }
        nudges += 1
        if d > 0 { return .repeatFirst }
        guard frames > 0 else { return .asIs }
        droppedSamples += 1
        return .dropFirst
    }

    /// Las muestras de silencio que faltan para que el eje llegue a `rigMs`: lo que mete el
    /// vigilante mientras el micro calla. Sin instante todavía, lo fija ahí y no pide nada.
    public mutating func silence(until rigMs: Double) -> Int {
        guard let esperado = self.rigMs(ofSample: samples) else {
            anchors = [Anchor(sample: samples, ms: rigMs)]
            return 0
        }
        let d = Int(((rigMs - esperado) * sampleRate / 1000).rounded())
        guard d > 0 else { return 0 }
        if d > maxFillSamples {
            anchors.append(Anchor(sample: samples, ms: rigMs))
            reanchors += 1
            return 0
        }
        silenceSamples += d
        return d
    }

    /// Anota que entraron `n` muestras al eje.
    public mutating func advance(by n: Int) {
        samples += n
    }

    /// Olvida las anclas que ya no sellan nada a partir de la muestra `index`.
    public mutating func prune(before index: Int) {
        while anchors.count > 1, anchors[1].sample <= index {
            anchors.removeFirst()
        }
    }

    /// Anclas vivas, para los tests.
    var anchorCount: Int { anchors.count }
}
