// Los tres ejes montados (IOS-34, réplica de la mitad de abajo de director.py, de la
// parte de CylindricalCanvas.fit que da la cobertura y de tightest_servable_hfov_rad).
//
// El acoplamiento que hace de tres muelles una cámara: el zoom se integra PRIMERO,
// porque de cuánto esté abierto el plano dependen los límites del paneo y el tamaño de
// sus zonas muertas. El remapeo del lienzo no cruza: en el móvil no hay panorama, solo
// su cobertura.

import Foundation

/// La extensión angular del lienzo cilíndrico: lo que el soporte abarca.
public struct CylindricalCanvas: Equatable, Sendable {
    public let focalPx: Double
    public let yawMinRad: Double
    public let yawMaxRad: Double
    public let pitchMinRad: Double
    public let pitchMaxRad: Double

    public init(
        focalPx: Double, yawMinRad: Double, yawMaxRad: Double, pitchMinRad: Double, pitchMaxRad: Double
    ) throws {
        guard focalPx > 0 else {
            throw RigError.message("la focal del lienzo debe ser positiva: \(focalPx)")
        }
        guard yawMinRad < yawMaxRad else {
            throw RigError.message("rango de yaw vacío: [\(yawMinRad), \(yawMaxRad)]")
        }
        let limite = Double.pi / 2
        guard -limite < pitchMinRad, pitchMinRad < pitchMaxRad, pitchMaxRad < limite else {
            throw RigError.message(
                "rango de pitch inválido: [\(pitchMinRad), \(pitchMaxRad)]. Un cilindro no llega a ±90°"
            )
        }
        self.focalPx = focalPx
        self.yawMinRad = yawMinRad
        self.yawMaxRad = yawMaxRad
        self.pitchMinRad = pitchMinRad
        self.pitchMaxRad = pitchMaxRad
    }

    public var width: Int { Int(((yawMaxRad - yawMinRad) * focalPx).rounded(.up)) }

    public var height: Int {
        Int(((tan(pitchMaxRad) - tan(pitchMinRad)) * focalPx).rounded(.up))
    }

    /// El lienzo más pequeño que contiene las imágenes enteras de `sides`. Con las dos
    /// es el `fit` de la referencia; con una sola, el modo degradado cuando una cámara
    /// se ha caído y la cámara virtual no puede apuntar a lo que ya no se ve.
    public static func fit(
        _ rig: RigModel,
        focalPx: Double? = nil,
        pitchLimitsRad: (low: Double, high: Double)? = nil,
        sides: [CameraSide] = CameraSide.allCases
    ) throws -> CylindricalCanvas {
        precondition(!sides.isEmpty, "hace falta al menos una cámara")
        let muestras = RigConstants.panoramaFitEdgeSamples
        // np.linspace(0, 1, n): i·paso, con el último forzado a 1 exacto.
        let pasoBorde = 1.0 / Double(muestras - 1)
        let borde = (0..<muestras).map { $0 == muestras - 1 ? 1.0 : Double($0) * pasoBorde }

        var yawMin = Double.infinity
        var yawMax = -Double.infinity
        var pitchMin = Double.infinity
        var pitchMax = -Double.infinity
        for side in sides {
            let intr = rig.camera(side).intrinsics
            let w = Double(intr.width - 1)
            let h = Double(intr.height - 1)
            var puntos: [(Double, Double)] = []
            puntos += borde.map { ($0 * w, 0.0) }
            puntos += borde.map { ($0 * w, h) }
            puntos += borde.map { (0.0, $0 * h) }
            puntos += borde.map { (w, $0 * h) }
            for (x, y) in puntos {
                let d = rig.directionOf(side, xPx: x, yPx: y)
                yawMin = min(yawMin, d.yawRad)
                yawMax = max(yawMax, d.yawRad)
                pitchMin = min(pitchMin, d.pitchRad)
                pitchMax = max(pitchMax, d.pitchRad)
            }
        }

        let focal = focalPx ?? sides.map { rig.camera($0).intrinsics.fx }.reduce(0, +)
            / Double(sides.count)
        let margen = RigConstants.panoramaFitMarginPx / focal
        var bajo = atan(tan(pitchMin) - margen)
        var alto = atan(tan(pitchMax) + margen)
        if let pitchLimitsRad {
            bajo = max(bajo, pitchLimitsRad.low)
            alto = min(alto, pitchLimitsRad.high)
        }
        return try CylindricalCanvas(
            focalPx: focal,
            yawMinRad: yawMin - margen,
            yawMaxRad: yawMax + margen,
            pitchMinRad: bajo,
            pitchMaxRad: alto
        )
    }
}

/// El plano más cerrado que la lente sirve sin ampliar píxeles: manda la focal más
/// pequeña de las dos cámaras, porque el encuadre puede caer en cualquiera.
public func tightestServableHfovRad(_ rig: RigModel, programWidth: Int) -> Double {
    let focal = min(rig.camera(.left).intrinsics.fx, rig.camera(.right).intrinsics.fx)
    return 2.0 * atan(Double(programWidth) / (2.0 * focal))
}

/// Hasta dónde puede llegar la cámara virtual sin salirse de lo que las cámaras ven.
/// El margen de paneo depende de cuánto esté abierto el plano.
public struct CameraLimits: Equatable, Sendable {
    public let yawLow: Double
    public let yawHigh: Double
    public let pitchLow: Double
    public let pitchHigh: Double
    public let hfovLow: Double
    public let hfovHigh: Double

    public init(
        yawRad: (Double, Double), pitchRad: (Double, Double), hfovRad: (Double, Double)
    ) throws {
        guard yawRad.0 <= yawRad.1 else {
            throw RigError.message("límites de yaw al revés: [\(yawRad.0), \(yawRad.1)]")
        }
        guard pitchRad.0 <= pitchRad.1 else {
            throw RigError.message("límites de pitch al revés: [\(pitchRad.0), \(pitchRad.1)]")
        }
        guard hfovRad.0 > 0 else {
            throw RigError.message("el plano más cerrado debe ser positivo: \(hfovRad.0)")
        }
        guard hfovRad.0 <= hfovRad.1 else {
            // Pasa de verdad: la lente pone el mínimo y la cobertura el máximo, y con
            // una lente muy ancha o una banda estrecha no hay ningún encuadre bueno.
            throw RigError.message(
                "no hay ningún plano que valga: la lente no sirve nada por debajo de "
                    + "\(hfovRad.0) rad y en la cobertura no cabe nada por encima de "
                    + "\(hfovRad.1) rad. Quien decida tiene que elegir entre ampliar y enseñar negro"
            )
        }
        yawLow = yawRad.0
        yawHigh = yawRad.1
        pitchLow = pitchRad.0
        pitchHigh = pitchRad.1
        hfovLow = hfovRad.0
        hfovHigh = hfovRad.1
    }

    /// Los límites de un lienzo sobre una salida de proporción `aspect` (alto/ancho).
    /// Lo que aprieta el máximo suele ser el alto: un plano abierto en 16:9 pide mucho
    /// campo vertical.
    public static func fromCanvas(
        _ canvas: CylindricalCanvas, hfovMinRad: Double, hfovMaxRad: Double, aspect: Double
    ) throws -> CameraLimits {
        guard aspect > 0 else {
            throw RigError.message("la proporción de la salida debe ser positiva: \(aspect)")
        }
        let cabeALoAlto = 2.0 * atan(tan((canvas.pitchMaxRad - canvas.pitchMinRad) / 2.0) / aspect)
        return try CameraLimits(
            yawRad: (canvas.yawMinRad, canvas.yawMaxRad),
            pitchRad: (canvas.pitchMinRad, canvas.pitchMaxRad),
            hfovRad: (
                hfovMinRad,
                min(hfovMaxRad, canvas.yawMaxRad - canvas.yawMinRad, cabeALoAlto)
            )
        )
    }

    /// Dónde puede quedar el centro del encuadre para que el encuadre entero quepa.
    public func yawRange(_ hfovRad: Double) -> (low: Double, high: Double) {
        Self.centredRange(yawLow, yawHigh, hfovRad)
    }

    public func pitchRange(_ vfovRad: Double) -> (low: Double, high: Double) {
        Self.centredRange(pitchLow, pitchHigh, vfovRad)
    }

    /// Si la ventana no cabe, el rango colapsa al centro: el negro se reparte por
    /// igual a los dos lados en vez de apilarse en uno.
    private static func centredRange(
        _ low: Double, _ high: Double, _ extent: Double
    ) -> (low: Double, high: Double) {
        if high - low <= extent {
            let medio = (low + high) / 2.0
            return (medio, medio)
        }
        let mitad = extent / 2.0
        return (low + mitad, high - mitad)
    }
}

/// Lleva la cámara virtual desde donde está hasta donde el director quiere (§18).
public final class VirtualCameraEngine {
    public let limits: CameraLimits
    public private(set) var view: RectilinearView
    public private(set) var yaw: AxisState
    public private(set) var pitch: AxisState
    public private(set) var hfov: AxisState

    public init(view: RectilinearView, limits: CameraLimits) {
        self.limits = limits
        self.view = view
        yaw = .at(view.yawRad)
        pitch = .at(view.pitchRad)
        hfov = .at(view.hfovRad)
    }

    /// `true` cuando ningún eje está persiguiendo nada: la cámara quieta.
    public var settled: Bool { !(yaw.engaged || pitch.engaged || hfov.engaged) }

    /// Un paso de los tres ejes. `target` o `hfovRad` a `nil` es «no tengo nada que
    /// decir»: se sigue persiguiendo el último, así que un movimiento en curso termina
    /// de frenar en vez de cortarse en seco.
    @discardableResult
    public func step(
        target: RigDirection?, hfovRad: Double?, dtS: Double, urgency: Double = 0
    ) throws -> RectilinearView {
        hfov = try integrateAxis(
            hfov,
            targetRad: hfovRad ?? hfov.targetRad,
            params: .hfov,
            dtS: dtS,
            scaleRad: hfov.positionRad,
            limits: (limits.hfovLow, limits.hfovHigh),
            urgency: urgency
        )
        let plano = try view.withHfov(hfov.positionRad)

        yaw = try integrateAxis(
            yaw,
            targetRad: target?.yawRad ?? yaw.targetRad,
            params: .yaw,
            dtS: dtS,
            scaleRad: plano.hfovRad,
            limits: limits.yawRange(plano.hfovRad),
            urgency: urgency
        )
        pitch = try integrateAxis(
            pitch,
            targetRad: target?.pitchRad ?? pitch.targetRad,
            params: .pitch,
            dtS: dtS,
            scaleRad: plano.vfovRad,
            limits: limits.pitchRange(plano.vfovRad),
            urgency: urgency
        )
        view = try plano.lookingAt(RigDirection(yawRad: yaw.positionRad, pitchRad: pitch.positionRad))
        return view
    }
}
