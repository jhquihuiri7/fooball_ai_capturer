// Los saltos de la huella del proceso, con su instante (2026-10-14), lógica pura.
//
// En el ensayo de 90 min por Wi-Fi Aware la memoria del maestro pasó de ~306 a ~487 MB
// de golpe entre los minutos 44 y 45 y se quedó ahí. `footprint_mb` es una muestra por
// minuto: no dice cuándo ni qué pasaba. Esto mira la huella cada pocos segundos y apunta
// cada subida de golpe; quien lo usa le pone el contexto de ese momento.

import Foundation

public struct FootprintJumps: Sendable {
    public struct Jump: Equatable, Sendable {
        /// Segundos desde el arranque de la pasada.
        public let atS: Double
        public let fromMb: Double
        public let toMb: Double

        public init(atS: Double, fromMb: Double, toMb: Double) {
            self.atS = atS
            self.fromMb = fromMb
            self.toMb = toMb
        }
    }

    /// Lo que tiene que subir entre dos muestras para contar como salto, en MB.
    public let thresholdMb: Double
    /// Los que se guardan como mucho (los primeros: el primero suele ser la causa).
    public let maxEvents: Int
    public private(set) var jumps: [Jump] = []
    /// Los que no cupieron.
    public private(set) var dropped = 0
    private var last: Double?

    public init(thresholdMb: Double = FootprintJumps.defaultThresholdMb, maxEvents: Int = FootprintJumps.defaultMaxEvents) {
        precondition(thresholdMb > 0 && maxEvents > 0, "un umbral y sitio para apuntar")
        self.thresholdMb = thresholdMb
        self.maxEvents = maxEvents
    }

    /// Una muestra de la huella. Devuelve el salto si lo es (ya apuntado).
    @discardableResult
    public mutating func sample(mb: Double, atS: Double) -> Jump? {
        defer { last = mb }
        guard let previa = last, mb - previa >= thresholdMb else { return nil }
        let salto = Jump(atS: atS, fromMb: previa, toMb: mb)
        if jumps.count < maxEvents { jumps.append(salto) } else { dropped += 1 }
        return salto
    }

    /// 20 MB: por encima del ruido de un minuto plano (±3 MB en el ensayo) y por debajo
    /// de un puñado de búferes 1080p NV12 (3,1 MB cada uno).
    public static let defaultThresholdMb = 20.0
    public static let defaultMaxEvents = 32
}
