import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

import 'fake_capture_api.dart';

Future<List<int>> _masterPts() async => <int>[0, frame30, 2 * frame30];

void main() {
  group('prepare', () {
    test('sin permiso de cámara se para antes de abrir nada', () async {
      final FakeCaptureApi api = FakeCaptureApi(cameraAccess: false);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.problem, contains('permiso'));
      expect(api.configureCalls, 0);
    });

    test('la red local se pide al preparar y, si la niegan, se dice sin parar nada', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: FakeCaptureApi(localNetwork: false));
      expect(session.localNetworkLabel, 'sin pedir');

      await session.prepare();

      expect(session.localNetworkAllowed, isFalse);
      expect(session.localNetworkLabel, contains('Red local'));
      expect(session.phase, SessionPhase.esperandoReloj);
    });

    test('sin ultra gran angular no hay cámara que valga', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: FakeCaptureApi(ultraWide: false));

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.problem, contains('ultra gran angular'));
      expect(session.canRecord, isFalse);
    });

    test('la estabilización activa invalida el soporte', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(status: fakeStatus(stabilizationDisabled: false)),
      );

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.problem, contains('estabilización'));
    });

    test('la exposición sin bloquear también', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(status: fakeStatus(exposureLocked: false)),
      );

      await session.prepare();

      expect(session.problem, contains('exposición'));
    });

    test('con todo en orden se queda esperando reloj, no lista', () async {
      // Grabar sin reloj común es volver a casa con dos vídeos que no parean.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.prepare();

      expect(api.accessRequests, 1);
      expect(session.phase, SessionPhase.esperandoReloj);
      expect(session.canRecord, isFalse);
    });
  });

  group('etiquetas de la cámara', () {
    test('la exposición se lee como obturación e ISO, no en segundos', () async {
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      expect(session.exposureLabel, 'AUTOMÁTICA');

      await session.prepare();

      expect(session.exposureLabel, 'bloqueada · 1/100 · ISO 320');
      expect(session.whiteBalanceLabel, 'bloqueado · 5400 K');
    });

    test('el código de tiempo avisa en cuanto falla un frame', () async {
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      expect(session.timecodeLabel, 'sin cámara');

      await session.prepare();
      expect(session.timecodeLabel, 'pintado en cada frame');

      session.status!.timecodeFailures = 3;
      expect(session.timecodeLabel, 'FALLA en 3 frames');
    });
  });

  group('cierre', () {
    test('si la pantalla se cierra mientras la cámara mide, prepare termina en silencio',
        () async {
      final FakeCaptureApi api = FakeCaptureApi()..configureGate = Completer<void>();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      final Future<void> preparing = session.prepare();
      session.dispose();
      api.configureGate!.complete();

      await preparing;
      expect(session.phase, SessionPhase.esperandoReloj);
    });
  });

  group('un solo móvil', () {
    test('con la cámara en orden pasa a lista sin esperar reloj', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: FakeCaptureApi(), standalone: true);

      await session.prepare();

      expect(session.phase, SessionPhase.lista);
      expect(session.canRecord, isTrue);
      expect(session.clockLabel, 'sin reloj');
      expect(session.modeLabel, contains('SIN RELOJ'));
    });

    test('lo que invalida la cámara la sigue invalidando', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(status: fakeStatus(stabilizationDisabled: false)),
        standalone: true,
      );

      await session.prepare();

      expect(session.phase, SessionPhase.fallo);
      expect(session.canRecord, isFalse);
    });
  });

  group('avisos del nativo', () {
    test('una interrupción se enseña mientras dura', () {
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());

      session.onInterrupted('motivo 1');
      expect(session.interruption, 'motivo 1');

      session.onResumed();
      expect(session.interruption, isNull);
    });

    test('el cambio térmico se refleja en el estado', () async {
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      await session.prepare();

      session.onThermalStateChanged(ThermalState.serious);

      expect(session.status!.thermalState, ThermalState.serious);
    });

    test('refreshStatus relee el nativo solo cuando ya hay cámara', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.refreshStatus();
      expect(api.statusCalls, 0);

      await session.prepare();
      await session.refreshStatus();
      expect(api.statusCalls, 1);
    });
  });

  group('fase de exposición', () {
    test('una fase buena se acepta sin reiniciar', () async {
      final FakeCaptureApi api = FakeCaptureApi(phases: <int>[2 * nsPerMillisecond]);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 0);
      expect(session.phase, SessionPhase.lista);
    });

    test('una fase mala se reintenta hasta sortear una buena', () async {
      final FakeCaptureApi api = FakeCaptureApi(
        phases: <int>[15 * nsPerMillisecond, 12 * nsPerMillisecond, 1 * nsPerMillisecond],
      );
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 2);
      expect(session.exposurePhaseNs, nsPerMillisecond);
      expect(session.phase, SessionPhase.lista);
    });

    test('agotados los intentos se graba igual', () async {
      final FakeCaptureApi api = FakeCaptureApi(phases: <int>[16 * nsPerMillisecond]);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, exposurePhaseMaxAttempts - 1);
      expect(session.phase, SessionPhase.lista);
    });

    test('la etiqueta traduce la fase a centímetros de balón', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(phases: <int>[5 * nsPerMillisecond]),
      );

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(session.phaseLabel, contains('15 cm'));
    });
  });

  group('reloj del soporte', () {
    test('al haber reloj se empuja el desfase al nativo y se pasa a ajustar fase', () async {
      final FakeCaptureApi api = FakeCaptureApi();
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
      expect(
        CaptureSession(role: CameraRole.left, api: FakeCaptureApi()).clockLabel,
        'sin reloj',
      );
    });
  });

  group('grabación', () {
    test('arranca y para el nativo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.toggleRecording();
      expect(session.recording, isTrue);
      expect(api.startCalls, 1);

      await session.toggleRecording();
      expect(session.recording, isFalse);
      expect(api.stopCalls, 1);
    });

    test('dos toques seguidos son una sola grabación', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      final Future<void> first = session.toggleRecording();
      final Future<void> second = session.toggleRecording();
      await Future.wait(<Future<void>>[first, second]);

      expect(api.startCalls, 1);
      expect(api.stopCalls, 0);
      expect(session.recording, isTrue);
    });

    test('si el nativo no puede grabar, se dice y la cámara sigue lista', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: FakeCaptureApi(failStart: true));

      await session.toggleRecording();

      expect(session.recording, isFalse);
      expect(session.phase, SessionPhase.lista);
      expect(session.problem, contains('disco lleno'));
    });

    test('tras un corte, la pantalla enseña el segmento nuevo que abrió el nativo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);
      await session.prepare();
      await session.toggleRecording();
      expect(session.recordingFileName, 'left-1.mov');

      // El nativo reabrió en otro archivo y lo cuenta en el estado.
      session.status!
        ..recordingFile = 'Documents/left-77-2.mov'
        ..recordingSegment = 2;

      expect(session.recordingFileName, 'left-77-2.mov');
      expect(session.recordingLabel, endsWith('· left-77-2.mov · segmento 2'));
    });

    test('se sabe en qué archivo se graba y cuánto lleva', () async {
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      expect(session.recordingFileName, isNull);

      await session.toggleRecording();

      expect(session.recordingFileName, 'left-1.mov');
      expect(session.recordingLabel, matches(r'^\d\d:\d\d · left-1\.mov$'));
    });
  });

  group('emisión', () {
    test('cada lado publica en su path, con el búfer de Starlink', () {
      final CaptureSession left = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(),
        serverHost: '10.10.18.100',
      );
      final CaptureSession right = CaptureSession(
        role: CameraRole.right,
        api: FakeCaptureApi(),
        serverHost: 'pod.football.ai',
      );

      expect(left.streamUrl, 'srt://10.10.18.100:8890?streamid=publish:izquierda&latency=1000');
      expect(right.streamUrl, 'srt://pod.football.ai:8890?streamid=publish:derecha&latency=1000');
    });

    test('sin servidor no se emite: solo se graba', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      expect(session.streamUrl, '');
      await session.toggleRecording();

      expect(api.lastSrtUrl, '');
      expect(session.streamLabel, contains('sin servidor'));
    });

    test('al grabar se pasa la URL de emisión al nativo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: api, serverHost: '10.0.0.5');

      await session.toggleRecording();

      expect(api.lastSrtUrl, startsWith('srt://10.0.0.5:8890'));
    });

    test('la etiqueta dice en qué está la emisión y avisa cuando va mal', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(status: fakeStatus(streamState: StreamState.streaming)),
        serverHost: '10.0.0.5',
      );
      await session.prepare();
      expect(session.streamLabel, 'EMITIENDO a 10.0.0.5 · 15 Mbit/s');
      expect(session.streamInTrouble, isFalse);

      session.status!
        ..streamState = StreamState.reconnecting
        ..streamDetail = 'se perdió el enlace';
      expect(session.streamLabel, 'RECONECTANDO · se perdió el enlace');
      expect(session.streamInTrouble, isTrue);
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
