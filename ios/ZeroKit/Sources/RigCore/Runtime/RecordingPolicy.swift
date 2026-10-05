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

    /// Si con este disco libre se puede abrir la 4K.
    public static func allowsLocalRecording(freeBytes: Int64) -> Bool {
        freeBytes >= phoneDiskReserveBytes
    }
}
