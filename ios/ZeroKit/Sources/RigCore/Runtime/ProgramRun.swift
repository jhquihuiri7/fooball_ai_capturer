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
    /// «Una cámara (sin pareja)» (2026-10-15): el programa sale de la lente de este móvil y
    /// de nada más. Sin parte que pintar ni que esperar, y tal cual: la lente entera, sin
    /// director ni recorte (`FullLensView`, enmienda del ADR 0025).
    public var singleCamera: Bool
    /// El tamaño y el techo con los que sale el programa (IOS-99, ADR 0025). 1080p salvo con
    /// «Una cámara», que puede ir a 720p.
    public var output: ProgramOutput
    /// El zoom de «Una cámara» (2026-10-30), como en la app Cámara: 0,5× es la lente entera.
    public var singleZoom: Double

    /// Lo que dura el banco si RIG_SPLIT_S no dice otra cosa: los 10 min de IOS-44, en s.
    public static let benchDefaultDurationS = 600.0

    /// El detector que busca la emisión en Documents/bench-resources: el CenterNet-MNv4 del
    /// plan B (ADR 0020), con el nombre de su ficha. No hay modelo en el registro todavía.
    public static let productionDetectorPackage = "players-centernet-mnv4.mlpackage"

    public init(
        purpose: Purpose, durationS: Double, director: Bool, publish: Bool, record4K: Bool,
        detectorPackage: String?, partBitrateBps: Int, benchFiles: Bool, ladderForce: LadderForce? = nil,
        singleCamera: Bool = false, output: ProgramOutput = .hd1080, singleZoom: Double = FullLensView.fullLensZoom
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
        self.singleCamera = singleCamera
        self.output = output
        self.singleZoom = singleZoom
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

    /// EMITIR con «Una cámara (sin pareja)»: lo mismo que `production` (el detector, el
    /// gráfico y la franja, la copia .mov y el SRT si hay QR Soporte), sin enlace y con el
    /// programa de una sola lente **tal cual**: sin director, la lente entera enderezada
    /// (`FullLensView`; ADR 0025, enmienda del 2026-10-15). Sin parte, su bitrate no se usa.
    /// Sale a la resolución que eligió el operador (IOS-99): 1080p de partida. Y con su zoom
    /// (2026-10-30): la lente entera (0,5×) de partida.
    public static func single(detectorPackage: String?, output: ProgramOutput = .hd1080,
                              zoom: Double = FullLensView.fullLensZoom) -> ProgramRunConfig {
        ProgramRunConfig(
            purpose: .production, durationS: .infinity, director: false, publish: true, record4K: false,
            detectorPackage: detectorPackage, partBitrateBps: noPartBitrateBps, benchFiles: false,
            singleCamera: true, output: output, singleZoom: zoom
        )
    }

    /// La parte de «Una cámara»: no hay, así que su bitrate es cero (bit/s).
    public static let noPartBitrateBps = 0

    static let bitsPerMegabit = 1_000_000.0
}

/// Qué enlace abre `startLink`: el Multipeer de siempre (cada móvil emite al pod) o el de
/// Network por un medio (la arquitectura B, ADR 0023).
public enum LinkChoice: Equatable, Sendable {
    case multipeer
    case network(LinkMedium)
    /// «Una cámara (sin pareja)» (2026-10-15): ningún enlace; este móvil emite solo.
    case single

    /// El entorno manda, para que los bancos lanzados desde el Mac sigan igual
    /// (RIG_LINK_MULTIPEER=0 y RIG_LINK_INTERFACE); sin él, lo que eligió la pantalla,
    /// también «Una cámara». nil si el entorno pide Network con un medio que no se entiende.
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

/// La clave con la que este móvil firma y verifica el mando (ADR 0023 §3; Bug A,
/// 2026-10-21). Con el secreto del soporte S, S: lo comparten los dos móviles y el VPS, y
/// cualquiera de ellos acepta el token del otro. Sin S —un iPhone que nunca lo recibió,
/// en «Una cámara»— no había con qué firmar el QR Mando, ni matando la app; ahí basta un
/// secreto propio de este móvil, porque el único que verifica es él: aleatorio, creado
/// una vez y guardado en su Keychain.
public enum ControlKeySource {
    /// De dónde salió la clave, para el latido.
    public enum Origin: String, Sendable {
        /// El secreto del soporte S.
        case rig
        /// El propio de este móvil, guardado.
        case device
        /// El propio, que no se pudo guardar (o el Keychain no se pudo leer): vale hasta
        /// que se cierre la app.
        case deviceUnsaved = "device_unsaved"
    }

    public struct Key: Equatable, Sendable {
        public let secret: Data
        public let origin: Origin

        public init(secret: Data, origin: Origin) {
            self.secret = secret
            self.origin = origin
        }
    }

    /// Lo que mide el secreto propio, en bytes: 256 bits, como S.
    public static let deviceSecretBytes = 32

    /// `rig`: S, si lo hay. `cached`: la propia que ya se resolvió en este proceso (la
    /// misma en cada QR mientras viva la app). `stored`: lo del Keychain, leído solo si
    /// hace falta; un `.failure` no se pisa con una nueva, que se queda sin guardar.
    /// `save`: guarda la nueva en base64 y dice si pudo.
    public static func resolve(
        rig: Data?, cached: Key?, stored: () -> Result<String?, any Error>,
        generate: () -> Data = randomDeviceSecret, save: (String) -> Bool
    ) -> Key {
        if let rig { return Key(secret: rig, origin: .rig) }
        if let cached, cached.origin != .rig { return cached }
        let leido = stored()
        if case let .success(texto?) = leido, let guardado = Data(base64Encoded: texto),
           guardado.count == deviceSecretBytes
        {
            return Key(secret: guardado, origin: .device)
        }
        let nuevo = generate()
        guard case .success = leido, save(nuevo.base64EncodedString()) else {
            return Key(secret: nuevo, origin: .deviceUnsaved)
        }
        return Key(secret: nuevo, origin: .device)
    }

    /// 32 bytes del generador del sistema, que en las plataformas de Apple es
    /// criptográficamente seguro.
    public static func randomDeviceSecret() -> Data {
        var generador = SystemRandomNumberGenerator()
        return Data((0 ..< deviceSecretBytes).map { _ in UInt8.random(in: .min ... .max, using: &generador) })
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
