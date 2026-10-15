// La salida del programa (IOS-99, ADR 0025 de football-ai): el tamaño con el que sale del
// codificador y el techo de su bitrate.
//
// El programa se compone siempre a 1080p (el gráfico, la franja y el director no cambian);
// con 720p, el codificador se crea a 1280×720 y escala él mismo cada fotograma. El soporte
// de dos móviles va siempre a 1080p; el 720p es solo para un móvil que emite solo. Copia de
// PROGRAM_OUTPUTS en tools/program_contract.py de football-ai.

import Foundation

public enum ProgramOutput: String, Sendable, CaseIterable {
    case hd1080 = "1080p"
    case hd720 = "720p"

    /// Píxeles de ancho a la salida del codificador: 1920 es la composición
    /// (PROGRAM_WIDTH); 1280, PROGRAM_720P_WIDTH.
    public var width: Int {
        switch self {
        case .hd1080: 1920
        case .hd720: 1280
        }
    }

    /// Píxeles de alto: PROGRAM_HEIGHT y PROGRAM_720P_HEIGHT.
    public var height: Int {
        switch self {
        case .hd1080: 1080
        case .hd720: 720
        }
    }

    /// Bits por segundo, el techo del vídeo: PROGRAM_VIDEO_BITRATE_BPS (6 Mbit/s) y
    /// PROGRAM_720P_VIDEO_BITRATE_BPS (3 Mbit/s, la misma densidad por píxel redondeada hacia
    /// arriba). El suelo y la forma de subir y bajar son los de AdaptiveRate.
    public var maximumBps: Int {
        switch self {
        case .hd1080: 6_000_000
        case .hd720: 3_000_000
        }
    }
}
