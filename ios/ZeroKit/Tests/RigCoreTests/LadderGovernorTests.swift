import XCTest

@testable import RigCore

/// La escalera actuando en la arquitectura B (IOS-06 con IOS-25/44/50): la peor de las dos
/// escaleras manda en la IA, la cadencia común por la orden del maestro, L2 sin detecciones,
/// L4 sin parte y el forzado de los bancos.
final class LadderGovernorTests: XCTestCase {
    /// Una escalera ya en `nivel` (empeorar es inmediato).
    private func gobernador(en nivel: LadderLevel, force: LadderForce? = nil) -> LadderGovernor {
        var g = LadderGovernor(force: force)
        g.step(sensors: nivel, elapsedS: 0, dtS: 1)
        return g
    }

    // MARK: - La peor de las dos

    func testElMaestroDetectaALaCadenciaDeLaPeorDeLasDos() {
        var maestro = gobernador(en: .l0)
        XCTAssertEqual(maestro.actions(isMaster: true).playerHz, LadderConstants.playerHzL0)

        // El esclavo cuenta L1 en su latido: los dos a 5 Hz, y el programa sigue igual.
        maestro.setPeer(level: .l1)
        XCTAssertEqual(maestro.aiLevel(isMaster: true), .l1)
        let a = maestro.actions(isMaster: true)
        XCTAssertEqual(LadderGovernor.detectionHz(a), LadderConstants.playerHzL1)
        XCTAssertFalse(a.ballEnabled)
        XCTAssertEqual(a.programBitrateFactor, 1.0, "el programa va con la escalera del maestro")
        XCTAssertEqual(maestro.level, .l0, "el latido no cambia la escalera propia")

        // Y si el esclavo cae, su escalera deja de contar.
        maestro.setPeer(level: nil)
        XCTAssertEqual(maestro.aiLevel(isMaster: true), .l0)
    }

    func testLaOrdenLlevaLaComunYElEsclavoNuncaPasaDeLaSuya() {
        // El maestro en L2 manda apagar: el esclavo, aunque esté frío, no detecta.
        var esclavo = gobernador(en: .l0)
        esclavo.setCommanded(level: CadenceCommand(level: gobernador(en: .l2).aiLevel(isMaster: true)).level)
        XCTAssertFalse(esclavo.actions(isMaster: false).aiEnabled)
        XCTAssertEqual(LadderGovernor.detectionHz(esclavo.actions(isMaster: false)), 0)

        // El esclavo en L1 con una orden de L0 vieja: lo suyo se aplica ya, sin esperarla.
        var caliente = gobernador(en: .l1)
        caliente.setCommanded(level: .l0)
        XCTAssertEqual(LadderGovernor.detectionHz(caliente.actions(isMaster: false)), LadderConstants.playerHzL1)

        // Sin maestro (la orden caduca), solo la suya.
        caliente.setCommanded(level: nil)
        XCTAssertEqual(caliente.aiLevel(isMaster: false), .l1)
    }

    func testLaIaDeUnLadoSiempreEsLaDelOtro() {
        // Cualquier pareja de escaleras: el maestro manda la común y el esclavo, con ella,
        // detecta a la misma cadencia que el maestro.
        for propio in LadderLevel.allCases {
            for otro in LadderLevel.allCases {
                var maestro = gobernador(en: propio)
                maestro.setPeer(level: otro)
                var esclavo = gobernador(en: otro)
                esclavo.setCommanded(level: CadenceCommand(level: maestro.aiLevel(isMaster: true)).level)
                XCTAssertEqual(maestro.aiLevel(isMaster: true), max(propio, otro))
                XCTAssertEqual(LadderGovernor.detectionHz(maestro.actions(isMaster: true)),
                               LadderGovernor.detectionHz(esclavo.actions(isMaster: false)),
                               "L\(propio.rawValue) y L\(otro.rawValue)")
            }
        }
    }

    // MARK: - L2: sin detecciones

    func testEnL2NoSeDetectaNada() {
        let maestro = gobernador(en: .l2)
        var puerta = DetectionGate(frameDurationMs: 1000.0 / 30)
        puerta.set(hz: LadderGovernor.detectionHz(maestro.actions(isMaster: true)))
        XCTAssertEqual(puerta.hz, 0)
        for n in 0..<300 {
            XCTAssertNil(puerta.due(latestRigMs: Int64((Double(n) * 1000 / 30).rounded())))
        }
        XCTAssertFalse(maestro.actions(isMaster: true).aiEnabled)
        XCTAssertTrue(maestro.actions(isMaster: true).programEnabled, "el programa sigue")
        XCTAssertTrue(maestro.actions(isMaster: true).localRecording)
    }

    // MARK: - L3 y L4

    func testL3BajaElProgramaYL4ParaLaParteDelEsclavo() {
        let m3 = gobernador(en: .l3).actions(isMaster: true)
        XCTAssertEqual(m3.programBitrateFactor, LadderConstants.bitrateFactorL3)

        // El esclavo en L4: sin parte; su grabación sigue.
        let e4 = gobernador(en: .l4).actions(isMaster: false)
        XCTAssertFalse(e4.partEnabled)
        XCTAssertTrue(e4.localRecording)

        // El maestro lo sabe por el latido y sigue con una lente; con L3, aún la espera.
        var maestro = gobernador(en: .l0)
        maestro.setPeer(level: .l4)
        XCTAssertTrue(maestro.peerStoppedParts)
        maestro.setPeer(level: .l3)
        XCTAssertFalse(maestro.peerStoppedParts)
        maestro.setPeer(level: nil)
        XCTAssertFalse(maestro.peerStoppedParts, "caído es la otra regla (IOS-81), no esta")

        // El maestro en L4 no tiene cesión todavía (IOS-86): sigue como en L3, con su parte.
        let m4 = gobernador(en: .l4).actions(isMaster: true)
        XCTAssertTrue(m4.partEnabled)
        XCTAssertTrue(m4.programEnabled)
        XCTAssertEqual(m4.programBitrateFactor, LadderConstants.bitrateFactorL3)
    }

    // MARK: - El forzado de los bancos

    func testElForzadoSeLeeDelEntorno() {
        XCTAssertNil(LadderForce.parse(environment: [:]))
        XCTAssertNil(LadderForce.parse(environment: ["RIG_LADDER_FORCE": "L5"]))
        XCTAssertNil(LadderForce.parse(environment: ["RIG_LADDER_FORCE": "caliente"]))
        XCTAssertEqual(LadderForce.parse(environment: ["RIG_LADDER_FORCE": "2"]), LadderForce(level: .l2))
        let f = LadderForce.parse(environment: [
            "RIG_LADDER_FORCE": " l4 ", "RIG_LADDER_FORCE_AT_S": "120", "RIG_LADDER_FORCE_UNTIL_S": "300",
            "RIG_LADDER_FORCE_SIDE": "Right",
        ])
        XCTAssertEqual(f, LadderForce(level: .l4, atS: 120, untilS: 300, side: .right))
        XCTAssertEqual(f?.applies(to: .right), true)
        XCTAssertEqual(f?.applies(to: .left), false)
        XCTAssertEqual(LadderForce(level: .l2).applies(to: .left), true, "sin lado, los dos")
    }

    func testElBancoLoLeeYEmitirNo() {
        let banco = ProgramRunConfig.bench(environment: ["RIG_LADDER_FORCE": "L2", "RIG_LADDER_FORCE_AT_S": "120"])
        XCTAssertEqual(banco.ladderForce, LadderForce(level: .l2, atS: 120))
        XCTAssertNil(ProgramRunConfig.bench(environment: [:]).ladderForce)
        XCTAssertNil(ProgramRunConfig.production(medium: .aware, detectorPackage: nil).ladderForce)
    }

    func testElForzadoEmpeoraYaYAlAcabarMejoraConLaHisteresis() {
        var g = LadderGovernor(force: LadderForce(level: .l2, atS: 120, untilS: 300))
        // Antes del tramo, los sensores.
        XCTAssertEqual(g.step(sensors: .l0, elapsedS: 119, dtS: 1), .l0)
        // En el tramo, de golpe.
        XCTAssertEqual(g.step(sensors: .l0, elapsedS: 120, dtS: 1), .l2)
        XCTAssertEqual(g.step(sensors: .l0, elapsedS: 299, dtS: 1), .l2)
        // Fuera, vuelven los sensores y la escalera baja un escalón cada recoverS.
        var t = 300.0
        while g.level == .l2 {
            g.step(sensors: .l0, elapsedS: t, dtS: 1)
            t += 1
        }
        XCTAssertEqual(g.level, .l1)
        XCTAssertEqual(t - 300, LadderConstants.recoverS, accuracy: 1)
        // Unos sensores peores que el forzado no se esconden: el forzado es el objetivo.
        var h = LadderGovernor(force: LadderForce(level: .l1))
        XCTAssertEqual(h.step(sensors: .l3, elapsedS: 10, dtS: 1), .l1)
        XCTAssertTrue(LadderForce(level: .l1).isActive(elapsedS: 10))
    }

    // MARK: - La orden

    func testLaOrdenDeCadenciaVaYVuelve() throws {
        for nivel in LadderLevel.allCases {
            let orden = CadenceCommand(level: nivel)
            let datos = try JSONSerialization.data(withJSONObject: orden.json, options: [.sortedKeys])
            let leida = try XCTUnwrap(JSONSerialization.jsonObject(with: datos) as? [String: Any])
            XCTAssertEqual(CadenceCommand(json: leida), orden)
        }
        let l1 = CadenceCommand(level: .l1)
        XCTAssertEqual(l1.playerHz, LadderConstants.playerHzL1)
        XCTAssertTrue(l1.aiEnabled)
        XCTAssertEqual(CadenceCommand(level: .l2).playerHz, 0)
        XCTAssertNil(CadenceCommand(json: ["kind": "calibration_capture", "level": 1]))
        XCTAssertNil(CadenceCommand(json: ["kind": "cadence", "level": 9]))
        XCTAssertNil(CadenceCommand(json: ["kind": "cadence"]))
    }
}
