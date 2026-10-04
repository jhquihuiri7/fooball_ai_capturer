// Lo que se desvían las intrínsecas por fotograma de las de rig.json (IOS-72). Vive en
// RigCore porque viaja en la telemetría; lo calcula IntrinsicsReader en RigMedia.

import Foundation

public struct IntrinsicsDrift: Codable, Equatable, Sendable {
    public init(
        fxPx: Double, fyPx: Double, cxPx: Double, cyPx: Double,
        focalRelDelta: Double, centerDeltaPx: Double
    ) {
        self.fxPx = fxPx
        self.fyPx = fyPx
        self.cxPx = cxPx
        self.cyPx = cyPx
        self.focalRelDelta = focalRelDelta
        self.centerDeltaPx = centerDeltaPx
    }

    /// Lo que entrega el iPhone, en píxeles del búfer.
    public let fxPx: Double
    public let fyPx: Double
    public let cxPx: Double
    public let cyPx: Double
    /// max(|Δfx|/fx, |Δfy|/fy) frente a rig.json.
    public let focalRelDelta: Double
    /// Distancia entre centros ópticos, en píxeles nativos de rig.json.
    public let centerDeltaPx: Double

    public var suggestsRecalibration: Bool {
        focalRelDelta > RigConstants.rigIntrinsicsMaxFocalRel
            || centerDeltaPx > RigConstants.rigIntrinsicsMaxCenterPx
    }

    enum CodingKeys: String, CodingKey {
        case fxPx = "fx_px"
        case fyPx = "fy_px"
        case cxPx = "cx_px"
        case cyPx = "cy_px"
        case focalRelDelta = "focal_rel_delta"
        case centerDeltaPx = "center_delta_px"
    }
}
