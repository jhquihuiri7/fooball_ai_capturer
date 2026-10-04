// Detección de jugadores del soporte (réplica de libs/core/types.PlayerDetection y de
// la fusión de libs/vision/rig_detection.py).
//
// Se detecta en cada cámara por separado y se funde por los PIES —el centro del borde
// inferior de la caja, el único punto en el suelo— en ángulos del soporte. No se funde
// por clase: la clase la decide quien mejor lo vio, y la caja que se conserva es la
// de esa cámara, porque el planificador de ROIs necesita su tamaño en píxeles.

import Foundation

/// Una persona detectada en UNA cámara, en píxeles nativos de esa cámara.
public struct PlayerDetection: Equatable, Sendable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double
    public let playerClass: PlayerClass
    public let score: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double, playerClass: PlayerClass, score: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.playerClass = playerClass
        self.score = score
    }

    /// Los pies: el centro del borde inferior de la caja.
    public var footXPx: Double { (x1 + x2) * 0.5 }
    public var footYPx: Double { y2 }
}

/// Una persona vista por el soporte.
public struct RigPlayerDetection: Equatable, Sendable, ActionSighting {
    /// Dónde están sus pies, en el sistema angular del soporte.
    public let direction: RigDirection
    /// La caja de la cámara que mejor la vio.
    public let detection: PlayerDetection
    /// De qué cámara es `detection`.
    public let side: CameraSide
    /// Qué cámaras la vieron. Con las dos, cayó en el solape.
    public let sides: [CameraSide]
    public let separationRad: Double

    public init(
        direction: RigDirection,
        detection: PlayerDetection,
        side: CameraSide,
        sides: [CameraSide],
        separationRad: Double = 0
    ) {
        self.direction = direction
        self.detection = detection
        self.side = side
        self.sides = sides
        self.separationRad = separationRad
    }

    public var playerClass: PlayerClass { detection.playerClass }
    public var score: Double { detection.score }
}

extension RigModel {
    /// Funde las detecciones de las dos cámaras (una puede venir vacía: la cámara
    /// caída de la decisión 4 del ADR 0012). Ordenado por score descendente.
    public func fusePlayers(
        left: [PlayerDetection],
        right: [PlayerDetection],
        maxAngleRad: Double = RigConstants.rigFuseMaxAngleRad
    ) -> [RigPlayerDetection] {
        let cajas: [CameraSide: [PlayerDetection]] = [.left: left, .right: right]
        var observaciones: [Observation] = []
        for side in CameraSide.allCases {
            for (indice, caja) in cajas[side]!.enumerated() {
                observaciones.append(
                    Observation(side: side, xPx: caja.footXPx, yPx: caja.footYPx, score: caja.score, key: indice)
                )
            }
        }
        return fuse(observaciones, maxAngleRad: maxAngleRad).map { item in
            // `max` de Python: a igual score se queda el PRIMERO, que es la izquierda.
            var mejor = (caja: cajas[item.sides[0]]![item.keys[0]], side: item.sides[0])
            for (side, key) in zip(item.sides, item.keys).dropFirst() {
                let caja = cajas[side]![key]
                if caja.score > mejor.caja.score {
                    mejor = (caja, side)
                }
            }
            return RigPlayerDetection(
                direction: item.direction,
                detection: mejor.caja,
                side: mejor.side,
                sides: item.sides,
                separationRad: item.separationRad
            )
        }
    }
}
