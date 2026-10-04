// Las intrínsecas por fotograma frente a rig.json (IOS-72, cierra la M2).
//
// El iPhone entrega con cada fotograma la matriz intrínseca de lo que de verdad
// capturó (RigPipeline la deja en FrameMeta.intrinsics, fila a fila, en píxeles del
// búfer). Aquí se compara con la de rig.json reescalada a ese búfer: el error de
// focal relativo y el desplazamiento del centro, en píxeles nativos. Va a la
// telemetría siempre, y por encima de los umbrales sugiere recalibrar.

import Foundation
import RigCore

public enum IntrinsicsReader {
    /// `matrix` es la del adjunto, fila a fila (9 valores). `nil` si no viene o no es
    /// una matriz intrínseca (la de la cámara siempre lleva 0, 0, 1 abajo).
    public static func drift(
        matrix: [Float]?,
        bufferWidth: Int,
        reference: CameraIntrinsics
    ) -> IntrinsicsDrift? {
        guard let m = matrix, m.count == 9, m[6] == 0, m[7] == 0, m[8] == 1,
              bufferWidth > 0, m[0] > 0, m[4] > 0
        else {
            return nil
        }
        // rig.json va en píxeles nativos; el búfer puede ser de otro tamaño.
        guard let ref = try? reference.scaled(Double(bufferWidth) / Double(reference.width)) else {
            return nil
        }
        let fx = Double(m[0]), fy = Double(m[4]), cx = Double(m[2]), cy = Double(m[5])
        let aNativo = Double(reference.width) / Double(bufferWidth)
        return IntrinsicsDrift(
            fxPx: fx, fyPx: fy, cxPx: cx, cyPx: cy,
            focalRelDelta: max(abs(fx - ref.fx) / ref.fx, abs(fy - ref.fy) / ref.fy),
            centerDeltaPx: hypot(cx - ref.cx, cy - ref.cy) * aNativo
        )
    }
}
