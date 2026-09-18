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

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/exposure_phase.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/rig_clock.dart';
import 'package:football_ai_capture/src/stream_url.dart';

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
  })  : _api = api ?? CaptureHostApi(),
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

  final CaptureHostApi _api;
  final RigClock _clock;
  StreamSubscription<ClockSample>? _clockSubscription;

  SessionPhase phase = SessionPhase.preparando;
  CaptureStatus? status;
  String? problem;

  /// La interrupción que avisó el nativo (llamada, otra app, calor), mientras dure.
  String? interruption;

  /// Permiso de red local de iOS. `null` hasta que se pide. Sin él no sale ni un
  /// paquete hacia el servidor ni hacia el otro móvil, y iOS no avisa.
  bool? localNetworkAllowed;

  int? exposurePhaseNs;
  int phaseAttempt = 0;

  /// Archivo de la grabación en curso, o de la última, tal como lo nombró el nativo.
  String? recordingFile;
  final Stopwatch _recordingClock = Stopwatch();

  bool get recording => phase == SessionPhase.grabando;

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
  String? get recordingFileName {
    final String? fromNative = status?.recordingFile;
    final String? path = (fromNative != null && fromNative.isNotEmpty) ? fromNative : recordingFile;
    return path?.split('/').last;
  }

  /// A dónde publica este móvil: un path por cámara en el MediaMTX del servidor
  /// (`izquierda` / `derecha`), con el búfer SRT que aguanta los traspasos de Starlink.
  String get streamUrl => buildStreamUrl(serverHost, role);

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
            '${defaultSettings(role).bitrateBps ~/ 1000000} Mbit/s';
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

  String get clockLabel {
    final ClockSyncEstimate? estimate = _clock.estimate;
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
      _set(standalone ? SessionPhase.lista : SessionPhase.esperandoReloj);
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
      exposurePhaseNs = measurePhaseNs(
        localPtsNs: await _api.recentFramePtsNs(),
        masterPtsNs: await masterPtsNs(),
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

  Future<void> toggleRecording({String? srtUrl, String recordingDirectory = ''}) async {
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
        return;
      }
      recordingFile = await _api.start(srtUrl ?? streamUrl, recordingDirectory);
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

  void _onClockSample(ClockSample sample) {
    _clock.add(sample);
    if (_clock.estimate != null) {
      unawaited(_api.setClockOffsetNs(_clock.offsetAtNs(sample.localMonotonicNs)));
      if (phase == SessionPhase.esperandoReloj) {
        _set(SessionPhase.ajustandoFase);
      }
    }
    notifyListeners();
  }

  void _set(SessionPhase next, {String? problem}) {
    phase = next;
    this.problem = problem;
    notifyListeners();
  }

  bool _disposed = false;

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
