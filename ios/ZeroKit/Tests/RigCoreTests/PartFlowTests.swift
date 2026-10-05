import Foundation
import XCTest

@testable import RigCore

/// El flujo de las partes (IOS-52): la cola del esclavo, la puerta del maestro y diez
/// minutos simulados con 1 % de pérdidas y 50 ms de jitter.
final class PartFlowTests: XCTestCase {
    private let vista = ViewCommand(
        targetRigMs: 0, viewId: 0, yawRad: 0, pitchRad: 0, hfovRad: 1, sides: [.left, .right],
        seamYawRad: 0, featherRad: 0.02, gains: .unity
    )

    private func parte(_ seq: UInt32, key: Bool, ms: Int64 = 0, bytes: Int = 10) -> PartPacket {
        PartPacket(
            partSeq: seq, frameRigMs: ms, view: vista, extrapolated: false, isKey: key,
            accessUnit: Data(count: bytes)
        )
    }

    // MARK: - La cola del esclavo

    func testColaLlenaTiraYEsperaAlIdr() {
        let q = PartSendQueue()
        XCTAssertTrue(q.push(parte(1, key: true)))
        XCTAssertTrue(q.push(parte(2, key: false)))
        XCTAssertFalse(q.push(parte(3, key: false)), "llena")
        XCTAssertTrue(q.needsIdr)
        XCTAssertEqual(q.pop()?.partSeq, 1)
        XCTAssertFalse(q.push(parte(4, key: false)), "con hueco, pero la cadena está rota")
        XCTAssertTrue(q.push(parte(5, key: true)))
        XCTAssertFalse(q.needsIdr)
        XCTAssertEqual(q.dropped, 2)
        XCTAssertEqual([q.pop()?.partSeq, q.pop()?.partSeq, q.pop()?.partSeq], [2, 5, nil])
    }

    func testLaPeticionDeIdrVaciaLasPYGuardaUnIdrEnCola() {
        let q = PartSendQueue()
        q.push(parte(1, key: false))
        q.push(parte(2, key: false))
        q.requestIdr()
        XCTAssertEqual(q.count, 0)
        XCTAssertTrue(q.needsIdr)
        q.push(parte(3, key: true))
        q.push(parte(4, key: false))
        q.requestIdr()
        XCTAssertEqual(q.count, 2, "el IDR en cola ya rearranca la cadena")
        XCTAssertFalse(q.needsIdr)
    }

    // MARK: - La puerta del maestro

    func testHuecoPideIdrYNoDecodificaHastaEl() {
        let r = PartReceiver()
        XCTAssertEqual(r.receive(parte(1, key: false), arrivalMs: 0), .awaitingIdr(requestIdr: 1),
                       "sin IDR todavía no hay cadena")
        XCTAssertEqual(r.receive(parte(2, key: true), arrivalMs: 0), .decode(parte(2, key: true)))
        XCTAssertEqual(r.receive(parte(3, key: false), arrivalMs: 0), .decode(parte(3, key: false)))
        XCTAssertEqual(r.receive(parte(5, key: false), arrivalMs: 0), .awaitingIdr(requestIdr: 5))
        XCTAssertEqual(r.receive(parte(4, key: false), arrivalMs: 0), .dropOld)
        XCTAssertEqual(r.receive(parte(6, key: false), arrivalMs: 0), .awaitingIdr(requestIdr: 6))
        XCTAssertEqual(r.receive(parte(7, key: true), arrivalMs: 0), .decode(parte(7, key: true)))
        XCTAssertEqual(r.lost, 1)
        XCTAssertEqual(r.idrRequests, 3)
    }

    func testElSeqDaLaVuelta() {
        let r = PartReceiver()
        _ = r.receive(parte(UInt32.max, key: true), arrivalMs: 0)
        XCTAssertEqual(r.receive(parte(0, key: false), arrivalMs: 0), .decode(parte(0, key: false)))
    }

    func testTasaYJitter() {
        let r = PartReceiver()
        for i in 0..<30 {
            // 125 000 B por fotograma a 30 fps = 30 Mbit/s; llegadas con ±5 ms alternos.
            _ = r.receive(parte(UInt32(i), key: i == 0, ms: Int64(i * 33), bytes: 125_000),
                          arrivalMs: Int64(i * 33 + (i % 2 == 0 ? 10 : 15)))
        }
        XCTAssertEqual(r.mbps(nowMs: 29 * 33 + 15), 29.0, accuracy: 1.1)
        XCTAssertGreaterThan(r.jitterMs, 2)
        XCTAssertLessThan(r.jitterMs, 5)
    }

    // MARK: - La aceptación, simulada

    /// Diez minutos a 30 fps: cada parte se pierde con un 1 % y llega con 0–50 ms de
    /// retraso (así que también desordenada); las peticiones de IDR vuelven con otros
    /// 0–50 ms. El decodificador nunca recibe una P cuyo anterior no recibió, y cada
    /// petición se atiende con un IDR en ≤2 fotogramas del esclavo.
    func testDiezMinutosConPerdidasYJitterNoRompenLaCadena() {
        var azar = SplitMix(seed: 52)
        let fotogramas = 10 * 60 * 30
        let frameMs: Int64 = 33
        let cola = PartSendQueue()
        let puerta = PartReceiver()

        // (llegada, parte) en vuelo hacia el maestro; (llegada, seq) de vuelta.
        var haciaMaestro: [(Int64, PartPacket)] = []
        var haciaEsclavo: [(Int64, UInt32)] = []
        var ultimoDecodificado: UInt32?
        var fotogramasDesdePeticion: Int?
        var peorEspera = 0
        var idrs = 0

        for n in 0..<fotogramas {
            let ahora = Int64(n) * frameMs
            // El esclavo atiende las peticiones que ya llegaron.
            let llegadas = haciaEsclavo.filter { $0.0 <= ahora }
            haciaEsclavo.removeAll { $0.0 <= ahora }
            if !llegadas.isEmpty {
                llegadas.forEach { _ in cola.requestIdr() }
                if fotogramasDesdePeticion == nil { fotogramasDesdePeticion = 0 }
            }
            // Codifica: IDR al principio o si la cadena está rota.
            let esIdr = n == 0 || cola.needsIdr
            if esIdr {
                idrs += 1
                if let espera = fotogramasDesdePeticion {
                    peorEspera = max(peorEspera, espera + 1)
                    fotogramasDesdePeticion = nil
                }
            } else if fotogramasDesdePeticion != nil {
                fotogramasDesdePeticion! += 1
            }
            cola.push(parte(UInt32(n), key: esIdr, ms: ahora))
            // El cable se lleva lo que hay en cola (va más rápido que la cámara).
            while let p = cola.pop() {
                if azar.unit() < 0.01 { continue }
                haciaMaestro.append((ahora + Int64(azar.unit() * 50), p))
            }
            // El maestro recibe en orden de llegada.
            let entregas = haciaMaestro.filter { $0.0 <= ahora }.sorted { $0.0 < $1.0 }
            haciaMaestro.removeAll { $0.0 <= ahora }
            for (llegada, p) in entregas {
                switch puerta.receive(p, arrivalMs: llegada) {
                case let .decode(d):
                    if !d.isKey {
                        XCTAssertEqual(d.partSeq, ultimoDecodificado.map { $0 &+ 1 },
                                       "una P sin su anterior: cadena rota")
                    }
                    ultimoDecodificado = d.partSeq
                case let .awaitingIdr(seq):
                    haciaEsclavo.append((llegada + Int64(azar.unit() * 50), seq))
                case .dropOld:
                    break
                }
            }
        }
        XCTAssertLessThanOrEqual(peorEspera, 2, "un IDR en ≤2 fotogramas tras la petición")
        XCTAssertGreaterThan(puerta.lost, 0, "la simulación tiene que perder algo")
        XCTAssertGreaterThan(Double(puerta.decoded) / Double(fotogramas), 0.5,
                             "con 1 % de pérdidas se decodifica la mayoría")
        XCTAssertGreaterThan(idrs, 1)
    }
}

/// Un generador reproducible: los tests no dependen de la suerte.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// En [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
