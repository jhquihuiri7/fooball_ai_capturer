// Cuándo abrir y cuándo cerrar el plano (IOS-35, réplica de libs/vision/shot.py,
// §20.5).
//
// Lo difícil no son las reglas, es no cambiar de plano todo el rato. Cada cambio se
// gana tres cosas: permanencia en el plano actual, insistencia de la condición nueva
// y asimetría —abrir es mucho más rápido que cerrar, porque quedarse corto cuesta la
// jugada y quedarse ancho solo que se vea lejos—. Sin balón quedan las reglas que se
// leen de los jugadores y del operador.

import Foundation

/// Tamaño de plano. Los valores en crudo son los nombres de la referencia.
public enum ShotSize: String, CaseIterable, Sendable {
    case wide = "WIDE"
    case normal = "NORMAL"
    case attack = "ATTACK"
}

/// Ángulo que ocupan `widthM` metros de campo a `distanceM` de la cámara: el puente
/// entre la tabla de §20.5, en metros, y la cámara virtual, en ángulos.
public func angularWidthRad(widthM: Double, distanceM: Double) throws -> Double {
    guard widthM > 0, distanceM > 0 else {
        throw RigError.message(
            "ancho y distancia tienen que ser positivos: \(widthM) m a \(distanceM) m"
        )
    }
    return 2.0 * atan(widthM / (2.0 * distanceM))
}

/// Cuánto abarca cada plano y a partir de qué dispersión se cambia, en ángulos.
public struct ShotPlan: Equatable, Sendable {
    public let hfovRad: [ShotSize: Double]
    /// Dispersión por debajo de la cual se cierra (regla 7).
    public let tightRad: Double
    /// Dispersión por encima de la cual se abre (regla 5).
    public let stretchedRad: Double

    public init(hfovRad: [ShotSize: Double], tightRad: Double, stretchedRad: Double) throws {
        let faltan = ShotSize.allCases.filter { hfovRad[$0] == nil }
        guard faltan.isEmpty else {
            throw RigError.message("faltan planos en el plan: \(faltan.map(\.rawValue))")
        }
        guard tightRad < stretchedRad else {
            throw RigError.message(
                "los umbrales están cruzados: cerrar por debajo de \(tightRad) y abrir por "
                    + "encima de \(stretchedRad) no deja hueco para el plano normal"
            )
        }
        self.hfovRad = hfovRad
        self.tightRad = tightRad
        self.stretchedRad = stretchedRad
    }

    /// El plan a esa distancia de la jugada, recortado a lo que la lente sirve: un
    /// ATTACK que no cabe sale como el plano más cerrado que sí cabe, nunca blando.
    public static func at(
        distanceM: Double = RigConstants.actionDistanceM,
        hfovMinRad: Double? = nil,
        hfovMaxRad: Double? = nil
    ) throws -> ShotPlan {
        let bajo = hfovMinRad ?? 0
        let alto = hfovMaxRad ?? Double.pi
        guard bajo <= alto else {
            throw RigError.message("no queda ningún plano servible entre \(bajo) y \(alto)")
        }
        let metros: [ShotSize: Double] = [
            .attack: RigConstants.shotTightM,
            .normal: RigConstants.shotStretchedM,
            .wide: RigConstants.shotWideM,
        ]
        var hfov: [ShotSize: Double] = [:]
        for (plano, m) in metros {
            let ancho = try angularWidthRad(widthM: m * RigConstants.shotHeadroom, distanceM: distanceM)
            hfov[plano] = min(max(ancho, bajo), alto)
        }
        return try ShotPlan(
            hfovRad: hfov,
            tightRad: angularWidthRad(widthM: RigConstants.shotTightM, distanceM: distanceM),
            stretchedRad: angularWidthRad(widthM: RigConstants.shotStretchedM, distanceM: distanceM)
        )
    }
}

/// El plano que toca y por qué. La razón es para el panel y la telemetría.
public struct ShotDecision: Equatable, Sendable {
    public let shot: ShotSize
    public let hfovRad: Double
    public let reason: String
    /// `true` solo en el ciclo en que se cambió de plano.
    public let changed: Bool
}

/// Elige el plano ciclo a ciclo. Sin reloj propio: quien la usa le dice cuánto
/// tiempo ha pasado.
public final class ShotGrammar {
    public let plan: ShotPlan
    /// Se arranca abierto: sin haber visto nada, el plano de situación no se equivoca.
    public private(set) var shot: ShotSize

    private var heldS = 0.0
    private var candidate: ShotSize?
    private var candidateS = 0.0
    private var situationS = 0.0
    private var reason = "arranque"

    public init(plan: ShotPlan, shot: ShotSize = .wide) {
        self.plan = plan
        self.shot = shot
    }

    /// Saque de centro o gol: plano de situación durante SHOT_SITUATION_S (regla 3).
    public func markSituation() {
        situationS = RigConstants.shotSituationS
    }

    /// La tabla de §20.5 con las reglas que se leen sin balón. Las urgentes se saltan
    /// la permanencia mínima.
    private func rules(_ evidence: PlayerEvidence?) -> (shot: ShotSize, reason: String, urgent: Bool) {
        if situationS > 0 {
            return (.wide, "situación", true)
        }
        guard let evidence else {
            // Sin saber dónde está la jugada se abre, y con urgencia: seguir cerrado
            // sobre un sitio equivocado es lo peor que puede hacer una cámara.
            return (.wide, "sin jugadores", true)
        }
        if evidence.spreadRad > plan.stretchedRad {
            return (.wide, "equipos estirados", false)
        }
        if evidence.spreadRad < plan.tightRad
            && evidence.confidence >= RigConstants.shotTightConfidence
        {
            return (.attack, "juego concentrado", false)
        }
        return (.normal, "por defecto", false)
    }

    /// El plano de este ciclo.
    public func step(_ evidence: PlayerEvidence?, dtS: Double) throws -> ShotDecision {
        guard dtS > 0 else { throw RigError.message("el paso de tiempo debe ser positivo: \(dtS)") }
        situationS = max(0, situationS - dtS)
        heldS += dtS
        let wanted = rules(evidence)

        if wanted.shot == shot {
            candidate = nil
            candidateS = 0
            reason = wanted.reason
            return decision(changed: false)
        }

        if wanted.shot != candidate {
            candidate = wanted.shot
            candidateS = 0
        }
        candidateS += dtS

        let insistencia = wanted.shot == .wide
            ? RigConstants.shotDwellExitWideS : RigConstants.shotDwellEnterS
        if candidateS < insistencia {
            return decision(changed: false)
        }
        if !wanted.urgent && heldS < RigConstants.shotDwellMinS {
            return decision(changed: false)
        }

        shot = wanted.shot
        reason = wanted.reason
        heldS = 0
        candidate = nil
        candidateS = 0
        return decision(changed: true)
    }

    private func decision(changed: Bool) -> ShotDecision {
        ShotDecision(shot: shot, hfovRad: plan.hfovRad[shot]!, reason: reason, changed: changed)
    }
}
