// La orden de cadencia (IOS-25, ADR 0023 §1 y §5): el maestro fija la escalera de la IA
// del soporte, la peor de las dos (la suya y la que el esclavo cuenta en su latido), y el
// esclavo detecta a esa cadencia, o a menos si la suya es peor (LadderGovernor).
//
// Va por control en un `command` JSON, como `calibration_capture`:
//   {"ai": false, "kind": "cadence", "level": 2, "player_hz": 0}
// Manda `level`: `player_hz` y `ai` son lo que ese nivel quiere decir, para que el registro
// se lea sin la tabla. Un esclavo de antes ignora el `kind` que no conoce, así que no sube
// `link_version` (un `type` nuevo sí la subiría).

import Foundation

public struct CadenceCommand: Equatable, Sendable {
    public static let kind = "cadence"

    /// La escalera común de la IA.
    public let level: LadderLevel

    public init(level: LadderLevel) {
        self.level = level
    }

    /// Jugadores por segundo que manda la orden (0 con la IA apagada).
    public var playerHz: Double {
        LadderGovernor.detectionHz(LadderActions.actions(for: level, role: .slave))
    }

    public var aiEnabled: Bool {
        LadderActions.actions(for: level, role: .slave).aiEnabled
    }

    /// El cuerpo del `command`, para JSONSerialization.
    public var json: [String: Any] {
        ["kind": Self.kind, "level": level.rawValue, "player_hz": playerHz, "ai": aiEnabled]
    }

    /// La orden de un `command` ya leído, o nil si no es `cadence` o su nivel no existe.
    public init?(json: [String: Any]) {
        guard json["kind"] as? String == Self.kind, let n = json["level"] as? Int,
              let nivel = LadderLevel(rawValue: n)
        else { return nil }
        level = nivel
    }
}
