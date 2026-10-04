// La foto de telemetría de 1 Hz (IOS-05): lo que el móvil dice de sí mismo.
//
// Es el contrato que viaja al VPS y acaba en la matriz de REF-45: claves snake_case
// fijas y nada opcional que cambie de nombre. Una línea de estas por segundo es lo que
// permite reconstruir un partido desde Documents/telemetry/ sin estar delante.

import Foundation

/// Las latencias de una etapa y su cadencia real.
public struct StageTelemetry: Codable, Equatable, Sendable {
    public var p50Ms: Double
    public var p90Ms: Double
    public var p99Ms: Double
    /// Hz reales medidos, no los nominales: es lo que delata a una etapa que se ahoga.
    public var hz: Double

    public init(p50Ms: Double, p90Ms: Double, p99Ms: Double, hz: Double) {
        self.p50Ms = p50Ms
        self.p90Ms = p90Ms
        self.p99Ms = p99Ms
        self.hz = hz
    }

    public init(histogram: LatencyHistogram, hz: Double) {
        self.init(p50Ms: histogram.p50Ms, p90Ms: histogram.p90Ms, p99Ms: histogram.p99Ms, hz: hz)
    }

    enum CodingKeys: String, CodingKey {
        case p50Ms = "p50_ms"
        case p90Ms = "p90_ms"
        case p99Ms = "p99_ms"
        case hz
    }
}

public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    /// El reloj del soporte en el instante de la foto, en ms.
    public var rigMs: Int64
    public var fps: Double
    /// `didDrop` acumulados de la sesión de cámara: el contador que ningún banco
    /// puede dejar de mirar.
    public var didDrop: Int
    /// Descartes por cola acotada, por nombre de cola.
    public var queueDrops: [String: Int]
    /// Latencias por etapa: capture, blit, preprocess, infer, decode, render, encode,
    /// link, srt. Las claves son los `RigStage.rawValue` de los signposts.
    public var stages: [String: StageTelemetry]
    /// ms de predicción por modelo (contrato de REF-45): "dfine-n-band", "ball-roilite"…
    public var inferMsByModel: [String: Double]
    public var thermalState: String
    public var systemPressure: String
    /// Nivel de la escalera de degradación (IOS-06), 0 = L0.
    public var ladderLevel: Int
    /// Batería de 0 a 1, y si está cargando por el hub.
    public var batteryLevel: Double
    public var charging: Bool
    /// `os_proc_available_memory`, en bytes: lo que queda antes del jetsam.
    public var availableMemoryBytes: Int64
    public var linkRttMs: Double?
    public var linkLossPercent: Double?
    public var programBitrateBps: Int?
    /// Las intrínsecas de este fotograma frente a rig.json (IOS-72, M2). Campo
    /// pasante de la telemetría v1: quien no lo conozca lo ignora.
    public var intrinsics: IntrinsicsDrift?
    /// La mediana de la separación de la costura (SeamWatch, IOS-72).
    public var seamMedianRad: Double?

    public init(
        rigMs: Int64,
        fps: Double,
        didDrop: Int,
        queueDrops: [String: Int],
        stages: [String: StageTelemetry],
        inferMsByModel: [String: Double],
        thermalState: String,
        systemPressure: String,
        ladderLevel: Int,
        batteryLevel: Double,
        charging: Bool,
        availableMemoryBytes: Int64,
        linkRttMs: Double? = nil,
        linkLossPercent: Double? = nil,
        programBitrateBps: Int? = nil,
        intrinsics: IntrinsicsDrift? = nil,
        seamMedianRad: Double? = nil
    ) {
        self.rigMs = rigMs
        self.fps = fps
        self.didDrop = didDrop
        self.queueDrops = queueDrops
        self.stages = stages
        self.inferMsByModel = inferMsByModel
        self.thermalState = thermalState
        self.systemPressure = systemPressure
        self.ladderLevel = ladderLevel
        self.batteryLevel = batteryLevel
        self.charging = charging
        self.availableMemoryBytes = availableMemoryBytes
        self.linkRttMs = linkRttMs
        self.linkLossPercent = linkLossPercent
        self.programBitrateBps = programBitrateBps
        self.intrinsics = intrinsics
        self.seamMedianRad = seamMedianRad
    }

    enum CodingKeys: String, CodingKey {
        case rigMs = "rig_ms"
        case fps
        case didDrop = "did_drop"
        case queueDrops = "queue_drops"
        case stages
        case inferMsByModel = "infer_ms_by_model"
        case thermalState = "thermal_state"
        case systemPressure = "system_pressure"
        case ladderLevel = "ladder_level"
        case batteryLevel = "battery_level"
        case charging
        case availableMemoryBytes = "available_memory_bytes"
        case linkRttMs = "link_rtt_ms"
        case linkLossPercent = "link_loss_percent"
        case programBitrateBps = "program_bitrate_bps"
        case intrinsics
        case seamMedianRad = "seam_median_rad"
    }

    /// Una línea JSONL determinista: claves ordenadas, sin flotantes exponenciales.
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
