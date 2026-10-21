// El vigía del micro: cuándo está muerto y hay que volver a ponerlo (Bug C, 2026-10-21).
//
// El 16-oct (17 en «Una cámara», emitiendo) el programa salió en ceros exactos a tramos y
// solo lo arregló matar Zero; medido al segundo sobre la grabación del programa del propio
// 17: a las 22:12:12 «otra app usa el micrófono» quitó el micro de la sesión (el sonido
// acaba a las 22:12:13) y no volvió hasta las 22:20:48; después se fue a las 22:24:03 y a
// las 22:29:53 sin ningún aviso de la cámara, con el micro puesto, y PARAR/EMITIR (22:31)
// siguió en ceros. Nada lo reponía: el micro solo volvía con el fin de una interrupción
// del audio o de una llamada, una vez y sin reintentar, y nada miraba si de verdad sonaba.
//
// Esto lo mira: con la cámara en marcha, el micro permitido y ninguna llamada en curso,
// está muerto si se quitó (otra app lo tomó), si no llega ningún búfer, si todo lo que
// llega son ceros exactos (un micro de verdad siempre tiene ruido de fondo; los ceros son
// el sistema silenciándolo) o si cada búfer falla. Entonces dice que se rehaga, y si sigue
// muerto lo vuelve a decir cada vez más espaciado. Swift puro: lo prueba el Mac.

import Foundation

public enum MicWatchConstants {
    /// Segundos sin un búfer del micro, con el micro puesto, tras los que está muerto. El
    /// micro entrega ~47 búferes por segundo.
    public static let noBuffersS = 3.0
    /// Segundos de ceros exactos seguidos, con el micro puesto, tras los que está muerto.
    /// Un micro de verdad nunca da cero exacto ni en una cancha callada.
    public static let digitalSilenceS = 5.0
    /// Segundos de búferes que fallan seguidos (no se pueden pasar al AAC).
    public static let failingS = 3.0
    /// Segundos entre un intento de rehacer el micro y el siguiente mientras siga muerto;
    /// el último se repite. Cada intento con otra app usando el micro le cuesta al vídeo una
    /// interrupción de décimas: espaciarlos lo deja en una cada minuto.
    public static let retryS: [Double] = [5, 15, 30, 60]
}

/// Lo que se sabe del micro en un instante (`AudioCapture.health`).
public struct MicHealth: Equatable, Sendable {
    /// Búferes del micro desde el principio, y los que no se pudieron pasar al AAC.
    public var buffersIn: Int
    public var failures: Int
    /// Segundos desde el último búfer (o desde que se puso el micro, si no ha llegado ninguno).
    public var withoutBuffersS: Double
    /// Segundos seguidos de ceros exactos hasta el último búfer; nil, el último tenía señal.
    public var digitalSilenceS: Double?
    /// Segundos seguidos fallando; nil, el último búfer entró bien.
    public var failingS: Double?
    /// La frecuencia del micro y las veces que ha cambiado (el AAC la pasa a 48 kHz).
    public var inputRateHz: Double
    public var inputRateChanges: Int

    public init(buffersIn: Int = 0, failures: Int = 0, withoutBuffersS: Double = 0, digitalSilenceS: Double? = nil,
                failingS: Double? = nil, inputRateHz: Double = 0, inputRateChanges: Int = 0) {
        self.buffersIn = buffersIn
        self.failures = failures
        self.withoutBuffersS = withoutBuffersS
        self.digitalSilenceS = digitalSilenceS
        self.failingS = failingS
        self.inputRateHz = inputRateHz
        self.inputRateChanges = inputRateChanges
    }
}

public struct MicWatch: Equatable, Sendable {
    /// Por qué el micro está muerto.
    public enum Problem: Equatable, Sendable {
        /// Se quitó de la sesión (otra app lo tomó) y no ha vuelto.
        case removed
        /// Está puesto y no entrega nada.
        case noBuffers(Double)
        /// Entrega ceros exactos.
        case digitalSilence(Double)
        /// Entrega búferes que no se pueden pasar al AAC.
        case failing(Double)

        public var text: String {
            switch self {
            case .removed: "el micro está fuera de la sesión"
            case let .noBuffers(s): String(format: "%.0f s sin búferes del micro", s)
            case let .digitalSilence(s): String(format: "%.0f s de ceros exactos del micro", s)
            case let .failing(s): String(format: "%.0f s de búferes del micro que fallan", s)
            }
        }
    }

    private let retryS: [Double]
    /// Intentos seguidos sin que el micro vuelva a sonar, y cuándo fue el último (s).
    public private(set) var attempts = 0
    private var lastAttemptS: Double?

    public init(retryS: [Double] = MicWatchConstants.retryS) {
        self.retryS = retryS
    }

    /// Qué le pasa al micro ahora, sin mirar si toca intentarlo.
    public static func problem(attached: Bool, health h: MicHealth) -> Problem? {
        guard attached else { return .removed }
        if h.withoutBuffersS > MicWatchConstants.noBuffersS { return .noBuffers(h.withoutBuffersS) }
        if let s = h.failingS, s > MicWatchConstants.failingS { return .failing(s) }
        if let s = h.digitalSilenceS, s > MicWatchConstants.digitalSilenceS { return .digitalSilence(s) }
        return nil
    }

    /// Si hay que rehacer el micro ahora (`nowS`, segundos monótonos), y por qué. Con la
    /// cámara parada, sin permiso o con una llamada en curso, nunca: el micro es de la
    /// llamada y vuelve al acabar. Sano, la cuenta de intentos vuelve a cero.
    public mutating func check(nowS: Double, running: Bool, allowed: Bool, callActive: Bool, attached: Bool,
                               health: MicHealth) -> Problem? {
        guard running, allowed, !callActive else { return nil }
        guard let problema = Self.problem(attached: attached, health: health) else {
            attempts = 0
            lastAttemptS = nil
            return nil
        }
        if let ultimo = lastAttemptS, !retryS.isEmpty, nowS - ultimo < retryS[min(attempts - 1, retryS.count - 1)] {
            return nil
        }
        attempts += 1
        lastAttemptS = nowS
        return problema
    }
}
