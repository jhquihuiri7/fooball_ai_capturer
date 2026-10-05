// La parte del esclavo y la vista en el cable (IOS-52, ADR 0023 §1, §2 y §5).
//
// Medios va en binario big-endian de campos fijos. La vista lleva sus ángulos en rad y
// en f32, como dice el ADR: el esclavo pinta con la vista tal y como llegó, y el maestro
// pinta su mitad con la vista que trae la parte, así que las dos mitades usan los mismos
// f32 y no hay desgarro por redondeo.
//
// `part`: part_seq (u32) ‖ vista ‖ unidad de acceso H.264 en AVCC. El instante de
// captura va en el `rig_ms` de la cabecera; IDR y «vista extrapolada», en `flags`.
// `no_part`: view_id (u32) de la vista que no pedía este lado; el instante, en `rig_ms`.
// `view`: n (u8) ‖ n vistas, de la más vieja a la más nueva (VIEW_HISTORY).
// `idr_request`: el part_seq (u32) del hueco.

import Foundation

public enum ViewWire {
    /// target(8) + view_id(4) + yaw, pitch, hfov, seam, feather (5×4) + sides(1) + 6 ganancias (6×4).
    public static let encodedLength = 8 + 4 + 5 * 4 + 1 + 6 * 4

    /// Componentes de color por lado en las ganancias (RGB).
    public static let gainComponents = 3

    public static func encode(_ view: ViewCommand, into data: inout Data) {
        data.appendBigEndian(view.targetRigMs)
        data.appendBigEndian(view.viewId)
        for angulo in [view.yawRad, view.pitchRad, view.hfovRad, view.seamYawRad, view.featherRad] {
            data.appendBigEndian(Float(angulo).bitPattern)
        }
        var lados: UInt8 = 0
        if view.sides.contains(.left) { lados |= 1 << 0 }
        if view.sides.contains(.right) { lados |= 1 << 1 }
        data.append(lados)
        for g in gainsTriple(view.gains.left) + gainsTriple(view.gains.right) {
            data.appendBigEndian(Float(g).bitPattern)
        }
    }

    public static func decode(_ reader: inout BigEndianReader) -> ViewCommand? {
        guard let target = reader.read(Int64.self), let id = reader.read(UInt32.self) else {
            return nil
        }
        var angulos: [Double] = []
        for _ in 0..<5 {
            guard let bits = reader.read(UInt32.self) else { return nil }
            angulos.append(Double(Float(bitPattern: bits)))
        }
        guard let lados = reader.read(UInt8.self), lados & ~0b11 == 0 else { return nil }
        var ganancias: [Double] = []
        for _ in 0..<(2 * gainComponents) {
            guard let bits = reader.read(UInt32.self) else { return nil }
            ganancias.append(Double(Float(bitPattern: bits)))
        }
        guard angulos.allSatisfy(\.isFinite), ganancias.allSatisfy(\.isFinite) else { return nil }
        var sides: [CameraSide] = []
        if lados & (1 << 0) != 0 { sides.append(.left) }
        if lados & (1 << 1) != 0 { sides.append(.right) }
        return ViewCommand(
            targetRigMs: target, viewId: id,
            yawRad: angulos[0], pitchRad: angulos[1], hfovRad: angulos[2],
            sides: sides, seamYawRad: angulos[3], featherRad: angulos[4],
            gains: ColorGains(
                left: Array(ganancias[0..<gainComponents]),
                right: Array(ganancias[gainComponents...])
            )
        )
    }

    /// La vista tal y como sale del cable: lo que ve el otro móvil. El maestro la usa
    /// para su propia mitad cuando compone con una lente, y así tampoco hay salto entre
    /// un fotograma de dos lentes y uno de una.
    public static func quantized(_ view: ViewCommand) -> ViewCommand {
        var data = Data()
        encode(view, into: &data)
        var reader = BigEndianReader(data: data)
        return decode(&reader)!
    }

    /// El mensaje `view`: las últimas vistas, de la más vieja a la más nueva.
    public static func encodeHistory(_ views: [ViewCommand]) -> Data {
        precondition(views.count <= Int(UInt8.max), "demasiadas vistas en un mensaje")
        var data = Data(capacity: 1 + views.count * encodedLength)
        data.append(UInt8(views.count))
        views.forEach { encode($0, into: &data) }
        return data
    }

    public static func decodeHistory(_ payload: Data) -> [ViewCommand]? {
        var reader = BigEndianReader(data: payload)
        guard let n = reader.read(UInt8.self) else { return nil }
        var vistas: [ViewCommand] = []
        for _ in 0..<n {
            guard let v = decode(&reader) else { return nil }
            vistas.append(v)
        }
        return reader.offset == payload.count ? vistas : nil
    }

    private static func gainsTriple(_ g: [Double]) -> [Double] {
        // Una ganancia que no traiga sus tres componentes viaja como neutra.
        g.count == gainComponents ? g : Array(repeating: 1, count: gainComponents)
    }
}

/// Una parte codificada del esclavo, lista para el cable.
public struct PartPacket: Equatable, Sendable {
    public let partSeq: UInt32
    /// Instante de captura del fotograma del esclavo (`rig_ms` de la cabecera).
    public let frameRigMs: Int64
    /// La vista que usó de verdad, ya en f32.
    public let view: ViewCommand
    public let extrapolated: Bool
    /// La unidad de acceso es un IDR: con ella el decodificador arranca de cero.
    public let isKey: Bool
    /// La unidad de acceso H.264 en AVCC (NAL con su longitud de 4 B delante).
    public let accessUnit: Data

    public init(
        partSeq: UInt32, frameRigMs: Int64, view: ViewCommand, extrapolated: Bool,
        isKey: Bool, accessUnit: Data
    ) {
        self.partSeq = partSeq
        self.frameRigMs = frameRigMs
        self.view = view
        self.extrapolated = extrapolated
        self.isKey = isKey
        self.accessUnit = accessUnit
    }

    public var flags: LinkFrame.Flags {
        var f: LinkFrame.Flags = []
        if isKey { f.insert(.idr) }
        if extrapolated { f.insert(.extrapolated) }
        return f
    }

    public func payload() -> Data {
        var data = Data(capacity: 4 + ViewWire.encodedLength + accessUnit.count)
        data.appendBigEndian(partSeq)
        ViewWire.encode(view, into: &data)
        data.append(accessUnit)
        return data
    }

    /// La trama de medios sin sellar (la sesión pone `session`, `seq` y el tag).
    public func frame(session: UInt32 = 0, seq: UInt32 = 0) -> LinkFrame {
        LinkFrame(
            type: .part, flags: flags, session: session, seq: seq,
            rigMs: UInt64(max(0, frameRigMs)), payload: payload()
        )
    }

    public static func decode(_ frame: LinkFrame) -> PartPacket? {
        guard frame.type == .part else { return nil }
        var reader = BigEndianReader(data: frame.payload)
        guard let seq = reader.read(UInt32.self), let vista = ViewWire.decode(&reader),
              reader.offset < frame.payload.count
        else {
            return nil
        }
        return PartPacket(
            partSeq: seq,
            frameRigMs: Int64(frame.rigMs),
            view: vista,
            extrapolated: frame.flags.contains(.extrapolated),
            isKey: frame.flags.contains(.idr),
            accessUnit: Data(frame.payload[(frame.payload.startIndex + reader.offset)...])
        )
    }
}

/// «Esta vista no necesita mi lado»: el maestro no espera la parte de ese instante.
public struct NoPartPacket: Equatable, Sendable {
    public let frameRigMs: Int64
    public let viewId: UInt32

    public init(frameRigMs: Int64, viewId: UInt32) {
        self.frameRigMs = frameRigMs
        self.viewId = viewId
    }

    public func frame(session: UInt32 = 0, seq: UInt32 = 0) -> LinkFrame {
        var payload = Data()
        payload.appendBigEndian(viewId)
        return LinkFrame(
            type: .noPart, session: session, seq: seq,
            rigMs: UInt64(max(0, frameRigMs)), payload: payload
        )
    }

    public static func decode(_ frame: LinkFrame) -> NoPartPacket? {
        guard frame.type == .noPart, frame.payload.count == 4 else { return nil }
        var reader = BigEndianReader(data: frame.payload)
        guard let id = reader.read(UInt32.self) else { return nil }
        return NoPartPacket(frameRigMs: Int64(frame.rigMs), viewId: id)
    }
}

/// `idr_request`, por control: el part_seq del hueco.
public enum IdrRequestWire {
    public static func encode(partSeq: UInt32) -> Data {
        var data = Data()
        data.appendBigEndian(partSeq)
        return data
    }

    public static func decode(_ payload: Data) -> UInt32? {
        guard payload.count == 4 else { return nil }
        var reader = BigEndianReader(data: payload)
        return reader.read(UInt32.self)
    }
}

/// `color_means`, por medios (IOS-38): la media BGR del solape del esclavo, en f32.
public enum ColorMeansWire {
    public static func encode(bgr: [Double]) -> Data {
        precondition(bgr.count == 3, "tres canales BGR")
        var data = Data()
        bgr.forEach { data.appendBigEndian(Float($0).bitPattern) }
        return data
    }

    public static func decode(_ payload: Data) -> [Double]? {
        guard payload.count == 12 else { return nil }
        var reader = BigEndianReader(data: payload)
        var bgr: [Double] = []
        for _ in 0..<3 {
            guard let bits = reader.read(UInt32.self) else { return nil }
            let v = Double(Float(bitPattern: bits))
            guard v.isFinite, v >= 0 else { return nil }
            bgr.append(v)
        }
        return bgr
    }
}
