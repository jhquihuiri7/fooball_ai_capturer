// La homografía del campo en el móvil (IOS-36, réplica de libs/vision/pitch.py).
//
// Aquí SOLO se aplica: el ajuste desde correspondencias (RANSAC, colinealidad,
// errores de reproyección) se queda en Python, en el VPS, que es quien produce
// pitch.json. El móvil lo carga, proyecta en los dos sentidos y filtra los pies
// que no pisan el campo. `imageToPitch` supone z=0 —lo que se proyecta está
// apoyado en el suelo—, y de ahí la decisión CV-1 de §11.1: el balón nunca pasa
// por aquí; los jugadores sí, porque no vuelan.

import Foundation

/// Homografía campo↔imagen de UNA cámara, con su inversa y las dimensiones de la
/// cancha. Los metros llevan el origen en el centro del campo (§11.1).
public struct PitchModel: Sendable {
    public static let fileVersion = 1

    /// 3×3, campo (m) → imagen (px). La `H` de §11.1.
    public let homography: Mat3
    /// 3×3, imagen (px) → campo (m). Válida solo para z=0.
    public let homographyInverse: Mat3
    public let pitchLengthM: Double
    public let pitchWidthM: Double
    /// Error medio con el que calibró el VPS; aquí solo se transporta.
    public let reprojectionErrorPx: Double

    public init(
        homography: Mat3,
        pitchLengthM: Double = RigConstants.pitchLengthM,
        pitchWidthM: Double = RigConstants.pitchWidthM,
        reprojectionErrorPx: Double = 0
    ) throws {
        // El determinante se mide sobre la matriz normalizada porque una homografía
        // está definida salvo escala: sin normalizar, multiplicar H por 0.01
        // dividiría su determinante por un millón sin que el modelo cambiara.
        let norm = homography.frobeniusNorm
        let normalizada = Mat3(rows: homography.values.map { $0 / norm })
        guard norm > 0, abs(normalizada.determinant) >= RigConstants.pitchMinHomographyDet
        else {
            throw RigError.message(
                "la homografia no es invertible: revisa los puntos de calibracion"
            )
        }
        self.homography = homography
        self.homographyInverse = try homography.inverted()
        self.pitchLengthM = pitchLengthM
        self.pitchWidthM = pitchWidthM
        self.reprojectionErrorPx = reprojectionErrorPx
    }

    /// Metros del campo a píxeles de la imagen.
    public func pitchToImage(xM: Double, yM: Double) throws -> (x: Double, y: Double) {
        try Self.project(homography, x: xM, y: yM)
    }

    /// Píxeles de la imagen a metros del campo, **suponiendo z=0**.
    public func imageToPitch(xPx: Double, yPx: Double) throws -> (x: Double, y: Double) {
        try Self.project(homographyInverse, x: xPx, y: yPx)
    }

    /// El filtro de pies que sustituye a la máscara de mapa de bits de §14.2: el
    /// pie a metros y contra el rectángulo del campo con margen. Un punto sin
    /// proyección finita (el horizonte o más allá) no pisa ningún césped.
    public func isInsidePlayable(
        xPx: Double,
        yPx: Double,
        marginM: Double = RigConstants.pitchPlayableMarginM
    ) -> Bool {
        guard let metros = try? imageToPitch(xPx: xPx, yPx: yPx) else { return false }
        return abs(metros.x) <= pitchLengthM / 2 + marginM
            && abs(metros.y) <= pitchWidthM / 2 + marginM
    }

    private static func project(
        _ matrix: Mat3, x: Double, y: Double
    ) throws -> (x: Double, y: Double) {
        let homogeneous = matrix.applied(to: Vec3(x, y, 1))
        guard abs(homogeneous.z) >= RigConstants.pitchMinProjectiveW else {
            throw RigError.message(
                "el punto (\(x), \(y)) cae sobre la linea del horizonte: no tiene imagen finita"
            )
        }
        return (homogeneous.x / homogeneous.z, homogeneous.y / homogeneous.z)
    }
}

/// Un mismo punto del césped marcado en las dos cámaras al calibrar (ADR 0012).
/// Se transporta porque es la prueba de que las dos homografías contaban la misma
/// historia; el móvil no lo necesita para proyectar.
public struct SharedGroundPoint: Equatable, Sendable {
    public let leftXPx: Double
    public let leftYPx: Double
    public let rightXPx: Double
    public let rightYPx: Double

    public init(leftXPx: Double, leftYPx: Double, rightXPx: Double, rightYPx: Double) {
        self.leftXPx = leftXPx
        self.leftYPx = leftYPx
        self.rightXPx = rightXPx
        self.rightYPx = rightYPx
    }
}

/// Una homografía por cámara sobre el MISMO origen: el centro del campo. Es lo que
/// hace que un jugador que cruza la costura conserve su posición en metros.
public struct RigPitchModel: Sendable {
    public let left: PitchModel
    public let right: PitchModel
    public let sharedPoints: [SharedGroundPoint]

    public init(
        left: PitchModel, right: PitchModel, sharedPoints: [SharedGroundPoint] = []
    ) throws {
        guard left.pitchLengthM == right.pitchLengthM,
              left.pitchWidthM == right.pitchWidthM
        else {
            throw RigError.message(
                "las dos camaras describen canchas distintas: "
                    + "(\(left.pitchLengthM), \(left.pitchWidthM)) m la izquierda y "
                    + "(\(right.pitchLengthM), \(right.pitchWidthM)) m la derecha. "
                    + "El soporte mira un solo campo"
            )
        }
        self.left = left
        self.right = right
        self.sharedPoints = sharedPoints
    }

    public func model(_ side: CameraSide) -> PitchModel {
        side == .left ? left : right
    }

    public func imageToPitch(
        _ side: CameraSide, xPx: Double, yPx: Double
    ) throws -> (x: Double, y: Double) {
        try model(side).imageToPitch(xPx: xPx, yPx: yPx)
    }

    public func pitchToImage(
        _ side: CameraSide, xM: Double, yM: Double
    ) throws -> (x: Double, y: Double) {
        try model(side).pitchToImage(xM: xM, yM: yM)
    }

    /// Distancia, en metros, entre donde cada cámara sitúa el mismo punto del suelo.
    public func crossCameraErrorM(_ point: SharedGroundPoint) throws -> Double {
        let izquierda = try imageToPitch(.left, xPx: point.leftXPx, yPx: point.leftYPx)
        let derecha = try imageToPitch(.right, xPx: point.rightXPx, yPx: point.rightYPx)
        return hypot(izquierda.x - derecha.x, izquierda.y - derecha.y)
    }

    /// Desacuerdo medio entre las dos cámaras. Sin puntos, 0.
    public func meanCrossCameraErrorM(_ points: [SharedGroundPoint]) throws -> Double {
        guard !points.isEmpty else { return 0 }
        var total = 0.0
        for point in points {
            total += try crossCameraErrorM(point)
        }
        return total / Double(points.count)
    }
}

// MARK: - Códec de pitch.json, versión 1

extension PitchModel {
    /// La inversa no se guarda: se recalcula al leer, y así el fichero no puede
    /// llevar dos matrices que no casen (igual que en el VPS).
    public func toDictionary() -> [String: Any] {
        [
            "version": Self.fileVersion,
            "homography": (0..<3).map { fila in (0..<3).map { self.homography[fila, $0] } },
            "pitch_length_m": pitchLengthM,
            "pitch_width_m": pitchWidthM,
            "reprojection_error_px": reprojectionErrorPx,
        ]
    }

    /// Inversa de `toDictionary`. Otra versión se rechaza, no se adivina.
    public static func fromDictionary(_ data: [String: Any]) throws -> PitchModel {
        guard let version = data["version"] as? Int, version == fileVersion else {
            throw RigError.message(
                "version de calibracion no soportada: \(String(describing: data["version"])) "
                    + "(se espera \(fileVersion))"
            )
        }
        guard let filas = data["homography"] as? [Any], filas.count == 3 else {
            throw RigError.message("pitch.json: la homografia debe ser 3 filas de 3 numeros")
        }
        var valores: [Double] = []
        for cruda in filas {
            guard let fila = cruda as? [Any], fila.count == 3 else {
                throw RigError.message("pitch.json: la homografia debe ser 3 filas de 3 numeros")
            }
            for celda in fila {
                guard let numero = celda as? Double ?? (celda as? Int).map(Double.init) else {
                    throw RigError.message("pitch.json: la homografia lleva una celda que no es numero")
                }
                valores.append(numero)
            }
        }
        return try PitchModel(
            homography: Mat3(rows: valores),
            pitchLengthM: dimension(data, "pitch_length_m"),
            pitchWidthM: dimension(data, "pitch_width_m"),
            reprojectionErrorPx: dimension(data, "reprojection_error_px", minimo: 0)
        )
    }

    /// Un número de pitch.json, con el campo en el mensaje si no lo es. El mínimo
    /// por defecto rechaza dimensiones nulas o negativas, como la referencia.
    private static func dimension(
        _ data: [String: Any], _ clave: String, minimo: Double = 1e-9
    ) throws -> Double {
        guard let valor = data[clave] as? Double ?? (data[clave] as? Int).map(Double.init),
              valor >= minimo
        else {
            throw RigError.message(
                "pitch.json: `\(clave)` tiene que ser un numero (>= \(minimo)) y es "
                    + String(describing: data[clave])
            )
        }
        return valor
    }
}

extension RigPitchModel {
    /// Lanza si un punto compartido cae sobre el horizonte de alguna cámara, igual
    /// que el `to_dict` de la referencia: `cross_error_m` se recalcula al escribir.
    public func toDictionary() throws -> [String: Any] {
        [
            "version": PitchModel.fileVersion,
            "left": left.toDictionary(),
            "right": right.toDictionary(),
            "shared_points": try sharedPoints.map { punto in
                [
                    "left_xy_px": [punto.leftXPx, punto.leftYPx],
                    "right_xy_px": [punto.rightXPx, punto.rightYPx],
                    "cross_error_m": try crossCameraErrorM(punto),
                ] as [String: Any]
            },
        ]
    }

    /// El `cross_error_m` guardado es informativo: se recalcula de las homografías,
    /// que son la verdad.
    public static func fromDictionary(_ data: [String: Any]) throws -> RigPitchModel {
        guard let version = data["version"] as? Int, version == PitchModel.fileVersion else {
            throw RigError.message(
                "version de calibracion no soportada: \(String(describing: data["version"])) "
                    + "(se espera \(PitchModel.fileVersion))"
            )
        }
        func lado(_ clave: String) throws -> PitchModel {
            guard let crudo = data[clave] as? [String: Any] else {
                throw RigError.message("pitch.json: falta la camara `\(clave)`")
            }
            return try PitchModel.fromDictionary(crudo)
        }
        let crudos = data["shared_points"] as? [Any] ?? []
        let puntos = try crudos.map { crudo -> SharedGroundPoint in
            guard let objeto = crudo as? [String: Any],
                  let izquierda = par(objeto["left_xy_px"]),
                  let derecha = par(objeto["right_xy_px"])
            else {
                throw RigError.message(
                    "pitch.json: cada punto compartido lleva `left_xy_px` y `right_xy_px` como [x, y]"
                )
            }
            return SharedGroundPoint(
                leftXPx: izquierda.0, leftYPx: izquierda.1,
                rightXPx: derecha.0, rightYPx: derecha.1
            )
        }
        return try RigPitchModel(left: lado("left"), right: lado("right"), sharedPoints: puntos)
    }

    /// Carga el pitch.json que produce la calibración del VPS (REF-30).
    public static func load(from url: URL) throws -> RigPitchModel {
        let data = try Data(contentsOf: url)
        guard let crudo = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RigError.message("\(url.lastPathComponent): no es un objeto JSON")
        }
        return try fromDictionary(crudo)
    }

    private static func par(_ crudo: Any?) -> (Double, Double)? {
        guard let lista = crudo as? [Any], lista.count == 2,
              let x = lista[0] as? Double ?? (lista[0] as? Int).map(Double.init),
              let y = lista[1] as? Double ?? (lista[1] as? Int).map(Double.init)
        else { return nil }
        return (x, y)
    }
}
