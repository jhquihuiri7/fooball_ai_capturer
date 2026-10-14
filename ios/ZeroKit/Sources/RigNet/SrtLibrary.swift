// libsrt dentro de la app (IOS-55): el xcframework propio que deja tools/build_libsrt.sh,
// libsrt 1.5 con mbedTLS para la passphrase. Su API C se llama con el prefijo csrt_
// (csrt_startup es srt_startup): así no choca con el libsrt de SRTHaishinKit en el Runner.
// Aquí solo el arranque, una vez por proceso, y la versión enlazada; el socket del programa
// es SrtSocket.

import CSrt
import Foundation

public enum SrtLibrary {
    /// srt_startup una sola vez. No hay srt_cleanup: la librería vive lo que el proceso.
    private static let started: Int32 = csrt_startup()

    /// Arranca libsrt si no lo estaba. Lo llama SrtSocket antes de crear un socket.
    @discardableResult
    public static func start() -> Bool { started >= 0 }

    /// La versión enlazada, «1.5.7».
    public static var version: String {
        let v = csrt_getversion()
        return "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}
