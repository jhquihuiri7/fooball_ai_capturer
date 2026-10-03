// Histograma de latencias con cubos fijos (IOS-05).
//
// Sin reservas después de construirlo: `record` es una suma en un array fijo, apta
// para llamarse por frame desde el camino caliente. Los percentiles salen del borde
// superior del cubo donde cae el cuantil: un p99 «pesimista por un cubo», que para
// vigilar una escalera térmica es exactamente lo que se quiere.

import Foundation

public struct LatencyHistogram: Sendable {
    /// Bordes superiores de cada cubo, en milisegundos, crecientes. El último cubo
    /// recoge todo lo que pase del último borde.
    public let boundsMs: [Double]
    private var counts: [UInt64]
    public private(set) var total: UInt64 = 0

    /// Los cubos por defecto: finos por debajo de un frame (33 ms), gruesos después.
    public static let defaultBoundsMs: [Double] = [
        0.5, 1, 2, 3, 5, 8, 12, 16, 22, 33, 50, 75, 100, 150, 250, 500, 1000,
    ]

    public init(boundsMs: [Double] = LatencyHistogram.defaultBoundsMs) {
        precondition(!boundsMs.isEmpty, "un histograma sin cubos no mide nada")
        precondition(boundsMs == boundsMs.sorted(), "los bordes van crecientes")
        self.boundsMs = boundsMs
        counts = Array(repeating: 0, count: boundsMs.count + 1)
    }

    public mutating func record(ms: Double) {
        // Búsqueda lineal: con ~18 cubos es más rápida que una binaria y no falla
        // nunca de caché. El camino caliente lo agradece.
        var indice = counts.count - 1
        for (posicion, borde) in boundsMs.enumerated() where ms <= borde {
            indice = posicion
            break
        }
        counts[indice] += 1
        total += 1
    }

    /// El borde superior del cubo donde cae el cuantil `p` (0–1). Sin datos, 0.
    public func percentile(_ p: Double) -> Double {
        guard total > 0 else { return 0 }
        let objetivo = UInt64((p.clamped01 * Double(total)).rounded(.up))
        var acumulado: UInt64 = 0
        for (indice, cuenta) in counts.enumerated() {
            acumulado += cuenta
            if acumulado >= max(objetivo, 1) {
                return indice < boundsMs.count ? boundsMs[indice] : Double.infinity
            }
        }
        return Double.infinity
    }

    public var p50Ms: Double { percentile(0.50) }
    public var p90Ms: Double { percentile(0.90) }
    public var p99Ms: Double { percentile(0.99) }

    public mutating func reset() {
        counts = Array(repeating: 0, count: boundsMs.count + 1)
        total = 0
    }
}

private extension Double {
    var clamped01: Double { Swift.min(1.0, Swift.max(0.0, self)) }
}
