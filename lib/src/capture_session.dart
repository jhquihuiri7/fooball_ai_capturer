/// El ciclo de vida de una cámara del soporte (ADR 0012, EPIC A).
///
/// Junta las tres cosas que tienen que estar bien antes de que alguien pulse GRABAR:
/// que la cámara se abriera con los ajustes correctos, que haya reloj común con el otro
/// móvil, y que la fase de exposición sea pequeña.
///
/// El transporte con el otro móvil entra por `clockSamples` en vez de construirse aquí.
/// Hoy ese stream lo llena la TASK A3 (Multipeer); mañana podría ser otra cosa, y así
/// esta clase se prueba sin levantar ninguna red.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/exposure_phase.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/rig_clock.dart';

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

class CaptureSession extends ChangeNotifier {
  CaptureSession({
    required this.role,
    CaptureHostApi? api,
    Stream<ClockSample>? clockSamples,
    RigClock? clock,
    this.phasePolicy = const PhaseSortPolicy(),
  })  : _api = api ?? CaptureHostApi(),
        _clock = clock ?? RigClock() {
    if (clockSamples != null) {
      _clockSubscription = clockSamples.listen(_onClockSample);
    }
  }

  final CameraRole role;
  final PhaseSortPolicy phasePolicy;

  final CaptureHostApi _api;
  final RigClock _clock;
  StreamSubscription<ClockSample>? _clockSubscription;

  SessionPhase phase = SessionPhase.preparando;
  CaptureStatus? status;
  String? problem;
  int? exposurePhaseNs;
  int phaseAttempt = 0;

  bool get recording => phase == SessionPhase.grabando;

  /// Solo se graba con la cámara lista. Dejar grabar antes es la forma más fácil de
  /// volver a casa con dos vídeos que no parean.
  bool get canRecord => phase == SessionPhase.lista || phase == SessionPhase.grabando;

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
      _set(SessionPhase.esperandoReloj);
    } on Exception catch (error) {
      _set(SessionPhase.fallo, problem: 'no se pudo abrir la cámara: $error');
    }
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

  /// Mide la fase de exposición y reinicia si salió mala (TASK A4).
  Future<void> sortExposurePhase() async {
    _set(SessionPhase.ajustandoFase);
    for (phaseAttempt = 1; phaseAttempt <= phasePolicy.maxAttempts; phaseAttempt++) {
      exposurePhaseNs = await _api.exposurePhaseNs();
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

  Future<void> toggleRecording({String srtUrl = '', String recordingDirectory = ''}) async {
    if (recording) {
      await _api.stop();
      _set(SessionPhase.lista);
      return;
    }
    await _api.start(srtUrl, recordingDirectory);
    _set(SessionPhase.grabando);
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

  @override
  void dispose() {
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
