// El muelle de un eje de la cámara virtual (IOS-34, réplica de la mitad de arriba de
// libs/vision/director.py, §18.3).
//
// Un paso hace seis cosas y en este orden: limita la velocidad del objetivo, aplica
// la zona muerta con histéresis, modula la rigidez por urgencia, aplica la ley PD con
// la aceleración acotada, suma el muro blando e integra con velocidad y posición
// acotadas. ζ = 1: llega lo más rápido posible sin pasarse, porque cualquier rebote
// el ojo lo lee como un error de quien opera.

import Foundation

/// Cómo se comporta un eje, en ángulos. Un muelle no sabe si mueve el yaw o el zoom:
/// los valores de cada eje están en `AxisParams.yaw/pitch/hfov`.
public struct AxisParams: Equatable, Sendable {
    public let fnBaseHz: Double
    public let fnUrgentGainHz: Double
    public let zeta: Double
    public let vMaxRadS: Double
    public let aMaxRadS2: Double
    /// Lo deprisa que puede moverse el OBJETIVO, no la cámara (paso 1).
    public let targetSlewRadS: Double
    /// Error que engancha el seguimiento, como fracción del plano.
    public let deadOutFrac: Double
    /// Error que lo suelta. Menor que el anterior: esa diferencia es la histéresis.
    public let deadInFrac: Double
    public let wallMarginFrac: Double

    public init(
        fnBaseHz: Double,
        fnUrgentGainHz: Double,
        zeta: Double,
        vMaxRadS: Double,
        aMaxRadS2: Double,
        targetSlewRadS: Double,
        deadOutFrac: Double,
        deadInFrac: Double,
        wallMarginFrac: Double
    ) throws {
        guard fnBaseHz > 0 else {
            throw RigError.message("la frecuencia natural debe ser positiva: \(fnBaseHz)")
        }
        guard zeta > 0 else {
            throw RigError.message("el amortiguamiento debe ser positivo: \(zeta)")
        }
        guard vMaxRadS > 0, aMaxRadS2 > 0 else {
            throw RigError.message("los topes deben ser positivos: \(vMaxRadS), \(aMaxRadS2)")
        }
        guard targetSlewRadS > 0 else {
            throw RigError.message("el límite del objetivo debe ser positivo: \(targetSlewRadS)")
        }
        guard deadInFrac >= 0, deadInFrac <= deadOutFrac else {
            throw RigError.message(
                "la zona muerta de salida no puede ser menor que la de entrada: "
                    + "\(deadOutFrac) < \(deadInFrac). Sin esa diferencia no hay "
                    + "histéresis y la cámara tiembla en la frontera"
            )
        }
        guard wallMarginFrac >= 0 else {
            throw RigError.message("el margen del muro no puede ser negativo: \(wallMarginFrac)")
        }
        self.fnBaseHz = fnBaseHz
        self.fnUrgentGainHz = fnUrgentGainHz
        self.zeta = zeta
        self.vMaxRadS = vMaxRadS
        self.aMaxRadS2 = aMaxRadS2
        self.targetSlewRadS = targetSlewRadS
        self.deadOutFrac = deadOutFrac
        self.deadInFrac = deadInFrac
        self.wallMarginFrac = wallMarginFrac
    }

    // Los valores de las constantes generadas son válidos por construcción, y el
    // test de los parámetros por eje lo comprueba: por eso el `try!`.
    public static let yaw = try! AxisParams(
        fnBaseHz: RigConstants.directorYawFnBaseHz,
        fnUrgentGainHz: RigConstants.directorYawUrgentGainHz,
        zeta: RigConstants.directorZeta,
        vMaxRadS: RigConstants.directorYawVMaxRadS,
        aMaxRadS2: RigConstants.directorYawAMaxRadS2,
        targetSlewRadS: RigConstants.directorYawSlewRadS,
        deadOutFrac: RigConstants.directorYawDeadOutFrac,
        deadInFrac: RigConstants.directorYawDeadInFrac,
        wallMarginFrac: RigConstants.directorYawWallMarginFrac
    )

    public static let pitch = try! AxisParams(
        fnBaseHz: RigConstants.directorPitchFnBaseHz,
        fnUrgentGainHz: RigConstants.directorPitchUrgentGainHz,
        zeta: RigConstants.directorZeta,
        vMaxRadS: RigConstants.directorPitchVMaxRadS,
        aMaxRadS2: RigConstants.directorPitchAMaxRadS2,
        targetSlewRadS: RigConstants.directorPitchSlewRadS,
        deadOutFrac: RigConstants.directorPitchDeadOutFrac,
        deadInFrac: RigConstants.directorPitchDeadInFrac,
        wallMarginFrac: RigConstants.directorPitchWallMarginFrac
    )

    /// El zoom no tiene histéresis: una sola fracción para entrar y salir.
    public static let hfov = try! AxisParams(
        fnBaseHz: RigConstants.directorHfovFnBaseHz,
        fnUrgentGainHz: RigConstants.directorHfovUrgentGainHz,
        zeta: RigConstants.directorZeta,
        vMaxRadS: RigConstants.directorHfovVMaxRadS,
        aMaxRadS2: RigConstants.directorHfovAMaxRadS2,
        targetSlewRadS: RigConstants.directorHfovSlewRadS,
        deadOutFrac: RigConstants.directorHfovDeadFrac,
        deadInFrac: RigConstants.directorHfovDeadFrac,
        wallMarginFrac: RigConstants.directorHfovWallMarginFrac
    )
}

/// Dónde está el eje, a qué velocidad y a qué persigue.
public struct AxisState: Equatable, Sendable {
    public var positionRad: Double
    public var velocityRadS: Double
    /// El objetivo YA limitado en velocidad: lo que el muelle persigue de verdad.
    public var targetRad: Double
    /// El latch de la histéresis del paso 2.
    public var engaged: Bool

    public init(
        positionRad: Double, velocityRadS: Double = 0, targetRad: Double = 0, engaged: Bool = false
    ) {
        self.positionRad = positionRad
        self.velocityRadS = velocityRadS
        self.targetRad = targetRad
        self.engaged = engaged
    }

    /// Un eje quieto donde se le diga, sin nada que perseguir todavía.
    public static func at(_ positionRad: Double) -> AxisState {
        AxisState(positionRad: positionRad, velocityRadS: 0, targetRad: positionRad)
    }
}

/// `max(low, min(high, value))`, en el mismo orden que el `_clamp` de la referencia.
@inline(__always)
func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    max(low, min(high, value))
}

/// Un paso del muelle sobre un eje: §18.3 entera. `scaleRad` es el tamaño del plano en
/// este eje y convierte las fracciones en ángulos; `limits`, hasta dónde puede llegar
/// sin salirse de lo que las cámaras ven.
public func integrateAxis(
    _ state: AxisState,
    targetRad: Double,
    params: AxisParams,
    dtS: Double,
    scaleRad: Double,
    limits: (low: Double, high: Double),
    urgency: Double = 0
) throws -> AxisState {
    guard dtS > 0 else { throw RigError.message("el paso de tiempo debe ser positivo: \(dtS)") }
    guard scaleRad > 0 else {
        throw RigError.message("el tamaño del plano debe ser positivo: \(scaleRad)")
    }
    let (low, high) = limits
    guard low <= high else { throw RigError.message("límites al revés: [\(low), \(high)]") }

    // 1) El objetivo no salta, y se recorta a lo alcanzable.
    let paso = params.targetSlewRadS * dtS
    let objetivo = clamp(
        clamp(targetRad, low, high), state.targetRad - paso, state.targetRad + paso
    )

    // 2) Zona muerta con histéresis.
    let (error, engaged) = deadZone(
        objetivo - state.positionRad,
        engaged: state.engaged,
        deadIn: params.deadInFrac * scaleRad,
        deadOut: params.deadOutFrac * scaleRad
    )

    // 3) Rigidez modulada por la urgencia.
    let omega = 2.0 * Double.pi * (params.fnBaseHz + clamp(urgency, 0, 1) * params.fnUrgentGainHz)

    // 4) Muelle con amortiguador, con la aceleración acotada.
    var aceleracion = clamp(
        omega * omega * error - 2.0 * params.zeta * omega * state.velocityRadS,
        -params.aMaxRadS2,
        params.aMaxRadS2
    )

    // 5) Muro blando, fuera del recorte de aMax a propósito.
    aceleracion += softWall(
        position: state.positionRad,
        velocity: state.velocityRadS,
        low: low,
        high: high,
        margin: params.wallMarginFrac * scaleRad,
        omega: omega
    )

    // 6) Integración; contra el tope la velocidad se anula (sin windup).
    var velocidad = clamp(state.velocityRadS + aceleracion * dtS, -params.vMaxRadS, params.vMaxRadS)
    var posicion = state.positionRad + velocidad * dtS
    if !(low <= posicion && posicion <= high) {
        posicion = clamp(posicion, low, high)
        velocidad = 0
    }
    return AxisState(
        positionRad: posicion, velocityRadS: velocidad, targetRad: objetivo, engaged: engaged
    )
}

/// Se engancha con `deadOut` y se suelta con `deadIn`, menor. Se descuenta la zona
/// muerta del error para que al enganchar la fuerza arranque de cero.
private func deadZone(
    _ errorRad: Double, engaged: Bool, deadIn: Double, deadOut: Double
) -> (Double, Bool) {
    let magnitud = abs(errorRad)
    var enganchado = engaged
    if !enganchado && magnitud > deadOut {
        enganchado = true
    } else if enganchado && magnitud < deadIn {
        enganchado = false
    }
    guard enganchado else { return (0, false) }
    return (errorRad - Double(signOf: errorRad, magnitudeOf: deadIn), true)
}

/// Un amortiguador cerca del borde: solo se opone al movimiento hacia fuera, y en
/// reposo calla, para que un objetivo legítimo pegado al límite se alcance.
private func softWall(
    position: Double, velocity: Double, low: Double, high: Double, margin: Double, omega: Double
) -> Double {
    guard margin > 0 else { return 0 }
    let profundidad: Double
    if velocity > 0 && position > high - margin {
        profundidad = min((position - (high - margin)) / margin, 1.0)
    } else if velocity < 0 && position < low + margin {
        profundidad = min(((low + margin) - position) / margin, 1.0)
    } else {
        return 0
    }
    return -RigConstants.directorWallDamping * omega * velocity * profundidad
}
