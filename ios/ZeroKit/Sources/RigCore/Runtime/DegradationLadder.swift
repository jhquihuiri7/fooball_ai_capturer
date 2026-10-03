// La escalera de degradación (IOS-06): qué se suelta, en qué orden, cuando el móvil
// se calienta.
//
// Orden del propietario: primero se suelta la IA, después la calidad del programa y
// después la emisión de este móvil; la grabación local va la última, porque es la
// verdad del partido y la materia prima del diferido.
//
// Lógica pura: ni notificaciones, ni KVO, ni reloj propio. Quien la usa le dice qué
// miden los sensores y cuánto tiempo pasó (como el muelle del director y la gramática
// de planos del servidor), así que se prueba entera en una tabla de secuencias.

import Foundation

/// El estado térmico del sistema, como lo da ProcessInfo. Espejo puro para que
/// RigCore no importe nada.
public enum ThermalLevel: Int, Comparable, Sendable {
    case nominal = 0, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// La presión del sistema de captura (AVCaptureDevice.SystemPressureState), que
/// avisa antes y con más detalle que la térmica: shutdown es «voy a cortar la cámara».
public enum PressureLevel: Int, Comparable, Sendable {
    case nominal = 0, fair, serious, critical, shutdown

    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum LadderLevel: Int, Comparable, CaseIterable, Sendable {
    case l0 = 0, l1, l2, l3, l4

    public static func < (lhs: LadderLevel, rhs: LadderLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Qué móvil es: en L4 el esclavo para su parte y el maestro pide la cesión.
public enum LadderRole: Sendable {
    case master
    case slave
}

/// Lo que cada nivel manda hacer. Los niveles son acumulativos: L2 incluye lo de L1.
public struct LadderActions: Equatable, Sendable {
    public var playerHz: Double
    /// La búsqueda global del balón. Es lo primero que se apaga (L1).
    public var ballEnabled: Bool
    public var ballRoiHz: Double
    public var aiEnabled: Bool
    public var programHeight: Int
    public var programBitrateFactor: Double
    public var programEnabled: Bool
    /// La parte que el esclavo manda al maestro. Solo cae en L4, y solo en el esclavo.
    public var partEnabled: Bool
    /// La última línea: no la toca ningún nivel de esta escalera.
    public var localRecording: Bool
    public var preview: Bool
    /// Solo el maestro en L4: pedir la cesión al esclavo (IOS-86). Sin esclavo sano,
    /// sigue emitiendo como en L3.
    public var requestsHandover: Bool

    public static func actions(for level: LadderLevel, role: LadderRole) -> LadderActions {
        var acciones = LadderActions(
            playerHz: LadderConstants.playerHzL0,
            ballEnabled: true,
            ballRoiHz: LadderConstants.ballRoiHz,
            aiEnabled: true,
            programHeight: LadderConstants.programHeightL0,
            programBitrateFactor: 1.0,
            programEnabled: true,
            partEnabled: true,
            localRecording: true,
            preview: true,
            requestsHandover: false
        )
        if level >= .l1 {
            acciones.playerHz = LadderConstants.playerHzL1
            acciones.ballEnabled = false
        }
        if level >= .l2 {
            acciones.aiEnabled = false
            acciones.playerHz = 0
            acciones.ballRoiHz = 0
            acciones.preview = false
        }
        if level >= .l3 {
            acciones.programHeight = LadderConstants.programHeightL3
            acciones.programBitrateFactor = LadderConstants.bitrateFactorL3
        }
        if level >= .l4 {
            switch role {
            case .slave:
                acciones.partEnabled = false
            case .master:
                acciones.requestsHandover = true
            }
        }
        return acciones
    }
}

public struct DegradationLadder: Sendable {
    public private(set) var level: LadderLevel = .l0

    /// Cuánto lleva sostenido un objetivo mejor que el nivel actual.
    private var recoverS: Double = 0

    public init() {}

    /// El nivel que piden los sensores ahora mismo, sin histéresis.
    ///
    /// La tabla es PROVISIONAL hasta M19. Sin carga (el hub caído) se sube un escalón:
    /// a batería sola el móvil se calienta más y no hay margen para apurar.
    public static func target(
        thermal: ThermalLevel,
        pressure: PressureLevel,
        charging: Bool
    ) -> LadderLevel {
        let porTermica: LadderLevel = switch thermal {
        case .nominal: .l0
        case .fair: .l1
        case .serious: .l2
        case .critical: .l3
        }
        let porPresion: LadderLevel = switch pressure {
        case .nominal: .l0
        case .fair: .l1
        case .serious: .l2
        case .critical: .l3
        case .shutdown: .l4
        }
        var objetivo = max(porTermica, porPresion)
        if !charging {
            objetivo = LadderLevel(rawValue: min(objetivo.rawValue + 1, LadderLevel.l4.rawValue))!
        }
        return objetivo
    }

    /// Un paso de la escalera. Empeorar es inmediato; mejorar exige sostener el
    /// objetivo mejor durante `LadderConstants.recoverS` seguidos.
    @discardableResult
    public mutating func step(
        thermal: ThermalLevel,
        pressure: PressureLevel,
        charging: Bool,
        dtS: Double
    ) -> LadderLevel {
        let objetivo = Self.target(thermal: thermal, pressure: pressure, charging: charging)
        if objetivo >= level {
            level = objetivo
            recoverS = 0
            return level
        }
        recoverS += dtS
        if recoverS >= LadderConstants.recoverS {
            // Un escalón cada vez: bajar de L3 a L0 de golpe recupera la carga entera
            // en un frame, y el calor que la causó sigue ahí.
            level = LadderLevel(rawValue: level.rawValue - 1)!
            recoverS = 0
        }
        return level
    }
}
