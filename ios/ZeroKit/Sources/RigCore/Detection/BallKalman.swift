// El filtro del balón (IOS-28): réplica de `AxisFilter` y `BallKalman` de
// libs/vision/ball_kalman.py (REF-28, ADR 0020), congelada en ball.json.
//
// Velocidad constante en los píxeles nativos de cada cámara, con los ejes x e y
// independientes, predicción a 30 fps y la puerta de Mahalanobis. La máquina de estados,
// las ROIs y la fusión van en BallTracker y BallRoiPlanner.

import Foundation

/// Un eje del filtro: posición, velocidad y su covarianza 2×2 simétrica. Las cuentas van
/// en el mismo orden que la referencia.
public struct BallAxisFilter: Equatable, Sendable {
    public var positionPx: Double
    public var velocityPxS: Double
    public var varPosPx2: Double
    public var covPosVelPx2S: Double
    public var varVelPx2S2: Double

    /// x ← F·x y P ← F·P·Fᵀ + Q, con F = [[1, dt], [0, 1]] y la aceleración blanca a
    /// trozos: Q = a²·[[dt⁴/4, dt³/2], [dt³/2, dt²]].
    mutating func predict(dtS: Double, accelVar: Double) {
        let dt2 = dtS * dtS
        positionPx += velocityPxS * dtS
        varPosPx2 += 2.0 * dtS * covPosVelPx2S + dt2 * varVelPx2S2 + accelVar * dt2 * dt2 / 4.0
        covPosVelPx2S += dtS * varVelPx2S2 + accelVar * dt2 * dtS / 2.0
        varVelPx2S2 += accelVar * dt2
    }

    /// S = P₀₀ + R: la varianza de lo que se espera medir en este eje.
    func innovationVar(_ measVar: Double) -> Double { varPosPx2 + measVar }

    /// La medida de la posición, con K = P·Hᵀ/S y P ← (I − K·H)·P.
    mutating func update(measuredPx: Double, measVar: Double) {
        let s = innovationVar(measVar)
        let kPos = varPosPx2 / s
        let kVel = covPosVelPx2S / s
        let innovation = measuredPx - positionPx
        positionPx += kPos * innovation
        velocityPxS += kVel * innovation
        varVelPx2S2 -= kVel * covPosVelPx2S
        covPosVelPx2S *= 1.0 - kPos
        varPosPx2 *= 1.0 - kPos
    }
}

/// Velocidad constante en los píxeles nativos de una cámara, con los ejes independientes:
/// la medida es el centro y su ruido es el mismo en x y en y, así que la covarianza no los
/// cruza. Nace en una detección con velocidad cero y la incertidumbre de lo más rápido que
/// se ve el balón; con la segunda medida ya la tiene.
public struct BallKalman: Equatable, Sendable {
    public private(set) var x: BallAxisFilter
    public private(set) var y: BallAxisFilter
    private let accelVar: Double
    private let measVar: Double

    public init(
        xPx: Double, yPx: Double,
        accelStdPxS2: Double = DetectionSpec.ballKfAccelStdPxS2,
        measStdPx: Double = DetectionSpec.ballKfMeasStdPx,
        initSpeedStdPxS: Double = DetectionSpec.ballKfInitSpeedStdPxS
    ) throws {
        guard accelStdPxS2 >= 0, measStdPx > 0, initSpeedStdPxS > 0 else {
            throw RigError.message(
                "aceleración \(accelStdPxS2), medida \(measStdPx) y velocidad inicial \(initSpeedStdPxS): "
                    + "las desviaciones no pueden ser negativas ni las dos últimas cero"
            )
        }
        accelVar = accelStdPxS2 * accelStdPxS2
        measVar = measStdPx * measStdPx
        let varVel = initSpeedStdPxS * initSpeedStdPxS
        x = BallAxisFilter(positionPx: xPx, velocityPxS: 0, varPosPx2: measVar, covPosVelPx2S: 0, varVelPx2S2: varVel)
        y = BallAxisFilter(positionPx: yPx, velocityPxS: 0, varPosPx2: measVar, covPosVelPx2S: 0, varVelPx2S2: varVel)
    }

    /// √traza de la covarianza de la posición, en px: la incertidumbre de §12.5.
    public var positionSigmaPx: Double { (x.varPosPx2 + y.varPosPx2).squareRoot() }

    /// Avanza el filtro `dtS` segundos.
    public mutating func predict(dtS: Double) throws {
        guard dtS >= 0 else { throw RigError.message("el filtro no va hacia atrás: dt = \(dtS) s") }
        x.predict(dtS: dtS, accelVar: accelVar)
        y.predict(dtS: dtS, accelVar: accelVar)
    }

    /// d² = yᵀ·S⁻¹·y de una medida frente a la predicción (§13.2).
    public func mahalanobis2(xPx: Double, yPx: Double) -> Double {
        let dx = xPx - x.positionPx
        let dy = yPx - y.positionPx
        return dx * dx / x.innovationVar(measVar) + dy * dy / y.innovationVar(measVar)
    }

    /// Corrige con un centro medido, sin mirar la puerta: eso es de quien llama.
    public mutating func update(xPx: Double, yPx: Double) {
        x.update(measuredPx: xPx, measVar: measVar)
        y.update(measuredPx: yPx, measVar: measVar)
    }
}
