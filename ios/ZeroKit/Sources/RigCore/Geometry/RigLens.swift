// La lente física de cada móvil y la geometría que le toca (ADR 0035, enmienda del 2026-11-04:
// la lente con dos cámaras).
//
// Con dos móviles también se elige la lente: 0,5× la ultra gran angular, 1× la principal, 2× la
// principal con el recorte del sensor… La calibración del soporte es de una lente: cada una
// tiene su fichero (`rig.json` la ultra; `rig-1x.json`, `rig-2x.json`… las demás). Y dos lentes
// cerradas pueden no tocarse: con la principal y los móviles a ±40° queda un hueco en el centro.
// Aquí se dice qué fichero toca, cuánto se solapan (porte de `RigModel.horizontal_overlap_rad`
// de libs/vision/rig.py, contra su dorado overlap.json) y qué hay que avisar.

import Foundation

/// La lente que abrió un móvil.
public struct RigLens: Equatable, Sendable {
    /// En la escala de la app Cámara: 0,5 la ultra gran angular, 1 la principal…
    public let zoom: Double
    /// Su campo horizontal, en rad; nil con la ultra, que tiene las intrínsecas de `rig.json`.
    public let hfovRad: Double?

    public init(zoom: Double, hfovRad: Double?) {
        self.zoom = zoom
        self.hfovRad = hfovRad
    }

    /// La ultra gran angular, la de la calibración de siempre.
    public static let ultraWide = RigLens(zoom: FullLensView.fullLensZoom, hfovRad: nil)

    public var isUltraWide: Bool { zoom <= FullLensView.fullLensZoom }

    /// Como la escribe la app Cámara: «0,5×», «1×», «2×».
    public var label: String {
        String(format: "%g", zoom).replacingOccurrences(of: ".", with: ",") + "×"
    }

    /// El fichero de su geometría en Documents: `rig.json` la ultra; `rig-1x.json`,
    /// `rig-2x.json`… las demás.
    public var rigFileName: String {
        isUltraWide ? "rig.json" : "rig-\(String(format: "%g", zoom))x.json"
    }
}

extension RigModel {
    /// Cuánto se solapan en yaw las dos cámaras a media altura de la imagen, visto desde el
    /// soporte: del borde interior de una al de la otra. Negativo si entre las dos queda un hueco
    /// que no ve ninguna.
    public func horizontalOverlapRad() -> Double {
        func tramo(_ side: CameraSide) -> (Double, Double) {
            let intr = camera(side).intrinsics
            let fila = (Double(intr.height) - 1) / 2
            let a = directionOf(side, xPx: 0, yPx: fila).yawRad
            let b = directionOf(side, xPx: Double(intr.width) - 1, yPx: fila).yawRad
            return (min(a, b), max(a, b))
        }
        let izq = tramo(.left), der = tramo(.right)
        return min(izq.1, der.1) - max(izq.0, der.0)
    }
}

/// Lo que hay que avisar de la geometría con dos cámaras, en palabras del operador.
public enum RigLensWarning {
    /// Los avisos: sin calibrar con esta lente, sin solape y lentes distintas. Vacío si todo
    /// cuadra. `peer` es la lente del otro móvil, si la dijo en su `hello`.
    public static func warnings(rig: RigModel, own: RigLens, peer: RigLens?, calibrated: Bool) -> [String] {
        var avisos: [String] = []
        if let peer, peer.zoom != own.zoom {
            avisos.append("los dos móviles llevan lentes distintas (\(own.label) y \(peer.label)): pon la misma en los dos")
        }
        if !own.isUltraWide, !calibrated {
            avisos.append("sin calibrar con la lente \(own.label): calibra el cosido desde el mando con esta lente")
        }
        if let consejo = gapAdvice(rig: rig, lens: own) { avisos.append(consejo) }
        return avisos
    }

    /// Si las dos lentes no llegan a solaparse lo que pide el cosido, qué hacer: cuánto juntar los
    /// móviles para esta lente, o volver a la ultra. nil si se solapan. Lo usan el aviso y el fallo
    /// de «Calibrar cosido»: el 2026-11-08, con 1× y los móviles a 81°, no había nada que calibrar.
    public static func gapAdvice(rig: RigModel, lens: RigLens) -> String? {
        let solape = rig.horizontalOverlapRad()
        guard solape < RigConstants.rigMinOverlapRad else { return nil }
        let grados = { (r: Double) in Int((abs(r) * 180 / .pi).rounded()) }
        let separacion = rig.camera(.right).pose.yawRad - rig.camera(.left).pose.yawRad
        let objetivo = separacion - (RigConstants.rigMinOverlapRad - solape)
        let que = solape < 0
            ? "las dos lentes no se tocan con \(lens.label): queda un hueco de \(grados(solape))° en el centro"
            : "las dos lentes apenas se solapan con \(lens.label) (\(grados(solape))°)"
        let otra = lens.isUltraWide ? "" : ", o usa 0,5×"
        return "\(que). Para coser, junta los móviles hasta unos \(grados(objetivo))° entre ellos (ahora \(grados(separacion))°) y calibra\(otra)"
    }
}
