// La franja jugable y cómo entra al detector (IOS-20, réplica de InputRegion e
// InputLayout de libs/vision/postprocess.py y del códec de BandGeometry de
// libs/vision/band.py).
//
// band.json lo escribe la calibración del VPS (tools/band_geometry.py); el móvil lo
// carga tal cual y no recalcula la franja. Sus píxeles «nativos» son los de la imagen
// ENDEREZADA, como rig.json y pitch.json: el móvil montado cabeza abajo (el izquierdo)
// pasa del búfer crudo a esas coordenadas con el giro de 180° de CameraMount.

import Foundation

/// Un rectángulo de la entrada del modelo y de dónde sale en el frame nativo. La
/// escala es la misma en los dos ejes por construcción y se valida: una región que
/// deformara devolvería cajas estiradas sin dar error.
public struct InputRegion: Equatable, Sendable {
    public let dstX: Int
    public let dstY: Int
    public let dstW: Int
    public let dstH: Int
    public let srcX: Double
    public let srcY: Double
    public let srcW: Double
    public let srcH: Double

    /// Tolerancia relativa al comprobar que sx = sy (`_SCALE_RTOL` de la referencia).
    static let scaleRelTol = 1e-9

    public init(
        dstX: Int, dstY: Int, dstW: Int, dstH: Int,
        srcX: Double, srcY: Double, srcW: Double, srcH: Double
    ) throws {
        guard dstW > 0, dstH > 0 else {
            throw RigError.message("la región de entrada debe tener área: \(dstW)×\(dstH)")
        }
        guard srcW > 0, srcH > 0 else {
            throw RigError.message("la región nativa debe tener área: \(srcW)×\(srcH)")
        }
        let sx = srcW / Double(dstW), sy = srcH / Double(dstH)
        guard abs(sx - sy) <= Self.scaleRelTol * max(abs(sx), abs(sy)) else {
            throw RigError.message(
                "la región deforma: \(sx) px nativos por píxel de entrada en x frente a "
                    + "\(sy) en y. La franja y el mosaico se reducen sin deformar (ADR 0020)"
            )
        }
        self.dstX = dstX
        self.dstY = dstY
        self.dstW = dstW
        self.dstH = dstH
        self.srcX = srcX
        self.srcY = srcY
        self.srcW = srcW
        self.srcH = srcH
    }

    /// Píxeles nativos por píxel de entrada. 1.0 es resolución nativa.
    public var scale: Double { srcW / Double(dstW) }

    public func toNative(xInput: Double, yInput: Double) -> (x: Double, y: Double) {
        (srcX + (xInput - Double(dstX)) * scale, srcY + (yInput - Double(dstY)) * scale)
    }

    /// Inversa exacta de `toNative`.
    public func toInput(xNative: Double, yNative: Double) -> (x: Double, y: Double) {
        (Double(dstX) + (xNative - srcX) / scale, Double(dstY) + (yNative - srcY) / scale)
    }

    public func containsInput(x: Double, y: Double) -> Bool {
        Double(dstX) <= x && x < Double(dstX + dstW) && Double(dstY) <= y && y < Double(dstY + dstH)
    }
}

/// Cómo está empaquetada la entrada: una región, o el mosaico por distancia.
public struct InputLayout: Equatable, Sendable {
    public let regions: [InputRegion]

    public init(regions: [InputRegion]) throws {
        guard !regions.isEmpty else {
            throw RigError.message("un layout sin regiones no describe ninguna entrada")
        }
        self.regions = regions
    }

    /// La región de un punto de la entrada: la primera que lo contiene, y si ninguna,
    /// la más cercana (a igual distancia, la primera, como `min` de Python).
    public func regionIndex(xInput: Double, yInput: Double) -> Int {
        if let i = regions.firstIndex(where: { $0.containsInput(x: xInput, y: yInput) }) {
            return i
        }
        var mejor = 0
        var mejorDistancia = Double.infinity
        for (i, r) in regions.enumerated() {
            let dx = max(Double(r.dstX) - xInput, 0, xInput - Double(r.dstX + r.dstW))
            let dy = max(Double(r.dstY) - yInput, 0, yInput - Double(r.dstY + r.dstH))
            let d = dx * dx + dy * dy
            if d < mejorDistancia {
                mejor = i
                mejorDistancia = d
            }
        }
        return mejor
    }
}

/// Qué filas nativas forman la franja de una cámara y cómo entran al detector.
public struct BandGeometry: Equatable, Sendable {
    public static let fileVersion = DetectionSpec.bandFileVersion

    public let side: CameraSide
    /// Primera fila nativa de la franja (incluida) y la que la acaba (excluida).
    public let rowTop: Int
    public let rowBottom: Int
    public let layout: InputLayout
    public let inputWidth: Int
    public let inputHeight: Int
    /// Fila nativa donde parte el mosaico, o `nil` con una sola región.
    public let farSplitRow: Int?

    public var rows: Int { rowBottom - rowTop }

    /// Píxeles nativos por píxel de entrada en esa fila: manda la región que la
    /// contiene; fuera de la franja, la más cercana por filas.
    public func scaleAtRow(_ nativeRow: Double) -> Double {
        if let r = layout.regions.first(where: { $0.srcY <= nativeRow && nativeRow < $0.srcY + $0.srcH }) {
            return r.scale
        }
        var mejor = layout.regions[0]
        var mejorDistancia = Double.infinity
        for r in layout.regions {
            let d = min(abs(nativeRow - r.srcY), abs(nativeRow - (r.srcY + r.srcH)))
            if d < mejorDistancia {
                mejor = r
                mejorDistancia = d
            }
        }
        return mejor.scale
    }

    /// Un punto de la entrada del detector en el búfer CRUDO de la cámara: la región
    /// lo lleva a nativo enderezado, y el móvil cabeza abajo lo gira 180°.
    public func toRaw(
        xInput: Double, yInput: Double, nativeWidth: Int, nativeHeight: Int, upsideDown: Bool
    ) -> (x: Double, y: Double) {
        let region = layout.regions[layout.regionIndex(xInput: xInput, yInput: yInput)]
        let nativo = region.toNative(xInput: xInput, yInput: yInput)
        guard upsideDown else { return nativo }
        return CameraMount.uprightPoint(x: nativo.x, y: nativo.y, width: nativeWidth, height: nativeHeight)
    }
}

// MARK: - Códec de band.json, versión 1

extension BandGeometry {
    public func toDictionary() -> [String: Any] {
        [
            "version": Self.fileVersion,
            "side": side.rawValue,
            "rows": [rowTop, rowBottom],
            "input_size": [inputWidth, inputHeight],
            "far_split_row": farSplitRow.map { $0 as Any } ?? NSNull(),
            "regions": layout.regions.map { r in
                [
                    "dst": [r.dstX, r.dstY, r.dstW, r.dstH],
                    "src": [r.srcX, r.srcY, r.srcW, r.srcH],
                ] as [String: Any]
            },
        ]
    }

    /// Inversa de `toDictionary`. Además de lo que valida la referencia, comprueba que
    /// la franja cabe en la entrada del detector del móvil (ADR 0020): con una
    /// entrada de otro tamaño, el modelo compilado no la aceptaría.
    public static func fromDictionary(_ data: [String: Any]) throws -> BandGeometry {
        guard let version = data["version"] as? Int, version == fileVersion else {
            throw RigError.message(
                "version de band.json no soportada: \(String(describing: data["version"])) "
                    + "(se espera \(fileVersion))"
            )
        }
        guard let filas = enteros(data["rows"]), filas.count == 2 else {
            throw RigError.message("band.json: `rows` tiene que ser [top, bottom]")
        }
        guard let tamano = enteros(data["input_size"]), tamano.count == 2 else {
            throw RigError.message("band.json: `input_size` tiene que ser [ancho, alto]")
        }
        guard let crudas = data["regions"] as? [Any], !crudas.isEmpty else {
            throw RigError.message("band.json: `regions` tiene que ser una lista no vacía")
        }
        var regiones: [InputRegion] = []
        for (numero, cruda) in crudas.enumerated() {
            guard let objeto = cruda as? [String: Any] else {
                throw RigError.message("band.json: la región \(numero) tiene que ser un objeto")
            }
            guard let dst = enteros(objeto["dst"]), dst.count == 4 else {
                throw RigError.message("band.json: región \(numero): `dst` tiene que ser [x, y, w, h]")
            }
            guard let src = numeros(objeto["src"]), src.count == 4 else {
                throw RigError.message("band.json: región \(numero): `src` tiene que ser [x, y, w, h]")
            }
            regiones.append(try InputRegion(
                dstX: dst[0], dstY: dst[1], dstW: dst[2], dstH: dst[3],
                srcX: src[0], srcY: src[1], srcW: src[2], srcH: src[3]
            ))
        }
        guard let ladoCrudo = data["side"] as? String, let lado = CameraSide(rawValue: ladoCrudo) else {
            throw RigError.message("band.json: `side` tiene que ser left o right")
        }
        var far: Int?
        if let crudo = data["far_split_row"], !(crudo is NSNull) {
            // Un NSNumber entero también «es» Bool en Swift: el booleano se reconoce por
            // su tipo de CoreFoundation, no con `is Bool`.
            let esBooleano = (crudo as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            guard let fila = crudo as? Int, !esBooleano else {
                throw RigError.message("band.json: `far_split_row` tiene que ser una fila o null")
            }
            far = fila
        }
        let banda = BandGeometry(
            side: lado,
            rowTop: filas[0],
            rowBottom: filas[1],
            layout: try InputLayout(regions: regiones),
            inputWidth: tamano[0],
            inputHeight: tamano[1],
            farSplitRow: far
        )
        try banda.checkFitsDetector()
        return banda
    }

    public static func load(from url: URL) throws -> BandGeometry {
        let data = try Data(contentsOf: url)
        guard let crudo = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RigError.message("\(url.lastPathComponent): no es un objeto JSON")
        }
        return try fromDictionary(crudo)
    }

    /// La entrada es la del detector y cada región cae dentro de ella.
    public func checkFitsDetector(
        width: Int = DetectionSpec.playerInputWidth, height: Int = DetectionSpec.playerInputHeight
    ) throws {
        guard inputWidth == width, inputHeight == height else {
            throw RigError.message(
                "band.json: la entrada es \(inputWidth)×\(inputHeight) y el detector espera \(width)×\(height)"
            )
        }
        for (i, r) in layout.regions.enumerated()
        where r.dstX < 0 || r.dstY < 0 || r.dstX + r.dstW > width || r.dstY + r.dstH > height {
            throw RigError.message("band.json: la región \(i) se sale de la entrada \(width)×\(height)")
        }
    }

    /// Números truncados a entero, como `int(...)` en la referencia.
    private static func enteros(_ crudo: Any?) -> [Int]? {
        numeros(crudo)?.map { Int($0) }
    }

    private static func numeros(_ crudo: Any?) -> [Double]? {
        guard let lista = crudo as? [Any] else { return nil }
        let valores = lista.compactMap { $0 as? Double ?? ($0 as? Int).map(Double.init) }
        return valores.count == lista.count ? valores : nil
    }
}
