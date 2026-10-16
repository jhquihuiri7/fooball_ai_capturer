// Una espera con plazo a un trabajo de otra cola (2026-10-15).
//
// Es lo único que `applicationWillTerminate` puede permitirse: iOS mata la app a los 5 s de
// pedirle que termine (FRONTBOARD 0x8BADF00D), y una cola de captura atascada no puede
// llevarse el hilo principal con ella. Lo que no llega a tiempo no se cancela: sigue en su
// cola, y el proceso se irá cuando iOS quiera.

import Foundation

public enum BoundedWait {
    /// Lanza `work` en `queue` y espera a que avise con `done`, como mucho `timeoutS`
    /// segundos. Devuelve si avisó a tiempo. Nunca se llama desde `queue`.
    @discardableResult
    public static func run(
        on queue: DispatchQueue,
        timeoutS: Double,
        _ work: @escaping (_ done: @escaping () -> Void) -> Void
    ) -> Bool {
        let aviso = DispatchSemaphore(value: 0)
        queue.async { work { aviso.signal() } }
        return aviso.wait(timeout: .now() + timeoutS) == .success
    }
}
