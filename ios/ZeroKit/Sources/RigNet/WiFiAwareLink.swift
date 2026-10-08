// Wi-Fi Aware como plan B del enlace (IOS-14, ADR 0023 §3).
//
// Mismo protocolo y mismo transporte: NWLinkTransport con otra cita. El izquierdo
// publica los dos canales por Wi-Fi Aware y el derecho se suscribe, sin router de por
// medio. Wi-Fi Aware solo ve a dispositivos emparejados: se emparejan una vez con
// DeviceDiscoveryUI («Emparejar sin cable») y el sistema lo recuerda.
//
// El datapath va en modo realtime (latencia antes que caudal y batería) y con la
// categoría de acceso de vídeo interactivo. Los dos lados tienen que ir en el mismo
// modo: si no, Apple da el comportamiento por indefinido.
//
// Pide el entitlement com.apple.developer.wifi-aware (Publish y Subscribe) y los
// servicios en WiFiAwareServices del Info.plist. El framework solo existe en iOS: en el
// Mac compilan los nombres de los servicios y su validación, que es lo que se prueba
// allí. Lo demás se prueba con los dos iPhone (banco link-bench con
// RIG_LINK_INTERFACE=aware).

import Foundation
import Network
import RigCore

/// Los servicios del enlace por Wi-Fi Aware, tal como van por el aire y en el Info.plist.
public enum WiFiAwareServices {
    /// El control (TCP): el mismo nombre que por Bonjour, que cabe en 15 caracteres.
    public static let control = "_footballai-rig._tcp"
    /// Los medios (UDP). `_footballai-media` no vale: RFC 6335 limita el nombre a 15
    /// caracteres, y con un nombre inválido en el Info.plist la app se cierra al arrancar.
    public static let media = "_footballai-av._udp"

    public static let all = [control, media]

    public static func name(for channel: LinkChannel) -> String {
        channel == .control ? control : media
    }

    /// Nombre completo válido según RFC 6335 §5.1: `_<nombre>._tcp` o `._udp`, con el
    /// nombre de 1 a 15 caracteres en minúsculas, cifras y guiones, al menos una letra,
    /// sin guion al principio ni al final y sin dos seguidos.
    public static func isValidServiceName(_ full: String) -> Bool {
        let partes = full.split(separator: ".", omittingEmptySubsequences: false)
        guard partes.count == 2, ["_tcp", "_udp"].contains(partes[1]),
              partes[0].hasPrefix("_")
        else {
            return false
        }
        let nombre = partes[0].dropFirst()
        let permitidos = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return (1...maxServiceNameLength).contains(nombre.count)
            && nombre.allSatisfy(permitidos.contains)
            && nombre.contains(where: \.isLetter)
            && !nombre.hasPrefix("-") && !nombre.hasSuffix("-")
            && !nombre.contains("--")
    }

    /// Caracteres del nombre de un servicio como mucho (RFC 6335 §5.1).
    static let maxServiceNameLength = 15
}

public enum WiFiAwareLinkError: Error, CustomStringConvertible {
    /// Este iPhone no tiene Wi-Fi Aware (anterior al iPhone 12) o el sistema no lo da.
    case unsupported
    /// El servicio no está en WiFiAwareServices del Info.plist.
    case serviceNotDeclared(String)

    public var description: String {
        switch self {
        case .unsupported: "este iPhone no tiene Wi-Fi Aware"
        case let .serviceNotDeclared(nombre): "\(nombre) no está en WiFiAwareServices del Info.plist"
        }
    }
}

#if os(iOS)
import DeviceDiscoveryUI
import UIKit
import WiFiAware

/// La cita por Wi-Fi Aware: publica el izquierdo y se suscribe el derecho, solo entre
/// dispositivos emparejados.
public struct WiFiAwareRendezvous: LinkRendezvous {
    /// Latencia antes que caudal y batería: lo que pide un directo (IOS-14). SPK-08 mide
    /// lo que cuesta en vatios.
    public static let performanceMode = WAPerformanceMode.realtime
    /// La categoría de acceso de la radio para los dos canales: vídeo interactivo.
    public static let serviceClass = NWParameters.ServiceClass.interactiveVideo

    public init() {}

    public var label: String { "aware" }

    public static var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
    }

    public func parameters(for channel: LinkChannel) -> NWParameters {
        let params: NWParameters = channel == .control ? .tcp : .udp
        params.wifiAware.performanceMode = Self.performanceMode
        params.serviceClass = Self.serviceClass
        return params
    }

    public func makeListener(for channel: LinkChannel, name _: String, txt _: [String: String]) throws -> NWListener {
        // Sin TXT: la huella del secreto no viaja, y el que no es del soporte cae en el
        // hello autenticado. Además solo conecta quien está emparejado.
        let servicio = try Self.publishable(channel)
        let cita = WAPublisherListener.wifiAware(.connecting(
            to: servicio, from: .allPairedDevices, datapath: .realtime
        ))
        let params = parameters(for: channel)
        cita.configureParameters(params)
        return try NWListener(service: cita.service, using: params)
    }

    public func makeBrowser(for channel: LinkChannel) throws -> NWBrowser {
        let servicio = try Self.subscribable(channel)
        let cita = WASubscriberBrowser.wifiAware(.connecting(to: .allPairedDevices, from: servicio))
        return NWBrowser(for: cita.makeDescriptor(), using: cita.configureParameters(parameters(for: channel)))
    }

    public func explain(_ error: NWError) -> String {
        guard let causa = error.wifiAware else { return "\(error)" }
        return switch causa {
        case .entitlementMissing: "Wi-Fi Aware: falta el entitlement com.apple.developer.wifi-aware"
        case .noPairedDevices: "Wi-Fi Aware: no hay ningún iPhone emparejado («Emparejar sin cable»)"
        case .serviceNotDeclared: "Wi-Fi Aware: servicio no declarado en WiFiAwareServices"
        case .wifiAwareUnsupported: "Wi-Fi Aware: este iPhone no lo tiene"
        default: "Wi-Fi Aware: \(causa)"
        }
    }

    static func publishable(_ channel: LinkChannel) throws -> WAPublishableService {
        let nombre = WiFiAwareServices.name(for: channel)
        guard let servicio = WAPublishableService.allServices[nombre] else {
            throw WiFiAwareLinkError.serviceNotDeclared(nombre)
        }
        return servicio
    }

    static func subscribable(_ channel: LinkChannel) throws -> WASubscribableService {
        let nombre = WiFiAwareServices.name(for: channel)
        guard let servicio = WASubscribableService.allServices[nombre] else {
            throw WiFiAwareLinkError.serviceNotDeclared(nombre)
        }
        return servicio
    }

    /// Lo que dice la radio del datapath de una conexión, para el informe del banco
    /// (SPK-08): señal 0-1, capacidad y techo en Mbit/s, latencia media de emisión de la
    /// categoría de vídeo en ms y segundos activo. Vacío si la ruta no es Wi-Fi Aware.
    public static func report(of path: NWPath) async -> [String: String] {
        guard let ruta = try? await path.wifiAware else { return [:] }
        let r = ruta.performance
        var informe = ["aware_active_s": "\(ruta.durationActive.components.seconds)"]
        informe["aware_signal"] = r.signalStrength.map { String(format: "%.2f", $0) }
        informe["aware_capacity_mbps"] = r.throughputCapacity.map { String(format: "%.1f", $0) }
        informe["aware_ceiling_mbps"] = r.throughputCeiling.map { String(format: "%.1f", $0) }
        if let media = r.transmitLatency[.interactiveVideo]?.average {
            let c = media.components
            informe["aware_tx_latency_video_ms"] = String(
                format: "%.2f", Double(c.seconds) * 1e3 + Double(c.attoseconds) / 1e15
            )
        }
        return informe
    }
}

/// El emparejado único con DeviceDiscoveryUI. El izquierdo publica el control y enseña
/// el código; el derecho lo busca, lo elige y teclea el código. El sistema lo recuerda:
/// después la cita usa `.allPairedDevices` sin volver a preguntar.
@MainActor
public enum WiFiAwarePairing {
    /// Presenta la hoja del lado sobre `presenter` y espera. Devuelve el nombre del
    /// emparejado nuevo; si se cierra la hoja sin emparejar, los que ya lo estaban, o ""
    /// si no hay ninguno.
    public static func pair(side: RigLinkSession.Side, from presenter: UIViewController) async throws -> String {
        guard WiFiAwareRendezvous.isSupported else { throw WiFiAwareLinkError.unsupported }
        let antes = Set((try? await WAPairedDevice.allDevices.current())?.keys.map { $0 } ?? [])
        let hoja: UIViewController
        let espera = PairingWait()
        var eleccion: Task<Void, Never>?
        switch side {
        case .left:
            let servicio = try WiFiAwareRendezvous.publishable(.control)
            let cita = WAPublisherListener.wifiAware(.connecting(
                to: servicio, from: .userSpecifiedDevices, datapath: .realtime
            ))
            guard DDDevicePairingViewController.isSupported(cita) else { throw WiFiAwareLinkError.unsupported }
            hoja = DDDevicePairingViewController(listenerProvider: cita, access: .permanent)
        case .right:
            let servicio = try WiFiAwareRendezvous.subscribable(.control)
            let cita = WASubscriberBrowser.wifiAware(.connecting(to: .userSpecifiedDevices, from: servicio))
            let params = cita.configureParameters(WiFiAwareRendezvous().parameters(for: .control))
            guard let picker = DDDevicePickerViewController(
                browseDescriptor: cita.makeDescriptor(), parameters: params, access: .permanent
            ) else {
                throw WiFiAwareLinkError.unsupported
            }
            hoja = picker
            // El selector devuelve el punto elegido cuando el emparejado termina.
            eleccion = Task { @MainActor in
                guard let punto = try? await picker.endpoint else { return }
                espera.finish(name(of: punto))
            }
        }
        // Lo que vale en los dos lados: aparece un emparejado nuevo.
        let vigia = Task { @MainActor in
            for try await dispositivos in WAPairedDevice.allDevices {
                if let nuevo = dispositivos.values.first(where: { !antes.contains($0.id) }) {
                    espera.finish(label(of: nuevo))
                    return
                }
            }
        }
        // Y si la hoja se cierra sola (no se sabe si DeviceDiscoveryUI lo hace al
        // terminar), se deja un segundo al vigía antes de dar la espera por acabada.
        let cierre = Task { @MainActor in
            try await Task.sleep(for: pairingPollInterval)
            while hoja.presentingViewController != nil {
                try await Task.sleep(for: pairingPollInterval)
            }
            try await Task.sleep(for: pairingPollInterval * 2)
            espera.finish("")
        }
        hoja.presentationController?.delegate = espera
        let nombre = await withCheckedContinuation { continuacion in
            espera.continuation = continuacion
            presenter.present(hoja, animated: true)
        }
        vigia.cancel()
        eleccion?.cancel()
        cierre.cancel()
        if hoja.presentingViewController != nil {
            hoja.dismiss(animated: true)
        }
        if !nombre.isEmpty { return nombre }
        let ahora = (try? await WAPairedDevice.allDevices.current()) ?? [:]
        return ahora.values.map(label(of:)).sorted().joined(separator: ", ")
    }

    /// Cada cuánto se mira si la hoja sigue en pantalla.
    static let pairingPollInterval = Duration.milliseconds(500)

    private static func label(of dispositivo: WAPairedDevice) -> String {
        dispositivo.name ?? dispositivo.pairingInfo?.pairingName ?? "iPhone"
    }

    private static func name(of punto: NWEndpoint) -> String {
        if #available(iOS 26.4, *), let wa = punto.wifiAware {
            return label(of: wa.device)
        }
        return "iPhone"
    }

    /// Lo primero que pase cierra la espera: emparejado, elegido o la hoja cerrada a mano.
    @MainActor
    private final class PairingWait: NSObject, UIAdaptivePresentationControllerDelegate {
        var continuation: CheckedContinuation<String, Never>?

        func finish(_ nombre: String) {
            continuation?.resume(returning: nombre)
            continuation = nil
        }

        func presentationControllerDidDismiss(_: UIPresentationController) {
            finish("")
        }
    }
}
#endif
