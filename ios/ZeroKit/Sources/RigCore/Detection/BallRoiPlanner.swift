// El planificador de ROIs del balón (IOS-28): réplica de `BallTracker.rois`,
// `heatmap_side` y `RoiSpec.clamped` de libs/vision (REF-27, REF-28), congelada en las
// secuencias de ball.json. El recorte del lote [2, 3, S, S] y su carril son de IOS-74.

import Foundation

/// Qué estrategia generó una ROI (§12.5), con los nombres de la referencia.
public enum BallRoiSource: String, Sendable {
    case predictive
    case expanded
    case playerGuided = "player_guided"
    case sweep
}

/// Una ventana cuadrada del frame nativo donde buscar el balón. Cuadrada a propósito: la
/// entrada del detector lo es, y el heatmap no reescala la ROI.
public struct BallRoi: Equatable, Sendable {
    /// Borde izquierdo y superior, en píxeles del frame nativo.
    public let x: Int
    public let y: Int
    /// Lado en píxeles nativos: la forma del tensor del export.
    public let side: Int
    public let source: BallRoiSource

    public init(x: Int, y: Int, side: Int, source: BallRoiSource) {
        self.x = x
        self.y = y
        self.side = side
        self.source = source
    }

    /// Desplazada para que quepa entera en el frame; si no cabe ni así, encogida hasta el
    /// lado mayor que quepa. Desplazar y no recortar: recortada dejaría de ser cuadrada.
    public func clamped(width: Int, height: Int) -> BallRoi {
        let lado = min(side, width, height)
        return BallRoi(
            x: min(max(x, 0), width - lado), y: min(max(y, 0), height - lado), side: lado, source: source
        )
    }

    /// El píxel i cubre [i, i+1): el borde derecho y el inferior quedan fuera.
    public func contains(x px: Double, y py: Double) -> Bool {
        Double(x) <= px && px < Double(x + side) && Double(y) <= py && py < Double(y + side)
    }
}

public enum BallRoiPlanner {
    /// Los lados de ROI con export del modelo. Python tiene `BALL_ROI_SIDES` (solo 256
    /// hasta que SPK-52 apruebe 320), pero DetectionSpec aún no la exporta: mientras
    /// tanto es el único lado que sí exporta.
    public static let defaultSides: [Int] = [DetectionSpec.ballRoiSide]

    /// El lado con export más cercano a `side`; a igual distancia, el mayor
    /// (`heatmap_side`). nil sin lados.
    public static func heatmapSide(_ side: Double, sides: [Int] = defaultSides) -> Int? {
        sides.min { a, b in
            let (da, db) = (abs(Double(a) - side), abs(Double(b) - side))
            return da != db ? da < db : a > b
        }
    }

    /// La ROI de lado `side` centrada en (cx, cy), con un redondeo explícito hacia la
    /// esquina más cercana —el `round` de Python redondea al par— y dentro del frame.
    public static func roi(
        centeredAt cx: Double, _ cy: Double, side: Int, source: BallRoiSource, width: Int, height: Int
    ) -> BallRoi {
        let mitad = Double(side) / 2.0
        return BallRoi(
            x: Int((cx - mitad + 0.5).rounded(.down)), y: Int((cy - mitad + 0.5).rounded(.down)),
            side: side, source: source
        ).clamped(width: width, height: height)
    }

    /// Las ROIs de un ciclo, todas del mismo lado porque son un lote.
    ///
    /// - Con predicción: su ROI, del lado con export más cercano a `ballRoiSigmaK`·σ +
    ///   `ballRoiMarginPx`, y de segunda hipótesis el grupo de `groups` más cercano a la
    ///   predicción que no caiga ya en la primera (a igual distancia, el primero).
    /// - Sin predicción: los primeros `maxRois` grupos, en el orden de quien llama, con el
    ///   lado mayor.
    ///
    /// Sin grupos sale una sola ROI (o ninguna sin predicción): la otra plaza del lote va
    /// a ceros, y eso es de IOS-74.
    public static func plan(
        prediction: (x: Double, y: Double, sigmaPx: Double)?,
        groups: [(x: Double, y: Double)],
        sides: [Int], maxRois: Int, width: Int, height: Int
    ) -> [BallRoi] {
        guard let mayor = sides.max(), maxRois > 0 else { return [] }
        guard let p = prediction else {
            return groups.prefix(maxRois).map {
                roi(centeredAt: $0.x, $0.y, side: mayor, source: .playerGuided, width: width, height: height)
            }
        }
        let pedido = DetectionSpec.ballRoiSigmaK * p.sigmaPx + Double(DetectionSpec.ballRoiMarginPx)
        let lado = heatmapSide(pedido, sides: sides) ?? mayor
        let primera = roi(centeredAt: p.x, p.y, side: lado, source: .predictive, width: width, height: height)
        guard maxRois > 1 else { return [primera] }
        var cercano: (x: Double, y: Double)?
        var mejor = Double.infinity
        for g in groups where !primera.contains(x: g.x, y: g.y) {
            let d2 = (g.x - p.x) * (g.x - p.x) + (g.y - p.y) * (g.y - p.y)
            if d2 < mejor { (cercano, mejor) = (g, d2) }
        }
        guard let g = cercano else { return [primera] }
        return [primera, roi(centeredAt: g.x, g.y, side: lado, source: .playerGuided, width: width, height: height)]
    }
}
