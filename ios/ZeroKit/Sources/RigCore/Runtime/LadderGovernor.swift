// La escalera actuando en la arquitectura B (IOS-06, consumida por IOS-25/44/50).
//
// Cada móvil lleva su escalera (DegradationLadder) con sus sensores, pero no todo lo que
// suelta es suyo:
// - La IA es del soporte entero. El director del maestro empareja las detecciones de las
//   dos cámaras por su instante de la rejilla, así que las dos detectan a la misma cadencia.
//   Manda la peor de las dos escaleras (la cadencia más baja, IOS-25): el esclavo cuenta su
//   nivel en el latido y el maestro fija la común con la orden `cadence` (ADR 0023 §1 y §5).
//   Ninguno detecta nunca por encima de lo que permite su propia escalera: lo suyo se aplica
//   al momento, sin esperar a la orden.
// - El programa es del maestro: L3 le baja el bitrate con su propio nivel.
// - La parte es del esclavo: en L4 deja de pintarla y el maestro sigue con una lente, como
//   cuando el esclavo cae (IOS-81).
//
// Lógica pura, como la escalera: quien la usa le dice qué piden los sensores, qué se sabe
// del otro y cuánto tiempo pasó.

import Foundation

/// El nivel forzado de un banco (RIG_LADDER_FORCE), para probar la escalera en el iPhone
/// sin Xcode ni calor. Solo lo lee el banco split: EMITIR no lo mira.
///
///   RIG_LADDER_FORCE          L0..L4 (o 0..4): el objetivo de la escalera en su tramo
///   RIG_LADDER_FORCE_AT_S     desde qué segundo de la pasada (0)
///   RIG_LADDER_FORCE_UNTIL_S  hasta qué segundo (sin él, hasta el final); después vuelven
///                             los sensores y la escalera mejora con su histéresis
///   RIG_LADDER_FORCE_SIDE     left o right: solo en ese móvil (sin él, en los dos), porque
///                             BANCO_EXTRA llega igual a los dos
///
/// El forzado es el OBJETIVO, no el nivel: pasa por la misma histéresis. Empeorar es
/// inmediato; forzar un nivel mejor que el de los sensores baja un escalón cada recoverS.
public struct LadderForce: Equatable, Sendable {
    public let level: LadderLevel
    public let atS: Double
    public let untilS: Double
    /// El único móvil al que se aplica, o nil para los dos.
    public let side: CameraSide?

    public init(level: LadderLevel, atS: Double = 0, untilS: Double = .infinity, side: CameraSide? = nil) {
        self.level = level
        self.atS = atS
        self.untilS = untilS
        self.side = side
    }

    /// El forzado del entorno, o nil si no hay (o si RIG_LADDER_FORCE no es un nivel: un
    /// banco mal escrito corre con los sensores, y el informe dice que no hubo forzado).
    public static func parse(environment env: [String: String]) -> LadderForce? {
        guard var texto = env["RIG_LADDER_FORCE"]?.trimmingCharacters(in: .whitespaces).uppercased() else {
            return nil
        }
        if texto.hasPrefix("L") { texto.removeFirst() }
        guard let n = Int(texto), let nivel = LadderLevel(rawValue: n) else { return nil }
        return LadderForce(
            level: nivel,
            atS: env["RIG_LADDER_FORCE_AT_S"].flatMap(Double.init) ?? 0,
            untilS: env["RIG_LADDER_FORCE_UNTIL_S"].flatMap(Double.init) ?? .infinity,
            side: env["RIG_LADDER_FORCE_SIDE"].flatMap { CameraSide(rawValue: $0.lowercased()) }
        )
    }

    /// Si se aplica en el móvil de este lado.
    public func applies(to lado: CameraSide) -> Bool {
        side == nil || side == lado
    }

    /// Si a los `elapsedS` de la pasada se está en el tramo forzado.
    public func isActive(elapsedS: Double) -> Bool {
        elapsedS >= atS && elapsedS < untilS
    }

    /// El objetivo a los `elapsedS` de la pasada: el forzado en su tramo, el de los
    /// sensores fuera de él.
    public func target(sensors: LadderLevel, elapsedS: Double) -> LadderLevel {
        isActive(elapsedS: elapsedS) ? level : sensors
    }
}

public struct LadderGovernor: Sendable {
    public private(set) var ladder = DegradationLadder()
    /// El forzado de este móvil, si lo hay (ya filtrado por lado).
    public let force: LadderForce?
    /// El nivel propio del otro móvil, de su latido, mientras se le oye; nil si no.
    public private(set) var peerLevel: LadderLevel?
    /// En el esclavo, la escalera común que mandó el maestro (`cadence`); nil sin maestro.
    public private(set) var commandedLevel: LadderLevel?

    public init(force: LadderForce? = nil) {
        self.force = force
    }

    /// El nivel de la escalera de este móvil: el que cuenta su latido y enseña su pantalla.
    public var level: LadderLevel { ladder.level }

    /// Un paso: el objetivo de los sensores (o el forzado, en su tramo) por la histéresis.
    @discardableResult
    public mutating func step(sensors: LadderLevel, elapsedS: Double, dtS: Double) -> LadderLevel {
        let objetivo = force?.target(sensors: sensors, elapsedS: elapsedS) ?? sensors
        return ladder.step(target: objetivo, dtS: dtS)
    }

    /// Lo que dice el latido del otro (nil si está caído o no se le ha oído).
    public mutating func setPeer(level: LadderLevel?) {
        peerLevel = level
    }

    /// La orden `cadence` del maestro (nil sin maestro: caído o al cambiar de papel).
    public mutating func setCommanded(level: LadderLevel?) {
        commandedLevel = level
    }

    /// La escalera que gobierna la IA de este móvil, la peor de las dos:
    /// - en el maestro, la suya y la del latido del esclavo; es la que manda la orden;
    /// - en el esclavo, la suya y la que mandó el maestro.
    public func aiLevel(isMaster: Bool) -> LadderLevel {
        max(level, (isMaster ? peerLevel : commandedLevel) ?? .l0)
    }

    /// Lo que hace este móvil ahora: la IA con la escalera común; el programa, la parte y
    /// el resto, con la suya.
    public func actions(isMaster: Bool) -> LadderActions {
        let rol: LadderRole = isMaster ? .master : .slave
        var acciones = LadderActions.actions(for: level, role: rol)
        let ia = LadderActions.actions(for: aiLevel(isMaster: isMaster), role: rol)
        acciones.playerHz = ia.playerHz
        acciones.ballEnabled = ia.ballEnabled
        acciones.ballRoiHz = ia.ballRoiHz
        acciones.aiEnabled = ia.aiEnabled
        return acciones
    }

    /// En el maestro: el esclavo dice en su latido que dejó de pintar su parte (L4). El
    /// programa sigue con una lente sin esperarla, como con el esclavo caído.
    public var peerStoppedParts: Bool {
        guard let p = peerLevel else { return false }
        return !LadderActions.actions(for: p, role: .slave).partEnabled
    }

    /// La cadencia de detección de esas acciones en Hz; 0 con la IA apagada.
    public static func detectionHz(_ acciones: LadderActions) -> Double {
        acciones.aiEnabled ? acciones.playerHz : 0
    }
}
