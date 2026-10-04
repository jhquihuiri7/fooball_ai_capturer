// Geometría del soporte: intrínsecas, pose y dirección (IOS-30, réplica de rig.py).
//
// Las dos lentes comparten prácticamente el mismo centro óptico, así que la relación
// entre las dos imágenes es una ROTACIÓN pura y existe un único sistema de coordenadas
// angulares —el del soporte— donde las dos cámaras son una sola de ~190°. Los dorados
// de REF-11 congelan cada fórmula; aquí no se decide nada, se replica.

import Foundation

/// Cuál de las dos cámaras del soporte.
public enum CameraSide: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

public enum RigError: Error, CustomStringConvertible, Sendable {
    case message(String)
    public var description: String {
        switch self { case let .message(text): return text }
    }
}

/// Modelo pinhole de una cámara, en píxeles, con la distorsión ya corregida.
public struct CameraIntrinsics: Equatable, Sendable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let width: Int
    public let height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) throws {
        guard fx > 0, fy > 0 else {
            throw RigError.message("la focal debe ser positiva: fx=\(fx), fy=\(fy)")
        }
        guard width > 0, height > 0 else {
            throw RigError.message("tamaño de imagen inválido: \(width)×\(height)")
        }
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Las mismas intrínsecas para la imagen reescalada por `factor`.
    ///
    /// Con la convención de que el centro del píxel está en `.5`: ignorarlo desplaza
    /// el centro óptico medio píxel, que la estabilización lee como oscilación.
    public func scaled(_ factor: Double) throws -> CameraIntrinsics {
        guard factor > 0 else {
            throw RigError.message("el factor de escala debe ser positivo: \(factor)")
        }
        return try CameraIntrinsics(
            fx: fx * factor,
            fy: fy * factor,
            cx: (cx + 0.5) * factor - 0.5,
            cy: (cy + 0.5) * factor - 0.5,
            width: max(1, Int((Double(width) * factor).rounded(.toNearestOrEven))),
            height: max(1, Int((Double(height) * factor).rounded(.toNearestOrEven)))
        )
    }

    /// Intrínsecas aproximadas desde el campo de visión horizontal (~106° la ultra
    /// gran angular). Para dimensionar y para tests; para cerrar una costura, no.
    public static func fromHfov(width: Int, height: Int, hfovRad: Double) throws -> CameraIntrinsics {
        guard hfovRad > 0, hfovRad < .pi else {
            throw RigError.message("el HFOV debe estar en (0, π): \(hfovRad)")
        }
        let focal = (Double(width) / 2.0) / tan(hfovRad / 2.0)
        return try CameraIntrinsics(
            fx: focal,
            fy: focal,
            cx: Double(width) / 2.0,
            cy: Double(height) / 2.0,
            width: width,
            height: height
        )
    }
}

/// Orientación de una cámara dentro del soporte, en radianes.
///
/// Ejes del soporte: X a la derecha, Y hacia abajo, Z hacia delante. `roll` es lo que
/// casi nunca es cero de verdad: el soporte se sujeta con gomas.
public struct CameraPose: Equatable, Sendable {
    public let yawRad: Double
    public let pitchRad: Double
    public let rollRad: Double

    public init(yawRad: Double = 0, pitchRad: Double = 0, rollRad: Double = 0) {
        self.yawRad = yawRad
        self.pitchRad = pitchRad
        self.rollRad = rollRad
    }

    /// Rotación cámara → soporte: `R_yaw · R_pitch · R_roll`, como en el servidor.
    public func matrix() -> Mat3 {
        let cy = cos(yawRad), sy = sin(yawRad)
        let cp = cos(pitchRad), sp = sin(pitchRad)
        let cr = cos(rollRad), sr = sin(rollRad)
        let rYaw = Mat3(rows: [cy, 0, sy, 0, 1, 0, -sy, 0, cy])
        let rPitch = Mat3(rows: [1, 0, 0, 0, cp, -sp, 0, sp, cp])
        let rRoll = Mat3(rows: [cr, -sr, 0, sr, cr, 0, 0, 0, 1])
        return rYaw.multiplied(by: rPitch).multiplied(by: rRoll)
    }

    /// Inversa de `matrix()`: sin ambigüedad mientras el pitch no llegue a ±90°,
    /// que un soporte mirando al campo nunca alcanza.
    public static func fromMatrix(_ rotation: Mat3) -> CameraPose {
        let pitch = asin(min(1.0, max(-1.0, -rotation[1, 2])))
        let yaw = atan2(rotation[0, 2], rotation[2, 2])
        let roll = atan2(rotation[1, 0], rotation[1, 1])
        return CameraPose(yawRad: yaw, pitchRad: pitch, rollRad: roll)
    }
}

/// Una dirección en el sistema del soporte: el sustituto del píxel con dos cámaras.
/// `yaw` 0 es el frente y crece a la derecha; `pitch` es positivo hacia arriba.
public struct RigDirection: Equatable, Sendable {
    public let yawRad: Double
    public let pitchRad: Double

    public init(yawRad: Double, pitchRad: Double) {
        self.yawRad = yawRad
        self.pitchRad = pitchRad
    }

    /// Vector unitario equivalente, en ejes del soporte.
    public func toUnit() -> Vec3 {
        let cp = cos(pitchRad)
        return Vec3(cp * sin(yawRad), -sin(pitchRad), cp * cos(yawRad))
    }
}

/// Ángulo entre dos direcciones del soporte, en radianes.
public func angularDistanceRad(_ a: RigDirection, _ b: RigDirection) -> Double {
    let dot = a.toUnit().dot(b.toUnit())
    return acos(min(1.0, max(-1.0, dot)))
}
