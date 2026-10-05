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

/// Presión del sistema de captura, copia de `AVCaptureDevice.SystemPressureState`
/// (IOS-06). Avisa antes y con más detalle que la térmica: `shutdown` significa que
/// iOS va a cortar la cámara.
enum SystemPressure { nominal, fair, serious, critical, shutdown }

/// Estado del enlace entre los dos móviles del soporte (TASK A3).
/// Lo que el móvil izquierdo, que es el maestro, le manda al derecho por el enlace.
///
/// Poner a grabar los dos móviles a mano es el paso donde más fácil es equivocarse en la
/// cancha: uno se queda sin grabar, o empiezan con medio minuto de diferencia. El
/// izquierdo manda y el derecho solo pone la cámara.
enum RigCommand {
  /// Empieza a emitir, sin guardar el vídeo en el móvil.
  record,

  /// Emite y además guarda el vídeo: el interruptor «Guardar vídeo» del izquierdo manda
  /// en los dos, para no volver con una grabación de una sola cámara.
  recordAndSave,
  stop,

  /// Graba unos segundos, para y sube la grabación al panel para calibrar el soporte.
  calibrate,
}

enum LinkState {
  /// Sin enlace: modo de un solo móvil, o antes de preparar la cámara.
  off,

  /// Anunciándose (izquierdo) o buscando al izquierdo (derecho).
  searching,

  /// Los dos móviles se ven. Por aquí viajan el reloj y los PTS del maestro.
  connected,

  /// Los dos dirigen partidos distintos (ADR 0023 §7): sin órdenes ni partes hasta que
  /// se elija a mano cuál manda.
  conflict,
}

/// Quién manda en el soporte (IOS-80). Ya no es el lado: lo negocia el enlace por term.
enum RigRole {
  master,
  slave,
}

/// Estado de la emisión al servidor (TASK A5).
enum StreamState {
  /// No se emite: sin servidor configurado, o antes de GRABAR.
  off,
  connecting,
  streaming,

  /// Se perdió el enlace y se reintenta sola. `streamDetail` dice por qué.
  reconnecting,
  failed,
}

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
    required this.pressure,
    required this.ladderLevel,
    required this.batteryLevel,
    required this.freeDiskBytes,
    required this.droppedFrames,
    required this.timecodeFailures,
    required this.recordingFile,
    required this.recordingSegment,
    required this.streamState,
    required this.streamDetail,
    required this.streamDroppedFrames,
    required this.streamBitrateBps,
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

  /// La presión de la sesión de captura (IOS-06).
  final SystemPressure pressure;

  /// Nivel de la escalera de degradación: 0 es L0 (todo encendido). Hoy la escalera
  /// observa y se enseña; gobernará el pipeline cuando IOS-25/IOS-44/IOS-50 consuman
  /// sus acciones.
  final int ladderLevel;

  final double batteryLevel;
  final int freeDiskBytes;
  final int droppedFrames;

  /// Frames en los que no se pudo pintar el código de tiempo (enmienda B1a). Tiene que
  /// ser cero: cada uno es un frame que el servidor no puede emparejar.
  final int timecodeFailures;

  /// Archivo que se está escribiendo ahora, o el último. Cambia solo tras una
  /// interrupción: la grabación sigue en un segmento nuevo (TASK A9).
  final String recordingFile;

  /// Número de segmento de la grabación en curso: 1 salvo que haya habido cortes.
  final int recordingSegment;

  final StreamState streamState;

  /// Por qué se está reconectando o falló, en palabras. Vacío si va bien.
  final String streamDetail;

  /// Frames que la emisión descartó porque el codificador iba por detrás.
  final int streamDroppedFrames;

  /// Bitrate al que se está codificando la emisión ahora mismo. Arranca en
  /// `CaptureSettings.bitrateBps` y baja solo si la red no lo traga (el vídeo se
  /// acumularía en el móvil y llegaría con minutos de retraso); vuelve a subir despacio
  /// cuando la red se recupera. 0 si no se emite.
  final int streamBitrateBps;
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

  /// Provoca el aviso de "red local" de iOS y dice si se concedió. Va al preparar la
  /// cámara: si saltara en mitad de la emisión, los paquetes se tirarían en silencio.
  /// `false` también si el operador no contesta en 20 s.
  @async
  bool requestLocalNetworkAccess();

  /// Atenúa la pantalla mientras se emite (IOS-07): el brillo al mínimo, y se
  /// restaura el que había al salir. La pantalla encendida a pleno sol es calor y
  /// batería que la escalera (IOS-06) acaba pagando.
  void setScreenDim(bool dimmed);

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

  /// Empieza a emitir por SRT y, si `saveVideo`, a grabar también en local.
  ///
  /// **Grabar es opcional desde el 27-09-2026.** El ADR 0012 (decisión 5) lo daba por
  /// hecho, porque una grabación local convierte un fallo de red en un partido en
  /// diferido; pero un partido son ~40 GB por móvil a 45 Mbit/s y llena el teléfono en
  /// dos partidos. Lo decide el operador con un interruptor, y para calibrar se graba
  /// igualmente, porque el clip es justo lo que se sube.
  ///
  /// Devuelve la ruta del archivo que se está escribiendo, o vacío si no se graba.
  String start(String srtUrl, String recordingDirectory, bool saveVideo);

  /// Para la grabación y la emisión. **No apaga la cámara**: así se puede volver a
  /// grabar sin cerrar la app, y la vista previa no se queda congelada.
  void stop();

  /// Apaga la cámara. Se llama al salir de la pantalla de captura; parar de grabar no la
  /// apaga, porque entonces habría que cerrar la app para volver a grabar.
  void releaseCamera();

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

  /// El servidor al que se emite (host o IP), guardado en el móvil para no teclearlo
  /// en cada partido. Vacío si no se ha configurado: entonces solo se graba.
  String loadServerHost();

  void saveServerHost(String host);

  /// Busca el servidor anunciado por Bonjour en la red local (`_footballai-srt._tcp`,
  /// el banco de pruebas). Devuelve su nombre `.local`, o vacío si no hay ninguno en
  /// unos segundos. El pod, al otro lado de Starlink, no se anuncia: ahí se teclea.
  @async
  String discoverServer();

  /// Abre la cámara a pantalla completa para leer el QR que enseña el panel del
  /// servidor (tarjeta «Cámaras»): lo que devuelve es lo que va en «Servidor», tal cual
  /// (`10.0.0.5`, `rtmp://rig:clave@1.2.3.4:10248`). Vacío si el operador cancela.
  /// Para el pod, cuya dirección cambia con cada despliegue y no se puede teclear en
  /// la cancha.
  @async
  String scanServerQr();

  /// El emparejamiento con el panel como mando (ADR 0017 del repo football-ai): el texto
  /// del QR «Mando», `https://<panel>/#mando=<token>`, tal cual. Vacío si no hay.
  ///
  /// En el Keychain y no en `UserDefaults`: el token mueve el marcador de un partido, y
  /// no puede viajar en la copia de seguridad del móvil ni pasar a otro iPhone.
  String loadPanelPairing();

  void savePanelPairing(String pairing);

  void clearPanelPairing();

  /// Manda una orden al otro móvil por el enlace. Solo el izquierdo la usa; en el
  /// derecho no hace nada. Sin enlace se pierde, y es lo correcto: quien está solo
  /// graba solo.
  void sendPeerCommand(RigCommand command);

  /// Abre el enlace con el otro móvil del soporte (Multipeer Connectivity, TASK A3).
  ///
  /// El izquierdo se anuncia y es el maestro del reloj; el derecho lo busca, se conecta
  /// y le pregunta la hora. Los cuatro sellos de cada pregunta se toman en nativo, con
  /// el mismo reloj que los frames, y llegan a Dart por `onClockStamps`.
  /// `prefersMaster` es «Este móvil dirige»: solo decide al empezar un partido.
  void startLink(CameraRole role, bool prefersMaster);

  void stopLink();

  /// El secreto del mando del partido `matchId`: HMAC-SHA256(S, "zero-control-v1 " ‖
  /// match_id) en base64url (ADR 0023 §3). Lo deriva el nativo, así que el secreto del
  /// soporte S no pasa nunca a Dart. Vacío si este móvil no tiene S.
  String controlSecret(String matchId);

  /// El partido que dirige este móvil (IOS-62): va en el hello de las conexiones
  /// siguientes, para que el otro lo adopte. Sin enlace de Network no hace nada.
  void setMatchId(String matchId);

  /// La IP del otro móvil por el enlace, o vacío. La lleva el QR Mando (IOS-63).
  String linkPeerAddress();

  /// El PIN del operador que abre la API del mando con los tres ámbitos (ADR 0017,
  /// enmienda §3). En el Keychain, como el emparejamiento. Vacío si no hay.
  String loadOperatorPin();

  void saveOperatorPin(String pin);

  /// La pizarra del partido (IOS-82): el maestro la manda al esclavo por el enlace.
  void sendReplica(String json);

  /// La pareja de fotogramas para calibrar (IOS-70): el maestro elige los instantes, se
  /// los manda al esclavo y los dos guardan JPEG q95 4K con su JSON en
  /// `Documents/calib/<id>/`. Devuelve el resumen del maestro en JSON (o `error`).
  @async
  String captureCalibrationPairs();

  /// PTS recientes del maestro, en tiempo del soporte, pedidos por el enlace (TASK A4).
  /// Solo tiene sentido en el derecho. Vacío si el maestro no contesta a tiempo.
  @async
  List<int> masterRecentPtsNs();
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

  /// El enlace con el otro móvil cambió de estado. `peerName` es su nombre, o vacío.
  void onLinkStateChanged(LinkState state, String peerName);

  /// Los cuatro sellos de una pregunta de hora al maestro, en nanosegundos: `t1` salida
  /// de la pregunta y `t4` llegada de la respuesta (reloj de este móvil); `t2` llegada y
  /// `t3` salida en el maestro (su reloj). Dart despeja el desfase (`solveClockSample`).
  void onClockStamps(int t1Ns, int t2Ns, int t3Ns, int t4Ns);

  /// La estimación del reloj nativo del soporte (IOS-13), cuando el enlace corre
  /// sobre Network. El desfase ya se aplica por fotograma en nativo, sin pasar por
  /// Pigeon: esto es para la pantalla y para salir de esperandoReloj.
  void onClockEstimate(int offsetNs, double driftPpm, int samples, int uncertaintyNs);

  /// Llegó una orden del maestro. Solo la recibe el esclavo.
  void onPeerCommand(RigCommand command);

  /// El enlace negoció quién manda (IOS-80): el rol, el term y el partido (o null, si
  /// ninguno de los dos traía) con los que sigue.
  void onRigRole(RigRole role, int term, String? matchId);

  /// Llegó la pizarra del maestro (IOS-82). Solo la recibe el esclavo.
  void onReplica(String json);
}
