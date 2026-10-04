// Dónde está la acción según los jugadores (IOS-33, réplica de libs/vision/action.py).
//
// El eje largo del campo es el yaw del soporte, así que la densidad de §16.2 se
// calcula en ángulos y no hace falta la homografía para dirigir. El centro sale del
// grupo denso; la dispersión, de todos (la regla 5 de §20.5 abre el plano justo
// cuando los equipos están estirados). Sin campo de convergencia —no hay velocidad—
// la confianza nunca pasa de 0.80.
//
// Corre en cada ciclo de detección: los búferes de trabajo se reservan al crear el
// estimador y se reutilizan, sin asignar memoria en el bucle.

import Foundation

/// Lo que la acción necesita de una detección ya fusionada: hacia dónde, qué es y
/// cuánto se fía el detector. La caja no se mira; IOS-23 hará que la detección del
/// soporte cumpla esto sin que este módulo sepa qué es una caja.
public protocol ActionSighting {
    var direction: RigDirection { get }
    var playerClass: PlayerClass { get }
    var score: Double { get }
}

/// El `PlayerEvidence` de §16.2 en ángulos.
public struct PlayerEvidence: Equatable, Sendable {
    /// El punto de atención: hacia dónde debería mirar la cámara.
    public let direction: RigDirection
    /// Cuánto ocupan los jugadores en yaw, en radianes: decide cómo de abierto va el plano.
    public let spreadRad: Double
    /// Jugadores de campo que sostienen la estimación, sin porteros ni árbitros.
    public let players: Int
    /// Segunda moda entre la primera, de 0 a 1: alta es un campo partido en dos grupos.
    public let bimodality: Double
    /// De 0 a 1; tope 0.80 mientras falte el campo de convergencia.
    public let confidence: Double

    public init(
        direction: RigDirection,
        spreadRad: Double,
        players: Int,
        bimodality: Double,
        confidence: Double
    ) {
        self.direction = direction
        self.spreadRad = spreadRad
        self.players = players
        self.bimodality = bimodality
        self.confidence = confidence
    }

    /// Incertidumbre del punto de atención, para la fusión por precisión de §17.2.
    public var sigmaRad: Double {
        RigConstants.actionBaseSigmaRad / max(confidence, RigConstants.actionConfidenceFloor)
    }
}

/// El estimador con sus búferes de trabajo. No es seguro entre hilos: uno por bucle
/// del director.
public final class ActionEstimator {
    public let bandwidthRad: Double
    public let stepRad: Double
    public let minPlayers: Int

    private var yaws: [Double] = []
    private var pitches: [Double] = []
    private var weights: [Double] = []
    private var grid: [Double] = []
    private var density: [Double] = []

    /// `playerCapacity` es el máximo de detecciones por ciclo que el llamante espera;
    /// la rejilla se reserva para el yaw entero (±π más los márgenes del núcleo), que
    /// es la cota física. Pasarse de cualquiera de los dos no falla: crece una vez y
    /// a partir de ahí vuelve a no asignar.
    public init(
        playerCapacity: Int,
        bandwidthRad: Double = RigConstants.actionKdeBandwidthRad,
        stepRad: Double = RigConstants.actionKdeStepRad,
        minPlayers: Int = RigConstants.actionMinPlayers
    ) {
        precondition(bandwidthRad > 0 && stepRad > 0, "el ancho de banda y el paso deben ser positivos")
        self.bandwidthRad = bandwidthRad
        self.stepRad = stepRad
        self.minPlayers = minPlayers
        yaws.reserveCapacity(playerCapacity)
        pitches.reserveCapacity(playerCapacity)
        weights.reserveCapacity(playerCapacity)
        let celdas = Int(((2 * Double.pi + 6 * bandwidthRad) / stepRad).rounded(.up)) + 2
        grid.reserveCapacity(celdas)
        density.reserveCapacity(celdas)
    }

    /// El punto de atención de un ciclo, o `nil` si no hay jugadores que lo sostengan.
    /// `nil` no es un error: es «no tengo nada que decir», y el director se queda
    /// donde estaba.
    public func evidence<S: ActionSighting>(from sightings: [S]) -> PlayerEvidence? {
        yaws.removeAll(keepingCapacity: true)
        pitches.removeAll(keepingCapacity: true)
        weights.removeAll(keepingCapacity: true)
        for sighting in sightings where sighting.playerClass == .player && sighting.score > 0 {
            yaws.append(sighting.direction.yawRad)
            pitches.append(sighting.direction.pitchRad)
            weights.append(sighting.score)
        }
        guard yaws.count >= minPlayers else { return nil }

        Self.fillDensity(
            yaws: yaws, weights: weights, bandwidthRad: bandwidthRad, stepRad: stepRad,
            grid: &grid, density: &density
        )
        // argmax de numpy: a igualdad gana el PRIMERO.
        var peak = 0
        for i in 1..<density.count where density[i] > density[peak] {
            peak = i
        }
        let bimodality = Self.bimodality(
            grid: grid, density: density, peak: peak,
            separationRad: RigConstants.actionModeSeparationRad
        )

        // El centro se refina con la media de los que caen bajo la moda, no con la
        // celda: el punto de atención se mueve de forma continua.
        var sumaPeso = 0.0
        var sumaYaw = 0.0
        var sumaPitch = 0.0
        for i in 0..<yaws.count where abs(yaws[i] - grid[peak]) <= bandwidthRad {
            sumaPeso += weights[i]
            sumaYaw += yaws[i] * weights[i]
            sumaPitch += pitches[i] * weights[i]
        }

        // La dispersión, en cambio, es de todos.
        var pesoTotal = 0.0
        var sumaTodos = 0.0
        for i in 0..<yaws.count {
            pesoTotal += weights[i]
            sumaTodos += yaws[i] * weights[i]
        }
        let media = sumaTodos / pesoTotal
        var sumaCuadrados = 0.0
        for i in 0..<yaws.count {
            let d = yaws[i] - media
            sumaCuadrados += d * d * weights[i]
        }

        let plantilla = min(Double(yaws.count) / Double(RigConstants.actionFullSquad), 1.0)
        let confidence = min(
            1.0,
            RigConstants.actionConfidenceBase
                + RigConstants.actionConfidencePerSquad * plantilla
                + RigConstants.actionConfidencePerUnimodal * (1.0 - bimodality)
        )
        return PlayerEvidence(
            direction: RigDirection(yawRad: sumaYaw / sumaPeso, pitchRad: sumaPitch / sumaPeso),
            spreadRad: (sumaCuadrados / pesoTotal).squareRoot(),
            players: yaws.count,
            bimodality: bimodality,
            confidence: confidence
        )
    }

    /// La densidad de jugadores a lo largo del yaw (paso 4 de §16.2), núcleo
    /// gaussiano. Asigna su salida: es la versión para pruebas y herramientas; el
    /// bucle usa el estimador.
    public static func yawDensity(
        yaws: [Double],
        weights: [Double],
        bandwidthRad: Double = RigConstants.actionKdeBandwidthRad,
        stepRad: Double = RigConstants.actionKdeStepRad
    ) -> (grid: [Double], density: [Double]) {
        precondition(bandwidthRad > 0 && stepRad > 0, "el ancho de banda y el paso deben ser positivos")
        var grid: [Double] = []
        var density: [Double] = []
        fillDensity(
            yaws: yaws, weights: weights, bandwidthRad: bandwidthRad, stepRad: stepRad,
            grid: &grid, density: &density
        )
        return (grid, density)
    }

    private static func fillDensity(
        yaws: [Double],
        weights: [Double],
        bandwidthRad: Double,
        stepRad: Double,
        grid: inout [Double],
        density: inout [Double]
    ) {
        let margin = 3.0 * bandwidthRad
        let start = yaws.min()! - margin
        let stop = yaws.max()! + margin + stepRad
        // np.arange: longitud ceil((stop − start)/step), y los valores como los rellena
        // numpy, start + i·delta con delta = (start + step) − start, no con step.
        let count = Int(((stop - start) / stepRad).rounded(.up))
        let delta = (start + stepRad) - start
        grid.removeAll(keepingCapacity: true)
        density.removeAll(keepingCapacity: true)
        for i in 0..<count {
            let celda = i == 0 ? start : (i == 1 ? start + stepRad : start + Double(i) * delta)
            grid.append(celda)
            var suma = 0.0
            for j in 0..<yaws.count {
                let gap = (celda - yaws[j]) / bandwidthRad
                suma += weights[j] * exp(-0.5 * (gap * gap))
            }
            density.append(suma)
        }
    }

    /// Cuánto pesa el segundo grupo frente al primero. Segundo grupo es OTRA moda, y
    /// lo bastante lejos: la cola de un grupo compacto o dos cimas de la misma
    /// cresta no son un campo partido.
    private static func bimodality(
        grid: [Double], density: [Double], peak: Int, separationRad: Double
    ) -> Double {
        guard density[peak] > 0, density.count >= 3 else { return 0 }
        var mejor: Double?
        for i in 1..<(density.count - 1)
        where density[i] > density[i - 1] && density[i] >= density[i + 1]
            && abs(grid[i] - grid[peak]) >= separationRad
        {
            mejor = max(mejor ?? density[i], density[i])
        }
        guard let mejor else { return 0 }
        return mejor / density[peak]
    }
}
