// El registro N0 del partido en el móvil (IOS-75): los registros de match-log-v1
// (libs/vision/match_log.py, EV-02), escritos byte a byte como `json.dumps(…,
// sort_keys=True, ensure_ascii=False)` de Python: claves ordenadas, separadores ", " y
// ": ", decimales con el repr más corto (100.0, 0.91) y null para lo que falta. La
// muestra dorada match_log_sample.jsonl lo comprueba línea a línea.

import Foundation

/// Un valor JSON con el formato de Python.
public indirect enum PyJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PyJSON])
    case object([String: PyJSON])

    public var text: String {
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .int(i): return String(i)
        case let .double(d): return Self.repr(d)
        case let .string(s): return Self.quote(s)
        case let .array(a): return "[" + a.map(\.text).joined(separator: ", ") + "]"
        case let .object(o):
            return "{" + o.keys.sorted().map { "\(Self.quote($0)): \(o[$0]!.text)" }.joined(separator: ", ") + "}"
        }
    }

    /// `repr` de un float de Python: el más corto que vuelve al mismo Double, siempre con
    /// punto o exponente (100.0, 0.91, 1e-05).
    static func repr(_ d: Double) -> String {
        guard d.isFinite else { return d.isNaN ? "NaN" : (d > 0 ? "Infinity" : "-Infinity") }
        var s = "\(d)"
        if let e = s.firstIndex(of: "e") {
            // Swift escribe 1e-05 y 1e+16 igual que Python; solo hay que quitar el ".0" de la mantisa.
            let mantisa = s[..<e], exp = s[e...]
            s = (mantisa.hasSuffix(".0") ? String(mantisa.dropLast(2)) : String(mantisa)) + exp
        }
        return s
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

/// Los registros de match-log-v1.
public enum MatchLogRecord: Equatable, Sendable {
    public static let schema = "match-log-v1"

    public struct Model: Equatable, Sendable {
        public let name: String, version: String, sha256: String
        public init(name: String, version: String, sha256: String) {
            self.name = name; self.version = version; self.sha256 = sha256
        }
    }

    public struct Box: Equatable, Sendable {
        public let box: [Double]  // x1, y1, x2, y2 en px nativos
        public let cls: String
        public let score: Double
        public let feetDeg: [Double]?
        public let feetM: [Double]?
        public init(box: [Double], cls: String, score: Double, feetDeg: [Double]?, feetM: [Double]?) {
            self.box = box; self.cls = cls; self.score = score; self.feetDeg = feetDeg; self.feetM = feetM
        }
    }

    case header(matchId: String, rigId: String, clockDomain: String, appVersion: String,
                models: [Model], rigSha: String?, pitchSha: String?, bandSha: String?)
    case det(rigMs: Int64, side: CameraSide, model: String, boxes: [Box])
    case view(rigMs: Int64, yawDeg: Double, pitchDeg: Double, hfovDeg: Double, shot: String)
    case mark(rigMs: Int64, kind: String, source: String, by: String?, confidence: Double?)
    case score(rigMs: Int64, home: Int, away: Int)
    case clock(rigMs: Int64, running: Bool, startedRigMs: Int64?, baseS: Double)
    case audio(rigMs: Int64, kind: String, durationMs: Int, confidence: Double)
    case clip(rigMs: Int64, id: String, kind: String, t0RigMs: Int64, t1RigMs: Int64)

    private static func opt(_ s: String?) -> PyJSON { s.map(PyJSON.string) ?? .null }
    private static func optD(_ d: Double?) -> PyJSON { d.map(PyJSON.double) ?? .null }
    private static func optA(_ a: [Double]?) -> PyJSON { a.map { .array($0.map(PyJSON.double)) } ?? .null }

    public var json: PyJSON {
        switch self {
        case let .header(m, r, c, a, models, rig, pitch, band):
            return .object([
                "schema": .string(Self.schema), "match_id": .string(m), "rig_id": .string(r),
                "clock_domain": .string(c), "app_version": .string(a),
                "models": .array(models.map {
                    .object(["name": .string($0.name), "version": .string($0.version), "sha256": .string($0.sha256)])
                }),
                "rig_sha": Self.opt(rig), "pitch_sha": Self.opt(pitch), "band_sha": Self.opt(band),
            ])
        case let .det(t, side, model, boxes):
            return .object([
                "type": .string("det"), "rig_ms": .int(t), "side": .string(side.rawValue), "model": .string(model),
                "boxes": .array(boxes.map {
                    .object([
                        "box": .array($0.box.map(PyJSON.double)), "cls": .string($0.cls), "score": .double($0.score),
                        "feet_deg": Self.optA($0.feetDeg), "feet_m": Self.optA($0.feetM),
                    ])
                }),
            ])
        case let .view(t, y, p, h, shot):
            return .object([
                "type": .string("view"), "rig_ms": .int(t), "yaw_deg": .double(y), "pitch_deg": .double(p),
                "hfov_deg": .double(h), "shot": .string(shot),
            ])
        case let .mark(t, kind, source, by, conf):
            return .object([
                "type": .string("mark"), "rig_ms": .int(t), "kind": .string(kind), "source": .string(source),
                "by": Self.opt(by), "confidence": Self.optD(conf),
            ])
        case let .score(t, h, a):
            return .object(["type": .string("score"), "rig_ms": .int(t), "home": .int(Int64(h)), "away": .int(Int64(a))])
        case let .clock(t, running, started, base):
            return .object([
                "type": .string("clock"), "rig_ms": .int(t), "running": .bool(running),
                "started_rig_ms": started.map(PyJSON.int) ?? .null, "base_s": .double(base),
            ])
        case let .audio(t, kind, dur, conf):
            return .object([
                "type": .string("audio"), "rig_ms": .int(t), "kind": .string(kind),
                "duration_ms": .int(Int64(dur)), "confidence": .double(conf),
            ])
        case let .clip(t, id, kind, t0, t1):
            return .object([
                "type": .string("clip"), "rig_ms": .int(t), "id": .string(id), "kind": .string(kind),
                "t0_rig_ms": .int(t0), "t1_rig_ms": .int(t1),
            ])
        }
    }

    /// La línea del JSONL, sin el salto.
    public var line: String { json.text }
}
