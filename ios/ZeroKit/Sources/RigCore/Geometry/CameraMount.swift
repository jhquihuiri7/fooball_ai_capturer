// La montura del móvil invertido (IOS-30).
//
// El soporte junta las dos lentes en el centro montando un móvil girado 180°: su
// búfer crudo captura el mundo al revés. rig.json va en coordenadas ENDEREZADAS
// (como hace --flip left en calibrate_from_recordings.py del servidor), así que
// todo lo que trabaje sobre el búfer crudo necesita la matriz F que lleva un píxel
// crudo a su píxel enderezado — y, por ser un giro de 180°, la misma F deshace el
// viaje: es su propia inversa.

import Foundation

public enum CameraMount {
    /// `(x, y)` del búfer crudo invertido → `(x, y)` de la imagen enderezada:
    /// `(w − 1 − x, h − 1 − y)`. Involutiva: aplicarla dos veces es la identidad.
    public static func uprightPoint(
        x: Double, y: Double, width: Int, height: Int
    ) -> (x: Double, y: Double) {
        (Double(width - 1) - x, Double(height - 1) - y)
    }

    /// La F homogénea 3×3 del giro, para componerla con intrínsecas u homografías.
    public static func uprightMatrix(width: Int, height: Int) -> Mat3 {
        Mat3(rows: [
            -1, 0, Double(width - 1),
            0, -1, Double(height - 1),
            0, 0, 1,
        ])
    }
}
