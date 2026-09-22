// Lee el QR del panel con la dirección del servidor.
//
// El pod cambia de dirección con cada despliegue, y `rtmp://rig:clave@1.2.3.4:10248` no
// es algo para teclear en un móvil en la cancha. El panel la enseña como QR; esto la lee
// con la cámara y la devuelve tal cual, para que vaya al campo «Servidor».
//
// Es una sesión de captura aparte, con la cámara gran angular normal (la ultra gran
// angular del soporte ve demasiado y el QR le queda pequeño). Solo se abre desde la
// pantalla de elegir lado, donde la cámara del soporte no está en marcha; las dos a la
// vez se interrumpirían.

import AVFoundation
import UIKit

final class QrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.footballai.qr")
    private var finished = false
    private let onResult: (String) -> Void

    init(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no se usa") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        let hint = UILabel()
        hint.text = "Apunta al QR de la tarjeta «Cámaras» del panel"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 16, weight: .medium)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancelar", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.heightAnchor.constraint(equalToConstant: 48),
        ])

        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { self.session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            finish(with: "")
            return
        }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            // Los tipos se fijan DESPUÉS de añadir la salida, o la lista disponible está vacía.
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let text = code.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            return
        }
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.finish(with: text)
        }
    }

    @objc private func cancelTapped() {
        finish(with: "")
    }

    /// Una sola respuesta: la cámara sigue entregando frames un instante después de leer.
    private func finish(with text: String) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { self.onResult(text) }
    }
}

enum QrScanner {
    /// Presenta el lector sobre la app y devuelve lo leído, o vacío si se cancela o no
    /// hay cámara disponible.
    @MainActor
    static func scan() async -> String {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        else {
            return ""
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return await withCheckedContinuation { continuation in
            let scanner = QrScannerViewController { continuation.resume(returning: $0) }
            top.present(scanner, animated: true)
        }
    }
}
