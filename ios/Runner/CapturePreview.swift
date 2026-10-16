// La imagen de la cámara dentro de Flutter: vista de plataforma `capture-preview`.
//
// Es una `AVCaptureVideoPreviewLayer` sobre la misma sesión que graba. La compone el
// GPU, así que no cuesta CPU ni afecta a la salida que va al archivo y al stream, y
// enseña exactamente el encuadre que sale, que es lo que hace falta para montar el
// soporte: que las dos cámaras miren al campo y que el solape exista.
//
// 2026-10-15: la capa es una sola para toda la vida de la sesión (CaptureEngine
// .makePreviewLayer) y cada vista nueva se la trae; la sesión se le pone en la cola de
// captura, no aquí. Montar y desmontar la vista (el vistazo, PARAR) ya no toca la sesión:
// hacerlo en el hilo principal con la app al fondo fue lo que mató al 17 (0x8BADF00D).

import AVFoundation
import Flutter
import UIKit

extension Notification.Name {
    /// La capa de vista previa ya tiene la sesión (`object`: la capa). Lo manda
    /// `CaptureEngine` en el hilo principal; la vista vuelve a girar la imagen, y el latido
    /// de la pasada lo apunta en `app_events`.
    static let capturePreviewAttached = Notification.Name("io.footballai.capture.previewAttached")
    /// La capa espera a que la app vuelva o la cámara deje de estar interrumpida
    /// (`userInfo["reason"]`, en palabras).
    static let capturePreviewDeferred = Notification.Name("io.footballai.capture.previewDeferred")
}

final class CapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let makeLayer: () -> AVCaptureVideoPreviewLayer

    init(makeLayer: @escaping () -> AVCaptureVideoPreviewLayer) {
        self.makeLayer = makeLayer
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        CapturePreviewPlatformView(frame: frame, previewLayer: makeLayer())
    }
}

final class CapturePreviewPlatformView: NSObject, FlutterPlatformView {
    private let previewView: CapturePreviewView

    init(frame: CGRect, previewLayer: AVCaptureVideoPreviewLayer) {
        previewView = CapturePreviewView(frame: frame, previewLayer: previewLayer)
        super.init()
    }

    func view() -> UIView {
        previewView
    }
}

/// La vista que aloja la capa. Sigue su tamaño y gira la imagen con la pantalla.
final class CapturePreviewView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var attachObserver: NSObjectProtocol?

    init(frame: CGRect, previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: frame)
        backgroundColor = .black
        // Entera y con bandas negras si hace falta: recortar engañaría sobre el encuadre.
        previewLayer.videoGravity = .resizeAspect
        // La misma capa que tuvo la vista anterior: se trae. Mover una capa es cosa de Core
        // Animation y no toca la sesión de captura.
        previewLayer.removeFromSuperlayer()
        layer.addSublayer(previewLayer)
        // La sesión (y con ella la conexión que gira la imagen) puede llegar después de
        // montar la vista: cuando llegue, otra pasada de `layoutSubviews`.
        attachObserver = NotificationCenter.default.addObserver(
            forName: .capturePreviewAttached, object: previewLayer, queue: .main
        ) { [weak self] _ in
            self?.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("no se crea desde un storyboard")
    }

    deinit {
        if let attachObserver { NotificationCenter.default.removeObserver(attachObserver) }
        // Flutter desmonta la vista (el vistazo acabó, EMITIR): la capa sigue viva en el
        // motor para la siguiente, sin padre.
        if previewLayer.superlayer === layer { previewLayer.removeFromSuperlayer() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        rotateWithInterface()
    }

    /// La capa de vista previa no gira sola con la pantalla: hay que decírselo.
    ///
    /// El sensor entrega la imagen en apaisado con el botón de inicio a la derecha; ese
    /// es el ángulo 0. El archivo se graba siempre en ese ángulo; aquí solo se gira lo
    /// que se ve para que el operador no tuerza el cuello.
    private func rotateWithInterface() {
        guard let connection = previewLayer.connection else { return }
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        let angle: CGFloat
        switch orientation {
        case .landscapeRight: angle = 0
        case .landscapeLeft: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}
