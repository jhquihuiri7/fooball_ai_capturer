// Cómo «ve» una cámara: lo que el maestro le pasa al otro móvil para que las dos
// mitades de la panorámica salgan del mismo color y con la misma luz.
//
// Viaja en unidades que no dependen del móvil: el balance en temperatura y tinte (las
// ganancias son de cada sensor) y la apertura junto al ISO, para que un móvil con otra
// lente compense la luz que le entra de más o de menos.
//
// Vive en RigCore porque viaja dentro de RigMessage y no toca ningún framework; quien
// la aplica a la cámara de verdad es Runner, con AVFoundation.

import Foundation

public struct CameraLook: Equatable, Sendable {
    public var exposureNs: Int64
    public var iso: Float
    public var aperture: Float
    public var kelvin: Float
    public var tint: Float

    public init(exposureNs: Int64, iso: Float, aperture: Float, kelvin: Float, tint: Float) {
        self.exposureNs = exposureNs
        self.iso = iso
        self.aperture = aperture
        self.kelvin = kelvin
        self.tint = tint
    }

    /// El ISO que da la misma luz con otra apertura: la luz va con el cuadrado del número f.
    public func iso(forAperture other: Float) -> Float {
        guard aperture > 0, other > 0 else { return iso }
        return iso * (other * other) / (aperture * aperture)
    }
}
