// La homografía programa → cámara y qué lados hacen falta (IOS-31).
//
// Las dos lentes y la cámara virtual comparten centro óptico (ADR 0012): entre dos
// pinhole que solo rotan hay EXACTAMENTE una homografía,
//
//     H = K_cámara · R_cámaraᵀ · R_vista · K_vista⁻¹
//
// la misma cuenta que una tabla de remapeo píxel a píxel, resuelta en tres
// multiplicaciones de 3×3. El convenio del medio píxel es el de directionAt: el
// centro del programa cae en el borde entre los dos píxeles centrales, y media
// de diferencia se VE al comparar monitores.

import Foundation

/// Píxel de la cámara (enderezada) ← píxel del programa.
public func viewHomography(rig: RigModel, view: RectilinearView, side: CameraSide) -> Mat3 {
    let intr = rig.camera(side).intrinsics
    let kCamera = Mat3(rows: [
        intr.fx, 0, intr.cx,
        0, intr.fy, intr.cy,
        0, 0, 1,
    ])
    let focal = view.focalPx
    let kViewInv = Mat3(rows: [
        1.0 / focal, 0, -(Double(view.width) / 2.0 - 0.5) / focal,
        0, 1.0 / focal, -(Double(view.height) / 2.0 - 0.5) / focal,
        0, 0, 1,
    ])
    let rotation = rig.rotation(side).transposed.multiplied(by: view.pose.matrix())
    return kCamera.multiplied(by: rotation).multiplied(by: kViewInv)
}

/// Píxel del BÚFER CRUDO ← píxel del programa, para la cámara que el soporte monta
/// girada 180°: la misma H compuesta con la F de la montura. rig.json va en
/// coordenadas enderezadas, así que el camino de Metal sobre el búfer crudo
/// necesita esta y no la otra.
public func viewHomographyToRaw(rig: RigModel, view: RectilinearView, side: CameraSide) -> Mat3 {
    let intr = rig.camera(side).intrinsics
    return CameraMount.uprightMatrix(width: intr.width, height: intr.height)
        .multiplied(by: viewHomography(rig: rig, view: view, side: side))
}

/// Qué cámaras hacen falta para pintar este encuadre. Casi siempre UNA: si las
/// cuatro esquinas caen dentro de una cámara, el encuadre entero está dentro
/// (la imagen de una cámara en el plano del programa es un cuadrilátero convexo),
/// y donde no hay costura no hay fantasma ni salto de color.
public func sidesFor(rig: RigModel, view: RectilinearView) -> [CameraSide] {
    let corners = [
        view.directionAt(xPx: 0, yPx: 0),
        view.directionAt(xPx: 0, yPx: Double(view.height) - 1),
        view.directionAt(xPx: Double(view.width) - 1, yPx: 0),
        view.directionAt(xPx: Double(view.width) - 1, yPx: Double(view.height) - 1),
    ]
    for side in CameraSide.allCases where corners.allSatisfy({ rig.sees(side, direction: $0) }) {
        return [side]
    }
    return CameraSide.allCases.map { $0 }
}
