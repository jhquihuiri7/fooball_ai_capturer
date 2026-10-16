// «Una cámara (sin pareja)» tal cual (ADR 0025, enmienda del 2026-10-15): el programa es la
// lente entera de ese móvil, sin director ni recorte.
//
// Se hace con la misma cámara virtual de siempre, quieta y del tamaño de la lente: mira
// hacia donde mira la cámara y abre el campo más ancho que cabe en ella a la relación de
// aspecto del programa. Así el render, el gráfico, la franja y el codificador no cambian,
// y el horizonte sale recto aunque el móvil vaya un poco girado (la vista no tiene roll).

import Foundation

public enum FullLensView {
    /// Fracción del campo de la lente que se usa: un pelo menos que entero. Al cruzar el
    /// enlace la vista se redondea (`ViewWire.quantized`) y el muestreo bilineal lee medio
    /// píxel alrededor; sin este margen, el borde del programa podría salir negro.
    public static let fillFraction = 0.99

    /// El campo de visión horizontal, en rad, de la vista más ancha que cabe entera en la
    /// lente de `camera` con la relación de aspecto `width`×`height` del programa.
    ///
    /// La vista mira por el eje óptico de la cámara y solo difiere de ella en el roll, así
    /// que en el plano de imagen normalizado es el rectángulo del programa girado ese roll:
    /// tiene que caber, girado, entre el centro óptico y el borde más cercano de la lente.
    public static func hfovRad(of camera: RigCamera, width: Int, height: Int) -> Double {
        let intr = camera.intrinsics
        // Distancia del centro óptico al borde más cercano, en el plano normalizado (el
        // píxel tiene su centro en .5: la imagen va de -0,5 a ancho - 0,5).
        let ax = min(intr.cx + 0.5, Double(intr.width) - 0.5 - intr.cx) / intr.fx
        let ay = min(intr.cy + 0.5, Double(intr.height) - 0.5 - intr.cy) / intr.fy
        let aspecto = Double(height) / Double(width)
        let c = abs(cos(camera.pose.rollRad)), s = abs(sin(camera.pose.rollRad))
        let tanMedio = min(ax / (c + aspecto * s), ay / (s + aspecto * c)) * fillFraction
        return 2 * atan(tanMedio)
    }

    /// La vista de la lente entera de `side`, en el tamaño del programa.
    public static func view(rig: RigModel, side: CameraSide, width: Int, height: Int) throws -> RectilinearView {
        let camara = rig.camera(side)
        return try RectilinearView(
            yawRad: camara.pose.yawRad,
            pitchRad: camara.pose.pitchRad,
            hfovRad: hfovRad(of: camara, width: width, height: height),
            width: width,
            height: height
        )
    }
}
