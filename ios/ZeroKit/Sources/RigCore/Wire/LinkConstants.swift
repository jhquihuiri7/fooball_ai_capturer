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

    /// Bits por segundo de la parte del esclavo por Wi-Fi. Medido el 2026-10-06 con los dos
    /// iPhone e imagen real: a 12 Mbit/s se perdía el 0,75 % de las partes (un IDR cada
    /// ~4 s); a 8, el 0,09 %. La Wi-Fi entre los dos móviles da ~10 Mbit/s útiles (SPK-02).
    public static let partBitrateWifiBps = 8_000_000

    /// Bits por segundo de la parte por Ethernet: provisional hasta medir con los hubs
    /// (SPK-02). Por cable caben 30 Mbit/s; 12 es lo que se usaba en el banco.
    public static let partBitrateEthernetBps = 12_000_000

    /// Latidos por segundo en los dos sentidos, por medios (LINK_HEARTBEAT_HZ, ADR 0023 §11).
    public static let heartbeatHz = 10.0

    /// Milisegundos sin un latido bueno tras los que el otro está caído
    /// (HEARTBEAT_LOSS_MS, objetivo hasta SPK-06). A la mitad pasa a «dudoso».
    public static let heartbeatLossMs: Int64 = 500

    /// El enlace tiene que llevar caído esto para que el esclavo se promueva
    /// (PROMOTE_AFTER_MS, objetivo hasta SPK-06).
    public static let promoteAfterMs: Int64 = 2000

    /// Y el hub tiene que decir `master_status: lost` desde hace esto
    /// (MASTER_LOST_PROMOTE_MS, objetivo hasta SPK-06).
    public static let masterLostPromoteMs: Int64 = 5000

    /// Con el enlace caído más de esto, en un partido que tuvo esclavo, el maestro solo
    /// reabre el SRT tras un `welcome` posterior a la caída (LINK_FENCE_MS; menor que
    /// PROMOTE_AFTER_MS).
    public static let linkFenceMs: Int64 = 1000

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
