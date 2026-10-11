// La política de la grabación 4K local (IOS-57).
//
// La 4K va encendida por defecto si queda la reserva libre, y no arranca por debajo: un
// AVAssetWriter que se queda sin disco a mitad no avisa dos veces. Las grabaciones viejas
// ya no se borran al empezar otra; las borra la ingesta (ML-08) al confirmarlas, o el
// operador a mano.

import Foundation

public enum RecordingPolicy {
    /// PHONE_DISK_RESERVE_GB: lo que tiene que quedar libre para grabar la 4K, en GB
    /// decimales. Un partido con descanso a 45 Mbit/s son ~39 GB; el resto es margen.
    public static let phoneDiskReserveGb: Int64 = 40
    public static let bytesPerGb: Int64 = 1_000_000_000
    public static var phoneDiskReserveBytes: Int64 { phoneDiskReserveGb * bytesPerGb }

    /// El bitrate de la 4K HEVC local, en bit/s: no comparte el límite de Starlink, y es de
    /// donde sale el partido bueno si la emisión se degrada.
    public static let localBitrateBps: Int64 = 45_000_000
    /// Banco (SPK-04): lo que se pide libre es lo que ocupa la pasada por este margen…
    public static let benchReserveFactor = 2.0
    /// …más este colchón fijo, en GB decimales.
    public static let benchReserveExtraGb: Int64 = 2
    static let bitsPerByte = 8.0

    /// Si con este disco libre se puede abrir la 4K. `reserveBytes`: la reserva del
    /// partido por defecto; un banco corto pide la suya (`benchReserveBytes`).
    public static func allowsLocalRecording(freeBytes: Int64, reserveBytes: Int64 = phoneDiskReserveBytes) -> Bool {
        freeBytes >= reserveBytes
    }

    /// La reserva de un banco de `durationS` segundos: 10 min son 3,4 GB de 4K y piden
    /// 8,75 GB libres, no los 40 GB del partido.
    public static func benchReserveBytes(durationS: Double) -> Int64 {
        let pasada = durationS * Double(localBitrateBps) / bitsPerByte
        return Int64(pasada * benchReserveFactor) + benchReserveExtraGb * bytesPerGb
    }
}
