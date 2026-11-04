// El cliente de «Calibrar cosido» contra un VPS de mentira (ADR 0035, IOS-122).

import Foundation
import RigCore
import RigNet
import XCTest

private final class VpsFalso: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var peticiones: [URLRequest] = []
    var respuestas: [(URLRequest) throws -> (Int, Data)] = []
    var porDefecto: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }

    func contesta(_ p: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        peticiones.append(p)
        if !respuestas.isEmpty { return try respuestas.removeFirst()(p) }
        return try porDefecto(p)
    }
}

private func json(_ codigo: Int, _ o: [String: Any]) -> (URLRequest) throws -> (Int, Data) {
    { _ in (codigo, try JSONSerialization.data(withJSONObject: o)) }
}

private let rigValido: [String: Any] = ["version": 1, "left": ["a": 1], "right": ["a": 2]]

private func resuelto(inliers: Int) -> (URLRequest) throws -> (Int, Data) {
    json(200, ["rig": rigValido, "report": ["inliers": inliers, "residual_deg": 0.25], "sha256": "x"])
}

final class RigCalibrationClientTests: XCTestCase {
    private func cliente(_ vps: VpsFalso) -> RigCalibrationClient {
        final class Reloj: @unchecked Sendable { var t = 0.0 }
        let reloj = Reloj()
        return RigCalibrationClient(
            baseUrl: URL(string: "https://vps.test")!, rigKey: "llave",
            transport: { try vps.contesta($0) },
            sleep: { reloj.t += $0 },
            nowS: { reloj.t }
        )
    }

    private let foto = CalibrationUpload(
        pairId: "100-105", side: .left, jpeg: Data([1, 2, 3]), rigMs: 106, flipped: true,
        intrinsics: [1440, 0, 1920, 0, 1440, 1080, 0, 0, 1]
    )

    func testLaSubidaLlevaLoQuePideElVps() async throws {
        let vps = VpsFalso()
        vps.porDefecto = json(201, ["pair_id": "100-105"])
        try await cliente(vps).upload(foto)
        let p = try XCTUnwrap(vps.peticiones.first)
        XCTAssertEqual(p.httpMethod, "PUT")
        XCTAssertEqual(p.url?.absoluteString, "https://vps.test/api/calibration/pairs/100-105/left")
        XCTAssertEqual(p.value(forHTTPHeaderField: "Authorization"), "Bearer llave")
        XCTAssertEqual(p.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(p.value(forHTTPHeaderField: "X-Rig-Ms"), "106")
        XCTAssertEqual(p.value(forHTTPHeaderField: "X-Flipped"), "true")
        XCTAssertEqual(p.value(forHTTPHeaderField: "X-Intrinsics"), "1440.0,0.0,1920.0,0.0,1440.0,1080.0,0.0,0.0,1.0")
        XCTAssertEqual(p.httpBody, Data([1, 2, 3]))
    }

    func testLaSubidaReintentaSiLaRedCortaYSeRindeConUnMotivo() async throws {
        let vps = VpsFalso()
        vps.respuestas = [{ _ in throw URLError(.networkConnectionLost) }]
        vps.porDefecto = json(201, [:])
        try await cliente(vps).upload(foto)
        XCTAssertEqual(vps.peticiones.count, 2)

        let sinRed = VpsFalso()
        sinRed.porDefecto = { _ in throw URLError(.notConnectedToInternet) }
        await assertThrows(RigCalibrationError.noInternet) { try await self.cliente(sinRed).upload(self.foto) }
        XCTAssertEqual(sinRed.peticiones.count, RigCalibrationConstants.uploadAttempts)

        let caducado = VpsFalso()
        caducado.porDefecto = json(401, ["detail": "token"])
        await assertThrows(RigCalibrationError.qrExpired) { try await self.cliente(caducado).upload(self.foto) }
        XCTAssertEqual(caducado.peticiones.count, 1, "reintentar no arregla un QR caducado")
    }

    func testSeQuedaConLaParejaDeMasPuntosYEsperaAlOtroMovil() async throws {
        let vps = VpsFalso()
        vps.respuestas = [
            json(409, ["detail": "falta la imagen right"]),
            resuelto(inliers: 40),
            json(422, ["detail": "solo hay 3 emparejamientos"]),
            resuelto(inliers: 90),
        ]
        let r = try await cliente(vps).solve(pairIds: ["a", "b", "c"])
        XCTAssertEqual(r.inliers, 90)
        XCTAssertEqual(r.pairId, "c")
        XCTAssertEqual(r.residualDeg, 0.25)
        XCTAssertTrue(r.rigText.contains("\"version\""))
        XCTAssertEqual(vps.peticiones.first?.url?.absoluteString, "https://vps.test/api/calibration/pairs/a/solve")
        XCTAssertEqual(vps.peticiones.first?.httpMethod, "POST")
    }

    func testSiNoCalibraDiceElMotivoDelVps() async throws {
        let vps = VpsFalso()
        vps.porDefecto = json(422, ["detail": "solo hay 3 emparejamientos"])
        await assertThrows(RigCalibrationError.notCalibrated("solo hay 3 emparejamientos")) {
            _ = try await self.cliente(vps).solve(pairIds: ["a", "b"])
        }
        XCTAssertTrue(RigCalibrationError.notCalibrated("x").description.contains("Apunta a algo lejano"))
    }

    func testSiElOtroMovilNoLlegaSeRindeAlTope() async throws {
        let vps = VpsFalso()
        vps.porDefecto = json(409, ["detail": "falta la imagen right"])
        await assertThrows(RigCalibrationError.missingPeer) { _ = try await self.cliente(vps).solve(pairIds: ["a"]) }
        let intentos = Int(RigCalibrationConstants.solveDeadlineS / RigCalibrationConstants.retryDelayS) + 1
        XCTAssertEqual(vps.peticiones.count, intentos)
    }

    func testLaDireccionSaleDelTunelDelQr() {
        XCTAssertEqual(
            RigCalibrationClient.baseUrl(tunnelUrl: URL(string: "wss://vps.test/tunnel/v1")!)?.absoluteString,
            "https://vps.test"
        )
        XCTAssertEqual(CalibrationUpload.pairId(calibrationId: 100, targetRigMs: 105), "100-105")
    }

    func testNingunMotivoLlevaLaLlave() {
        for e: RigCalibrationError in [.qrExpired, .noInternet, .missingPeer, .notCalibrated("x"), .server(500, "y")] {
            XCTAssertFalse(e.description.contains("llave"))
        }
    }

    private func assertThrows(
        _ esperado: RigCalibrationError, _ cuerpo: () async throws -> Void, line: UInt = #line
    ) async {
        do {
            try await cuerpo()
            XCTFail("no lanzó", line: line)
        } catch {
            XCTAssertEqual(error as? RigCalibrationError, esperado, line: line)
        }
    }
}
