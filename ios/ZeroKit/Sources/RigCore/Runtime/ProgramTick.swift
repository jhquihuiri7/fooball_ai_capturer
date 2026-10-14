// El tic del programa en fase con la rejilla (2026-10-14), lógica pura.
//
// El tic del maestro se armaba una vez con un temporizador de GCD que se repetía cada
// 1/30 s. GCD pasa el intervalo a ticks de mach (24 MHz en el iPhone) truncando:
// 33 333 333 ns son 799 999,99 ticks y se quedan en 799 999, 41,7 ns menos por tic
// (−1,25 ppm). La fase del tic frente a la rejilla del programa se iba 0,075 ms por
// minuto, 6,75 ms en un partido. En el ensayo de 90 min por Wi-Fi Aware del 2026-10-14
// (`bench/dos-moviles-20261014-1010`) eso hizo dos cosas:
// - hacia el minuto 40 el tic del director cayó en la frontera de la rejilla: uno de
//   cada tres daba el mismo instante que el anterior y el siguiente se lo saltaba. Hasta
//   570 instantes por minuto sin vista del director: salían con el barrido de guion (un
//   salto de plano de un fotograma) y sin la parte del esclavo, que tampoco la tenía;
// - hacia el minuto 80, lo mismo con el instante que se compone: hasta 570 huecos por
//   minuto (el programa a 20 fps) y, pasada la frontera, un fotograma más de espera
//   (latencia añadida p95 de 144 a 169 ms).
// Ahora cada tic se arma para el siguiente instante de la rejilla más el margen, medido
// en el reloj del soporte: no hay nada que acumular.

import Foundation

public struct ProgramTickPhase: Sendable {
    /// Fotogramas por segundo de la rejilla: con un entero la cuenta es exacta en ns (a
    /// 30 fps el periodo es 33 333 333,3 ns y en coma flotante el instante justo del tic
    /// caía a veces en el fotograma anterior).
    public let framesPerSecond: Int64
    /// Lo que el tic va detrás de cada instante de la rejilla, en ns: lo justo para que el
    /// instante ya haya pasado aunque el disparo se adelante un poco.
    public let marginNs: Int64

    public init(framesPerSecond: Int, marginMs: Double) {
        precondition(framesPerSecond > 0, "la rejilla necesita una cadencia")
        let periodoMs = Self.msPerS / Double(framesPerSecond)
        precondition(marginMs >= 0 && marginMs < periodoMs, "el margen cabe en un fotograma")
        self.framesPerSecond = Int64(framesPerSecond)
        marginNs = Int64((marginMs * Self.nsPerMs).rounded())
    }

    /// Lo que falta desde `nowRigNs` hasta el siguiente tic, en ns: el primer instante de
    /// la rejilla más el margen que sea posterior a `nowRigNs`. Siempre en (0, un fotograma].
    public func delayToNextTickNs(nowRigNs: Int64) -> Int64 {
        // k: el último instante de la rejilla cuyo tic (instante + margen) no pasa de ahora.
        let k = Self.floorDiv((nowRigNs - marginNs) * framesPerSecond, Self.nsPerS)
        let siguiente = Self.ceilDiv((k + 1) * Self.nsPerS, framesPerSecond) + marginNs
        return siguiente - nowRigNs
    }

    /// La fase de un tic: lo que `nowRigNs` pasa del instante de la rejilla anterior, en
    /// ms, en [0, un fotograma). Con el tic en fase se queda en el margen.
    public func phaseMs(nowRigNs: Int64) -> Double {
        let k = Self.floorDiv(nowRigNs * framesPerSecond, Self.nsPerS)
        let instante = Self.ceilDiv(k * Self.nsPerS, framesPerSecond)
        return Double(nowRigNs - instante) / Self.nsPerMs
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 {
        -floorDiv(-a, b)
    }

    static let nsPerS: Int64 = 1_000_000_000
    static let nsPerMs = 1_000_000.0
    static let msPerS = 1000.0
}

extension ProgramClock {
    /// El índice k del instante de la rejilla más reciente que no pasa de `rigMs`.
    /// (Con el mismo épsilon que `gridInstant(atOrBefore:)`.)
    public func gridIndex(atOrBefore rigMs: Int64) -> Int64 {
        Int64((Double(rigMs) / frameDurationMs + 1e-9).rounded(.down))
    }

    /// El instante k de la rejilla, en ms redondeados (el que da `gridInstant`).
    public func instant(index k: Int64) -> Int64 {
        Int64((Double(k) * frameDurationMs).rounded())
    }

    /// Los instantes de la rejilla posteriores a `last` que no pasan de `target`, de más
    /// viejo a más nuevo, y como mucho los `limit` últimos. Los dos son instantes de la
    /// rejilla (de `gridInstant`); sin `last`, solo `target`. Un tic que llega tarde se
    /// salta instantes: con esto el director da vista a todos.
    public func gridInstants(after last: Int64?, through target: Int64, limit: Int) -> [Int64] {
        guard limit > 0 else { return [] }
        // Un instante está a ≤0,5 ms de k·periodo: redondear devuelve su k.
        let hasta = Int64((Double(target) / frameDurationMs).rounded())
        guard let last else { return [instant(index: hasta)] }
        let desde = Int64((Double(last) / frameDurationMs).rounded())
        guard hasta > desde else { return [] }
        let primero = max(desde + 1, hasta - Int64(limit) + 1)
        return (primero...hasta).map { instant(index: $0) }
    }
}
