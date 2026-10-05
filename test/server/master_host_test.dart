/// El maestro como servidor del mando (IOS-62/63): arranca al dirigir, firma el QR con el
/// secreto que deriva el nativo y cierra al dejar de dirigir.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/master_host.dart';

import '../fake_capture_api.dart';

const int _ahoraS = 1790000000;

void main() {
  final List<int> s = utf8.encode('secreto-del-soporte-de-prueba-0123456789');
  late Directory dir;
  late FakeCaptureApi api;
  late MasterHost host;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ios62h');
    api = FakeCaptureApi()..peerAddress = '192.168.7.21';
    host = MasterHost(
      directory: dir,
      // El nativo deriva con S; aquí, lo mismo en Dart.
      controlSecret: (String id) async => ascii.decode(deriveControlSecret(s, id)),
      announceMatch: api.setMatchId,
      peerAddress: api.linkPeerAddress,
      operatorPin: api.loadOperatorPin,
      addresses: () async => <String>['192.168.7.20'],
      wallS: () => _ahoraS,
      port: 0,
    );
  });
  tearDown(() async {
    await host.stepDown();
    dir.deleteSync(recursive: true);
  });

  test('sin partido del enlace, empieza uno y lo anuncia', () async {
    await host.becomeMaster(null);
    expect(host.serving, isTrue);
    expect(api.announcedMatchId, host.engine!.matchId);
    expect(File('${dir.path}/$matchFileName').existsSync(), isTrue);
  });

  test('el QR lleva este móvil, el otro y un token que verifica el otro móvil', () async {
    await host.becomeMaster('m_rig_1');
    final PanelPairing p = PanelPairing.parse((await host.pairingText(stream: true))!)!;
    expect(p.panel.host, '192.168.7.20');
    expect(p.panel.port, host.boundPort);
    expect(p.alternates.single.toString(), 'http://192.168.7.21:$masterApiPort');
    final ControlClaims c = verifyToken(
      deriveControlSecret(s, 'm_rig_1'), p.token, matchId: 'm_rig_1', nowS: _ahoraS,
    );
    expect(c.scopes, <String>{panelScopeMatch, panelScopeStream});
    expect(api.announcedMatchId, isNull, reason: 'el partido ya venía del enlace');
  });

  test('otro partido del enlace aparta el guardado; dejar de dirigir cierra', () async {
    await host.becomeMaster('m_a');
    host.engine!.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
    await host.becomeMaster('m_a');
    expect(host.engine!.homeGoals, 1, reason: 'el mismo partido no se reabre');
    await host.becomeMaster('m_b');
    expect(host.engine!.matchId, 'm_b');
    expect(host.engine!.homeGoals, 0);
    expect(File('${dir.path}/match-m_a.json').existsSync(), isTrue);
    await host.stepDown();
    expect(host.serving, isFalse);
    expect(await host.pairingText(), isNull);
  });

  test('sin secreto del soporte sirve igual, pero sin QR', () async {
    final MasterHost sinS = MasterHost(
      directory: dir,
      controlSecret: (_) async => '',
      announceMatch: (_) async {},
      peerAddress: () async => '',
      operatorPin: () async => '123456',
      addresses: () async => <String>['192.168.7.20'],
      port: 0,
    );
    await sinS.becomeMaster('m_x');
    expect(sinS.serving, isTrue);
    expect(sinS.canPair, isFalse);
    expect(await sinS.pairingText(), isNull);
    await sinS.stepDown();
  });

  test('CaptureSession lo arranca al dirigir y lo para al pasar a esclavo', () async {
    final CaptureSession session = CaptureSession(role: CameraRole.right, api: api, masterHost: host);
    session.onRigRole(RigRole.master, 1, 'm_s');
    await _until(() => host.serving);
    expect(host.engine!.matchId, 'm_s');
    session.onRigRole(RigRole.slave, 2, 'm_s');
    await _until(() => !host.serving);
  });
}

Future<void> _until(bool Function() condition) async {
  final Stopwatch waited = Stopwatch()..start();
  while (!condition()) {
    if (waited.elapsed > const Duration(seconds: 5)) {
      fail('no llegó a tiempo');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
