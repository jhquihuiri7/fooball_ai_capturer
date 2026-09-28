import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/calibration_upload.dart';
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
          CaptureSession(role: CameraRole.right, api: FakeCaptureApi(localNetwork: false));
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

    test('el derecho, con todo en orden, abre el enlace y espera reloj: no está listo', () async {
      // Grabar sin reloj común es volver a casa con dos vídeos que no parean.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.right, api: api);

      await session.prepare();

      expect(api.accessRequests, 1);
      expect(api.startLinkCalls, 1);
      expect(api.linkRole, CameraRole.right);
      expect(session.phase, SessionPhase.esperandoReloj);
      expect(session.canRecord, isFalse);
    });

    test('el izquierdo es el maestro del reloj: queda listo sin esperar a nadie', () async {
      // Su hora es la del soporte por definición. Si el derecho no llega nunca, media
      // cancha es mejor que ninguna.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.prepare();

      expect(api.linkRole, CameraRole.left);
      expect(session.phase, SessionPhase.lista);
      expect(session.clockLabel, contains('maestro'));
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
      final CaptureSession session = CaptureSession(role: CameraRole.right, api: api);

      final Future<void> preparing = session.prepare();
      session.dispose();
      api.configureGate!.complete();

      await preparing;
      // Y sin abrir el enlace: abierto después de cerrar la pantalla, nadie lo cerraba.
      expect(api.startLinkCalls, 0);
      expect(api.stopLinkCalls, 0);
    });

    test('se cierra el enlace aunque el aviso de su estado no haya llegado', () async {
      // `linkState` llega por un aviso del nativo. Si la pantalla se cerraba antes, el
      // enlace se quedaba abierto (bug 2 del 22-09).
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);
      await session.prepare();
      expect(session.linkState, LinkState.off);

      session.dispose();

      expect(api.stopLinkCalls, 1);
    });

    test('la pantalla vieja no cierra el enlace que ya abrió la nueva', () async {
      // Volver atrás e invertir los lados: la nueva abre su enlace antes de que se libere
      // la vieja. Cerrarlo entonces dejaba a la nueva sin enlace hasta reiniciar la app.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession vieja = CaptureSession(role: CameraRole.left, api: api);
      await vieja.prepare();
      final CaptureSession nueva = CaptureSession(role: CameraRole.right, api: api);
      await nueva.prepare();

      vieja.dispose();
      expect(api.stopLinkCalls, 0);

      nueva.dispose();
      expect(api.stopLinkCalls, 1);
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
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api, phaseSettle: Duration.zero);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 0);
      expect(session.phase, SessionPhase.lista);
    });

    test('una fase mala se reintenta hasta sortear una buena', () async {
      final FakeCaptureApi api = FakeCaptureApi(
        phases: <int>[15 * nsPerMillisecond, 12 * nsPerMillisecond, 1 * nsPerMillisecond],
      );
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api, phaseSettle: Duration.zero);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, 2);
      expect(session.exposurePhaseNs, nsPerMillisecond);
      expect(session.phase, SessionPhase.lista);
    });

    test('agotados los intentos se graba igual', () async {
      final FakeCaptureApi api = FakeCaptureApi(phases: <int>[16 * nsPerMillisecond]);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api, phaseSettle: Duration.zero);

      await session.sortExposurePhase(masterPtsNs: _masterPts, frameIntervalNs: frame30);

      expect(api.restarts, exposurePhaseMaxAttempts - 1);
      expect(session.phase, SessionPhase.lista);
    });

    test('la etiqueta traduce la fase a centímetros de balón', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(phases: <int>[5 * nsPerMillisecond]),
        phaseSettle: Duration.zero,
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
        autoSortPhase: false,
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

    test('los sellos del enlace dan reloj, y con reloj el derecho mide la fase solo', () async {
      final FakeCaptureApi api = FakeCaptureApi(phases: <int>[2 * nsPerMillisecond]);
      final CaptureSession session =
          CaptureSession(role: CameraRole.right, api: api, phaseSettle: Duration.zero);
      await session.prepare();
      session.onLinkStateChanged(LinkState.connected, 'iPhone (izquierda)');
      expect(session.linkLabel, 'conectado con iPhone (izquierda)');

      // El maestro va 7 ms por delante y la ida y vuelta son 2 ms.
      for (int i = 0; i < 4; i++) {
        final int t1 = i * nsPerSecond;
        final int t2 = t1 + 8 * nsPerMillisecond;
        session.onClockStamps(t1, t2, t2, t1 + 2 * nsPerMillisecond);
      }
      await pumpEventQueue();

      expect(api.offsets.last, 7 * nsPerMillisecond);
      expect(session.clockLabel, contains('7.0 ms ±1.0'));
      expect(session.exposurePhaseNs, 2 * nsPerMillisecond);
      expect(session.phase, SessionPhase.lista);
    });

    test('si el maestro no contesta con sus PTS, se graba igual con la fase sin medir', () async {
      final FakeCaptureApi api = FakeCaptureApi()..masterPts = <int>[];
      final CaptureSession session =
          CaptureSession(role: CameraRole.right, api: api, phaseSettle: Duration.zero);
      await session.prepare();

      for (int i = 0; i < 4; i++) {
        final int t1 = i * nsPerSecond;
        session.onClockStamps(t1, t1 + nsPerMillisecond, t1 + nsPerMillisecond, t1 + 2 * nsPerMillisecond);
      }
      await pumpEventQueue();

      expect(api.restarts, 0);
      expect(session.phaseLabel, 'sin medir');
      expect(session.phase, SessionPhase.lista);
    });

    test('al cerrar la pantalla se cierra el enlace', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);
      await session.prepare();
      session.onLinkStateChanged(LinkState.searching, '');

      session.dispose();

      expect(api.stopLinkCalls, 1);
    });

    test('sin muestras la etiqueta lo dice en vez de mentir un cero', () {
      expect(
        CaptureSession(role: CameraRole.right, api: FakeCaptureApi()).clockLabel,
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

    test('parar y volver a grabar, sin cerrar la app', () async {
      // Pasaba en los dos móviles el 27-09: PARAR apagaba la camara entera y el siguiente
      // GRABAR se quedaba esperando frames que ya no llegaban. Habia que cerrar la app.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.toggleRecording();
      await session.toggleRecording();
      await session.toggleRecording();

      expect(session.recording, isTrue);
      expect(api.startCalls, 2);
      // Parar no suelta la camara: eso es lo que rompia la segunda grabacion.
      expect(api.releaseCalls, 0);
    });

    test('la cámara se suelta al salir de la pantalla, no al parar', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);
      await session.toggleRecording();
      await session.toggleRecording();
      expect(api.releaseCalls, 0);

      session.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(api.releaseCalls, 1);
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
      await session.toggleRecording(save: true);
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

      await session.toggleRecording(save: true);

      expect(session.recordingFileName, 'left-1.mov');
      expect(session.recordingLabel, matches(r'^\d\d:\d\d · left-1\.mov$'));
    });

    test('emitir sin guardar no deja fichero en el móvil', () async {
      // Lo de siempre: un partido son ~40 GB por móvil y llenaba el teléfono en dos.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: api);

      await session.toggleRecording();

      expect(session.recording, isTrue, reason: 'emite igual');
      expect(api.lastSaveVideo, isFalse);
      expect(session.recordingFileName, isNull, reason: 'pero no graba');
    });

    test('el interruptor de guardar manda también en el otro móvil', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: api, serverHost: '10.0.0.5');
      session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');

      session.setSaveVideo(true);
      await session.toggleRecording();

      expect(api.lastSaveVideo, isTrue);
      expect(api.peerCommands, contains(RigCommand.recordAndSave));

      // Y el derecho obedece: guarda solo si se lo dicen.
      final FakeCaptureApi apiDer = FakeCaptureApi();
      final CaptureSession derecho = CaptureSession(role: CameraRole.right, api: apiDer);
      derecho.onPeerCommand(RigCommand.record);
      await Future<void>.delayed(Duration.zero);
      expect(apiDer.lastSaveVideo, isFalse);
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

      expect(left.streamUrl, 'srt://10.10.18.100:8890?streamid=publish:rig/izquierda&latency=1000');
      expect(right.streamUrl, 'srt://pod.football.ai:8890?streamid=publish:rig/derecha&latency=1000');
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

    test('el izquierdo pone a grabar al derecho, y a parar', () async {
      // En la cancha, poner a grabar los dos a mano es donde se queda uno sin grabar.
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: api, serverHost: '10.0.0.5');
      session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');

      await session.toggleRecording();
      expect(api.peerCommands, <RigCommand>[RigCommand.record]);

      await session.toggleRecording();
      expect(api.peerCommands, <RigCommand>[RigCommand.record, RigCommand.stop]);
    });

    test('sin enlace no se manda nada: quien está solo graba solo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: api, serverHost: '10.0.0.5');

      await session.toggleRecording();

      expect(session.recording, isTrue);
      expect(api.peerCommands, isEmpty);
    });

    test('el derecho nunca manda: dos móviles mandándose serían un bucle', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.right, api: api, serverHost: '10.0.0.5');
      session.onLinkStateChanged(LinkState.connected, 'iPhone (izquierda)');

      await session.toggleRecording();

      expect(api.peerCommands, isEmpty);
    });

    test('el derecho obedece la orden del izquierdo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session =
          CaptureSession(role: CameraRole.right, api: api, serverHost: '10.0.0.5');
      session.onLinkStateChanged(LinkState.connected, 'iPhone (izquierda)');

      session.onPeerCommand(RigCommand.record);
      await Future<void>.delayed(Duration.zero);
      expect(session.recording, isTrue);

      // Repetir la orden no abre una segunda grabación.
      session.onPeerCommand(RigCommand.record);
      await Future<void>.delayed(Duration.zero);
      expect(session.recording, isTrue);

      session.onPeerCommand(RigCommand.stop);
      await Future<void>.delayed(Duration.zero);
      expect(session.recording, isFalse);
    });

    test('CALIBRAR: graba en los dos, sube, avisa del resultado y arranca la emisión',
        () async {
      // El flujo entero de un toque, tal como se pidió: antes eran cuatro pasos a mano y
      // salían grabaciones de 1 GB que tardaban hora y media (medido el 27-09).
      final FakeCaptureApi api = FakeCaptureApi();
      final _FakeUploader panel = _FakeUploader(calibrating: true)
        ..result = const CalibrationResult(
          attempt: 4,
          ok: true,
          message: 'calibrado con 60 de 147 puntos',
          hint: '',
        );
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: api,
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
        uploader: (Uri uri, CameraRole rol, ({String user, String password})? creds) => panel,
      );
      await session.prepare();
      session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
      expect(session.canCalibrate, isTrue);

      await session.calibrateNow();

      // Mandó calibrar al derecho, subió, y el soporte quedó calibrado...
      expect(api.peerCommands.first, RigCommand.calibrate);
      expect(panel.file, isNotNull);
      expect(session.calibrationResult?.ok, isTrue);
      expect(session.calibrationResultLabel, startsWith('CALIBRADO'));
      // ...así que arrancó la emisión, en los dos.
      expect(session.recording, isTrue);
      expect(api.peerCommands, contains(RigCommand.record));
    });

    test('si no calibra, se dice por qué y no se arranca a emitir', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final _FakeUploader panel = _FakeUploader(calibrating: true)
        ..result = const CalibrationResult(
          attempt: 2,
          ok: false,
          message: 'solo 28 de 76 emparejamientos son coherentes con una rotacion',
          hint: 'apunta a algo lejano, a mas de diez metros',
        );
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: api,
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
        uploader: (Uri uri, CameraRole rol, ({String user, String password})? creds) => panel,
      );
      await session.prepare();
      session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');

      await session.calibrateNow();

      expect(session.calibrationResultLabel, startsWith('NO CALIBRÓ'));
      expect(session.calibrationResultLabel, contains('diez metros'));
      expect(session.recording, isFalse, reason: 'sin soporte bueno no se emite');
    });

    test('el clip dura lo que dice la constante, y para solo', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: api,
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
        uploader: (Uri uri, CameraRole rol, ({String user, String password})? creds) =>
            _FakeUploader(),
      );
      await session.prepare();
      session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');

      await fakeAsync((FakeAsync async) {
        unawaited(session.calibrateNow());
        async.flushMicrotasks();
        expect(session.recording, isTrue);

        async.elapse(const Duration(seconds: 9));
        expect(session.recording, isTrue, reason: 'antes de los diez segundos sigue');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(session.recording, isFalse, reason: 'para sola a los diez segundos');
      });
    });

    test('el derecho, al recibir calibrate, graba su clip sin que nadie lo toque', () {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = CaptureSession(
        role: CameraRole.right,
        api: api,
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
      );
      session.onLinkStateChanged(LinkState.connected, 'iPhone (izquierda)');

      fakeAsync((FakeAsync async) {
        session.onPeerCommand(RigCommand.calibrate);
        async.flushMicrotasks();
        expect(session.recording, isTrue);

        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(session.recording, isFalse);
        // Y el derecho nunca manda ordenes, ni siquiera haciendo su clip.
        expect(api.peerCommands, isEmpty);
      });
    });

    test('solo el izquierdo ofrece calibrar', () async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession derecho = CaptureSession(
        role: CameraRole.right,
        api: api,
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
      );
      await derecho.prepare();
      expect(derecho.canCalibrate, isFalse);

      // Y con un solo movil no hay soporte que calibrar.
      final CaptureSession solo = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(),
        serverHost: 'rtmp://rig:c@1.2.3.4:1935?panel=http://1.2.3.4:8090',
        standalone: true,
      );
      await solo.prepare();
      expect(solo.canCalibrate, isFalse);
    });

    test('la etiqueta dice en qué está la emisión y avisa cuando va mal', () async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(status: fakeStatus(streamState: StreamState.streaming)),
        serverHost: '10.0.0.5',
      );
      await session.prepare();
      expect(session.streamLabel, 'EMITIENDO por SRT a 10.0.0.5 · 15 Mbit/s');
      expect(session.streamInTrouble, isFalse);

      session.status!
        ..streamState = StreamState.reconnecting
        ..streamDetail = 'se perdió el enlace';
      expect(session.streamLabel, 'RECONECTANDO · se perdió el enlace');
      expect(session.streamInTrouble, isTrue);
    });

    test('la etiqueta enseña el bitrate real cuando la red obligó a bajarlo', () async {
      // Medido contra un pod: 2 Mbit/s de subida con 15 codificados llegaban con minutos
      // de retraso. El nativo baja el bitrate y la pantalla tiene que decir a cuánto va.
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(
          status: fakeStatus(streamState: StreamState.streaming, streamBitrateBps: 6200000),
        ),
        serverHost: 'rtmp://rig:clave@47.47.180.47:33185',
      );
      await session.prepare();
      expect(session.streamLabel, 'EMITIENDO por RTMP a 47.47.180.47 · 6.2 Mbit/s');
      expect(CaptureSession.formatMbps(15000000), '15');
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

  group('subir la grabación para calibrar', () {
    const String qr = 'rtmp://camara:clave@1.2.3.4:17377?panel=https://abc-8090.proxy.runpod.net';

    Future<CaptureSession> grabada({
      required _FakeUploader subida,
      String server = qr,
      bool standalone = false,
    }) async {
      final CaptureSession session = CaptureSession(
        role: CameraRole.left,
        api: FakeCaptureApi(),
        serverHost: server,
        standalone: standalone,
        uploader: (Uri panel, CameraRole role, ({String user, String password})? credentials) =>
            subida..seen = (panel: panel, role: role, credentials: credentials),
      );
      await session.prepare();
      await session.toggleRecording(save: true);
      await session.toggleRecording(); // grabar y parar: ya hay fichero
      return session;
    }

    test('sin grabación no hay nada que subir', () async {
      final CaptureSession session =
          CaptureSession(role: CameraRole.left, api: FakeCaptureApi(), serverHost: qr);
      await session.prepare();

      expect(session.canUploadForCalibration, isFalse);
    });

    test('grabando no se sube: el fichero todavía está abierto', () async {
      final CaptureSession session = await grabada(subida: _FakeUploader());
      await session.toggleRecording();

      expect(session.recording, isTrue);
      expect(session.canUploadForCalibration, isFalse);
    });

    test('sube la última grabación al panel del QR, con las credenciales de las cámaras', () async {
      final _FakeUploader subida = _FakeUploader(calibrating: true);
      final CaptureSession session = await grabada(subida: subida);
      expect(session.canUploadForCalibration, isTrue);

      await session.uploadForCalibration();

      expect(subida.seen!.panel, Uri.parse('https://abc-8090.proxy.runpod.net'));
      expect(subida.seen!.credentials, (user: 'camara', password: 'clave'));
      expect(subida.file!.path, endsWith('left-1.mov'));
      expect(session.calibrationUpload, CalibrationUpload.subida);
      expect(session.calibrationUploadLabel, 'SUBIDA · EL SERVIDOR CALIBRA');
    });

    test('si falta la del otro móvil lo dice', () async {
      final CaptureSession session = await grabada(subida: _FakeUploader());

      await session.uploadForCalibration();

      expect(session.calibrationUploadLabel, 'SUBIDA · FALTA LA DEL OTRO MÓVIL');
    });

    test('mientras sube enseña cuánto lleva', () async {
      final _FakeUploader subida = _FakeUploader(progress: <int>[4 * 1048576])
        ..gate = Completer<void>();
      final CaptureSession session = await grabada(subida: subida);

      final Future<void> subiendo = session.uploadForCalibration();
      await pumpEventQueue();

      expect(session.calibrationUploadLabel, 'SUBIENDO 4 / 8 MB');
      expect(session.canUploadForCalibration, isFalse); // no se lanza dos veces
      subida.gate!.complete();
      await subiendo;
    });

    test('si falla, dice por qué y deja reintentar', () async {
      final CaptureSession session = await grabada(subida: _FakeUploader(error: 'la red no deja'));

      await session.uploadForCalibration();

      expect(session.calibrationUpload, CalibrationUpload.fallo);
      expect(session.uploadProblem, 'la red no deja');
      expect(session.calibrationUploadLabel, 'NO SE SUBIÓ · REINTENTAR');
      expect(session.canUploadForCalibration, isTrue);
    });

    test('con un solo móvil no hay soporte que calibrar', () async {
      final CaptureSession session = await grabada(subida: _FakeUploader(), standalone: true);

      expect(session.canUploadForCalibration, isFalse);
    });

    test('sin servidor no hay a dónde subir', () async {
      final CaptureSession session = await grabada(subida: _FakeUploader(), server: '');

      expect(session.canUploadForCalibration, isFalse);
    });
  });
}

/// Un subidor que no sube: dice lo que le pidieron y contesta lo que toca.
class _FakeUploader extends CalibrationUploader {
  _FakeUploader({this.calibrating = false, this.error, this.progress = const <int>[]})
      : super(panel: Uri.parse('http://nadie'), role: CameraRole.left);

  final bool calibrating;
  final String? error;
  final List<int> progress;

  /// Lo que el panel contesta cuando se le pregunta cómo fue. `null` = no contestó a
  /// tiempo, que es distinto de «falló».
  CalibrationResult? result;
  int attempts = 0;
  Completer<void>? gate;
  ({Uri panel, CameraRole role, ({String user, String password})? credentials})? seen;
  File? file;

  @override
  Future<bool> upload(File file, {void Function(int sent, int total)? onProgress}) async {
    this.file = file;
    for (final int sent in progress) {
      onProgress?.call(sent, 8 * 1048576);
    }
    await gate?.future;
    if (error != null) {
      throw CalibrationUploadException(error!);
    }
    return calibrating;
  }

  @override
  Future<int> lastAttempt() async => attempts;

  @override
  Future<CalibrationResult?> waitForResult({
    required int previousAttempt,
    Duration timeout = calibrationResultTimeout,
    Duration pollDelay = calibrationPollDelay,
  }) async =>
      result;
}
