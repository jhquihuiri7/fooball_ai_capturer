// Álgebra 3×3 en Double, sin simd (IOS-30).
//
// Es la réplica de las cuentas de numpy en rig.py del servidor: mismas fórmulas y
// mismo orden de operaciones, que es lo que mantiene a los dorados dentro de la
// tolerancia. simd queda fuera a propósito: RigCore es Foundation puro (decisión 17
// del plan) y el fusionado de float de simd puede reordenar lo que numpy no reordena.

import Foundation

/// Un vector columna de 3 en ejes del soporte o de la cámara.
public struct Vec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    public func scaled(by factor: Double) -> Vec3 {
        Vec3(x * factor, y * factor, z * factor)
    }

    public func dot(_ other: Vec3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public var norm: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Una matriz 3×3 por filas, como el ndarray de numpy que replica.
public struct Mat3: Equatable, Sendable {
    /// Las nueve celdas, fila a fila: m[fila][columna] es `values[fila * 3 + columna]`.
    public var values: [Double]

    public init(rows values: [Double]) {
        precondition(values.count == 9, "una Mat3 lleva 9 celdas, no \(values.count)")
        self.values = values
    }

    public static let identity = Mat3(rows: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double {
        get { values[row * 3 + column] }
        set { values[row * 3 + column] = newValue }
    }

    public var transposed: Mat3 {
        Mat3(rows: [
            values[0], values[3], values[6],
            values[1], values[4], values[7],
            values[2], values[5], values[8],
        ])
    }

    /// `self · other`, en el mismo orden que `a @ b` de numpy.
    public func multiplied(by other: Mat3) -> Mat3 {
        var out = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                out[row * 3 + column] =
                    values[row * 3] * other.values[column]
                    + values[row * 3 + 1] * other.values[3 + column]
                    + values[row * 3 + 2] * other.values[6 + column]
            }
        }
        return Mat3(rows: out)
    }

    /// `self · v`, como `matriz @ vector` de numpy.
    public func applied(to v: Vec3) -> Vec3 {
        Vec3(
            values[0] * v.x + values[1] * v.y + values[2] * v.z,
            values[3] * v.x + values[4] * v.y + values[5] * v.z,
            values[6] * v.x + values[7] * v.y + values[8] * v.z
        )
    }

    /// Norma de Frobenius, como `np.linalg.norm` sin argumentos sobre una 3×3.
    public var frobeniusNorm: Double {
        values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    /// Determinante por cofactores de la primera fila.
    public var determinant: Double {
        values[0] * (values[4] * values[8] - values[5] * values[7])
            - values[1] * (values[3] * values[8] - values[5] * values[6])
            + values[2] * (values[3] * values[7] - values[4] * values[6])
    }

    /// La inversa por la adjugada. Quien quiera un umbral de invertibilidad con
    /// sentido lo comprueba antes sobre la matriz NORMALIZADA (PitchModel lo hace):
    /// aquí solo se rechaza el determinante exactamente cero.
    public func inverted() throws -> Mat3 {
        let det = determinant
        guard det != 0 else {
            throw RigError.message("la matriz es singular: no tiene inversa")
        }
        let adjugate = [
            values[4] * values[8] - values[5] * values[7],
            values[2] * values[7] - values[1] * values[8],
            values[1] * values[5] - values[2] * values[4],
            values[5] * values[6] - values[3] * values[8],
            values[0] * values[8] - values[2] * values[6],
            values[2] * values[3] - values[0] * values[5],
            values[3] * values[7] - values[4] * values[6],
            values[1] * values[6] - values[0] * values[7],
            values[0] * values[4] - values[1] * values[3],
        ]
        return Mat3(rows: adjugate.map { $0 / det })
    }
}
