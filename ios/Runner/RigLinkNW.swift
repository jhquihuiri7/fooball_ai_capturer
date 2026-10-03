// El enlace nuevo sobre Network.framework (IOS-12, ADR 0023), detrás del interruptor
// RIG_LINK_MULTIPEER.
//
// El Multipeer de hoy (RigLink) sigue siendo el predeterminado hasta que haya hubs
// Ethernet con los que pasar la aceptación de campo. Con RIG_LINK_MULTIPEER=0 en el
// entorno del proceso, startLink levanta en su lugar RigLinkSession sobre
// NWLinkTransport: mismo contrato hacia Dart, otro cable por debajo.
//
// El secreto del soporte llega por la variable RIG_LINK_SECRET (base64) hasta que
// IOS-97 lo provisione en el Keychain; con `devicectl … launch --environment-variables`
// se inyecta en banco. Sin secreto no hay enlace: se falla claro en vez de inventar uno.

import CoreMedia
import Foundation
import RigCore
import RigNet
import UIKit

/// Lo que `CaptureHostApiImpl` necesita de un enlace. Lo cumplen el Multipeer de hoy y
/// el nuevo sobre Network, para que el interruptor sea elegir una clase y nada más.
protocol PeerLinking: AnyObject {
    var onState: ((LinkState, String) -> Void)? { get set }
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)? { get set }
    var recentPts: (() -> [Int64])? { get set }
    var currentLook: (() -> CameraLook?)? { get set }
    var onLook: ((CameraLook) -> Void)? { get set }
    var onCommand: ((RigCommand) -> Void)? { get set }
    func start()
    func stop()
    func publish(look: CameraLook)
    func send(command: RigCommand)
    func masterRecentPts() async -> [Int64]
}

extension RigLink: PeerLinking {}

final class RigLinkNW: PeerLinking {
    var onState: ((LinkState, String) -> Void)?
    var onStamps: ((Int64, Int64, Int64, Int64) -> Void)?
    var recentPts: (() -> [Int64])?
    var currentLook: (() -> CameraLook?)?
    var onLook: ((CameraLook) -> Void)?
    var onCommand: ((RigCommand) -> Void)?

    private let session: RigLinkSession

    /// El secreto del soporte, mientras no exista la provisión del Keychain (IOS-97).
    static func benchSecret() -> Data? {
        guard let valor = ProcessInfo.processInfo.environment["RIG_LINK_SECRET"],
              let secreto = Data(base64Encoded: valor),
              !secreto.isEmpty
        else {
            return nil
        }
        return secreto
    }

    init(role: CameraRole, secret: Data) {
        let side: RigLinkSession.Side = role == .left ? .left : .right
        // Escucha el izquierdo y conecta el derecho (ADR 0023): el anuncio lleva el lado
        // y la huella del secreto en la TXT, para no invitar a un soporte ajeno.
        let transport: NWLinkTransport
        if side == .left {
            transport = NWLinkTransport(mode: .advertise(
                name: UIDevice.current.name,
                txt: ["side": "left", "fp": LinkAuth.fingerprint(secret: secret)]
            ))
        } else {
            transport = NWLinkTransport(mode: .browse)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        session = RigLinkSession(
            transport: transport,
            secret: secret,
            side: side,
            deviceId: UIDevice.current.name,
            appVersion: version ?? "0"
        )
        session.hostNowNs = { RigLink.hostNowNs() }
        session.recentPts = { [weak self] in self?.recentPts?() ?? [] }
        session.currentLook = { [weak self] in self?.currentLook?() }
        session.onLook = { [weak self] look in self?.onLook?(look) }
        session.onCommand = { [weak self] wire in
            guard let command = RigCommand(rawValue: Int(wire.rawValue)) else { return }
            self?.onCommand?(command)
        }
        session.onStamps = { [weak self] t1, t2, t3, t4 in
            self?.onStamps?(t1, t2, t3, t4)
        }
        session.onState = { [weak self] estado in
            switch estado {
            case .searching, .authenticating:
                self?.onState?(.searching, "")
            case let .connected(peer):
                self?.onState?(.connected, peer)
            case let .rejected(motivo):
                // La pantalla de hoy no tiene estado «rechazado»: queda sin enlace y el
                // motivo en el log hasta que la UI lo estrene.
                NSLog("[enlace] rechazado: %@", motivo)
                self?.onState?(.off, "")
            case .off:
                self?.onState?(.off, "")
            }
        }
    }

    func start() {
        session.start()
    }

    func stop() {
        session.stop()
    }

    func publish(look: CameraLook) {
        session.publish(look: look)
    }

    func send(command: RigCommand) {
        guard let wire = RigWireCommand(rawValue: UInt8(command.rawValue)) else { return }
        session.send(command: wire)
    }

    func masterRecentPts() async -> [Int64] {
        await withCheckedContinuation { continuation in
            session.masterRecentPts { continuation.resume(returning: $0) }
        }
    }
}
