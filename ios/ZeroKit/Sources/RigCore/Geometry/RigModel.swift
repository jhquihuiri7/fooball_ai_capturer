// Las dos cámaras como un único sistema angular (IOS-30, réplica de rig.py).
//
// La fusión de detecciones NO está aquí: llega con IOS-32. Este fichero es la
// geometría —directionOf, project, sees, inOverlap— y el códec de rig.json v1,
// que va en coordenadas ENDEREZADAS (como --flip left del servidor).

import Foundation

/// Una de las dos cámaras: cómo ve y hacia dónde mira.
public struct RigCamera: Equatable, Sendable {
    public let intrinsics: CameraIntrinsics
    public let pose: CameraPose

    public init(intrinsics: CameraIntrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics
        self.pose = pose
    }
}

public struct RigModel: Sendable {
    /// Versión del formato de rig.json. Se sube cuando cambia el SIGNIFICADO de un
    /// campo: leer una calibración con otro significado apuntaría las cámaras a otro
    /// sitio sin dar error.
    public static let fileVersion = 1

    private let cameras: [CameraSide: RigCamera]
    /// Precalculadas: esto corre por detección y construir senos y cosenos por punto
    /// no cabe en el camino caliente.
    private let rotations: [CameraSide: Mat3]

    public init(left: RigCamera, right: RigCamera) {
        cameras = [.left: left, .right: right]
        rotations = [.left: left.pose.matrix(), .right: right.pose.matrix()]
    }

    public func camera(_ side: CameraSide) -> RigCamera {
        cameras[side]!
    }

    /// Rotación cámara → soporte, para el cálculo por tabla que no puede llamar a
    /// `directionOf` por píxel.
    public func rotation(_ side: CameraSide) -> Mat3 {
        rotations[side]!
    }

    /// El mismo soporte con otra pose para una de las cámaras. Devuelve un modelo
    /// nuevo: el que ya circula lo comparten detector, fusión y render.
    public func withPose(_ side: CameraSide, pose: CameraPose) -> RigModel {
        let nueva = RigCamera(intrinsics: camera(side).intrinsics, pose: pose)
        switch side {
        case .left: return RigModel(left: nueva, right: camera(.right))
        case .right: return RigModel(left: camera(.left), right: nueva)
        }
    }

    /// Hacia dónde mira un píxel de una de las cámaras, en ejes del soporte.
    public func directionOf(_ side: CameraSide, xPx: Double, yPx: Double) -> RigDirection {
        let intr = camera(side).intrinsics
        let ray = Vec3((xPx - intr.cx) / intr.fx, (yPx - intr.cy) / intr.fy, 1.0)
        let rotated = rotations[side]!.applied(to: ray)
        return RigDirection(
            yawRad: atan2(rotated.x, rotated.z),
            pitchRad: atan2(-rotated.y, (rotated.x * rotated.x + rotated.z * rotated.z).squareRoot())
        )
    }

    /// Píxel donde cae esa dirección, o `nil` si queda detrás. Devuelve el píxel
    /// aunque esté fuera del encuadre: eso lo decide `sees`, y al planificador de
    /// ROIs le importa que algo cayera 20 px fuera del borde.
    public func project(_ side: CameraSide, direction: RigDirection) -> (x: Double, y: Double)? {
        let inCamera = rotations[side]!.transposed.applied(to: direction.toUnit())
        guard inCamera.z > 0 else { return nil }
        let intr = camera(side).intrinsics
        return (
            intr.fx * inCamera.x / inCamera.z + intr.cx,
            intr.fy * inCamera.y / inCamera.z + intr.cy
        )
    }

    /// `project` y `sees` a la vez para un haz de rayos en ejes del soporte, sin
    /// normalizar (la proyección divide por z y la norma se va). Los píxeles de los
    /// rayos con `inside == false` no significan nada.
    public func projectRays(
        _ side: CameraSide, rays: [Vec3]
    ) -> (xPx: [Double], yPx: [Double], inside: [Bool]) {
        let intr = camera(side).intrinsics
        let rt = rotations[side]!.transposed
        var xs = [Double](repeating: 0, count: rays.count)
        var ys = [Double](repeating: 0, count: rays.count)
        var dentro = [Bool](repeating: false, count: rays.count)
        for (indice, ray) in rays.enumerated() {
            let inCamera = rt.applied(to: ray)
            let front = inCamera.z > 0
            let safeZ = front ? inCamera.z : 1.0
            let x = intr.fx * inCamera.x / safeZ + intr.cx
            let y = intr.fy * inCamera.y / safeZ + intr.cy
            xs[indice] = x
            ys[indice] = y
            dentro[indice] =
                front
                && x >= 0 && x <= Double(intr.width - 1)
                && y >= 0 && y <= Double(intr.height - 1)
        }
        return (xs, ys, dentro)
    }

    /// `true` si esa dirección cae dentro del encuadre de esa cámara.
    public func sees(_ side: CameraSide, direction: RigDirection) -> Bool {
        guard let pixel = project(side, direction: direction) else { return false }
        let intr = camera(side).intrinsics
        return pixel.x >= 0 && pixel.x < Double(intr.width)
            && pixel.y >= 0 && pixel.y < Double(intr.height)
    }

    /// `true` si las dos cámaras la ven: la zona de la costura.
    public func inOverlap(_ direction: RigDirection) -> Bool {
        sees(.left, direction: direction) && sees(.right, direction: direction)
    }
}

// MARK: - Códec de rig.json, versión 1

extension RigModel {
    public func toDictionary() -> [String: Any] {
        func lado(_ cam: RigCamera) -> [String: Any] {
            [
                "intrinsics": [
                    "fx": cam.intrinsics.fx,
                    "fy": cam.intrinsics.fy,
                    "cx": cam.intrinsics.cx,
                    "cy": cam.intrinsics.cy,
                    "width": cam.intrinsics.width,
                    "height": cam.intrinsics.height,
                ],
                "pose": [
                    "yaw_rad": cam.pose.yawRad,
                    "pitch_rad": cam.pose.pitchRad,
                    "roll_rad": cam.pose.rollRad,
                ],
            ]
        }
        return [
            "version": Self.fileVersion,
            "left": lado(camera(.left)),
            "right": lado(camera(.right)),
        ]
    }

    /// Inversa de `toDictionary`. Otra versión se rechaza, no se adivina.
    public static func fromDictionary(_ data: [String: Any]) throws -> RigModel {
        guard let version = data["version"] as? Int, version == fileVersion else {
            throw RigError.message(
                "version de soporte no soportada: \(String(describing: data["version"])) "
                    + "(se espera \(fileVersion))"
            )
        }
        func lado(_ raw: Any?) throws -> RigCamera {
            guard let dict = raw as? [String: Any],
                  let intr = dict["intrinsics"] as? [String: Any],
                  let pose = dict["pose"] as? [String: Any]
            else {
                throw RigError.message("cada camara del soporte debe ser un objeto con intrinsics y pose")
            }
            func numero(_ fuente: [String: Any], _ clave: String) throws -> Double {
                guard let valor = fuente[clave] as? Double ?? (fuente[clave] as? Int).map(Double.init)
                else { throw RigError.message("falta \(clave) en el soporte") }
                return valor
            }
            return try RigCamera(
                intrinsics: CameraIntrinsics(
                    fx: numero(intr, "fx"),
                    fy: numero(intr, "fy"),
                    cx: numero(intr, "cx"),
                    cy: numero(intr, "cy"),
                    width: Int(numero(intr, "width")),
                    height: Int(numero(intr, "height"))
                ),
                pose: CameraPose(
                    yawRad: numero(pose, "yaw_rad"),
                    pitchRad: numero(pose, "pitch_rad"),
                    rollRad: numero(pose, "roll_rad")
                )
            )
        }
        return try RigModel(left: lado(data["left"]), right: lado(data["right"]))
    }

    /// Carga un rig.json (el `soporte.json` que deja la calibración del pod).
    public static func load(from url: URL) throws -> RigModel {
        let data = try Data(contentsOf: url)
        guard let crudo = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RigError.message("\(url.lastPathComponent): no es un objeto JSON")
        }
        return try fromDictionary(crudo)
    }
}
