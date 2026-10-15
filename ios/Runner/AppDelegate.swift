import Flutter
import RigMedia
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Se guarda como propiedad porque `CaptureHostApiSetup.setUp` no retiene el objeto: si se
  /// deja caer, el canal queda registrado contra nada y la primera llamada desde Dart
  /// se pierde sin error.
  private var captureApi: CaptureHostApiImpl?
  private var rigApi: RigHostApiImpl?
  private var idleObserver: NSObjectProtocol?

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
    // 2026-10-14: y otra vez cada vez que la app vuelve a primer plano. Las hojas del
    // sistema (el escaner, el emparejado sin cable, una llamada) pueden devolverlo a su
    // valor y entonces el movil se bloquearia a los pocos minutos de EMITIR.
    idleObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      UIApplication.shared.isIdleTimerDisabled = true
    }

    // RIG_PURGE_BENCH=1 (tools/limpiar_moviles.sh --borrar-pruebas): borra las pruebas de antes
    // de hoy de Documents/bench, bench4k y nv12, fuera del hilo principal (BenchPurge).
    let entorno = ProcessInfo.processInfo.environment
    if entorno[BenchPurge.environmentKey] == "1",
       let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
      DispatchQueue.global(qos: .utility).async {
        BenchPurge.purgeIfAsked(environment: entorno, documents: docs, now: Date())
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let api = CaptureHostApiImpl(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    captureApi = api
    rigApi = RigHostApiImpl(binaryMessenger: engineBridge.applicationRegistrar.messenger())
    // La imagen de la cámara en pantalla: una vista de plataforma sobre la misma sesión
    // que graba, así que enseña el encuadre real (`CapturePreview.swift`).
    engineBridge.pluginRegistry
      .registrar(forPlugin: "capture-preview")?
      .register(CapturePreviewFactory(makeLayer: api.makePreviewLayer), withId: "capture-preview")
  }
}
