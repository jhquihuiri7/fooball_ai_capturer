// Constantes del codificador del programa (IOS-50), con unidades y por qué.

import Foundation

public enum VideoConstants {
    /// Intervalo máximo entre IDR, en segundos (`PROGRAM_GOP_S`, ADR 0021).
    ///
    /// Es el tamaño del segmento del búfer del VPS (ADR 0013 §6): cada segmento tiene
    /// que empezar en IDR. Un IDR forzado a mitad puede alargar un segmento hasta casi
    /// el doble; NUBE-04 lo tiene en cuenta.
    public static let programGopS = 2.0

    /// Ventana de los DataRateLimits, en segundos.
    ///
    /// Un segundo: el tamaño de ráfaga que el enlace entre móviles traga sin encolar
    /// (el Fragmenter espacia dentro del fotograma, no entre fotogramas).
    public static let dataRateWindowS = 1.0

    /// Cuánto puede excederse la ventana sobre el bitrate medio (sin unidad).
    ///
    /// 1,5×: el IDR de cada GOP pesa varios P juntos y sin margen el control de tasa
    /// lo castigaría con un QP alto justo en el fotograma del que cuelga todo el GOP.
    /// Provisional hasta que el banco de IOS-50 lo mida en el iPhone.
    public static let dataRateBurstRatio = 1.5

    /// Tope de QP por fotograma (`MaxAllowedFrameQP`, solo en modo de baja latencia).
    ///
    /// 45: por debajo de eso un fotograma 1080p de fútbol todavía se ve; sin tope, el
    /// control de tasa responde a un pico dejando pasar un fotograma de papilla que
    /// además arrastra al resto del GOP. Provisional hasta el banco en el iPhone.
    public static let maxAllowedFrameQp = 45

    /// Huecos de la cola de salida del codificador.
    ///
    /// 16 fotogramas son ~0,5 s a 30 fps: si quien consume (el enlace o el mux) se
    /// atasca más que eso, lo correcto es tirar lo viejo y pedir IDR, no encolar
    /// latencia (CLAUDE.md §2 del servidor).
    public static let encodedQueueSlots = 16
}
