import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

const int frame30 = 33333333; // ns, un frame a 30 fps

Future<List<int>> _masterPts() async => <int>[0, frame30, 2 * frame30];

CaptureStatus _status({
  bool stabilizationDisabled = true,
  bool exposureLocked = true,
}) {
  return CaptureStatus(
    running: true,
    width: 3840,
    height: 2160,
    actualFps: 30.0,
    stabilizationDisabled: stabilizationDisabled,
    exposureLocked: exposureLocked,
    whiteBalanceLocked: true,
    focusLocked: true,
    intrinsicsAvailable: true,
    thermalState: ThermalState.nominal,
    batteryLevel: 0.9,
    freeDiskBytes: 64000000000,
    droppedFrames: 0,
  );
}

/// Cámara falsa: el nativo no existe en un test de Dart, y tampoco hace falta.
class _FakeApi extends CaptureHostApi {
  _FakeApi({
    this.ultraWide = true,
    CaptureStatus? status,
    this.phases = const <int>[0],
  }) : applied = status ?? _status();

  final bool ultraWide;

  /// No se puede llamar `status`: chocaría con el método `status()` del contrato.
  final CaptureStatus applied;
  final List<int> phases;

  int configureCalls = 0;
  int restarts = 0;
  int startCalls = 0;
  int stopCalls = 0;
  final List<int> offsets = <int>[];
  int _phaseIndex = 0;

  @override
  Future<bool> hasUltraWideCamera() async => ultraWide;

  @override
  Future<CaptureStatus> configure(CaptureSettings settings) async {
    configureCalls++;
    return applied;
  }

  @override
  Future<CaptureStatus> status() async => applied;

  /// Cada intento entrega un PTS local desplazado la fase que toque; el maestro
  /// siempre está en 0, así que la resta da exactamente esa fase.
  @override
  Future<List<int>> recentFramePtsNs() async {
    final int value = phases[_phaseIndex.clamp(0, phases.length - 1)];
    _phaseIndex++;
    return <int>[value, frame30 + value, 2 * frame30 + value];
  }

  @override
  Future<void> restartForPhase() async => restarts++;

  @override
  Future<void> start(String srtUrl, String recordingDirectory) async => startCalls++;

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> setClockOffsetNs(int offsetNs) async => offsets.add(offsetNs);
}

void main() {
  group('prepare', () {
    test('sin ultra gran angular no hay cámara que valga', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: _FakeApi(ultraWide: false));

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.problem, contains('ultra gran angular'));
      expect(session.canRecord, isFalse);
    });

    test('la estabilización activa invalida el soporte', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: _FakeApi(status: _status(stabilizationDisabled: false)),
      );

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.problem, contains('estabilización'));
    });

    test('la exposición sin bloquear también', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: _FakeApi(status: _status(exposureLocked: false)),
      );

      await session.prepare();

      expect(session.problem, contains('exposición'));
    });

    test('con todo en orden se queda esperando reloj, no lista', () async {
      // Grabar sin reloj común es volver a casa con dos vídeos que no parean.
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: _FakeApi());

      await session.prepare();

      expect(session.phase, SessionPhase.esperandoReloj);
      expect(session.canRecord, isFalse);
    });
  });

  group('fase de exposición', () {
    test('una fase buena se acepta sin reiniciar', () async {
      final _FakeApi api = _FakeApi(phases: <int>[2 * nsPerMillisecond]);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 0);
      expect(session.phase, SessionPhase.lista);
    });

    test('una fase mala se reintenta hasta sortear una buena', () async {
      final _FakeApi api = _FakeApi(
        phases: <int>[15 * nsPerMillisecond, 12 * nsPerMillisecond, 1 * nsPerMillisecond],
      );
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 2);
      expect(session.exposurePhaseNs, nsPerMillisecond);
      expect(session.phase, SessionPhase.lista);
    });

    test('agotados los intentos se graba igual', () async {
      final _FakeApi api = _FakeApi(phases: <int>[16 * nsPerMillisecond]);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, exposurePhaseMaxAttempts - 1);
      expect(session.phase, SessionPhase.lista);
    });

    test('la etiqueta traduce la fase a centímetros de balón', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: _FakeApi(phases: <int>[5 * nsPerMillisecond]),
      );

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(session.phaseLabel, contains('15 cm'));
    });
  });

  group('reloj del soporte', () {
    test('al haber reloj se empuja el desfase al nativo y se pasa a ajustar fase', () async {
      final _FakeApi api = _FakeApi();
      final StreamController<ClockSample> samples = StreamController<ClockSample>();
      final CaptureSession session = CaptureSession(
        role: CameraRole.right,
        api: api,
        clockSamples: samples.stream,
      );
      await session.prepare();

      for (int i = 0; i < 4; i++) {
        samples.add(ClockSample(
          roundTripNs: 2 * nsPerMillisecond,
          offsetNs: 7 * nsPerMillisecond,
          localMonotonicNs: i * nsPerSecond,
        ));
      }
      await Future<void>.delayed(Duration.zero);

      expect(api.offsets, isNotEmpty);
      expect(api.offsets.last, 7 * nsPerMillisecond);
      expect(session.phase, SessionPhase.ajustandoFase);
      expect(session.clockLabel, contains('7.0 ms'));

      await samples.close();
      session.dispose();
    });

    test('sin muestras la etiqueta lo dice en vez de mentir un cero', () {
      expect(CaptureSession(role: CameraRole.left, api: _FakeApi()).clockLabel, 'sin reloj');
    });
  });

  group('grabación', () {
    test('arranca y para el nativo', () async {
      final _FakeApi api = _FakeApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.toggleRecording();
      expect(session.recording, isTrue);
      expect(api.startCalls, 1);

      await session.toggleRecording();
      expect(session.recording, isFalse);
      expect(api.stopCalls, 1);
    });
  });

  group('defaultSettings', () {
    test('son los del ADR 0012, no preferencias', () {
      final CaptureSettings settings = defaultSettings(CameraRole.left);

      expect(settings.width, 3840);
      expect(settings.height, 2160);
      expect(settings.cropToPlayableBand, isTrue);
      // Múltiplo de la frecuencia de red: si no, los focos dan bandas.
      expect(settings.shutterDenominator % 50, 0);
    });
  });
}
