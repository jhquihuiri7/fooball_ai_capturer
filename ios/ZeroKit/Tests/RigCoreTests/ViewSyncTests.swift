// La sincronía de vistas y partes (IOS-42): la simulación de la aceptación con
// pérdidas, jitter de 0–80 ms y reordenado.

import Foundation
import RigCore
import XCTest

final class ViewSyncTests: XCTestCase {
    private static let frameMs = 1000.0 / 30.0

    /// Un enlace simulado: cada mensaje llega tras un retardo al azar, o se pierde.
    private struct Red<T> {
        var enVuelo: [(llega: Int64, cosa: T)] = []
        mutating func manda(_ cosa: T, ahora: Int64, retardoMs: Int64) { enVuelo.append((ahora + retardoMs, cosa)) }
        mutating func entrega(hasta t: Int64) -> [T] {
            let llegan = enVuelo.filter { $0.llega <= t }.sorted { $0.llega < $1.llega }.map(\.cosa)
            enVuelo.removeAll { $0.llega <= t }
            return llegan
        }
    }

    private struct Azar {
        var s: UInt64
        mutating func uno() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    private static func vista(_ t: Int64, id: UInt32) -> ViewCommand {
        let x = Double(t) / 1000
        return ViewCommand(
            targetRigMs: t, viewId: id, yawRad: 0.3 * sin(x * 0.7), pitchRad: -0.15 + 0.02 * cos(x),
            hfovRad: 1.0 + 0.1 * sin(x * 0.3), sides: [.left, .right], seamYawRad: 0, featherRad: 0.035,
            gains: .unity
        )
    }

    func testConPerdidasJitterYReordenadoNoHayDesgarros() {
        var azar = Azar(s: 42)
        let perdidaVistas = 0.10, perdidaPartes = 0.05
        let historia = ViewHistory()
        let esclavo = SlaveViewResolver(frameDurationMs: Self.frameMs)
        let maestro = ProgramSync(frameDurationMs: Self.frameMs)
        var redVistas = Red<[ViewCommand]>(), redPartes = Red<PartInfo>()
        var vistaUsadaPorElEsclavo: [Int64: ViewCommand] = [:]
        var partesPerdidas = Set<Int64>()
        var retardos: [Int64] = []
        let fase: Int64 = 3  // el esclavo captura 3 ms después (fase ≤5 ms, ADR 0012)
        let fotogramas = 30 * 120  // dos minutos
        var siguienteAComponer = 0
        var esperadasUnaLente = 0

        for k in 0..<fotogramas {
            let t = Int64((Double(k) * Self.frameMs).rounded())
            // El maestro: su vista del instante t y el mensaje con las tres últimas.
            let v = Self.vista(t, id: UInt32(k))
            historia.append(v)
            if azar.uno() >= perdidaVistas {
                redVistas.manda(historia.message(), ahora: t, retardoMs: Int64(azar.uno() * 80))
            }
            // El esclavo: su fotograma en t + fase, con la vista que tenga.
            let tEsclavo = t + fase
            esclavo.receive(redVistas.entrega(hasta: tEsclavo).flatMap { $0 })
            if let resuelta = esclavo.resolve(frameRigMs: tEsclavo) {
                vistaUsadaPorElEsclavo[tEsclavo] = resuelta.command
                if azar.uno() >= perdidaPartes {
                    redPartes.manda(PartInfo(frameRigMs: tEsclavo, view: resuelta), ahora: tEsclavo,
                                    retardoMs: Int64(azar.uno() * 80))
                } else {
                    partesPerdidas.insert(tEsclavo)
                }
            }
            // El maestro compone lo que ya toca, a su tic.
            for p in redPartes.entrega(hasta: t) { maestro.receive(p) }
            while siguienteAComponer < k {
                let tc = Int64((Double(siguienteAComponer) * Self.frameMs).rounded())
                guard let salida = maestro.compose(programRigMs: tc, nowRigMs: t, masterView: historia.view(at: tc)!) else { break }
                if partesPerdidas.contains(tc + fase) || vistaUsadaPorElEsclavo[tc + fase] == nil {
                    esperadasUnaLente += 1
                }
                retardos.append(t - tc)
                switch salida {
                case let .twoLens(view, slaveFrame):
                    // La mitad del maestro y la del esclavo con la MISMA vista.
                    XCTAssertEqual(view, vistaUsadaPorElEsclavo[slaveFrame], "desgarro en \(tc)")
                    XCTAssertFalse(partesPerdidas.contains(slaveFrame))
                case .oneLens:
                    // Solo cae a una lente si esa parte se perdió (o no hubo vista aún).
                    let suya = tc + fase
                    XCTAssertTrue(partesPerdidas.contains(suya) || vistaUsadaPorElEsclavo[suya] == nil,
                                  "una lente en \(tc) sin pérdida inyectada")
                }
                siguienteAComponer += 1
            }
        }
        XCTAssertEqual(maestro.oneLensFrames, esperadasUnaLente, "las caídas a una lente son las pérdidas")
        XCTAssertGreaterThan(maestro.twoLensFrames, fotogramas * 9 / 10)
        XCTAssertGreaterThan(esclavo.extrapolations, 0, "con 10 % de vistas perdidas alguna se extrapola")
        // El retardo es el configurado ±1 fotograma.
        let tope = Double(LinkConstants.partMaxWaitMs) + Self.frameMs
        XCTAssertTrue(retardos.allSatisfy { Double($0) >= Double(LinkConstants.partMaxWaitMs) && Double($0) <= tope })
    }

    func testLaExtrapolacionSigueLaTrayectoria() {
        let esclavo = SlaveViewResolver(frameDurationMs: Self.frameMs)
        esclavo.receive([Self.vista(0, id: 0), Self.vista(33, id: 1)])
        let r = esclavo.resolve(frameRigMs: 67)!
        XCTAssertTrue(r.extrapolated)
        let real = Self.vista(67, id: 2)
        XCTAssertEqual(r.command.yawRad, real.yawRad, accuracy: 1e-3)
        XCTAssertEqual(r.command.targetRigMs, 67)
        // La de su instante, si llega, gana y no se marca.
        esclavo.receive([Self.vista(67, id: 2)])
        XCTAssertFalse(esclavo.resolve(frameRigMs: 67)!.extrapolated)
    }

    func testElMaestroNoComponeAntesDeSuTic() {
        let maestro = ProgramSync(frameDurationMs: Self.frameMs)
        let v = Self.vista(1000, id: 1)
        XCTAssertNil(maestro.compose(programRigMs: 1000, nowRigMs: 1099, masterView: v))
        maestro.receive(PartInfo(frameRigMs: 1003, view: ResolvedView(command: v, extrapolated: false)))
        XCTAssertEqual(maestro.compose(programRigMs: 1000, nowRigMs: 1100, masterView: v),
                       .twoLens(view: v, slaveFrameRigMs: 1003))
    }

    func testElMensajeViewLlevaLasTresUltimas() {
        let h = ViewHistory(capacity: 8)
        for k in 0..<10 { h.append(Self.vista(Int64(k) * 33, id: UInt32(k))) }
        XCTAssertEqual(h.message().map(\.viewId), [7, 8, 9])
        XCTAssertNil(h.view(at: 0), "el anillo está acotado")
    }
}
