// Contrato entre Flutter y el código nativo (ADR 0012 del repo football-ai, EPIC A).
//
// Por qué Pigeon y no un MethodChannel a mano: el canal a mano pasa mapas sin tipo y
// un campo mal escrito falla en tiempo de ejecución, dentro del móvil, en la cancha.
// Pigeon genera las dos mitades del canal desde este fichero, así que un cambio aquí
// rompe la compilación en vez de romper el partido.
//
// Regenerar (desde la raíz del repo, funciona también en Windows):
//   dart run pigeon --input pigeons/capture_api.dart
//
// El código generado se versiona a propósito: en el Mac hay que poder abrir Xcode y
// compilar sin ejecutar antes ningún generador.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/capture_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/CaptureApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'football_ai_capture',
  ),
)
/// Qué papel cumple este móvil en el soporte.
enum CameraRole {
  /// Cubre la mitad izquierda del campo. Es además el maestro del reloj: el otro
  /// móvil mide su desfase contra este (ADR 0012, decisión 2).
  left,

  /// Cubre la mitad derecha y sigue el reloj de la izquierda.
  right,
}

/// Estado térmico del dispositivo, copia de `ProcessInfo.ThermalState`.
///
/// No es telemetría decorativa: es la señal con la que se baja el bitrate antes de
/// que iOS decida bajarlo por su cuenta matando la sesión de captura.
enum ThermalState { nominal, fair, serious, critical }

/// Ajustes con los que se abre la cámara. Todos son decisiones del ADR 0012, no
/// preferencias: cambiarlos invalida la calibración del soporte.
class CaptureSettings {
  CaptureSettings({
    required this.role,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrateBps,
    required this.shutterDenominator,
    required this.iso,
    required this.cropToPlayableBand,
  });

  final CameraRole role;

  /// 3840×2160. El balón de 5–25 px no sobrevive a menos resolución (§9.2).
  final int width;
  final int height;

  /// Cadencia nominal. Las dos cámaras tienen que coincidir dentro de 0.5 Hz o el
  /// servidor rechaza el soporte (`RIG_MAX_FPS_MISMATCH_HZ`).
  final int fps;

  /// Tasa de bits del encoder HEVC. Fija, nunca adaptativa: los dos móviles comparten
  /// el enlace de Starlink y dos controles adaptativos se pelean entre sí.
  final int bitrateBps;

  /// Denominador de la obturación: 100 con red de 50 Hz, 120 con 60 Hz. Múltiplo de la
  /// frecuencia de red para que los focos del campo no produzcan bandas.
  final int shutterDenominator;

  /// ISO de reserva. La exposición se mide en automático al abrir la cámara y se
  /// congela trasladada a la obturación sin parpadeo; este valor solo se usa si la
  /// cámara no llega a medir nada. Igual en los dos móviles para que la costura no
  /// cambie de brillo; si los modelos son distintos, lo remata la corrección de
  /// ganancia del servidor.
  final int iso;

  /// Recorta verticalmente a la banda jugable antes de codificar (TASK A6). Ahorra un
  /// tercio del bitrate tirando cielo y grada, que no se usan para nada.
  final bool cropToPlayableBand;
}

/// Lo que la cámara consiguió aplicar de verdad.
///
/// Existe porque «pedirlo» y «tenerlo» no son lo mismo en AVFoundation: un formato
/// puede no admitir la combinación exacta de resolución y cadencia, y enterarse en la
/// cancha por la cara del vídeo no es una opción.
class CaptureStatus {
  CaptureStatus({
    required this.running,
    required this.width,
    required this.height,
    required this.actualFps,
    required this.stabilizationDisabled,
    required this.exposureLocked,
    required this.exposureSeconds,
    required this.iso,
    required this.whiteBalanceLocked,
    required this.whiteBalanceKelvin,
    required this.focusLocked,
    required this.intrinsicsAvailable,
    required this.thermalState,
    required this.batteryLevel,
    required this.freeDiskBytes,
    required this.droppedFrames,
  });

  final bool running;
  final int width;
  final int height;
  final double actualFps;

  /// `false` aquí invalida el soporte entero: con la estabilización activa el iPhone
  /// recorta y desplaza la imagen, y la rotación calibrada deja de valer.
  final bool stabilizationDisabled;

  final bool exposureLocked;

  /// Lo que quedó congelado: obturación en segundos e ISO. Se enseñan para que quien
  /// monta el soporte vea que los dos móviles miden lo mismo.
  final double exposureSeconds;
  final int iso;

  final bool whiteBalanceLocked;

  /// Temperatura de color congelada, en kelvin.
  final int whiteBalanceKelvin;

  final bool focusLocked;

  /// La matriz intrínseca por frame. Sin ella hay que caer a `from_hfov`, que sirve
  /// para dimensionar y no para cerrar una costura.
  final bool intrinsicsAvailable;

  final ThermalState thermalState;
  final double batteryLevel;
  final int freeDiskBytes;
  final int droppedFrames;
}

/// Una medida de desfase entre este móvil y el maestro del reloj.
class ClockSample {
  ClockSample({
    required this.roundTripNs,
    required this.offsetNs,
    required this.localMonotonicNs,
  });

  /// Ida y vuelta de la medida. Se conserva porque es lo que decide si la muestra
  /// vale: con jitter de WiFi, solo las de RTT mínimo dan un offset creíble.
  final int roundTripNs;

  /// Desfase estimado: cuánto hay que sumar al reloj local para obtener el del maestro.
  final int offsetNs;

  final int localMonotonicNs;
}

/// La cámara nativa. Todo lo que Flutter no puede hacer por sí mismo.
@HostApi()
abstract class CaptureHostApi {
  /// Pide al sistema el permiso de cámara y espera la respuesta.
  ///
  /// Va antes que cualquier otra llamada: sin permiso, AVFoundation acepta abrir la
  /// sesión y no entrega ni un frame, sin error. Es asíncrono porque el diálogo de iOS
  /// lo es: la respuesta llega cuando el operador pulsa.
  @async
  bool requestCameraAccess();

  /// `true` si este iPhone tiene ultra gran angular.
  ///
  /// Se resuelve con `AVCaptureDevice.DiscoverySession`, **nunca con una lista de
  /// modelos**: Veo Go rechazó el iPhone 17 Pro por tener una lista desactualizada.
  bool hasUltraWideCamera();

  /// Abre la cámara con los ajustes dados y devuelve lo que se aplicó de verdad.
  ///
  /// Tarda unos segundos: la cámara mide exposición y balance en automático antes de
  /// congelarlos, y no se responde hasta que estén congelados.
  @async
  CaptureStatus configure(CaptureSettings settings);

  /// Empieza a grabar en local y a emitir por SRT. La grabación local no es opcional:
  /// es lo que convierte un fallo de red en un partido en diferido (ADR 0012, dec. 5).
  ///
  /// Devuelve la ruta del archivo que se está escribiendo: la pantalla lo enseña, y
  /// quien lo busque después en Finder sabe cuál es.
  String start(String srtUrl, String recordingDirectory);

  void stop();

  CaptureStatus status();

  /// PTS de los últimos frames capturados, ya en tiempo del soporte (TASK A4).
  ///
  /// El nativo no puede calcular la fase de exposición él solo: la fase es un desfase
  /// **entre los dos móviles**, y cada uno solo conoce sus propios sellos. Así que
  /// entrega los suyos y la resta se hace en Dart, que es quien tiene el enlace con el
  /// otro móvil (`measurePhaseNs`).
  List<int> recentFramePtsNs();

  /// Reabre la sesión para volver a sortear la fase.
  void restartForPhase();

  /// Fija el desfase de reloj que se aplicará a los PTS emitidos. Es lo que pone los
  /// dos streams en el dominio de tiempo del soporte (ADR 0012, decisión 2).
  void setClockOffsetNs(int offsetNs);
}

/// Avisos que el nativo empuja hacia Flutter sin que nadie pregunte.
@FlutterApi()
abstract class CaptureFlutterApi {
  /// La sesión se interrumpió (llamada entrante, otra app tomó la cámara, calor).
  /// Tras esto la grabación continúa en un segmento nuevo.
  void onInterrupted(String reason);

  void onResumed();

  /// Cambio de estado térmico. Por encima de `serious` hay que bajar el bitrate.
  void onThermalStateChanged(ThermalState state);

  void onStatus(CaptureStatus status);
}
