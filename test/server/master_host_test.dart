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

  test('un partido guardado ilegible se aparta y el mando arranca igual (no muere en cada arranque)', () async {
    // Un nombre vacío o un número negativo hacían que MatchEngine.open lanzara y el mando
    // no arrancara nunca: ni matando la app, porque el fichero sigue ahí.
    for (final String roto in <String>[
      '{"version": 1, "match_id": "m_viejo", "home": "", "away": "B", "home_goals": 0, "away_goals": 0,'
          ' "clock_ms": 0, "clock_running": false, "started_rig_ms": null, "clock_domain": "d"}',
      '{"version": 1, "match_id": "m_viejo", "home": "A", "away": "B", "home_goals": -1, "away_goals": 0,'
          ' "clock_ms": 0, "clock_running": false, "started_rig_ms": null, "clock_domain": "d"}',
      '{roto',
    ]) {
      File('${dir.path}/$matchFileName').writeAsStringSync(roto);
      await host.becomeMaster(null);
      expect(host.serving, isTrue, reason: roto);
      expect(host.problem, contains('se empezó uno nuevo'), reason: roto);
      expect(await host.pairingText(), isNotNull, reason: roto);
      final List<String> apartados = dir
          .listSync()
          .map((FileSystemEntity e) => e.path.split('/').last)
          .where((String n) => n.startsWith('$matchFileName.$unreadableMatchSuffix-'))
          .toList();
      expect(apartados, isNotEmpty, reason: 'se guarda el roto para mirarlo');
      await host.stepDown();
      for (final FileSystemEntity e in dir.listSync()) {
        e.deleteSync(recursive: true);
      }
    }
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

  test('sin secreto sirve igual, sin QR: lo dice y da el panel para el PIN', () async {
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
    final MandoPairing p = await sinS.pairing();
    expect(p.reason, mandoReasonNoSecret);
    expect(p.manual.single.toString(), 'http://192.168.7.20:${sinS.boundPort}');
    await sinS.stepDown();
  });

  test('sin IPv4 propia: «sin red local» y no «sin secreto», aunque el otro móvil tenga dirección', () async {
    final MasterHost sinRed = MasterHost(
      directory: dir,
      controlSecret: (String id) async => ascii.decode(deriveControlSecret(s, id)),
      announceMatch: (_) async {},
      // El otro móvil sí tiene dirección, pero no sirve el mando mientras no haya relevo.
      peerAddress: () async => '172.20.10.3',
      operatorPin: () async => '',
      addresses: () async => <String>[],
      port: 0,
    );
    await sinRed.becomeMaster('m_x');
    final MandoPairing p = await sinRed.pairing();
    expect(p.text, isNull);
    expect(p.reason, mandoReasonNoLan);
    expect(p.manual, isEmpty);
    await sinRed.stepDown();
  });

  test('sin servir: el motivo; y si no arrancó, el problema tal cual', () async {
    expect((await host.pairing()).reason, mandoReasonNotServing);
    // El puerto ocupado (otro servidor, una pantalla anterior): no arranca.
    final ServerSocket ocupado = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final MasterHost h = MasterHost(
      directory: dir,
      controlSecret: (String id) async => ascii.decode(deriveControlSecret(s, id)),
      announceMatch: api.setMatchId,
      peerAddress: () async => '',
      operatorPin: () async => '',
      addresses: () async => <String>['192.168.7.20'],
      wallS: () => _ahoraS,
      port: ocupado.port,
    );
    await h.becomeMaster(null);
    expect(h.serving, isFalse);
    expect(h.problem, startsWith('$mandoFailedPrefix: '));
    expect(h.canPair, isFalse);
    final MandoPairing p = await h.pairing();
    expect(p.text, isNull);
    expect(p.reason, h.problem);
    final String anunciado = api.announcedMatchId!;

    // «REINTENTAR MANDO» con el puerto libre: sirve el mismo partido, sin anunciar otro.
    await ocupado.close();
    api.announcedMatchId = null;
    await h.retry();
    expect(h.serving, isTrue);
    expect(h.problem, isNull);
    expect(h.engine!.matchId, anunciado);
    expect(api.announcedMatchId, isNull);
    expect((await h.pairing()).text, isNotNull);

    // Ya sirviendo, reintentar no reabre nada; de esclavo, tampoco arranca.
    final int? puerto = h.boundPort;
    await h.retry();
    expect(h.boundPort, puerto);
    await h.stepDown();
    await h.retry();
    expect(h.serving, isFalse);
    expect(h.problem, isNull);
  });

  test('el estado del mando sale hacia el latido al servir y al dejarlo', () async {
    final List<Map<String, Object?>> estados = <Map<String, Object?>>[];
    final MasterHost h = MasterHost(
      directory: dir,
      controlSecret: (String id) async => ascii.decode(deriveControlSecret(s, id)),
      announceMatch: (_) async {},
      peerAddress: () async => '',
      operatorPin: () async => '',
      addresses: () async => <String>['172.20.10.1'],
      port: 0,
      reportState: (String json) async => estados.add(jsonDecode(json) as Map<String, Object?>),
    );
    await h.becomeMaster('m_latido');
    await pumpEventQueue();
    expect(estados.last, <String, Object?>{
      'serving': true,
      'port': h.boundPort,
      'match_id': 'm_latido',
      'addresses': <Object?>['172.20.10.1'],
      'can_pair': true,
      'problem': null,
    });
    await h.stepDown();
    await pumpEventQueue();
    expect(estados.last['serving'], isFalse);
    expect(estados.last['addresses'], isEmpty);
  });

  group('lanAddressesOf', () {
    test('el punto de acceso (bridge100) cuenta, detrás de la Wi-Fi; los datos móviles no', () {
      final List<NetworkInterface> red = <NetworkInterface>[
        _Interfaz('pdp_ip0', <String>['10.120.4.7']),
        _Interfaz('bridge100', <String>['172.20.10.1']),
        _Interfaz('lo0', <String>['127.0.0.1']),
        _Interfaz('en0', <String>['192.168.1.34']),
        _Interfaz('awdl0', <String>['169.254.3.9']),
      ];
      expect(lanAddressesOf(red), <String>['192.168.1.34', '172.20.10.1']);
    });

    test('el móvil que comparte datos: en0 sin IPv4, solo el puente', () {
      expect(
        lanAddressesOf(<NetworkInterface>[
          _Interfaz('en0', <String>[]),
          _Interfaz('pdp_ip0', <String>['10.120.4.7']),
          _Interfaz('bridge100', <String>['172.20.10.1']),
        ]),
        <String>['172.20.10.1'],
      );
    });

    test('el orden: en (Wi-Fi y hub), bridge y ap; sin link-local ni IPv6', () {
      expect(
        lanAddressesOf(<NetworkInterface>[
          _Interfaz('ap1', <String>['172.20.10.2']),
          _Interfaz('en2', <String>['192.168.50.2', '169.254.7.7']),
          _Interfaz('bridge100', <String>['172.20.10.1', 'fe80::1']),
          _Interfaz('en0', <String>['192.168.1.34']),
        ]),
        <String>['192.168.1.34', '192.168.50.2', '172.20.10.1', '172.20.10.2'],
      );
    });
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

/// Una interfaz de red de mentira, con el nombre que da iOS y sus direcciones.
class _Interfaz implements NetworkInterface {
  _Interfaz(this.name, List<String> ips) : addresses = <InternetAddress>[for (final String ip in ips) InternetAddress(ip)];

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
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
