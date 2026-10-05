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

    /// Vistas que lleva cada mensaje `view` (ADR 0023 §5, IOS-42): las 3 últimas, para
    /// que un datagrama perdido no obligue al esclavo a extrapolar.
    public static let viewHistory = 3

    /// Milisegundos que el maestro espera la parte del esclavo antes de componer el
    /// instante T (objetivo de SPK-04). Compone SIEMPRE en T + esto, llegue o no: el
    /// retardo del programa queda fijo, y una parte que no llegó a tiempo hace que ese
    /// fotograma salga de una lente.
    public static let partMaxWaitMs: Int64 = 100

    /// Latidos por segundo en los dos sentidos, por medios (LINK_HEARTBEAT_HZ, ADR 0023 §11).
    public static let heartbeatHz = 10.0

    /// Milisegundos sin un latido bueno tras los que el otro está caído
    /// (HEARTBEAT_LOSS_MS, objetivo hasta SPK-06). A la mitad pasa a «dudoso».
    public static let heartbeatLossMs: Int64 = 500

    /// Datagramas que el emisor suelta de golpe antes de esperar (IOS-52, ADR 0023 §5):
    /// un IDR de cientos de KB en ráfaga desbordaría el búfer del receptor. 16 × 1200 B
    /// son 19 KB por golpe.
    public static let pacingBurstDatagrams = 16

    /// Espera entre golpes, en ms: 19 KB cada 2 ms son ~77 Mbit/s de pico, holgados para
    /// 30 Mbit/s de media y por debajo de lo que traga una Wi-Fi o el hub.
    public static let pacingIntervalMs = 2

    /// Datagramas en espera como mucho (~2,4 MB, dos IDR gordos): la cola va acotada y
    /// una trama que no cabe se tira entera y se cuenta.
    public static let pacingMaxQueuedDatagrams = 2048
}
