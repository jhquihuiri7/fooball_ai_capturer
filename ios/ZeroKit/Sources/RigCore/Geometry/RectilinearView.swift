// El encuadre de la cámara virtual (IOS-31, réplica de reprojection.py).
//
// Una pinhole sin distorsión centrada en el soporte, con el mismo convenio de ejes
// que las físicas. SIN roll: el horizonte del programa se mantiene recto pase lo
// que pase, que es lo primero que delata a una transmisión amateur. El alto no
// lleva su propio campo de visión: sale del ancho y de la relación de aspecto.

import Foundation

public struct RectilinearView: Equatable, Sendable {
    public let yawRad: Double
    public let pitchRad: Double
    public let hfovRad: Double
    public let width: Int
    public let height: Int

    public init(yawRad: Double, pitchRad: Double, hfovRad: Double, width: Int, height: Int) throws {
        guard hfovRad > 0, hfovRad < .pi else {
            throw RigError.message("el campo de visión debe estar en (0, π): \(hfovRad)")
        }
        guard width > 0, height > 0 else {
            throw RigError.message("el tamaño de la salida debe ser positivo: \(width)×\(height)")
        }
        guard pitchRad > -.pi / 2, pitchRad < .pi / 2 else {
            throw RigError.message("el pitch debe estar en (-π/2, π/2): \(pitchRad)")
        }
        self.yawRad = yawRad
        self.pitchRad = pitchRad
        self.hfovRad = hfovRad
        self.width = width
        self.height = height
    }

    /// Distancia focal de la cámara virtual, en píxeles de la salida.
    public var focalPx: Double {
        (Double(width) / 2.0) / tan(hfovRad / 2.0)
    }

    /// Campo de visión vertical, que se deriva y no se elige.
    public var vfovRad: Double {
        2.0 * atan((Double(height) / 2.0) / focalPx)
    }

    /// La orientación como pose del soporte, para compartir convenio con las físicas.
    public var pose: CameraPose {
        CameraPose(yawRad: yawRad, pitchRad: pitchRad, rollRad: 0)
    }

    /// El mismo encuadre más abierto o más cerrado. Es el zoom.
    public func withHfov(_ hfovRad: Double) throws -> RectilinearView {
        try RectilinearView(
            yawRad: yawRad, pitchRad: pitchRad, hfovRad: hfovRad, width: width, height: height
        )
    }

    /// El mismo plano apuntado a otro sitio. Es el movimiento de cámara.
    public func lookingAt(_ direction: RigDirection) throws -> RectilinearView {
        try RectilinearView(
            yawRad: direction.yawRad,
            pitchRad: direction.pitchRad,
            hfovRad: hfovRad,
            width: width,
            height: height
        )
    }

    /// Hacia dónde mira un píxel del programa, en ejes del soporte. El medio píxel
    /// pone el centro del programa en el borde entre los dos píxeles centrales.
    public func directionAt(xPx: Double, yPx: Double) -> RigDirection {
        let ray = Vec3(
            (xPx + 0.5 - Double(width) / 2.0) / focalPx,
            (yPx + 0.5 - Double(height) / 2.0) / focalPx,
            1.0
        )
        let rotated = pose.matrix().applied(to: ray)
        return RigDirection(
            yawRad: atan2(rotated.x, rotated.z),
            pitchRad: atan2(-rotated.y, (rotated.x * rotated.x + rotated.z * rotated.z).squareRoot())
        )
    }

    /// `true` si esa dirección cae dentro del encuadre. `margin` descuenta esa
    /// fracción del cuadro por cada lado: con el METRIC_FRAME_MARGIN de §38.3 mide
    /// «cabe con holgura», que es lo que pide *action in frame*.
    public func contains(_ direction: RigDirection, margin: Double = 0) throws -> Bool {
        guard margin >= 0, margin < 0.5 else {
            throw RigError.message("el margen debe estar en [0, 0.5): \(margin)")
        }
        let inView = pose.matrix().transposed.applied(to: direction.toUnit())
        guard inView.z > 0 else { return false }
        let xPx = focalPx * inView.x / inView.z + Double(width) / 2.0
        let yPx = focalPx * inView.y / inView.z + Double(height) / 2.0
        let bordeX = margin * Double(width)
        let bordeY = margin * Double(height)
        return xPx >= bordeX && xPx < Double(width) - bordeX
            && yPx >= bordeY && yPx < Double(height) - bordeY
    }
}
