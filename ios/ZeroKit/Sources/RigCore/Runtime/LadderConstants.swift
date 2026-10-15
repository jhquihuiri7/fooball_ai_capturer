// Las constantes de la escalera de degradación (IOS-06), con unidades y por qué.
//
// TODOS los valores de este fichero son PROVISIONALES hasta que el remojo térmico los
// mida (M19: SPK-54 y SPK-07 en football-ai/docs/MEDICIONES.md). Se tocan aquí y en
// ningún otro sitio.

import Foundation

public enum LadderConstants {
    /// Segundos sosteniendo un objetivo mejor antes de subir de nivel. Empeorar es
    /// inmediato; mejorar espera, o la escalera oscila con cada nube que pasa.
    public static let recoverS: Double = 60

    /// Hz de jugadores en L0: la cadencia del plan (30 fps / 4, ADR 0020).
    public static let playerHzL0: Double = 7.5

    /// Hz de jugadores en L1: la mitad útil. Perder resolución temporal es lo más
    /// barato que la escalera puede soltar primero.
    public static let playerHzL1: Double = 5

    /// Hz del lote de ROIs del balón mientras la IA sigue viva (ADR 0020).
    public static let ballRoiHz: Double = 15

    /// Alto del programa en L0-L2 y en L3, en píxeles.
    public static let programHeightL0 = 1080
    public static let programHeightL3 = 720

    /// Factor del bitrate del programa en L3: ×0,6 sobre el techo configurado.
    public static let bitrateFactorL3 = 0.6

    // La escalera actuando en la arquitectura B (LadderGovernor). Estos dos no son de la
    // tabla de M19: son el ritmo del mecanismo.

    /// Segundos entre dos pasos de la escalera en el banco split y EMITIR: el mismo ritmo
    /// que la foto de estado de 1 Hz que la avanzaba en IOS-06. Los sensores cambian en
    /// minutos; más a menudo no compra nada.
    public static let stepEveryS: Double = 1

    /// Segundos entre dos repeticiones de la orden `cadence` del maestro aunque no cambie:
    /// un esclavo que se reconecta (o una orden perdida al cerrarse el control) la tiene de
    /// nuevo en este plazo sin que el maestro lleve la cuenta de quién la recibió.
    public static let cadenceResendS: Double = 5
}
