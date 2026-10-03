// Las constantes del enlace que fija IOS-10 (ADR 0023 §11), con unidades y por qué.
// Las demás constantes del ADR llegan con sus tarjetas (latidos, relevo, réplica).

import Foundation

public enum LinkConstants {
    /// Bytes de carga útil por datagrama UDP. 1200 cabe en el MTU mínimo de IPv6
    /// (1280) con las cabeceras de IP, UDP y del fragmento, sin fragmentación del SO.
    public static let datagramPayloadB = 1200

    /// Tope duro de una trama. Una parte de vídeo de un fotograma 1080p30 a
    /// 35 Mbit/s ronda los 150 KB; 1 MiB deja margen para un IDR gordo y corta
    /// cualquier longitud disparatada de una trama corrupta.
    public static let maxFrameB = 1 << 20

    /// Tramas a medias que el reensamblador retiene como mucho. Se acota por número y
    /// no por tiempo, como el FramePairer del servidor: con 4 en vuelo, la quinta
    /// expulsa a la más vieja, que se cuenta como incompleta.
    public static let reassemblyFrames = 4
}
