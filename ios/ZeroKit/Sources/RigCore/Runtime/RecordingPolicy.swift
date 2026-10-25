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

    /// Un cambio del desfase al reloj del soporte mayor que esto entre dos fotogramas de la
    /// 4K cierra el segmento, en ns (100 ms, tres fotogramas a 30 fps). RigClock se corrige
    /// por la mitad del RTT filtrado (unos ms por Wi-Fi; el filtro ×3 deja hasta ~50 ms al
    /// arrancar con un RTT malo) y deriva decenas de ppm (µs por fotograma). Un cambio de
    /// dominio —la primera estimación del esclavo, un relevo— son horas o días: el
    /// 2026-10-11, +591 898 s entre los dos iPhone (RecordingClockGate).
    public static let clockJumpSegmentNs: Int64 = 100_000_000

    /// Lo más que la 4K de un esclavo espera al reloj del soporte antes de grabar con el de
    /// su host, en ns (30 s). El enlace sube en 1-3,4 s (una vez en 24 s, el 2026-10-08) y
    /// la estimación llega ~0,5 s después (3 muestras de la ráfaga de 250 ms). Pasado esto,
    /// perder la 4K es peor que un segmento sin emparejar: cuando llegue la estimación, el
    /// salto abre otro segmento.
    public static let clockWaitMaxNs: Int64 = 30_000_000_000

    /// Si con este disco libre se puede abrir la 4K. `reserveBytes`: la reserva del
    /// partido por defecto; un banco corto pide la suya (`benchReserveBytes`).
    public static func allowsLocalRecording(freeBytes: Int64, reserveBytes: Int64 = phoneDiskReserveBytes) -> Bool {
        freeBytes >= reserveBytes
    }

    /// La reserva de un banco de `durationS` segundos: 10 min son 3,4 GB de 4K y piden
    /// 8,75 GB libres, no los 40 GB del partido. Un banco largo no pide más que un partido
    /// (los 40 GB), salvo que la pasada sola no quepa en ellos: el plan B de la cancha, 6000 s,
    /// pedía 69,5 GB y la 4K no arrancaba (2026-10-14).
    public static func benchReserveBytes(durationS: Double) -> Int64 {
        let pasada = durationS * Double(localBitrateBps) / bitsPerByte
        let colchon = benchReserveExtraGb * bytesPerGb
        let holgada = Int64(pasada * benchReserveFactor) + colchon
        return min(holgada, max(phoneDiskReserveBytes, Int64(pasada) + colchon))
    }

    /// Cada cuánto escriben las copias locales (la 4K y el .mov del programa) un fragmento
    /// de película, en s. Sin fragmentos, el índice (`moov`) solo se escribe al cerrar: si la
    /// app muere a mitad (batería, jetsam, disco lleno, un cierre a mano), el fichero entero
    /// no se puede abrir. Con ellos se lee hasta el último fragmento: se pierden como mucho
    /// estos segundos. Es lo que hace AVCaptureMovieFileOutput por defecto (10 s).
    public static let movieFragmentIntervalS = 10.0

    /// Lo que tiene que quedar libre mientras se graba la 4K, en GB decimales: por debajo se
    /// cierra (el fichero queda entero) para que la copia del programa (~2,7 GB/h), el N0 y
    /// los informes sigan teniendo sitio. Con el disco lleno fallan todos a la vez.
    public static let diskFloorGb: Int64 = 2
    public static var diskFloorBytes: Int64 { diskFloorGb * bytesPerGb }

    /// Si la 4K en marcha tiene que cerrarse ya por el disco (`diskFloorBytes`).
    public static func mustStopForDisk(freeBytes: Int64) -> Bool {
        freeBytes < diskFloorBytes
    }

    // MARK: - La copia del programa (2026-10-24)
    //
    // El 24-oct la copia .mov del programa, que se graba siempre al EMITIR (~2 GB/h) y nunca se
    // borraba, llenó el disco del 17 tras ~5 h de partidos: falló a las 19:53, se reabrió con
    // IDR forzado y la emisión se atascó. La copia es un respaldo (el VPS graba el programa):
    // nunca puede costar la emisión. Se borran las copias viejas cuando hace falta sitio y, si
    // aun así no lo hay, la copia se para y la emisión sigue.

    /// GB libres por debajo de los que la copia del programa no se abre, y la abierta se cierra.
    /// Por encima del suelo de la 4K (`diskFloorGb`): la copia es lo primero que sobra.
    public static let programCopyFloorGb: Int64 = 3
    public static var programCopyFloorBytes: Int64 { programCopyFloorGb * bytesPerGb }

    /// GB libres que se intentan dejar borrando copias viejas del programa, al abrir la copia y
    /// cada minuto de emisión: unas 5 h más de copia (el 24-oct fueron 4,8 h de emisión).
    public static let programCopyTargetFreeGb: Int64 = 12
    public static var programCopyTargetFreeBytes: Int64 { programCopyTargetFreeGb * bytesPerGb }

    /// Si con este disco libre la copia del programa puede abrirse o seguir abierta.
    public static func programCopyAllowed(freeBytes: Int64) -> Bool {
        freeBytes >= programCopyFloorBytes
    }

    /// Si un fichero de Documents es una copia del programa: `program-<partido>-<t>.mov` y sus
    /// segmentos `…-N.mov`. Las del banco van en `bench/`, que no se mira.
    public static func isProgramCopy(_ name: String) -> Bool {
        name.hasPrefix("program-") && name.hasSuffix(".mov")
    }

    /// Una copia guardada: su nombre, lo que ocupa y cuándo se escribió por última vez (s).
    public struct StoredCopy: Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let modifiedS: Double

        public init(name: String, bytes: Int64, modifiedS: Double) {
            self.name = name
            self.bytes = bytes
            self.modifiedS = modifiedS
        }
    }

    /// Las copias viejas que borrar, de la más vieja a la más nueva, hasta que queden
    /// `targetFreeBytes` libres. Las de `keeping` (la que se está escribiendo) no se tocan.
    public static func programCopiesToDelete(
        _ copias: [StoredCopy], freeBytes: Int64, targetFreeBytes: Int64 = programCopyTargetFreeBytes,
        keeping: Set<String> = []
    ) -> [String] {
        var libre = freeBytes
        var borrar: [String] = []
        for copia in copias.sorted(by: { $0.modifiedS < $1.modifiedS }) {
            guard libre < targetFreeBytes else { break }
            guard !keeping.contains(copia.name) else { continue }
            borrar.append(copia.name)
            libre += copia.bytes
        }
        return borrar
    }
}
