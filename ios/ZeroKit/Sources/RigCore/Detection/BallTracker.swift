// El seguimiento del balón en una cámara (IOS-28): réplica de `BallTracker` y
// `fuse_estimates` de libs/vision/ball_kalman.py (REF-28, ADR 0020), congelada en ball.json.
//
// Cada móvil sigue el balón en los píxeles nativos de SU cámara, a 30 fps, con lo que dan
// las 2 ROIs a 15 Hz y la búsqueda global (IOS-74). El orden de un fotograma, que fijan
// los dorados:
//
// 1. `predict(dtS:)` hasta el fotograma;
// 2. `rois(groups:)`: las ventanas que el detector mira en él (BallRoiPlanner);
// 3. `update(_:)` solo si en ese fotograma corrió un detector, con todo lo que dieron
//    juntas las ROIs y la búsqueda global. Un fotograma sin detector no es una pérdida.
//
// La edad de la pista se acumula en Double sumando cada dt y caduca al pasar ESTRICTAMENTE
// de `ballLostAfterS`: quince fotogramas de 1/30 suman 0,49999999999999994 y caduca en el
// 16. En Float suman 0,5 justos, y con `>=` caducaría en el 15.

import Foundation

/// La máquina de §13.3 reducida a tres estados (REF-28).
public enum BallKalmanState: String, Sendable {
    /// El último ciclo de detección aceptó una.
    case tracking = "TRACKING"
    /// Hay pista, pero el último ciclo no aceptó nada: manda la predicción.
    case coasting = "COASTING"
    /// Sin pista confirmada. Puede haber una candidata esperando a que la confirmen.
    case lost = "LOST"
}

/// Una detección del balón en píxeles nativos de una cámara. El heatmap no mide la caja.
public struct BallDetection: Equatable, Sendable {
    public let xPx: Double
    public let yPx: Double
    public let score: Double
    /// La ROI del ciclo de la que salió, para auditar el planificador.
    public let roiId: Int
    public let source: BallRoiSource

    public init(xPx: Double, yPx: Double, score: Double, roiId: Int = 0, source: BallRoiSource = .sweep) {
        self.xPx = xPx
        self.yPx = yPx
        self.score = score
        self.roiId = roiId
        self.source = source
    }
}

/// Dónde está el balón en una cámara, en píxeles nativos de esa cámara.
public struct BallEstimate: Equatable, Sendable {
    public let state: BallKalmanState
    public let xPx: Double
    public let yPx: Double
    public let vxPxS: Double
    public let vyPxS: Double
    public let varXPx2: Double
    public let varYPx2: Double
    /// 0..1. El score de la mejor detección aceptada, decayendo sin detecciones.
    public let confidence: Double
    /// Segundos desde la última detección que tomó el filtro.
    public let ageS: Double

    public init(
        state: BallKalmanState, xPx: Double, yPx: Double, vxPxS: Double = 0, vyPxS: Double = 0,
        varXPx2: Double, varYPx2: Double, confidence: Double, ageS: Double
    ) {
        self.state = state
        self.xPx = xPx
        self.yPx = yPx
        self.vxPxS = vxPxS
        self.vyPxS = vyPxS
        self.varXPx2 = varXPx2
        self.varYPx2 = varYPx2
        self.confidence = confidence
        self.ageS = ageS
    }
}

/// El balón en una cámara: el filtro, la máquina reducida de §13.3 y las ROIs del ciclo.
///
/// - TRACKING o COASTING lo decide el último ciclo de detección, no un temporizador.
/// - Salir de LOST pide dos detecciones: la primera abre una candidata (el filtro nace en
///   ella, el estado sigue en LOST y la búsqueda global a 10 Hz) y la confirma otra que
///   caiga en su puerta. Si en un ciclo ninguna cae, la sustituye la de más score.
/// - Sin una detección aceptada durante más de `ballLostAfterS`, la pista o la candidata
///   se tiran.
public struct BallTracker: Sendable {
    public let width: Int
    public let height: Int
    public let roiSides: [Int]
    public let maxRois: Int
    public private(set) var state: BallKalmanState = .lost
    private var filter: BallKalman?
    private var ageS: Double = 0
    private var confidence: Double = 0

    public init(
        width: Int, height: Int,
        roiSides: [Int] = BallRoiPlanner.defaultSides,
        maxRois: Int = DetectionSpec.ballMaxRoisPerCycleMobile
    ) throws {
        guard width > 0, height > 0, maxRois > 0, !roiSides.isEmpty else {
            throw RigError.message(
                "cámara de \(width)x\(height), \(maxRois) ROIs y lados \(roiSides): "
                    + "hacen falta área, alguna ROI y algún lado con export"
            )
        }
        self.width = width
        self.height = height
        self.roiSides = roiSides
        self.maxRois = maxRois
    }

    /// La cadencia de la búsqueda global que pide el estado (ADR 0020): la normal con
    /// pista; la de balón perdido sin ella, también con una candidata sin confirmar.
    public var globalSearchHz: Int {
        state == .lost ? DetectionSpec.ballGlobalLostHz : DetectionSpec.ballGlobalHz
    }

    /// La pista o la candidata (con estado LOST), o nil si no hay ninguna.
    public func estimate() -> BallEstimate? {
        guard let f = filter else { return nil }
        return BallEstimate(
            state: state, xPx: f.x.positionPx, yPx: f.y.positionPx,
            vxPxS: f.x.velocityPxS, vyPxS: f.y.velocityPxS,
            varXPx2: f.x.varPosPx2, varYPx2: f.y.varPosPx2,
            confidence: confidence, ageS: ageS
        )
    }

    /// Avanza hasta el fotograma siguiente; la pista caduca si lleva demasiado sin ver el
    /// balón. La confianza decae como conf·exp(−dt/τ).
    public mutating func predict(dtS: Double) throws {
        guard dtS >= 0 else { throw RigError.message("el seguimiento no va hacia atrás: dt = \(dtS) s") }
        guard filter != nil else { return }
        try filter!.predict(dtS: dtS)
        ageS += dtS
        confidence *= exp(-dtS / DetectionSpec.ballConfidenceTauS)
        if ageS > DetectionSpec.ballLostAfterS {
            filter = nil
            state = .lost
            ageS = 0
            confidence = 0
        }
    }

    /// Un ciclo de detección, con todo lo que dieron las ROIs y la búsqueda global.
    ///
    /// Con pista, gana la de menor d²/score dentro de la puerta (§13.2) y el estado pasa a
    /// TRACKING; si ninguna entra, a COASTING, y las de fuera no tocan nada. Sin pista, la
    /// de más score abre una candidata. Devuelve el índice en `detections` de la que tomó
    /// el filtro, o nil.
    @discardableResult
    public mutating func update(_ detections: [BallDetection]) -> Int? {
        guard var f = filter else { return open(detections) }
        guard let elegida = Self.gated(f, detections) else {
            if state == .lost { return open(detections) }
            state = .coasting
            return nil
        }
        f.update(xPx: detections[elegida].xPx, yPx: detections[elegida].yPx)
        filter = f
        ageS = 0
        confidence = max(confidence, detections[elegida].score)
        state = .tracking
        return elegida
    }

    /// Las ROIs del ciclo, ya dentro del frame y todas del mismo lado (un lote): la
    /// predicción y el grupo de jugadores más cercano (centros en píxeles nativos de esta
    /// cámara), o sin filtro los primeros grupos.
    public func rois(groups: [(x: Double, y: Double)] = []) -> [BallRoi] {
        BallRoiPlanner.plan(
            prediction: filter.map { (x: $0.x.positionPx, y: $0.y.positionPx, sigmaPx: $0.positionSigmaPx) },
            groups: groups, sides: roiSides, maxRois: maxRois, width: width, height: height
        )
    }

    /// Abre (o sustituye) la candidata en la detección de más score; a igualdad, la primera.
    private mutating func open(_ detections: [BallDetection]) -> Int? {
        var mejor: Int?
        for (i, d) in detections.enumerated() where d.score > 0 {
            if mejor == nil || d.score > detections[mejor!].score { mejor = i }
        }
        guard let mejor else { return nil }
        // Las desviaciones por defecto son válidas: el init no puede fallar aquí.
        filter = try? BallKalman(xPx: detections[mejor].xPx, yPx: detections[mejor].yPx)
        state = .lost
        ageS = 0
        confidence = detections[mejor].score
        return mejor
    }

    /// La de menor d²/score dentro de la puerta; a igualdad, la primera.
    private static func gated(_ f: BallKalman, _ detections: [BallDetection]) -> Int? {
        var elegida: Int?
        var mejor = Double.infinity
        for (i, d) in detections.enumerated() where d.score > 0 {
            let d2 = f.mahalanobis2(xPx: d.xPx, yPx: d.yPx)
            guard d2 < DetectionSpec.ballGateChi2 else { continue }
            let coste = d2 / d.score
            if coste < mejor { (elegida, mejor) = (i, coste) }
        }
        return elegida
    }
}

extension RigModel {
    /// El balón del soporte a partir de lo que sigue cada cámara (`fuse_estimates`).
    ///
    /// Entran las pistas confirmadas (TRACKING o COASTING), predichas al mismo instante del
    /// soporte —eso es de quien llama—, con su confianza de score y la clave 0 (izquierda)
    /// o 1 (derecha). Si las dos ven el mismo balón a menos de `maxAngleRad`, sale el punto
    /// medio; si no, la de más confianza. nil si ninguna cámara tiene pista.
    public func fuseBall(
        _ estimates: [CameraSide: BallEstimate],
        maxAngleRad: Double = DetectionSpec.rigFuseMaxAngleRad
    ) -> FusedObservation? {
        let observaciones = [CameraSide.left, .right].enumerated().compactMap { clave, lado -> Observation? in
            guard let e = estimates[lado], e.state != .lost else { return nil }
            return Observation(side: lado, xPx: e.xPx, yPx: e.yPx, score: e.confidence, key: clave)
        }
        return fuse(observaciones, maxAngleRad: maxAngleRad).first
    }
}
