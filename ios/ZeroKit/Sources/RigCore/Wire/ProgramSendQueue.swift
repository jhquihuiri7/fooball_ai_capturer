// La cola del publicador del programa (IOS-56): lo que el maestro ha codificado y aún no
// ha entrado en SRT, y qué se tira cuando la red no da.
//
// Guarda unidades de acceso (un fotograma H.264 con su SEI, o una trama AAC) y no TS ya
// multiplexado: así lo que se tira no deja huecos en los contadores de continuidad del TS,
// que se multiplexa justo al enviar.
//
// - Acotada a ~1 s de espera (y a un tope de unidades por si fallan los relojes).
// - Ante congestión (la cola pasa de su tope, o SRT corta un fotograma), se tira lo que
//   espera y todo lo que llegue hasta el siguiente IDR, y se pide uno: un fotograma P sin
//   su referencia es basura en todos los lectores hasta el próximo IDR.
// - El audio va con el vídeo: se tira con él mientras se espera al IDR, para que el
//   programa vuelva entero y en el mismo instante.
// - Empieza esperando un IDR: MediaMTX no da por listo `programa` sin SPS/PPS e IDR.

import Foundation

/// Los números del publicador del programa, con sus unidades.
public enum ProgramPublish {
    /// Milisegundos que puede esperar una unidad en la cola antes de que sea congestión:
    /// «unos 1 s de TS» (la tarjeta). Es latencia que se suma a la de SRT.
    public static let queueMaxWaitMs = 1000.0

    /// Unidades en la cola como mucho: 1 s son 30 fotogramas y ~47 tramas AAC (1024
    /// muestras a 48 kHz); el doble, por si un reloj se para y la espera no crece.
    public static let queueMaxUnits = 160

    /// Divisor de la latencia SRT en uso que da los milisegundos del búfer de envío (lo que
    /// aún no ha confirmado el VPS) por encima de los que no se le mete más: la mitad (750 ms
    /// con 1500 de latencia; 1250 con 2500; 2000 con 4000). Por encima de la latencia, libsrt
    /// tira paquetes sueltos por su cuenta (TLPKTDROP) y rompe fotogramas a medias; antes, se
    /// retiene en la cola y, si no se vacía, se tira hasta el IDR, entero. Era una constante
    /// (750) hasta el 2026-10-15; con la latencia que sube (ProgramSrtLatency) va con ella.
    public static let congestionSendBufferDivisor: Int32 = 2

    /// El umbral de retención para una latencia dada, en ms.
    public static func congestionSendBufferMs(latencyMs: Int32) -> Int {
        Int(latencyMs / congestionSendBufferDivisor)
    }

    /// Segundos entre un fallo y el siguiente intento de conectar (ADR 0022 §8).
    public static let reconnectDelayS = 3.0

    /// Segundos entre cerrar una conexión atascada (el vigía, o la congestión sostenida) y
    /// volver a conectar. Menos que `reconnectDelayS`: la conexión no se cayó, la cerramos
    /// nosotros con el servidor contestando, y MediaMTX (overridePublisher) acepta al nuevo
    /// aunque aún tenga al viejo. Con el vigía (5 s) y el conectar, el programa vuelve en
    /// ~6-7 s desde que dejó de salir vídeo.
    public static let stallReconnectDelayS = 1.0

    /// Segundos seguidos con la muestra congestionada (búfer de envío por encima de la mitad
    /// de la latencia, o la cola tirando) antes de reconectar con el escalón de latencia
    /// siguiente, mientras quede uno: la red tiene más RTT del que la latencia aguanta y el
    /// bitrate no lo arregla (medido el 2026-10-15: RTT 1,2-2,8 s contra 1500 ms, 2-15 % de
    /// los fotogramas enviados). Un corte de ~2 s a cambio de dejar de retener. Sin escalón
    /// que subir no se reconecta: no ganaría nada.
    public static let sustainedCongestionReconnectS = 10.0

    /// Segundos que puede seguir «publishing» una conexión viva a la que llegan fotogramas
    /// del codificador sin que ninguno entre en SRT, antes de cerrarla y volver a conectar:
    /// el vigía de atasco (2026-10-15). libsrt no da por rota una conexión cuyo otro lado
    /// contesta, aunque su búfer de envío no baje nunca; medido en el 17, 9 min
    /// «publishing» sin un fotograma en el VPS. Tiene que superar la espera de la cola
    /// (1 s) y el RTT que aún aguanta la latencia SRT (1500 ms), para no reconectar en
    /// cada retención de un Wi-Fi con bufferbloat.
    public static let stallReconnectS = 5.0

    /// Segundos seguidos con el búfer de envío de SRT por encima de la latencia SRT antes de
    /// reconectar en vez de retener: dos GOP del programa (VideoConstants.programGopS, 2 s).
    /// Por encima de la latencia libsrt ya tira paquetes sueltos por su cuenta (TLPKTDROP) y
    /// lo que sale llega roto; y un búfer que no baja en dos GOP con la conexión viva es el
    /// atasco del 2026-10-15 (se quedó en 1520 ms, la latencia más los 20 ms de libsrt).
    public static let bufferOverLatencyReconnectS = 4.0

    /// Segundos de espera, como mucho, tras rechazos seguidos (clave o passphrase malas):
    /// reintentar cada 3 s no lo arregla y cada intento le cuesta 2 s a MediaMTX.
    public static let rejectedMaxDelayS = 30.0

    /// Segundos entre muestras de SRT: estadísticas y bitrate adaptativo.
    public static let statsEveryS = 1.0
}

/// Una unidad de acceso del programa, lista para multiplexar.
public struct ProgramUnit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case video(keyframe: Bool)
        case audio
    }

    public let kind: Kind
    /// Vídeo: la muestra AVCC con la SEI (y SPS/PPS delante si es IDR). Audio: AAC crudo,
    /// sin cabecera ADTS.
    public let payload: Data
    /// El instante del soporte, en ms: el PTS es `rigMs × 90`.
    public let rigMs: Double

    public init(kind: Kind, payload: Data, rigMs: Double) {
        self.kind = kind
        self.payload = payload
        self.rigMs = rigMs
    }

    public var isKeyframe: Bool { kind == .video(keyframe: true) }
    public var isVideo: Bool { kind != .audio }
}

public struct ProgramSendQueue: Sendable {
    /// Lo tirado y por qué, para la telemetría.
    public struct Counts: Equatable, Sendable {
        public var videoDropped = 0
        public var audioDropped = 0
        /// Veces que la cola se dio por congestionada (se tiró lo que esperaba).
        public var congestions = 0
        /// IDR pedidos por esta cola.
        public var idrRequests = 0
    }

    public let maxWaitMs: Double
    public let maxUnits: Int
    public private(set) var counts = Counts()
    /// Tirando todo hasta el próximo IDR.
    public private(set) var waitingForIdr = true
    private var units: [(unit: ProgramUnit, arrivalMs: Double)] = []

    public init(maxWaitMs: Double = ProgramPublish.queueMaxWaitMs, maxUnits: Int = ProgramPublish.queueMaxUnits) {
        precondition(maxUnits >= 1, "una cola sin hueco no es una cola")
        self.maxWaitMs = maxWaitMs
        self.maxUnits = maxUnits
        units.reserveCapacity(maxUnits + 1)
    }

    public var count: Int { units.count }
    public var isEmpty: Bool { units.isEmpty }

    /// Lo que lleva esperando la unidad más vieja, en ms.
    public func oldestWaitMs(nowMs: Double) -> Double {
        units.first.map { nowMs - $0.arrivalMs } ?? 0
    }

    /// Mete una unidad que llega en `nowMs` (reloj monótono). Devuelve true si hay que
    /// pedir un IDR al codificador.
    public mutating func push(_ unit: ProgramUnit, nowMs: Double) -> Bool {
        if waitingForIdr {
            guard unit.isKeyframe else {
                countDropped(unit)
                return false
            }
            waitingForIdr = false
        }
        units.append((unit, nowMs))
        guard units.count > maxUnits || nowMs - units[0].arrivalMs > maxWaitMs else { return false }
        // Si lo que desborda es un IDR, se sigue desde él: no hace falta pedir otro.
        if unit.isKeyframe {
            let idr = units.removeLast()
            discardAll()
            counts.congestions += 1
            units.append(idr)
            return false
        }
        return congest()
    }

    public func peek() -> ProgramUnit? { units.first?.unit }

    public mutating func pop() -> ProgramUnit? {
        units.isEmpty ? nil : units.removeFirst().unit
    }

    /// Congestión vista fuera de la cola (SRT no tragó un fotograma entero): se tira lo
    /// que espera y lo que llegue hasta el próximo IDR. True si hay que pedirlo.
    public mutating func dropUntilIdr() -> Bool {
        congest()
    }

    /// Una conexión nueva: se vacía sin contarlo como congestión y se espera al IDR, que
    /// el publicador pide.
    public mutating func restart() {
        discardAll()
        waitingForIdr = true
    }

    private mutating func congest() -> Bool {
        discardAll()
        counts.congestions += 1
        guard !waitingForIdr else { return false }
        waitingForIdr = true
        counts.idrRequests += 1
        return true
    }

    private mutating func discardAll() {
        units.forEach { countDropped($0.unit) }
        units.removeAll(keepingCapacity: true)
    }

    private mutating func countDropped(_ unit: ProgramUnit) {
        if unit.isVideo { counts.videoDropped += 1 } else { counts.audioDropped += 1 }
    }
}

/// Cuándo volver a intentar conectar: cada 3 s (ADR 0022 §8), salvo tras rechazos seguidos
/// del servidor, que esperan el doble cada vez hasta 30 s, y salvo tras cerrar nosotros una
/// conexión atascada, que espera 1 s.
public struct ReconnectBackoff: Sendable {
    public enum Failure: Sendable, Equatable {
        /// Sin respuesta, sin red o sin resolver el host.
        case unreachable
        /// Estaba publicando y se cortó.
        case lost
        /// El servidor dijo que no (credenciales o passphrase).
        case rejected
        /// Estaba publicando, viva, y la cerramos por atasco o congestión sostenida.
        case stalled
    }

    public private(set) var consecutiveRejections = 0

    public init() {}

    /// Segundos hasta el próximo intento.
    public mutating func delayS(after failure: Failure) -> Double {
        if failure == .stalled { return ProgramPublish.stallReconnectDelayS }
        guard failure == .rejected else { return ProgramPublish.reconnectDelayS }
        consecutiveRejections += 1
        let doble = ProgramPublish.reconnectDelayS * pow(2, Double(consecutiveRejections - 1))
        return min(doble, ProgramPublish.rejectedMaxDelayS)
    }

    /// Conectó: la próxima espera vuelve a ser la de siempre.
    public mutating func connected() {
        consecutiveRejections = 0
    }
}
