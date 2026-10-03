// El canal de control del enlace sobre Network.framework (IOS-11, ADR 0023 §3).
//
// Solo control (TCP, tramas separadas por su `length`): los medios por UDP y el
// `hello` autenticado llegan con IOS-16 e IOS-12. Escucha el izquierdo —anuncia
// `_footballai-rig._tcp` con el lado y la huella del secreto en la TXT— y conecta el
// derecho con NWBrowser, en cualquier orden de arranque. La reconexión espera
// creciente con tope de 2 s (decisión 3): en la cancha, «se soltó el cable» tiene que
// curarse solo y rápido.
//
// Para los tests de macOS el transporte también sabe escuchar en un puerto del
// loopback y conectar a él directamente, sin Bonjour ni Ethernet: la lógica de
// tramas, estados y reconexión es la misma.

import Foundation
import Network
import os
import RigCore

public final class NWLinkTransport: LinkTransport {
    /// Cómo se llega al otro móvil.
    public enum Mode {
        /// El izquierdo: anuncia el servicio con la TXT {side, huella}.
        case advertise(name: String, txt: [String: String])
        /// El derecho: busca el servicio y conecta.
        case browse
        /// Tests: escuchar en un puerto del loopback (0 = efímero).
        case listen(port: UInt16)
        /// Tests: conectar a un host y puerto concretos.
        case connect(host: String, port: UInt16)
    }

    public static let serviceType = "_footballai-rig._tcp"

    /// Espera creciente de la reconexión, con el tope de 2 s de la decisión 3.
    static let reconnectDelaysS: [Double] = [0.25, 0.5, 1.0, 2.0]

    public var onFrame: ((LinkFrame, LinkChannel) -> Void)?
    public var onState: ((LinkTransportState) -> Void)?
    public var onPath: ((String) -> Void)?

    public private(set) var state: LinkTransportState = .idle {
        didSet { if oldValue != state { onState?(state) } }
    }
    public private(set) var stats = LinkTransportStats()

    /// El puerto real al escuchar (para los tests, con puerto efímero).
    public private(set) var localPort: UInt16 = 0
    public var onReady: ((UInt16) -> Void)?

    private let mode: Mode
    private let interfaceType: NWInterface.InterfaceType?
    private let queue = DispatchQueue(label: "io.footballai.zero.link.control")
    private let log = Logger(subsystem: "io.footballai.zero", category: "link")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pathMonitor: NWPathMonitor?
    private var buffer = Data()
    private var reconnectAttempt = 0
    private var stopped = false

    /// `interfaceType` por defecto: Ethernet por el hub (ADR 0023). `.wifi` para el
    /// banco sin cables y `nil` para el loopback de los tests.
    public init(mode: Mode, interfaceType: NWInterface.InterfaceType? = .wiredEthernet) {
        self.mode = mode
        self.interfaceType = interfaceType
    }

    // MARK: - Ciclo de vida

    public func start() {
        queue.async { [self] in
            stopped = false
            startPathMonitor()
            open()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
            pathMonitor?.cancel()
            pathMonitor = nil
            state = .idle
        }
    }

    public func send(_ frame: LinkFrame, on channel: LinkChannel) {
        queue.async { [self] in
            // Los medios (UDP) llegan con IOS-16: hasta entonces todo va por control.
            guard channel == .control else { return }
            guard let connection, state == .connected else { return }
            connection.send(content: frame.encode(), completion: .contentProcessed { [weak self] error in
                if error == nil {
                    self?.stats.framesSent += 1
                }
            })
        }
    }

    // MARK: - Abrir según el modo

    private func open() {
        guard !stopped else { return }
        switch mode {
        case let .advertise(name, txt):
            openListener(service: NWListener.Service(
                name: name,
                type: Self.serviceType,
                txtRecord: NWTXTRecord(txt)
            ), port: nil)
        case let .listen(port):
            openListener(service: nil, port: port)
        case .browse:
            openBrowser()
        case let .connect(host, port):
            openConnection(to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!
            ))
        }
    }

    private func parameters() -> NWParameters {
        let params = NWParameters.tcp
        if let interfaceType {
            params.requiredInterfaceType = interfaceType
        }
        // En la LAN del soporte no hay DNS ni rutas: nada de esperas de resolución.
        params.includePeerToPeer = false
        return params
    }

    private func openListener(service: NWListener.Service?, port: UInt16?) {
        do {
            let listener: NWListener
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: parameters(), on: nwPort)
            } else {
                listener = try NWListener(using: parameters())
            }
            listener.service = service
            listener.newConnectionHandler = { [weak self] nueva in
                guard let self else { return }
                // Un soporte son dos móviles: la conexión nueva sustituye a la vieja,
                // que Network puede tardar en dar por muerta (el patrón de RigLink).
                self.connection?.cancel()
                self.adopt(connection: nueva)
            }
            listener.stateUpdateHandler = { [weak self] estado in
                guard let self else { return }
                switch estado {
                case .ready:
                    self.localPort = listener.port?.rawValue ?? 0
                    self.state = .listening
                    self.onReady?(self.localPort)
                case let .failed(error):
                    self.state = .failed("\(error)")
                    self.scheduleReopen()
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed("\(error)")
            scheduleReopen()
        }
    }

    private func openBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let primero = results.first else { return }
            self.openConnection(to: primero.endpoint)
        }
        browser.stateUpdateHandler = { [weak self] estado in
            if case let .failed(error) = estado {
                self?.state = .failed("\(error)")
                self?.scheduleReopen()
            }
        }
        self.browser = browser
        state = .connecting
        browser.start(queue: queue)
    }

    private func openConnection(to endpoint: NWEndpoint) {
        state = .connecting
        let conexion = NWConnection(to: endpoint, using: parameters())
        adopt(connection: conexion)
    }

    private func adopt(connection nueva: NWConnection) {
        connection = nueva
        buffer.removeAll(keepingCapacity: true)
        nueva.stateUpdateHandler = { [weak self] estado in
            guard let self else { return }
            switch estado {
            case .ready:
                self.reconnectAttempt = 0
                self.state = .connected
                self.receive(on: nueva)
            case let .failed(error):
                self.log.info("control caído: \(String(describing: error))")
                self.dropConnection()
            case .cancelled:
                self.dropConnection()
            default:
                break
            }
        }
        nueva.start(queue: queue)
    }

    private func dropConnection() {
        guard !stopped else { return }
        connection?.cancel()
        connection = nil
        stats.reconnects += 1
        // El que escucha sigue escuchando; el que conecta lo reintenta con espera.
        switch mode {
        case .advertise, .listen:
            state = .listening
        case .browse, .connect:
            state = .connecting
            scheduleReopen()
        }
    }

    private func scheduleReopen() {
        guard !stopped else { return }
        let delay = Self.reconnectDelaysS[min(reconnectAttempt, Self.reconnectDelaysS.count - 1)]
        reconnectAttempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            switch self.mode {
            case .browse:
                self.browser?.cancel()
                self.openBrowser()
            case .connect:
                self.open()
            case .advertise, .listen:
                if self.listener == nil { self.open() }
            }
        }
    }

    // MARK: - Lectura del stream

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, terminado, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if terminado || error != nil {
                self.dropConnection()
                return
            }
            self.receive(on: connection)
        }
    }

    private func drainBuffer() {
        while true {
            switch LinkFrame.decode(from: buffer) {
            case let .frame(frame, consumed):
                buffer.removeFirst(consumed)
                stats.framesReceived += 1
                onFrame?(frame, .control)
            case .needsMoreData:
                return
            case let .invalid(campo):
                // Basura por control: se tira y se cierra (ADR 0023 §2).
                stats.invalidFrames += 1
                log.error("trama inválida por control (\(campo)): se cierra")
                buffer.removeAll(keepingCapacity: false)
                dropConnection()
                return
            }
        }
    }

    // MARK: - La ruta a internet

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaz = path.availableInterfaces.first.map(\.name) ?? "ninguna"
            self?.onPath?(interfaz)
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }
}
