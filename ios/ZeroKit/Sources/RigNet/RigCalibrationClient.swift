// «Calibrar cosido» desde el mando (ADR 0035, IOS-122): la subida de las fotos a NUBE-09 y el
// cálculo. Es IOS-71 en corto: cada móvil sube las suyas con su `rig_key`, y el maestro pide
// `solve` por pareja y se queda con la de más puntos coherentes.
//
// El transporte se inyecta: los tests no necesitan red. Nada de aquí sale con un secreto dentro.

import Foundation
import RigCore

public enum RigCalibrationConstants {
    /// Fotos que sube cada móvil de las 5 que hace (`rigCalibPairCount`): una de cada dos, para
    /// no gastar datos en parejas casi iguales. Cada foto son ~1,3 MB.
    public static let uploadEvery = 2

    /// Veces que se intenta subir una foto antes de rendirse: los datos en la cancha cortan.
    public static let uploadAttempts = 3

    /// Segundos entre intentos, y mientras el VPS espera las fotos del otro móvil.
    public static let retryDelayS = 5.0

    /// Segundos que se espera a que el otro móvil suba las suyas y el VPS calcule, en total.
    public static let solveDeadlineS = 240.0

    /// Segundos que puede tardar una petición: subir 1,3 MB por datos malos, o el cálculo.
    public static let requestTimeoutS = 120.0
}

/// Una foto para subir.
public struct CalibrationUpload: Equatable, Sendable {
    public let pairId: String
    public let side: CameraSide
    public let jpeg: Data
    public let rigMs: Int64
    public let flipped: Bool
    /// La matriz 3×3 por filas; vacía si la cámara no la dio.
    public let intrinsics: [Double]

    public init(pairId: String, side: CameraSide, jpeg: Data, rigMs: Int64, flipped: Bool, intrinsics: [Double]) {
        self.pairId = pairId
        self.side = side
        self.jpeg = jpeg
        self.rigMs = rigMs
        self.flipped = flipped
        self.intrinsics = intrinsics
    }

    /// El nombre de la pareja en el VPS: el mismo en los dos móviles.
    public static func pairId(calibrationId: Int64, targetRigMs: Int64) -> String {
        "\(calibrationId)-\(targetRigMs)"
    }
}

/// Lo que devuelve el VPS con la mejor pareja.
public struct CalibrationSolved: Equatable, Sendable {
    public let rigText: String
    public let inliers: Int
    public let residualDeg: Double
    public let pairId: String
}

public enum RigCalibrationError: Error, Equatable, CustomStringConvertible {
    /// El token no vale o caducó.
    case qrExpired
    /// No hay red, o el VPS no contesta.
    case noInternet
    /// El VPS no llegó a tener las fotos del otro móvil.
    case missingPeer
    /// El otro móvil dijo que no pudo subir sus fotos.
    case peerFailed(String)
    /// Ninguna pareja calibra: el motivo es el del VPS.
    case notCalibrated(String)
    case server(Int, String)

    public var description: String {
        switch self {
        case .qrExpired:
            return "el QR Soporte no vale o caducó: escanéalo otra vez en los dos móviles"
        case .noInternet:
            return "sin internet o sin respuesta del VPS"
        case .missingPeer:
            return "el otro móvil no subió sus fotos: mira que tenga internet"
        case let .peerFailed(motivo):
            return "el otro móvil no pudo subir sus fotos: \(motivo)"
        case let .notCalibrated(motivo):
            return "no se pudo calibrar: \(motivo). Apunta a algo lejano y con detalle, sin nadie cerca"
        case let .server(codigo, detalle):
            return "el VPS contestó \(codigo): \(detalle)"
        }
    }
}

public final class RigCalibrationClient: Sendable {
    /// Hace la petición y devuelve el código y el cuerpo; lanza si no hay respuesta.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    private let baseUrl: URL
    private let rigKey: String
    private let transport: Transport
    private let sleep: @Sendable (Double) async -> Void
    private let nowS: @Sendable () -> Double

    public init(
        baseUrl: URL,
        rigKey: String,
        transport: @escaping Transport = RigCalibrationClient.urlSession,
        sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        nowS: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    ) {
        self.baseUrl = baseUrl
        self.rigKey = rigKey
        self.transport = transport
        self.sleep = sleep
        self.nowS = nowS
    }

    /// `https://<dominio>` a partir del túnel del QR Soporte (`wss://<dominio>/tunnel/v1`).
    public static func baseUrl(tunnelUrl: URL) -> URL? {
        guard let host = tunnelUrl.host else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = tunnelUrl.port
        return c.url
    }

    public static let urlSession: Transport = { peticion in
        let (cuerpo, respuesta) = try await URLSession.shared.data(for: peticion)
        return ((respuesta as? HTTPURLResponse)?.statusCode ?? 0, cuerpo)
    }

    /// Sube una foto, reintentando si la red corta.
    public func upload(_ foto: CalibrationUpload) async throws {
        var p = request(path: "\(foto.pairId)/\(foto.side.rawValue)", method: "PUT")
        p.httpBody = foto.jpeg
        p.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        p.setValue(String(foto.rigMs), forHTTPHeaderField: "X-Rig-Ms")
        p.setValue(foto.flipped ? "true" : "false", forHTTPHeaderField: "X-Flipped")
        if !foto.intrinsics.isEmpty {
            p.setValue(foto.intrinsics.map { String($0) }.joined(separator: ","), forHTTPHeaderField: "X-Intrinsics")
        }
        var ultimo = RigCalibrationError.noInternet
        for intento in 0..<RigCalibrationConstants.uploadAttempts {
            if intento > 0 { await sleep(RigCalibrationConstants.retryDelayS) }
            guard let (codigo, cuerpo) = try? await transport(p) else {
                ultimo = .noInternet
                continue
            }
            switch codigo {
            case 200, 201:
                return
            case 401, 403:
                throw RigCalibrationError.qrExpired
            case 500...:
                ultimo = .server(codigo, Self.detail(cuerpo))
            default:
                throw RigCalibrationError.server(codigo, Self.detail(cuerpo))
            }
        }
        throw ultimo
    }

    /// Pide el cálculo de cada pareja, esperando al otro móvil, y devuelve la de más puntos.
    /// `peerProblem`: si el otro móvil ya dijo que no sube sus fotos, para qué seguir esperando.
    public func solve(pairIds: [String], peerProblem: @escaping () -> String? = { nil }) async throws -> CalibrationSolved {
        let tope = nowS() + RigCalibrationConstants.solveDeadlineS
        var mejor: CalibrationSolved?
        var motivo = ""
        var faltaElOtro = false
        for id in pairIds {
            lazo: while true {
                let p = request(path: "\(id)/solve", method: "POST")
                var espera: RigCalibrationError?
                if let (codigo, cuerpo) = try? await transport(p) {
                    switch codigo {
                    case 200:
                        let r = try Self.parse(cuerpo, pairId: id)
                        if r.inliers > (mejor?.inliers ?? -1) { mejor = r }
                        break lazo
                    case 422:
                        motivo = Self.detail(cuerpo)
                        break lazo
                    case 409:
                        // Falta el lado del otro móvil.
                        faltaElOtro = true
                        if let motivo = peerProblem() { throw RigCalibrationError.peerFailed(motivo) }
                        espera = .missingPeer
                    case 503:
                        espera = .server(codigo, Self.detail(cuerpo))
                    case 401, 403:
                        throw RigCalibrationError.qrExpired
                    default:
                        throw RigCalibrationError.server(codigo, Self.detail(cuerpo))
                    }
                } else {
                    espera = .noInternet
                }
                if nowS() >= tope {
                    if mejor != nil { break lazo }
                    throw espera ?? .noInternet
                }
                await sleep(RigCalibrationConstants.retryDelayS)
            }
        }
        if let mejor { return mejor }
        throw motivo.isEmpty && faltaElOtro ? RigCalibrationError.missingPeer : .notCalibrated(motivo)
    }

    private func request(path: String, method: String) -> URLRequest {
        let url = baseUrl.appendingPathComponent("api/calibration/pairs").appendingPathComponent(path)
        var p = URLRequest(url: url, timeoutInterval: RigCalibrationConstants.requestTimeoutS)
        p.httpMethod = method
        p.setValue("Bearer \(rigKey)", forHTTPHeaderField: "Authorization")
        return p
    }

    private static func detail(_ cuerpo: Data) -> String {
        let o = try? JSONSerialization.jsonObject(with: cuerpo) as? [String: Any]
        return o?["detail"] as? String ?? ""
    }

    private static func parse(_ cuerpo: Data, pairId: String) throws -> CalibrationSolved {
        guard let o = try? JSONSerialization.jsonObject(with: cuerpo) as? [String: Any],
              let rig = o["rig"] as? [String: Any],
              let informe = o["report"] as? [String: Any],
              let inliers = (informe["inliers"] as? NSNumber)?.intValue,
              let datos = try? JSONSerialization.data(withJSONObject: rig, options: [.prettyPrinted, .sortedKeys]),
              let texto = String(data: datos, encoding: .utf8)
        else {
            throw RigCalibrationError.server(200, "respuesta sin rig")
        }
        return CalibrationSolved(
            rigText: texto, inliers: inliers,
            residualDeg: (informe["residual_deg"] as? NSNumber)?.doubleValue ?? 0, pairId: pairId
        )
    }
}
