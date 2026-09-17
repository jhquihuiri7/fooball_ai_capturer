// La imagen de la cámara dentro de Flutter: vista de plataforma `capture-preview`.
//
// Es una `AVCaptureVideoPreviewLayer` sobre la misma sesión que graba. La compone el
// GPU, así que no cuesta CPU ni afecta a la salida que va al archivo y al stream, y
// enseña exactamente el encuadre que sale, que es lo que hace falta para montar el
// soporte: que las dos cámaras miren al campo y que el solape exista.

import AVFoundation
import Flutter
import UIKit

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

    init(frame: CGRect, previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: frame)
        backgroundColor = .black
        // Entera y con bandas negras si hace falta: recortar engañaría sobre el encuadre.
        previewLayer.videoGravity = .resizeAspect
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("no se crea desde un storyboard")
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
        if #available(iOS 17.0, *) {
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
        } else if connection.isVideoOrientationSupported {
            switch orientation {
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }
}
