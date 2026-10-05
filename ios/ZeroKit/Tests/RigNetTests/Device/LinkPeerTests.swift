import Foundation
import XCTest

import RigCore
@testable import RigNet

/// El Mac como el otro móvil del soporte (SPK-02, IOS-52), para probar el enlace con
/// un solo iPhone: el Mac es el izquierdo (escucha por Wi-Fi y dirige) y el iPhone corre
/// el link-bench como derecho con RIG_LINK_PARTS=1. El Mac recibe sus partes por el
/// mismo camino que el maestro de verdad, pide IDR ante un hueco y mide.
///
/// Se salta salvo con RIG_LINK_PEER_S (segundos) y RIG_LINK_SECRET (base64) en el
/// entorno; el informe va a RIG_LINK_PEER_OUT si se da.
final class LinkPeerTests: XCTestCase {
    func testElMacDeIzquierdoRecibeLasPartesDelIphone() throws {
        let entorno = ProcessInfo.processInfo.environment
        let lock = NSLock()
        guard let segundos = entorno["RIG_LINK_PEER_S"].flatMap(Double.init),
              let secreto = entorno["RIG_LINK_SECRET"].flatMap({ Data(base64Encoded: $0) })
        else {
            throw XCTSkip("sin RIG_LINK_PEER_S y RIG_LINK_SECRET: banco con iPhone")
        }
        // RIG_LINK_PEER_SIDE=right: el Mac es el derecho y no dirige (el iPhone es el
        // maestro con su cámara: program-split en una lente).
        let derecho = entorno["RIG_LINK_PEER_SIDE"] == "right"
        let transporte = derecho
            ? NWLinkTransport(mode: .browse, interfaceType: .wifi)
            : NWLinkTransport(
                mode: .advertise(
                    name: "mac-banco",
                    txt: ["side": "left", "fp": LinkAuth.fingerprint(secret: secreto)]
                ),
                interfaceType: .wifi
            )
        let sesion = RigLinkSession(
            transport: transporte, secret: secreto, side: derecho ? .right : .left,
            deviceId: "mac-banco", appVersion: "banco"
        )
        let reloj = { Int64(DispatchTime.now().uptimeNanoseconds) }
        sesion.hostNowNs = reloj
        sesion.claimedRole = .slave
        sesion.prefersMaster = !derecho
        nonisolated(unsafe) var vistas = 0
        sesion.onViews = { _ in lock.lock(); vistas += 1; lock.unlock() }

        let receptor = PartReceiver()
        nonisolated(unsafe) var ultimo: Double?
        nonisolated(unsafe) var peorHueco = 0.0
        nonisolated(unsafe) var paron100 = 0
        nonisolated(unsafe) var paron150 = 0
        nonisolated(unsafe) var nadas = 0
        nonisolated(unsafe) var maxMbps = 0.0
        nonisolated(unsafe) var conectado = false
        func latido() {
            let ms = Double(DispatchTime.now().uptimeNanoseconds) / 1e6
            if let u = ultimo {
                peorHueco = max(peorHueco, ms - u)
                if ms - u > 100 { paron100 += 1 }
                if ms - u > 150 { paron150 += 1 }
            }
            ultimo = ms
        }
        sesion.onState = { e in
            if case .connected = e { lock.lock(); conectado = true; lock.unlock() }
        }
        sesion.onPart = { parte, _ in
            let ahora = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
            lock.lock()
            let d = receptor.receive(parte, arrivalMs: ahora)
            latido()
            maxMbps = max(maxMbps, receptor.mbps(nowMs: ahora))
            lock.unlock()
            if case let .awaitingIdr(seq) = d { sesion.requestIdr(partSeq: seq) }
        }
        sesion.onNoPart = { _ in lock.lock(); nadas += 1; latido(); lock.unlock() }

        sesion.start()
        let tope = Date().addingTimeInterval(segundos)
        while Date() < tope { Thread.sleep(forTimeInterval: 1) }
        sesion.stop()

        lock.lock()
        let total = receptor.received + receptor.lost
        let informe: [String: Any] = [
            "connected": conectado,
            "views_received": vistas,
            "is_master": sesion.isMaster,
            "parts_received": receptor.received,
            "parts_decodable": receptor.decoded,
            "parts_lost": receptor.lost,
            "parts_loss_ppm": total == 0 ? 0 : receptor.lost * 1_000_000 / total,
            "idr_requests": receptor.idrRequests,
            "no_parts": nadas,
            "stalls_over_100ms": paron100,
            "stalls_over_150ms": paron150,
            "worst_gap_ms": Int(peorHueco.rounded()),
            "jitter_ms": receptor.jitterMs,
            "max_mbps": maxMbps,
            "media_loss_gaps": transporte.stats.mediaLossGaps,
            "media_stalls_over_100ms": transporte.stats.mediaStallsOver100Ms,
        ]
        lock.unlock()
        let json = try JSONSerialization.data(withJSONObject: informe, options: [.sortedKeys, .prettyPrinted])
        if let salida = entorno["RIG_LINK_PEER_OUT"] {
            try json.write(to: URL(fileURLWithPath: salida))
        }
        print(String(data: json, encoding: .utf8)!)
        XCTAssertTrue(conectado, "el iPhone no llegó a conectar")
    }
}
