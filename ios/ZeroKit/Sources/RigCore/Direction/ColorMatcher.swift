// El igualado de color del solape, lógica pura (IOS-38): réplica de
// PanoramaStitcher.observe_color (libs/vision/panorama.py), congelada en color.json.
//
// Donde las dos cámaras ven lo mismo, sus medias por canal tendrían que coincidir. De su
// cociente sale una ganancia por canal que lleva a las dos a un punto intermedio —la raíz
// del cociente para una y su inversa para la otra—, con tope y suavizada, en vez de dar
// por buena a una. Las medias y las ganancias van en BGR, el orden de la referencia y el
// que espera ReprojectKernel. Las ganancias viajan en cada ViewCommand.

import Foundation

public final class ColorMatcher {
    public private(set) var gains = ColorGains.unity
    private let smoothing: Double

    public init(smoothing: Double = RigConstants.panoramaColorMatchSmoothing) {
        precondition(smoothing > 0 && smoothing <= 1, "el suavizado del color debe estar en (0, 1]")
        self.smoothing = smoothing
    }

    /// Acerca la ganancia de cada cámara a lo que piden las medias BGR de su solape. Con
    /// algún canal por debajo de PANORAMA_COLOR_MATCH_MIN_LEVEL no hace nada: de noche o
    /// con el solape tapado, el cociente es ruido.
    public func observe(meanLeft: [Double], meanRight: [Double]) {
        precondition(meanLeft.count == 3 && meanRight.count == 3, "medias BGR de tres canales")
        guard min(meanLeft.min()!, meanRight.min()!) >= RigConstants.panoramaColorMatchMinLevel else {
            return
        }
        let tope = RigConstants.panoramaColorMatchMaxGain
        func recorta(_ v: Double) -> Double { min(max(v, 1 / tope), tope) }
        let objetivoIzq = zip(meanRight, meanLeft).map { recorta(($0 / $1).squareRoot()) }
        let objetivoDer = zip(meanLeft, meanRight).map { recorta(($0 / $1).squareRoot()) }
        let resto = 1 - smoothing
        gains = ColorGains(
            left: zip(gains.left, objetivoIzq).map { resto * $0 + smoothing * $1 },
            right: zip(gains.right, objetivoDer).map { resto * $0 + smoothing * $1 }
        )
    }
}
