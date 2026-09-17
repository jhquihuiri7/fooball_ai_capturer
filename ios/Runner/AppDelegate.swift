import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Se guarda como propiedad porque `CaptureHostApiSetup.setUp` no retiene el objeto: si se
  /// deja caer, el canal queda registrado contra nada y la primera llamada desde Dart
  /// se pierde sin error.
  private var captureApi: CaptureHostApiImpl?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Hace falta para poder informar del nivel de bateria: sin esto,
    // `UIDevice.current.batteryLevel` devuelve -1 y el panel no ve venir el apagon.
    UIDevice.current.isBatteryMonitoringEnabled = true

    // La pantalla no se apaga: iOS no captura en segundo plano, asi que si el movil se
    // bloquea a mitad de partido deja de haber camara (ADR 0012, operativa de campo).
    application.isIdleTimerDisabled = true

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let api = CaptureHostApiImpl(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    captureApi = api
    // La imagen de la cámara en pantalla: una vista de plataforma sobre la misma sesión
    // que graba, así que enseña el encuadre real (`CapturePreview.swift`).
    engineBridge.pluginRegistry
      .registrar(forPlugin: "capture-preview")?
      .register(CapturePreviewFactory(makeLayer: api.makePreviewLayer), withId: "capture-preview")
  }
}
