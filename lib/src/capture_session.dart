/// El ciclo de vida de una cámara del soporte (ADR 0012, EPIC A).
///
/// Junta las tres cosas que tienen que estar bien antes de que alguien pulse GRABAR:
/// que la cámara se abriera con los ajustes correctos, que haya reloj común con el otro
/// móvil, y que la fase de exposición sea pequeña.
///
/// El transporte con el otro móvil entra por `clockSamples` en vez de construirse aquí.
/// Hoy ese stream lo llena la TASK A3 (Multipeer); mañana podría ser otra cosa, y así
/// esta clase se prueba sin levantar ninguna red.
///
/// Los avisos que el nativo empuja sin que nadie pregunte (`CaptureFlutterApi`) entran
/// también por aquí: la sesión es quien sabe qué hacer con una interrupción, y así se
/// prueban llamando al método, sin canal de por medio.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/calibration_upload.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/exposure_phase.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/rig_clock.dart';
import 'package:football_ai_capture/src/server/master_host.dart';
import 'package:football_ai_capture/src/server/replica.dart';
import 'package:football_ai_capture/src/stream_url.dart';

/// Cómo va la subida de la grabación al panel para calibrar.
enum CalibrationUpload { ninguna, subiendo, subida, fallo }

/// Quién sube la grabación. Cambiable para los tests, que no tienen panel.
typedef CalibrationUploaderFactory = CalibrationUploader Function(
  Uri panel,
  CameraRole role,
  ({String user, String password})? credentials,
);

CalibrationUploader _defaultUploader(
  Uri panel,
  CameraRole role,
  ({String user, String password})? credentials,
) =>
    CalibrationUploader(panel: panel, role: role, credentials: credentials);

/// En qué punto de la preparación está esta cámara.
enum SessionPhase {
  /// Comprobando que el iPhone sirve y abriendo la cámara.
  preparando,

  /// Cámara abierta, esperando reloj común con el otro móvil.
  esperandoReloj,

  /// Midiendo la fase de exposición y reiniciando si hace falta (TASK A4).
  ajustandoFase,

  /// Todo listo. Se puede grabar.
  lista,

  /// Grabando y emitiendo.
  grabando,

  /// Algo impide grabar. `problem` dice qué.
  fallo,
}

class CaptureSession extends ChangeNotifier implements CaptureFlutterApi {
  CaptureSession({
    required this.role,
    CaptureHostApi? api,
    Stream<ClockSample>? clockSamples,
    RigClock? clock,
    this.phasePolicy = const PhaseSortPolicy(),
    this.standalone = false,
    this.serverHost = '',
    this.autoSortPhase = true,
    this.phaseSettle = phaseSettleDelay,
    this.linkOnly = false,
    this.uploader = _defaultUploader,
    bool? prefersMaster,
    this.masterHost,
    this.replicaStore,
  })  : prefersMaster = prefersMaster ?? role == CameraRole.left,
        _api = api ?? CaptureHostApi(),
        _clock = clock ?? RigClock() {
    if (clockSamples != null) {
      _clockSubscription = clockSamples.listen(_onClockSample);
    }
  }

  final CameraRole role;
  final PhaseSortPolicy phasePolicy;

  /// Un solo móvil, sin reloj ni fase: para probar la cámara en el banco.
  ///
  /// Salta las dos comprobaciones que hacen que dos vídeos pareen, así que lo que se
  /// grabe así no sirve para el soporte y la pantalla lo dice en grande. Lo que sí
  /// sigue valiendo es la comprobación de la cámara —ajustes aplicados de verdad—,
  /// que es justo lo que se viene a probar.
  final bool standalone;

  /// Host o IP del MediaMTX que recibe la emisión. Vacío: solo se graba.
  final String serverHost;

  /// En cuanto hay reloj, medir la fase contra el maestro sin que nadie pulse nada.
  /// Solo los tests lo apagan, para mirar el estado intermedio.
  final bool autoSortPhase;

  /// Espera antes de cada medida de fase (ver `phaseSettleDelay`). Cero en los tests.
  final Duration phaseSettle;

  /// Banco de pruebas del enlace: abre solo el enlace entre móviles, sin cámara. Sirve
  /// para probar reloj y emparejado en simuladores, que no tienen ultra gran angular.
  final bool linkOnly;

  final CaptureHostApi _api;
  final RigClock _clock;

  /// La última estimación del reloj nativo (IOS-13), si el enlace corre sobre
  /// Network. Cuando está, manda sobre `_clock` en la etiqueta: la cuenta buena vive
  /// en nativo y esta es su copia para la pantalla.
  ClockSyncEstimate? _nativeClockEstimate;

  /// Quién sube la grabación para calibrar (ver [CalibrationUploaderFactory]).
  final CalibrationUploaderFactory uploader;
  StreamSubscription<ClockSample>? _clockSubscription;

  /// La subida de la última grabación al panel para calibrar el soporte.
  CalibrationUpload calibrationUpload = CalibrationUpload.ninguna;
  int uploadSent = 0;
  int uploadTotal = 0;

  /// Con esta subida el panel ya tenía las dos y se puso a calibrar.
  bool uploadCalibrating = false;
  String? uploadProblem;

  SessionPhase phase = SessionPhase.preparando;
  CaptureStatus? status;
  String? problem;

  /// La interrupción que avisó el nativo (llamada, otra app, calor), mientras dure.
  String? interruption;

  /// Permiso de red local de iOS. `null` hasta que se pide. Sin él no sale ni un
  /// paquete hacia el servidor ni hacia el otro móvil, y iOS no avisa.
  bool? localNetworkAllowed;

  /// El enlace con el otro móvil del soporte (TASK A3).
  LinkState linkState = LinkState.off;
  String linkPeer = '';
  bool _sortingPhase = false;

  /// El izquierdo es el maestro: su hora es la del soporte por definición (ADR 0012,
  /// decisión 2), así que no espera reloj de nadie. El derecho mide su desfase contra él.
  /// «Este móvil dirige» (IOS-80): solo decide al empezar un partido.
  final bool prefersMaster;

  /// El rol que negoció el enlace, o null si todavía no hay (o el enlace de Multipeer,
  /// que no negocia y deja de maestro al izquierdo).
  RigRole? rigRole;
  int rigTerm = 0;

  /// El partido que negoció el enlace, si alguno de los dos traía.
  String? rigMatchId;

  /// El servidor del mando, si esta pantalla lo levanta al dirigir (IOS-62).
  final MasterHost? masterHost;

  /// La pizarra del maestro que guarda el esclavo (IOS-82).
  final ReplicaStore? replicaStore;

  /// Quién manda en el soporte: el negociado si lo hay; si no, el izquierdo.
  bool get isRigMaster => rigRole == null ? role == CameraRole.left : rigRole == RigRole.master;

  /// El maestro del reloj es el maestro del soporte (IOS-80).
  bool get isClockMaster => isRigMaster;

  int? exposurePhaseNs;
  int phaseAttempt = 0;

  /// Archivo de la grabación en curso, o de la última, tal como lo nombró el nativo.
  String? recordingFile;
  final Stopwatch _recordingClock = Stopwatch();

  bool get recording => phase == SessionPhase.grabando;

  /// Cuánto lleva grabando el segmento en curso. Es el mismo reloj que usa
  /// [recordingLabel]; el HUD lo enseña solo, sin el nombre del archivo.
  Duration get recordingElapsed => _recordingClock.elapsed;

  /// Solo se graba con la cámara lista. Dejar grabar antes es la forma más fácil de
  /// volver a casa con dos vídeos que no parean.
  bool get canRecord => phase == SessionPhase.lista || phase == SessionPhase.grabando;

  String get modeLabel =>
      standalone ? 'un solo móvil · SIN RELOJ' : 'soporte de dos móviles';

  String get localNetworkLabel {
    switch (localNetworkAllowed) {
      case null:
        return 'sin pedir';
      case true:
        return 'permitida';
      case false:
        return 'NO PERMITIDA · Ajustes → Privacidad y seguridad → Red local';
    }
  }

  /// Cuánto lleva grabando y en qué archivo: es lo que se lee de un vistazo en la
  /// cancha para saber que de verdad se está grabando.
  String get recordingLabel {
    final Duration elapsed = _recordingClock.elapsed;
    final String minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final String seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final String? file = recordingFileName;
    if (file == null) {
      return '$minutes:$seconds';
    }
    final int segment = status?.recordingSegment ?? 1;
    final String suffix = segment > 1 ? ' · segmento $segment' : '';
    return '$minutes:$seconds · $file$suffix';
  }

  /// El archivo en curso. Manda el que dice el nativo: tras un corte, la grabación
  /// sigue en un segmento nuevo que la pantalla tiene que enseñar sin que nadie pulse.
  String? get recordingFileName => recordingPath?.split('/').last;

  /// La ruta entera de la grabación en curso o de la última, con el mismo criterio.
  String? get recordingPath {
    final String? fromNative = status?.recordingFile;
    final String? path = (fromNative != null && fromNative.isNotEmpty) ? fromNative : recordingFile;
    return (path == null || path.isEmpty) ? null : path;
  }

  /// Dónde está el panel del servidor, o `null` si no hay servidor.
  Uri? get panelUri => panelUriFrom(serverHost);

  /// Se puede subir la última grabación para calibrar: hay una, ya no se está grabando,
  /// hay panel, y es un soporte de dos (con un solo móvil no hay nada que calibrar).
  bool get canUploadForCalibration =>
      !standalone &&
      !recording &&
      recordingPath != null &&
      panelUri != null &&
      calibrationUpload != CalibrationUpload.subiendo;

  /// Se puede pedir una calibración: soporte de dos, con panel, sin estar grabando ya.
  /// Solo el izquierdo lo ofrece, porque es quien manda al derecho.
  bool get canCalibrate =>
      isClockMaster &&
      !standalone &&
      !recording &&
      panelUri != null &&
      phase == SessionPhase.lista &&
      calibrationUpload != CalibrationUpload.subiendo;

  /// Graba un clip corto en los dos móviles y lo sube al panel para calibrar el soporte.
  ///
  /// Un paso en vez de cuatro: antes había que grabar a mano en los dos, pararlos, y
  /// subir desde cada uno. Lo que se sube es la grabación local (45 Mbit/s con el código
  /// de tiempo pintado), no la emisión, que por Starlink llega sin esquinas.
  Future<void> calibrateNow({String recordingDirectory = ''}) async {
    if (!canCalibrate) {
      return;
    }
    calibrationResult = null;
    final CalibrationUploader panel =
        uploader(panelUri!, role, cameraCredentialsFrom(serverHost));
    // Antes de nada, por qué intento va el panel: así se distingue el resultado de esta
    // calibración del de la anterior, que puede seguir ahí de hace un rato.
    final int previous = await panel.lastAttempt();

    await _orderPeer(RigCommand.calibrate);
    await _recordClip(recordingDirectory: recordingDirectory);
    await uploadForCalibration();
    if (calibrationUpload != CalibrationUpload.subida) {
      return; // la subida ya dejó dicho qué falló
    }

    calibrationWaiting = true;
    notifyListeners();
    calibrationResult = await panel.waitForResult(previousAttempt: previous);
    calibrationWaiting = false;
    notifyListeners();

    // Si el soporte quedó calibrado, a emitir: es lo que se iba a hacer a continuación
    // de todos modos, y con el soporte ya bueno.
    if (calibrationResult?.ok ?? false) {
      await toggleRecording(recordingDirectory: recordingDirectory);
    }
  }

  /// Borra del móvil la grabación que se acaba de subir.
  ///
  /// El clip se graba solo para calibrar: con «Guardar vídeo» apagado, dejarlo sería
  /// justo lo que este ajuste evita. Si no se puede borrar, no pasa nada: la próxima
  /// grabación lo hará igual.
  Future<void> _discardRecording() async {
    final String? path = recordingPath;
    if (path == null) {
      return;
    }
    try {
      await File(path).delete();
      recordingFile = null;
      notifyListeners();
    } on FileSystemException {
      // El fichero ya no estaba, o el sistema no deja: no es motivo para avisar de nada.
    }
  }

  /// Cómo acabó la última calibración, según el panel. `null` mientras no se haya pedido
  /// ninguna o si el panel no contestó a tiempo.
  CalibrationResult? calibrationResult;

  /// Se está esperando a que el panel termine de calibrar.
  bool calibrationWaiting = false;

  /// Lo que la pantalla enseña de la calibración: una línea, la que importa.
  String? get calibrationResultLabel {
    if (calibrationWaiting) {
      return 'calibrando en el servidor…';
    }
    final CalibrationResult? result = calibrationResult;
    if (result == null) {
      return null;
    }
    if (result.ok) {
      return 'CALIBRADO · ${result.message}';
    }
    return 'NO CALIBRÓ · ${result.message}${result.hint.isEmpty ? '' : '\n${result.hint}'}';
  }

  /// Graba `calibrationClipDuration` y para. Lo usan el botón CALIBRAR del izquierdo y
  /// la orden que le llega al derecho, para que los dos clips se solapen en el tiempo.
  Future<void> _recordClip({String recordingDirectory = ''}) async {
    _clipping = true;
    try {
      await _recordClipInner(recordingDirectory: recordingDirectory);
    } finally {
      _clipping = false;
    }
  }

  Future<void> _recordClipInner({String recordingDirectory = ''}) async {
    // El clip se graba aunque «Guardar vídeo» esté apagado: es justo el fichero que se
    // sube, y se borra en cuanto el panel lo tiene.
    await toggleRecording(recordingDirectory: recordingDirectory, save: true);
    if (!recording) {
      return; // no arrancó: `toggleRecording` ya dejó dicho por qué
    }
    await Future<void>.delayed(calibrationClipDuration);
    if (recording) {
      await toggleRecording();
    }
  }

  /// Sube la última grabación al panel. Cuando el panel tenga las de los dos móviles,
  /// calibra el soporte solo y la cámara virtual arranca con esa calibración.
  Future<void> uploadForCalibration() async {
    final String? path = recordingPath;
    final Uri? panel = panelUri;
    if (!canUploadForCalibration || path == null || panel == null) {
      return;
    }
    calibrationUpload = CalibrationUpload.subiendo;
    uploadSent = 0;
    uploadTotal = 0;
    uploadProblem = null;
    notifyListeners();
    try {
      uploadCalibrating = await uploader(panel, role, cameraCredentialsFrom(serverHost)).upload(
        File(path),
        onProgress: (int sent, int total) {
          uploadSent = sent;
          uploadTotal = total;
          notifyListeners();
        },
      );
      calibrationUpload = CalibrationUpload.subida;
      if (!saveVideo) {
        await _discardRecording();
      }
    } on CalibrationUploadException catch (error) {
      calibrationUpload = CalibrationUpload.fallo;
      uploadProblem = error.message;
    } on FileSystemException catch (error) {
      calibrationUpload = CalibrationUpload.fallo;
      uploadProblem = 'no se pudo leer la grabación: ${error.message}';
    }
    notifyListeners();
  }

  /// Lo que dice el botón de subir, en mayúsculas como los demás de esta pantalla.
  String get calibrationUploadLabel {
    String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
    return switch (calibrationUpload) {
      CalibrationUpload.ninguna => 'SUBIR PARA CALIBRAR',
      CalibrationUpload.subiendo =>
        uploadTotal == 0 ? 'SUBIENDO…' : 'SUBIENDO ${mb(uploadSent)} / ${mb(uploadTotal)} MB',
      CalibrationUpload.subida =>
        uploadCalibrating ? 'SUBIDA · EL SERVIDOR CALIBRA' : 'SUBIDA · FALTA LA DEL OTRO MÓVIL',
      CalibrationUpload.fallo => 'NO SE SUBIÓ · REINTENTAR',
    };
  }

  /// A dónde publica este móvil: un path por cámara en el MediaMTX del servidor
  /// (`izquierda` / `derecha`), con el búfer SRT que aguanta los traspasos de Starlink.
  String get streamUrl => buildStreamUrl(serverHost, role);

  /// `15000000` → `15`, `6200000` → `6.2`: sin decimales cuando son cero.
  static String formatMbps(int bps) {
    final double mbps = bps / 1e6;
    return mbps.toStringAsFixed(mbps == mbps.roundToDouble() ? 0 : 1);
  }

  String get streamLabel {
    final CaptureStatus? applied = status;
    switch (applied?.streamState ?? StreamState.off) {
      case StreamState.off:
        if (serverHost.trim().isEmpty) {
          return 'apagada: sin servidor configurado';
        }
        return streamUrl.isEmpty ? 'apagada: no se entiende el servidor' : 'apagada';
      case StreamState.connecting:
        return 'conectando por ${describeStreamTarget(serverHost)}…';
      case StreamState.streaming:
        return 'EMITIENDO por ${describeStreamTarget(serverHost)} · '
            '${formatMbps(applied!.streamBitrateBps > 0 ? applied.streamBitrateBps : defaultSettings(role).bitrateBps)} Mbit/s';
      case StreamState.reconnecting:
        return 'RECONECTANDO · ${applied!.streamDetail}';
      case StreamState.failed:
        return 'FALLO · ${applied!.streamDetail}';
    }
  }

  bool get streamInTrouble {
    final StreamState state = status?.streamState ?? StreamState.off;
    return state == StreamState.reconnecting || state == StreamState.failed;
  }

  /// Lo que quedó congelado, en la unidad en que se lee: 1/100 e ISO, no segundos.
  String get exposureLabel {
    final CaptureStatus? applied = status;
    if (applied == null || !applied.exposureLocked) {
      return 'AUTOMÁTICA';
    }
    final int denominator = applied.exposureSeconds > 0 ? (1 / applied.exposureSeconds).round() : 0;
    return 'bloqueada · 1/$denominator · ISO ${applied.iso}';
  }

  /// El código de tiempo pintado en cada frame: sin él el servidor no empareja.
  String get timecodeLabel {
    final CaptureStatus? applied = status;
    if (applied == null) {
      return 'sin cámara';
    }
    return applied.timecodeFailures == 0
        ? 'pintado en cada frame'
        : 'FALLA en ${applied.timecodeFailures} frames';
  }

  String get whiteBalanceLabel {
    final CaptureStatus? applied = status;
    if (applied == null || !applied.whiteBalanceLocked) {
      return 'AUTOMÁTICO';
    }
    return 'bloqueado · ${applied.whiteBalanceKelvin} K';
  }

  String get linkLabel {
    switch (linkState) {
      case LinkState.off:
        return standalone ? 'apagado: un solo móvil' : 'apagado';
      case LinkState.searching:
        return role == CameraRole.left ? 'esperando al móvil derecho…' : 'buscando al móvil izquierdo…';
      case LinkState.connected:
        return 'conectado con $linkPeer';
      case LinkState.conflict:
        return 'conflicto: los dos dirigen partidos distintos';
    }
  }

  String get clockLabel {
    if (isClockMaster && !standalone) {
      return 'maestro: este móvil marca la hora';
    }
    final ClockSyncEstimate? estimate = _nativeClockEstimate ?? _clock.estimate;
    if (estimate == null) {
      return 'sin reloj';
    }
    final double offsetMs = estimate.offsetNs / 1e6;
    final double uncertaintyMs = estimate.uncertaintyNs / 1e6;
    return '${offsetMs.toStringAsFixed(1)} ms ±${uncertaintyMs.toStringAsFixed(1)} · '
        '${estimate.driftPpm.toStringAsFixed(1)} ppm';
  }

  String get phaseLabel {
    final int? measured = exposurePhaseNs;
    if (measured == null) {
      return 'sin medir';
    }
    final double smearCm =
        phasePolicy.smearMeters(phaseNs: measured, speedMetersPerSecond: 30.0) * 100;
    return '${(measured / 1e6).toStringAsFixed(1)} ms · balón ${smearCm.round()} cm';
  }

  /// Comprueba el dispositivo y abre la cámara con los ajustes del ADR 0012.
  Future<void> prepare({CaptureSettings? settings}) async {
    _set(SessionPhase.preparando, problem: null);
    try {
      if (linkOnly) {
        localNetworkAllowed = await _api.requestLocalNetworkAccess();
        if (!await _startLink()) {
          return;
        }
        _set(SessionPhase.esperandoReloj);
        return;
      }
      // El permiso va primero: sin él la sesión abre igual y no llega ni un frame.
      if (!await _api.requestCameraAccess()) {
        _set(
          SessionPhase.fallo,
          problem: 'sin permiso de cámara: concédelo en Ajustes y vuelve a entrar',
        );
        return;
      }
      // No es fatal: sin red local se graba igual. Pero se pide ahora, con el
      // operador mirando, y no en mitad del partido.
      localNetworkAllowed = await _api.requestLocalNetworkAccess();
      if (!await _api.hasUltraWideCamera()) {
        _set(
          SessionPhase.fallo,
          problem: 'este iPhone no tiene ultra gran angular: no puede ser cámara',
        );
        return;
      }
      status = await _api.configure(settings ?? defaultSettings(role));
      final String? wrong = _whatIsWrong(status!);
      if (wrong != null) {
        _set(SessionPhase.fallo, problem: wrong);
        return;
      }
      if (standalone) {
        _set(SessionPhase.lista);
        return;
      }
      // Con la cámara en orden se abre el enlace. El maestro ya puede grabar: si el
      // derecho no llega nunca, media cancha es mejor que ninguna (decisión 4).
      if (!await _startLink()) {
        return;
      }
      _set(isClockMaster ? SessionPhase.lista : SessionPhase.esperandoReloj);
    } on Exception catch (error) {
      _set(SessionPhase.fallo, problem: 'no se pudo abrir la cámara: $error');
    }
  }

  /// Vuelve a leer el estado del nativo.
  ///
  /// La pantalla lo llama cada segundo: batería, temperatura y frames perdidos cambian
  /// sin que nadie avise, y `running` solo es verdad un rato después de configurar.
  /// Antes de tener cámara no hay nada que leer.
  Future<void> refreshStatus() async {
    if (status == null) {
      return;
    }
    try {
      status = await _api.status();
    } on Exception {
      // Un fallo puntual del canal no es un problema de captura: se reintenta al
      // segundo siguiente sin asustar a nadie.
      return;
    }
    notifyListeners();
  }

  /// Lo que invalida el soporte aunque la cámara haya abierto.
  ///
  /// Se comprueba lo aplicado y no lo pedido: AVFoundation acepta peticiones que luego
  /// no cumple, y enterarse por la cara del vídeo no es una opción.
  String? _whatIsWrong(CaptureStatus applied) {
    if (!applied.stabilizationDisabled) {
      return 'la estabilización sigue activa: recorta y mueve la imagen, y la '
          'calibración del soporte deja de valer';
    }
    if (!applied.exposureLocked) {
      return 'la exposición no quedó bloqueada: la costura cambiará de brillo';
    }
    return null;
  }

  /// Mide la fase de exposición contra el otro móvil y reinicia si salió mala (A4).
  ///
  /// `masterPtsNs` los trae el enlace entre móviles (TASK A3), no la cámara: la fase es
  /// un desfase entre los dos y ninguno de los dos lo conoce solo.
  Future<void> sortExposurePhase({
    required Future<List<int>> Function() masterPtsNs,
    required int frameIntervalNs,
  }) async {
    _set(SessionPhase.ajustandoFase);
    for (phaseAttempt = 1; phaseAttempt <= phasePolicy.maxAttempts; phaseAttempt++) {
      // Los PTS tienen que ser posteriores al último arranque, o se mide la fase vieja.
      await Future<void>.delayed(phaseSettle);
      final List<int> local = await _api.recentFramePtsNs();
      final List<int> master = await masterPtsNs();
      if (local.isEmpty || master.isEmpty) {
        // Alguna de las dos cámaras aún no entrega frames, o el maestro no contestó.
        // Cuenta como intento, pero no se reinicia nada: no hay fase mala que sortear.
        continue;
      }
      exposurePhaseNs = measurePhaseNs(
        localPtsNs: local,
        masterPtsNs: master,
        frameIntervalNs: frameIntervalNs,
      );
      final PhaseDecision decision =
          phasePolicy.decide(phaseNs: exposurePhaseNs!, attempt: phaseAttempt);
      notifyListeners();
      if (decision != PhaseDecision.retry) {
        _set(SessionPhase.lista);
        return;
      }
      await _api.restartForPhase();
    }
    _set(SessionPhase.lista);
  }

  bool _toggling = false;

  /// Guardar el vídeo en el móvil además de emitirlo.
  ///
  /// Apagado por defecto: un partido son ~40 GB por móvil a 45 Mbit/s y llena el
  /// teléfono en dos. Se enciende cuando hace falta el respaldo en local, por ejemplo si
  /// la red del campo no es de fiar y se prefiere volver con el partido en diferido.
  bool saveVideo = false;

  void setSaveVideo(bool value) {
    if (saveVideo == value) {
      return;
    }
    saveVideo = value;
    notifyListeners();
    unawaited(_orderPeer(value ? RigCommand.recordAndSave : RigCommand.record));
  }

  /// Mientras dura el clip de calibración, `toggleRecording` no manda nada al otro
  /// móvil: ya recibió `calibrate` y está haciendo su propio clip.
  bool _clipping = false;

  Future<void> toggleRecording({
    String? srtUrl,
    String recordingDirectory = '',
    bool? save,
  }) async {
    // Dos toques seguidos son uno: el segundo llegaría con el nativo a medio abrir.
    if (_toggling) {
      return;
    }
    _toggling = true;
    try {
      if (recording) {
        await _api.stop();
        _recordingClock.stop();
        _set(SessionPhase.lista);
        await _orderPeer(RigCommand.stop);
        return;
      }
      final bool guardar = save ?? saveVideo;
      final String file = await _api.start(srtUrl ?? streamUrl, recordingDirectory, guardar);
      recordingFile = file.isEmpty ? null : file;
      // Con el soporte montado, el izquierdo manda: poner a grabar los dos a mano es
      // donde más fácil es dejarse uno sin grabar o empezarlos con medio minuto de
      // diferencia. Va después de arrancar la propia: si esta falla, no se manda nada.
      await _orderPeer(guardar ? RigCommand.recordAndSave : RigCommand.record);
      _recordingClock
        ..reset()
        ..start();
      _set(SessionPhase.grabando);
    } on Exception catch (error) {
      // Grabar puede fallar (disco lleno, archivo no creado) sin que la cámara deje de
      // valer: se queda lista y se dice por qué.
      _set(SessionPhase.lista, problem: 'no se pudo grabar: $error');
    } finally {
      _toggling = false;
    }
  }

  /// Manda una orden al otro móvil. Solo el izquierdo manda, y solo con enlace: el que
  /// está solo graba solo, sin esperar a nadie.
  Future<void> _orderPeer(RigCommand command) async {
    if (_clipping && command != RigCommand.calibrate) {
      return;
    }
    if (!isClockMaster || linkState != LinkState.connected || standalone) {
      return;
    }
    try {
      await _api.sendPeerCommand(command);
    } on Exception {
      // Que la orden no salga no puede parar la grabación de este móvil, que es la que
      // el operador acaba de pedir con el dedo.
    }
  }

  /// Lo que hace el derecho cuando el izquierdo manda. `calibrate` llega en la segunda
  /// parte de esto; por ahora se ignora, que es mejor que grabar sin saber cuánto.
  @override
  void onPeerCommand(RigCommand command) {
    switch (command) {
      case RigCommand.record:
      case RigCommand.recordAndSave:
        final bool guardar = command == RigCommand.recordAndSave;
        saveVideo = guardar;
        if (!recording) {
          unawaited(toggleRecording(save: guardar));
        }
      case RigCommand.stop:
        if (recording) {
          unawaited(toggleRecording());
        }
      case RigCommand.calibrate:
        if (!recording) {
          unawaited(_recordClip().then((_) => uploadForCalibration()));
        }
    }
  }

  // Avisos del nativo (CaptureFlutterApi). Llegan por el canal cuando la pantalla
  // registra esta sesión con `CaptureFlutterApi.setUp`.

  @override
  void onInterrupted(String reason) {
    interruption = reason;
    notifyListeners();
  }

  @override
  void onResumed() {
    interruption = null;
    notifyListeners();
  }

  @override
  void onThermalStateChanged(ThermalState state) {
    status?.thermalState = state;
    notifyListeners();
  }

  @override
  void onStatus(CaptureStatus latest) {
    status = latest;
    notifyListeners();
  }

  @override
  void onRigRole(RigRole role, int term, String? matchId) {
    rigRole = role;
    rigTerm = term;
    rigMatchId = matchId;
    // El que dirige sirve el mando en la LAN (IOS-62); el que deja de dirigir, cierra.
    final MasterHost? host = masterHost;
    if (host != null) {
      unawaited(role == RigRole.master ? host.becomeMaster(matchId) : host.stepDown());
    }
    notifyListeners();
  }

  @override
  void onReplica(String json) {
    final ReplicaStore? store = replicaStore;
    if (store != null && store.accept(json)) {
      // El esclavo adopta el reloj del maestro: si se promueve, sigue en el mismo dominio.
      unawaited(_api.adoptClockDomain(store.latest!.clockDomain));
    }
  }

  @override
  void onLinkStateChanged(LinkState state, String peerName) {
    linkState = state;
    linkPeer = peerName;
    notifyListeners();
  }

  /// Los cuatro sellos de una pregunta de hora al maestro, tomados en nativo. Aquí solo
  /// se despeja el desfase y se acumula: es la parte que se puede probar sin red.
  @override
  void onClockStamps(int t1Ns, int t2Ns, int t3Ns, int t4Ns) {
    _onClockSample(solveClockSample(t1: t1Ns, t2: t2Ns, t3: t3Ns, t4: t4Ns));
  }

  /// La estimación del reloj nativo (IOS-13), con el enlace sobre Network. El desfase
  /// ya va aplicado por fotograma en nativo, sin `setClockOffsetNs`: aquí solo mueve
  /// la fase y lo que enseña la pantalla.
  @override
  void onClockEstimate(int offsetNs, double driftPpm, int samples, int uncertaintyNs) {
    _nativeClockEstimate = ClockSyncEstimate(
      offsetNs: offsetNs,
      driftPpm: driftPpm,
      samples: samples,
      bestRoundTripNs: uncertaintyNs * 2,
    );
    if (phase == SessionPhase.esperandoReloj && !linkOnly) {
      _set(SessionPhase.ajustandoFase);
      if (autoSortPhase) {
        unawaited(_sortPhaseAgainstMaster());
      }
    }
    notifyListeners();
  }

  void _onClockSample(ClockSample sample) {
    _clock.add(sample);
    if (_clock.estimate != null) {
      unawaited(_api.setClockOffsetNs(_clock.offsetAtNs(sample.localMonotonicNs)));
      if (kDebugMode) {
        debugPrint('[reloj] $clockLabel · ${_clock.estimate!.samples} muestras');
      }
      if (phase == SessionPhase.esperandoReloj && !linkOnly) {
        _set(SessionPhase.ajustandoFase);
        if (autoSortPhase) {
          unawaited(_sortPhaseAgainstMaster());
        }
      }
    }
    notifyListeners();
  }

  /// Con reloj ya se puede medir la fase: se hace sola, sin que nadie pulse nada.
  Future<void> _sortPhaseAgainstMaster() async {
    if (_sortingPhase) {
      return;
    }
    _sortingPhase = true;
    try {
      await sortExposurePhase(
        masterPtsNs: _api.masterRecentPtsNs,
        frameIntervalNs: nsPerSecond ~/ defaultSettings(role).fps,
      );
    } on Exception catch (error) {
      // Sin fase medida se graba igual: es peor costura, no un partido perdido.
      _set(SessionPhase.lista, problem: 'no se pudo medir la fase: $error');
    } finally {
      _sortingPhase = false;
    }
  }

  void _set(SessionPhase next, {String? problem}) {
    final bool grababa = phase == SessionPhase.grabando;
    phase = next;
    this.problem = problem;
    // IOS-07: la pantalla se atenúa al empezar a emitir y vuelve al parar. Va aquí y
    // no en la página, para que un stop por orden del maestro también la restaure.
    final bool graba = next == SessionPhase.grabando;
    if (graba != grababa) {
      screenDim(graba);
    }
    notifyListeners();
  }

  /// IOS-07: el toque de «ver 30 s» de la página levanta el brillo y lo vuelve a
  /// bajar. Un fallo del canal no puede tumbar la emisión: se ignora.
  void screenDim(bool dimmed) {
    unawaited(_api.setScreenDim(dimmed).catchError((Object _) {}));
  }

  bool _disposed = false;

  /// La última sesión que abrió el enlace. En el nativo hay un solo enlace, así que
  /// cerrarlo es cosa de quien lo abrió **el último**: si el operador vuelve atrás y entra
  /// otra vez (por ejemplo, para invertir los lados), la pantalla vieja se libera después
  /// de que la nueva haya abierto el suyo, y cerrarlo entonces dejaba a la nueva sin
  /// enlace hasta reiniciar la app (bug 2 del 22-09).
  static CaptureSession? _linkOwner;

  /// Abre el enlace, salvo que la pantalla ya se haya cerrado: abrirlo entonces lo dejaba
  /// huérfano, sin nadie que lo cerrara. `false` si no se abrió.
  Future<bool> _startLink() async {
    if (_disposed) {
      return false;
    }
    _linkOwner = this;
    await _api.startLink(role, prefersMaster);
    return true;
  }

  /// `prepare` puede terminar después de que la pantalla se haya cerrado (el operador
  /// vuelve atrás mientras la cámara mide la luz). Avisar a una sesión liberada tira la
  /// app en debug y no sirve de nada en release: se calla.
  @override
  void notifyListeners() {
    if (_disposed) {
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // La cámara se suelta al salir de la pantalla. Parar de grabar ya no la apaga.
    unawaited(_api.releaseCamera());
    // Por quién lo abrió y no por `linkState`: ese estado llega en un aviso del nativo
    // que puede no haber llegado todavía, y entonces el enlace se quedaba abierto.
    if (identical(_linkOwner, this)) {
      _linkOwner = null;
      unawaited(_api.stopLink());
    }
    unawaited(masterHost?.stepDown());
    unawaited(_clockSubscription?.cancel());
    super.dispose();
  }
}

/// Los ajustes del ADR 0012. No son preferencias: cambiarlos invalida la calibración.
CaptureSettings defaultSettings(CameraRole role) {
  return CaptureSettings(
    role: role,
    width: 3840,
    height: 2160,
    fps: 30,
    // 15 Mbit/s: el techo de lo que cabe por Starlink compartido entre dos móviles, y
    // el suelo de lo que deja un balón de 6 px detectable. Se ajusta en la primera
    // emisión real; el ADR 0012 no lo fija a propósito.
    bitrateBps: 15000000,
    // 1/100 con red de 50 Hz. Con 60 Hz hay que poner 120 o los focos dan bandas.
    shutterDenominator: 100,
    iso: 200,
    cropToPlayableBand: true,
  );
}
