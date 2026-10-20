/// EMITIR sin tocar la pantalla (`AUTO_EMITIR`): el camino automático llama a lo mismo
/// que los toques, en el mismo orden; el esclavo no emite solo; PARAR a los s segundos; y
/// sin los defines, nada cambia.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/main.dart';
import 'package:football_ai_capture/src/auto_emitir.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';

import 'fake_capture_api.dart';
import 'fake_rig_api.dart';

/// Las dos API falsas apuntan cada llamada en una sola lista, para mirar el orden.
class _OrderedApi extends FakeCaptureApi {
  _OrderedApi(this.calls);
  final List<String> calls;

  @override
  Future<void> startLink(CameraRole role, bool prefersMaster, LinkMode mode) {
    calls.add('startLink ${role.name} dirige=$prefersMaster ${mode.name}');
    return super.startLink(role, prefersMaster, mode);
  }

  @override
  Future<String> start(String srtUrl, String recordingDirectory, bool saveVideo) {
    calls.add('start url="$srtUrl" 4k=$saveVideo');
    return super.start(srtUrl, recordingDirectory, saveVideo);
  }

  @override
  Future<void> stop() {
    calls.add('stop');
    return super.stop();
  }

  @override
  Future<void> sendPeerCommand(RigCommand command) {
    calls.add('peer ${command.name}');
    return super.sendPeerCommand(command);
  }
}

class _OrderedRig extends FakeRigApi {
  _OrderedRig(this.calls, {super.startProblem});
  final List<String> calls;

  @override
  Future<String> startProgram(ProgramResolution resolution) {
    calls.add('startProgram');
    return super.startProgram(resolution);
  }

  @override
  Future<void> stopProgram() {
    calls.add('stopProgram');
    return super.stopProgram();
  }
}

CaptureSession _session(FakeCaptureApi api, FakeRigApi rig, CameraRole role) => CaptureSession(
  role: role,
  api: api,
  rigApi: rig,
  linkMode: LinkMode.aware,
  phaseSettle: Duration.zero,
);

const Duration _settle = Duration(seconds: 20);

void main() {
  group('el maestro', () {
    test('llama a lo mismo que los toques, en orden, y PARAR a los s segundos', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final List<String> log = <String>[];
        final CaptureSession session = _session(_OrderedApi(calls), _OrderedRig(calls), CameraRole.left);
        final AutoEmitir auto = AutoEmitir(
          session: session,
          config: const AutoEmitirConfig(stopAfter: Duration(seconds: 90)),
          log: log.add,
        )..start();
        // «Abrir cámara»: la pantalla llama a prepare al montarse.
        session.prepare();
        async.flushMicrotasks();
        expect(session.phase, SessionPhase.lista);
        expect(calls, <String>['startLink left dirige=true aware']);

        // Sin enlace no se emite, aunque la cámara esté lista.
        async.elapse(const Duration(minutes: 1));
        expect(calls, hasLength(1));

        session.onRigRole(RigRole.master, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
        expect(auto.step, AutoEmitirStep.asentando);
        async.elapse(_settle - const Duration(seconds: 1));
        expect(calls, hasLength(1), reason: 'se deja al esclavo su reloj y su fase');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(calls, <String>[
          'startLink left dirige=true aware',
          'start url="" 4k=false',
          'startProgram',
          'peer record',
        ]);
        expect(session.recording, isTrue);
        expect(auto.step, AutoEmitirStep.emitiendo);

        async.elapse(const Duration(seconds: 89));
        expect(session.recording, isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(calls.skip(4), <String>['stopProgram', 'stop', 'peer stop']);
        expect(session.recording, isFalse);
        expect(auto.step, AutoEmitirStep.parado);
        expect(log.where((String l) => l.contains('EMITIR')), isNotEmpty);
        expect(log.last, contains('parado'));
        auto.dispose();
      });
    });

    test('con AUTO_EMITIR_4K, «Guardar vídeo» encendido; sin AUTO_EMITIR_S no para solo', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final CaptureSession session = _session(_OrderedApi(calls), _OrderedRig(calls), CameraRole.left);
        final AutoEmitir auto = AutoEmitir(
          session: session,
          config: const AutoEmitirConfig(save4k: true),
          log: (_) {},
        )..start();
        session.prepare();
        session.onRigRole(RigRole.master, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
        async.elapse(_settle);
        expect(calls, containsAllInOrder(<String>['start url="" 4k=true', 'startProgram', 'peer recordAndSave']));
        async.elapse(const Duration(hours: 2));
        expect(session.recording, isTrue);
        expect(calls, isNot(contains('stopProgram')));
        auto.dispose();
      });
    });

    test('sin LISTA en el tope no emite y dice por qué', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final List<String> log = <String>[];
        final CaptureSession session = _session(_OrderedApi(calls), _OrderedRig(calls), CameraRole.left);
        final AutoEmitir auto = AutoEmitir(session: session, config: const AutoEmitirConfig(), log: log.add)
          ..start();
        session.prepare();
        async.elapse(autoEmitirReadyTimeout);
        expect(auto.step, AutoEmitirStep.sinLista);
        expect(log.last, contains('sin LISTA'));
        expect(log.last, contains('enlace off'));
        // Si el enlace sube después, ya no se emite: la pasada se da por fallida.
        session.onRigRole(RigRole.master, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
        async.elapse(_settle * 2);
        expect(calls, isNot(contains('startProgram')));
        auto.dispose();
      });
    });

    test('si el programa no arranca, lo dice y no ordena nada', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final List<String> log = <String>[];
        final CaptureSession session =
            _session(_OrderedApi(calls), _OrderedRig(calls, startProblem: 'sin detector'), CameraRole.left);
        final AutoEmitir auto = AutoEmitir(session: session, config: const AutoEmitirConfig(), log: log.add)
          ..start();
        session.prepare();
        session.onRigRole(RigRole.master, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
        async.elapse(_settle);
        expect(auto.step, AutoEmitirStep.fallo);
        expect(log.last, contains('sin detector'));
        expect(calls.where((String c) => c.startsWith('peer')), isEmpty);
        auto.dispose();
      });
    });
  });

  group('«Una cámara (sin pareja)», AUTO_LINK=single', () {
    test('el derecho solo emite en cuanto está LISTA, sin enlace ni espera, y PARA a los s', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final List<String> log = <String>[];
        final CaptureSession session = CaptureSession(
          role: CameraRole.right,
          api: _OrderedApi(calls),
          rigApi: _OrderedRig(calls),
          linkMode: LinkMode.single,
          prefersMaster: false,
          phaseSettle: Duration.zero,
        );
        final AutoEmitir auto = AutoEmitir(
          session: session,
          config: const AutoEmitirConfig(stopAfter: Duration(seconds: 60), save4k: true),
          log: log.add,
        )..start();
        session.prepare();
        async.flushMicrotasks();
        // El nativo dice «sin enlace» y que este dirige: nada más hace falta.
        session.onLinkStateChanged(LinkState.off, '');
        session.onRigRole(RigRole.master, 0, null);
        async.flushMicrotasks();
        expect(calls, <String>[
          'startLink right dirige=true single',
          'start url="" 4k=true',
          'startProgram',
        ], reason: 'sin los 20 s del esclavo y sin orden a nadie');
        expect(auto.step, AutoEmitirStep.emitiendo);
        expect(log.where((String l) => l.contains('una cámara')), isNotEmpty);

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(calls.skip(3), <String>['stopProgram', 'stop']);
        expect(auto.step, AutoEmitirStep.parado);
        auto.dispose();
      });
    });

    test('autoEmitirShell con single: dirige del lado que sea', () {
      for (final String lado in <String>['left', 'right']) {
        final ZeroShell shell =
            autoEmitirShell(role: lado, link: 'single', save4k: false, stopAfterS: 0, prefersMaster: 'false');
        expect(shell.linkMode, LinkMode.single);
        expect(shell.prefersMaster, isTrue);
      }
    });
  });

  group('el esclavo', () {
    test('no emite solo: arranca y para por la orden del maestro', () {
      fakeAsync((FakeAsync async) {
        final List<String> calls = <String>[];
        final List<String> log = <String>[];
        final CaptureSession session = CaptureSession(
          role: CameraRole.right,
          api: _OrderedApi(calls),
          rigApi: _OrderedRig(calls),
          linkMode: LinkMode.aware,
          prefersMaster: false,
          phaseSettle: Duration.zero,
        );
        final AutoEmitir auto = AutoEmitir(
          session: session,
          config: const AutoEmitirConfig(stopAfter: Duration(seconds: 30)),
          log: log.add,
        )..start();
        session.prepare();
        session.onRigRole(RigRole.slave, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (izquierda)');
        session.onClockEstimate(0, 0, 8, 1000);
        async.elapse(const Duration(minutes: 10));
        expect(auto.step, AutoEmitirStep.esclavo);
        expect(calls, <String>['startLink right dirige=false aware']);

        session.onPeerCommand(RigCommand.record);
        async.flushMicrotasks();
        expect(calls.skip(1), <String>['start url="" 4k=false', 'startProgram']);
        async.elapse(const Duration(minutes: 5));
        expect(session.recording, isTrue, reason: 'su PARAR es la orden del maestro');

        session.onPeerCommand(RigCommand.stop);
        async.flushMicrotasks();
        expect(session.recording, isFalse);
        expect(log.where((String l) => l.contains('esclavo')), isNotEmpty);
        auto.dispose();
      });
    });
  });

  group('la pantalla', () {
    testWidgets('con autoEmitir, la de captura emite sola; sin él, nunca', (WidgetTester tester) async {
      Future<FakeRigApi> monta(AutoEmitirConfig? auto) async {
        final FakeRigApi rig = FakeRigApi();
        final CaptureSession session = CaptureSession(
          role: CameraRole.left,
          api: FakeCaptureApi(),
          rigApi: rig,
          linkMode: LinkMode.aware,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CapturePage(
                role: CameraRole.left,
                session: session,
                linkMode: LinkMode.aware,
                autoEmitir: auto,
              ),
            ),
          ),
        );
        await tester.pump();
        session.onRigRole(RigRole.master, 1, null);
        session.onLinkStateChanged(LinkState.connected, 'iPhone (derecha)');
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        return rig;
      }

      expect((await monta(null)).startCalls, 0);
      expect((await monta(const AutoEmitirConfig(slaveSettle: Duration.zero))).startCalls, 1);
    });

    test('autoEmitirShell: el izquierdo dirige, aware por defecto, nunca Multipeer', () {
      final ZeroShell izq = autoEmitirShell(role: 'left', link: '', save4k: false, stopAfterS: 0);
      expect(izq.role, CameraRole.left);
      expect(izq.prefersMaster, isTrue);
      expect(izq.linkMode, LinkMode.aware);
      expect(izq.autoEmitir!.stopAfter, isNull);
      expect(izq.serverHost, '');

      final ZeroShell der = autoEmitirShell(role: 'right', link: 'wifi', save4k: true, stopAfterS: 3600);
      expect(der.role, CameraRole.right);
      expect(der.prefersMaster, isFalse);
      expect(der.linkMode, LinkMode.wifi);
      expect(der.autoEmitir!.save4k, isTrue);
      expect(der.autoEmitir!.stopAfter, const Duration(seconds: 3600));

      expect(autoEmitirShell(role: 'left', link: 'multipeer', save4k: false, stopAfterS: 0).linkMode,
          LinkMode.aware);
    });

    testWidgets('sin los defines, la app abre el tipo de evento y el fútbol, la pantalla de lado', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(CaptureApp(api: FakeCaptureApi()));
      await tester.pump();
      expect(find.byType(EventPage), findsOneWidget);
      expect(find.byType(RolePage), findsNothing);
      await tester.tap(find.text('FÚTBOL'));
      await tester.pumpAndSettle();
      expect(find.byType(RolePage), findsOneWidget);
      expect(find.byType(CapturePage), findsNothing);
    });
  });
}
