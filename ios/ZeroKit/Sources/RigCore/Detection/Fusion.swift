// La fusión angular de detecciones (IOS-32, réplica de rig.py fuse).
//
// Se funde POR LOS PIES y en ángulos del soporte, nunca en metros: la rotación pura
// entre las dos lentes vale a cualquier profundidad (ADR 0012). Solo entre cámaras
// DISTINTAS: dos detecciones de la misma imagen son dos objetos, y desduplicar
// dentro de una cámara es del postproceso del detector.

import Foundation

/// Una detección en píxeles de una de las dos cámaras, antes de fusionar.
public struct Observation: Equatable, Sendable {
    public let side: CameraSide
    public let xPx: Double
    public let yPx: Double
    public let score: Double
    /// Identificador que pone quien llama y la fusión devuelve intacto: el camino de
    /// vuelta a la caja original sin que este módulo sepa qué es una caja.
    public let key: Int

    public init(side: CameraSide, xPx: Double, yPx: Double, score: Double = 1, key: Int = 0) {
        self.side = side
        self.xPx = xPx
        self.yPx = yPx
        self.score = score
        self.key = key
    }
}

/// Una detección ya en coordenadas del soporte, vista por una o por las dos cámaras.
public struct FusedObservation: Equatable, Sendable {
    public let direction: RigDirection
    public let score: Double
    /// Con las dos cámaras, cayó en el solape y es la más fiable que hay.
    public let sides: [CameraSide]
    public let keys: [Int]
    /// Paralaje más error de calibración entre las dos observaciones; 0 con una sola.
    /// Si crece por encima de lo que predice la distancia, una pose se ha movido.
    public let separationRad: Double

    public init(
        direction: RigDirection,
        score: Double,
        sides: [CameraSide],
        keys: [Int],
        separationRad: Double = 0
    ) {
        self.direction = direction
        self.score = score
        self.sides = sides
        self.keys = keys
        self.separationRad = separationRad
    }
}

extension RigModel {
    /// Une las detecciones de las dos cámaras en una lista sin duplicados, ordenada
    /// por score descendente (lo que el planificador de ROIs necesita).
    ///
    /// El emparejado es VORAZ por score: la izquierda de mayor a menor, y cada una se
    /// queda con la derecha libre más próxima dentro de `maxAngleRad`. No es el óptimo
    /// global, y es lo que corresponde al tamaño del problema: en el solape hay un
    /// puñado de detecciones, y un emparejado subóptimo lo absorbe el tracker.
    public func fuse(
        _ observations: [Observation], maxAngleRad: Double
    ) -> [FusedObservation] {
        let izquierda = directions(of: observations, side: .left)
        let derecha = directions(of: observations, side: .right)
        var tomadas = Set<Int>()
        var fused: [FusedObservation] = []

        for (observacion, direccion) in izquierda {
            let (indice, separacion) = Self.closest(
                to: direccion, among: derecha, taken: tomadas, maxAngleRad: maxAngleRad
            )
            guard let indice else {
                fused.append(Self.single(observacion, direccion))
                continue
            }
            tomadas.insert(indice)
            let (pareja, direccionPareja) = derecha[indice]
            fused.append(
                FusedObservation(
                    direction: Self.midpoint(direccion, direccionPareja),
                    score: max(observacion.score, pareja.score),
                    sides: [.left, .right],
                    keys: [observacion.key, pareja.key],
                    separationRad: separacion
                )
            )
        }

        for (indice, par) in derecha.enumerated() where !tomadas.contains(indice) {
            fused.append(Self.single(par.0, par.1))
        }
        // Orden descendente ESTABLE, como list.sort de Python: a igual score manda
        // el orden de inserción, o los dorados no cuadrarían.
        return fused.enumerated()
            .sorted { a, b in
                a.element.score != b.element.score
                    ? a.element.score > b.element.score
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    private func directions(
        of observations: [Observation], side: CameraSide
    ) -> [(Observation, RigDirection)] {
        let pares = observations.filter { $0.side == side }.map {
            ($0, directionOf(side, xPx: $0.xPx, yPx: $0.yPx))
        }
        // El mismo orden estable por score descendente que Python.
        return pares.enumerated()
            .sorted { a, b in
                a.element.0.score != b.element.0.score
                    ? a.element.0.score > b.element.0.score
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    private static func closest(
        to direction: RigDirection,
        among candidates: [(Observation, RigDirection)],
        taken: Set<Int>,
        maxAngleRad: Double
    ) -> (Int?, Double) {
        var mejorIndice: Int?
        var mejorAngulo = maxAngleRad
        for (indice, candidato) in candidates.enumerated() where !taken.contains(indice) {
            let angulo = angularDistanceRad(direction, candidato.1)
            // `<=`, no `<`: a igual ángulo gana el último, exactamente como Python.
            if angulo <= mejorAngulo {
                mejorIndice = indice
                mejorAngulo = angulo
            }
        }
        return (mejorIndice, mejorIndice != nil ? mejorAngulo : 0)
    }

    private static func single(
        _ observation: Observation, _ direction: RigDirection
    ) -> FusedObservation {
        FusedObservation(
            direction: direction,
            score: observation.score,
            sides: [observation.side],
            keys: [observation.key]
        )
    }

    /// Dirección media por VECTORES unitarios, no por ángulos: con yaw cerca de ±π la
    /// media de los ángulos da la dirección contraria, y el fallo sería silencioso.
    private static func midpoint(_ first: RigDirection, _ second: RigDirection) -> RigDirection {
        let combinado = first.toUnit() + second.toUnit()
        let norma = combinado.norm
        guard norma != 0 else { return first }  // opuestas: imposible en tolerancia
        let unit = combinado.scaled(by: 1.0 / norma)
        return RigDirection(
            yawRad: atan2(unit.x, unit.z),
            pitchRad: atan2(-unit.y, (unit.x * unit.x + unit.z * unit.z).squareRoot())
        )
    }
}
