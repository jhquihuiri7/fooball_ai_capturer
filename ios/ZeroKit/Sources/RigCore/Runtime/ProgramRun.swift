// Qué pone en marcha EMITIR en la arquitectura B (IOS-58), y el banco split con lo mismo.
//
// El banco split (RIG_SPLIT=1, IOS-43/44) y la emisión de producción son la misma
// orquestación —SplitBench en el Runner: la parte del esclavo, el programa del maestro, el
// director, el detector, las copias locales y el publicador SRT—. Lo que cambia es de
// dónde salen sus ajustes: el banco, del entorno con el que lo lanza el Mac; la emisión, de
// la pantalla. Los mandos de medir (el guion de SPK-04, apagar la cámara, el sesgo de
// exposición…) siguen en el entorno y, sin él, no hacen nada.
//
// También aquí, porque se deciden sin red ni cámara: qué enlace abre `startLink`, de dónde
// sale el secreto del soporte mientras no exista IOS-97, y el ritmo de un contador para la
// pantalla.

import Foundation

/// Los ajustes de una pasada del programa: el banco split o la emisión.
public struct ProgramRunConfig: Equatable, Sendable {
    public enum Purpose: String, Sendable {
        case bench
        case production
    }

    public var purpose: Purpose
    /// Lo que dura, en s. El banco para solo (RIG_SPLIT_S); la emisión, al PARAR.
    public var durationS: Double
    /// Dirige el DirectorService con las detecciones (IOS-73); si no, el barrido de guion.
    public var director: Bool
    /// El maestro publica el programa por SRT (IOS-56) mientras es maestro.
    public var publish: Bool
    /// El banco graba además la 4K de su pasada (SPK-04). La emisión la abre por
    /// `CaptureHostApi.start`, con la reserva del partido.
    public var record4K: Bool
    /// El paquete del detector de jugadores en Documents/bench-resources, o nil sin detector.
    public var detectorPackage: String?
    /// La parte del esclavo, en bit/s: RIG_SPLIT_PART_MBPS o la del medio del enlace.
    public var partBitrateBps: Int
    /// Lo que solo sirve para medir: el .ts del programa y las vistas por instante
    /// (SPK-04, REF-41). La emisión guarda solo la copia .mov de IOS-57.
    public var benchFiles: Bool
    /// El nivel forzado de la escalera (RIG_LADDER_FORCE…), solo en el banco: EMITIR la
    /// deja siempre a sus sensores.
    public var ladderForce: LadderForce?

    /// Lo que dura el banco si RIG_SPLIT_S no dice otra cosa: los 10 min de IOS-44, en s.
    public static let benchDefaultDurationS = 600.0

    /// El detector que busca la emisión en Documents/bench-resources: el CenterNet-MNv4 del
    /// plan B (ADR 0020), con el nombre de su ficha. No hay modelo en el registro todavía.
    public static let productionDetectorPackage = "players-centernet-mnv4.mlpackage"

    public init(
        purpose: Purpose, durationS: Double, director: Bool, publish: Bool, record4K: Bool,
        detectorPackage: String?, partBitrateBps: Int, benchFiles: Bool, ladderForce: LadderForce? = nil
    ) {
        self.purpose = purpose
        self.durationS = durationS
        self.director = director
        self.publish = publish
        self.record4K = record4K
        self.detectorPackage = detectorPackage
        self.partBitrateBps = partBitrateBps
        self.benchFiles = benchFiles
        self.ladderForce = ladderForce
    }

    /// El banco split, como siempre: todo del entorno.
    public static func bench(environment env: [String: String]) -> ProgramRunConfig {
        let medio = LinkMedium.parse(env["RIG_LINK_INTERFACE"]) ?? .ethernet
        let parteBps = env["RIG_SPLIT_PART_MBPS"].flatMap(Double.init).map { Int($0 * bitsPerMegabit) }
        return ProgramRunConfig(
            purpose: .bench,
            durationS: env["RIG_SPLIT_S"].flatMap(Double.init) ?? benchDefaultDurationS,
            director: env["RIG_SPLIT_DIRECTOR"] == "1",
            publish: env["RIG_SPLIT_PUBLISH"] == "1",
            record4K: env["RIG_SPLIT_RECORD_4K"] == "1",
            detectorPackage: env["RIG_DETECT"],
            partBitrateBps: parteBps ?? medio.partBitrateBps,
            benchFiles: true,
            ladderForce: LadderForce.parse(environment: env)
        )
    }

    /// EMITIR: sin fin, con el director y publicando. El detector, si su paquete está en
    /// el móvil (lo resuelve quien sabe mirar el disco).
    public static func production(medium: LinkMedium, detectorPackage: String?) -> ProgramRunConfig {
        ProgramRunConfig(
            purpose: .production, durationS: .infinity, director: true, publish: true, record4K: false,
            detectorPackage: detectorPackage, partBitrateBps: medium.partBitrateBps, benchFiles: false
        )
    }

    static let bitsPerMegabit = 1_000_000.0
}

/// Qué enlace abre `startLink`: el Multipeer de siempre (cada móvil emite al pod) o el de
/// Network por un medio (la arquitectura B, ADR 0023).
public enum LinkChoice: Equatable, Sendable {
    case multipeer
    case network(LinkMedium)

    /// El entorno manda, para que los bancos lanzados desde el Mac sigan igual
    /// (RIG_LINK_MULTIPEER=0 y RIG_LINK_INTERFACE); sin él, lo que eligió la pantalla.
    /// nil si el entorno pide Network con un medio que no se entiende.
    public static func resolve(environment env: [String: String], requested: LinkChoice) -> LinkChoice? {
        guard let multipeer = env["RIG_LINK_MULTIPEER"] else { return requested }
        if multipeer != "0" { return .multipeer }
        return LinkMedium.parse(env["RIG_LINK_INTERFACE"]).map(LinkChoice.network)
    }
}

/// El secreto del soporte S (ADR 0023 §3) hasta que IOS-97 lo aprovisione con un QR de un
/// solo uso: RIG_LINK_SECRET, en base64, manda y se guarda en el Keychain; sin él, lo
/// guardado. Así basta lanzar la app una vez desde el Mac con el secreto (o el banco) para
/// que después se abra desde el icono.
public enum RigSecretSource {
    /// `environment`: RIG_LINK_SECRET; `stored`: lo del Keychain; `save`: guarda el del
    /// entorno si es otro. nil si no hay ninguno, o si el del entorno no es base64: un
    /// secreto mal pegado tiene que fallar claro, no caer en el viejo sin avisar.
    public static func resolve(environment: String?, stored: String?, save: (String) -> Void) -> Data? {
        if let valor = environment?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard let secreto = Data(base64Encoded: valor), !secreto.isEmpty else { return nil }
            if valor != stored { save(valor) }
            return secreto
        }
        guard let guardado = stored, let secreto = Data(base64Encoded: guardado), !secreto.isEmpty else {
            return nil
        }
        return secreto
    }
}

/// El ritmo de un contador entre dos lecturas: los fps del programa y los Mbit/s de la
/// parte que enseña la pantalla, sin guardar historia.
public struct RateMeter: Sendable {
    private var last: (count: Double, atNs: UInt64)?

    public init() {}

    /// Lo que subió `count` por segundo desde la lectura anterior; 0 en la primera, si el
    /// reloj no avanzó o si el contador bajó (otra pasada).
    public mutating func rate(count: Double, nowNs: UInt64) -> Double {
        defer { last = (count, nowNs) }
        guard let previa = last, nowNs > previa.atNs, count >= previa.count else { return 0 }
        return (count - previa.count) / (Double(nowNs - previa.atNs) / Self.nsPerSecond)
    }

    static let nsPerSecond = 1e9
}
