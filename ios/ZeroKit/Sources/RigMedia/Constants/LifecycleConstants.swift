// Los plazos del ciclo de vida de la app (2026-10-15), con unidades y por qué.

import Foundation

public enum LifecycleConstants {
    /// Lo más que `applicationWillTerminate` espera a que la 4K cierre su índice, en s.
    ///
    /// iOS da 5 s para terminar y después mata el proceso (FRONTBOARD 0x8BADF00D: el 17,
    /// 2026-10-15 18:32). La 4K y la copia del programa van en fragmentos de 10 s
    /// (`RecordingPolicy.movieFragmentIntervalS`), así que si no llega a tiempo se pierde
    /// como mucho el último fragmento; bloquear más que esto sí pierde la app entera.
    public static let terminationFlushS = 1.0
}
