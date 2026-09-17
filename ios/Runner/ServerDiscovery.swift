// Encontrar el servidor en la red local sin teclear una IP.
//
// El banco de pruebas (`tools/banco.sh`) anuncia MediaMTX por Bonjour como
// `_footballai-srt._tcp`. Aquí se busca ese anuncio y se resuelve a un nombre `.local`
// que libsrt sabe resolver por mDNS. Si no hay anuncio (el pod está al otro lado de
// Starlink, sin Bonjour), se devuelve vacío y el operador escribe el host una vez; queda
// guardado en el móvil.

import Foundation

final class ServerDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Tipo Bonjour del servidor. Está en `NSBonjourServices` del Info.plist.
    static let serviceType = "_footballai-srt._tcp."

    /// Segundos de búsqueda. En una red local el anuncio llega en menos de uno; el resto
    /// es margen para un móvil que acaba de despertar la WiFi.
    private static let timeoutSeconds: Double = 4

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false

    /// Host del servidor encontrado (`nombre.local`), o vacío.
    static func find() async -> String {
        let discovery = ServerDiscovery()
        return await discovery.run()
    }

    private func run() async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in
                self?.finish("")
            }
        }
    }

    private func finish(_ host: String) {
        guard !finished else { return }
        finished = true
        browser.stop()
        services.forEach { $0.stop() }
        continuation?.resume(returning: host)
        continuation = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: Self.timeoutSeconds)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Mejor la IPv4 que el nombre: no todos los clientes SRT resuelven `.local`.
        for data in sender.addresses ?? [] {
            var storage = sockaddr_storage()
            _ = withUnsafeMutableBytes(of: &storage) { data.copyBytes(to: $0) }
            guard storage.ss_family == sa_family_t(AF_INET) else { continue }
            var address = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                finish(String(cString: text))
                return
            }
        }
        guard let host = sender.hostName else { return }
        // Sin el punto final que pone Bonjour: `mac.local.` → `mac.local`.
        finish(host.hasSuffix(".") ? String(host.dropLast()) : host)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[servidor] no se pudo resolver %@: %@", sender.name, errorDict)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("[servidor] no se pudo buscar: %@", errorDict)
        finish("")
    }
}
