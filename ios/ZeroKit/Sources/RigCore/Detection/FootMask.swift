// La máscara del campo del decodificador de jugadores (§14.2, IOS-23): dice si los pies
// de una caja pisan el campo. Es el `pitch_mask[y, x]` de PlayerDetector.detect sin el
// mapa de bits: el pie se recorta al fotograma y se trunca a píxel igual que allí, y el
// píxel se pregunta a quien sepa la respuesta. Con un PitchModel (IOS-36), es la máscara
// rasterizada como la define el blueprint —cada píxel, ¿su proyección a metros cae en el
// área jugable?— evaluada solo en los pies que hacen falta.

import Foundation

public struct FootMask: Sendable {
    /// El tamaño del fotograma NATIVO de la cámara, el de las cajas.
    public let width: Int
    public let height: Int
    private let inside: @Sendable (Int, Int) -> Bool

    /// `inside(x, y)` responde por el píxel nativo (x, y), con 0 ≤ x < width y 0 ≤ y < height.
    public init(width: Int, height: Int, inside: @escaping @Sendable (Int, Int) -> Bool) throws {
        guard width > 0, height > 0 else {
            throw RigError.message("la máscara del campo necesita un fotograma y mide \(width)x\(height)")
        }
        self.width = width
        self.height = height
        self.inside = inside
    }

    /// La máscara de la homografía de la cámara: el píxel, a metros, dentro del campo con
    /// `marginM` (PitchModel.isInsidePlayable).
    public init(
        pitch: PitchModel, width: Int, height: Int, marginM: Double = RigConstants.pitchPlayableMarginM
    ) throws {
        try self.init(width: width, height: height) { x, y in
            pitch.isInsidePlayable(xPx: Double(x), yPx: Double(y), marginM: marginM)
        }
    }

    /// Los pies (centro del borde inferior, en float32 como la referencia) recortados al
    /// fotograma y truncados a píxel: `np.clip(...).astype(np.intp)`. Un pie NaN (una
    /// salida rota del modelo) no pisa el campo: truncarlo abortaría la app.
    public func contains(footX: Float, footY: Float) -> Bool {
        guard !footX.isNaN, !footY.isNaN else { return false }
        let x = min(max(footX, 0), Float(width - 1))
        let y = min(max(footY, 0), Float(height - 1))
        return inside(Int(x), Int(y))
    }
}
