/// La API del mando en el maestro (IOS-62): el cliente de verdad (PanelControl) contra el
/// servidor de verdad en el mismo proceso, más las piezas sueltas (puerta, idempotencia,
/// espera larga, 503 a la novena, stream por el relé).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart' show MatchTeam;
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/control_pairing.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/idempotency.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

const int _ahoraS = 1790000000;
const String _pin = '482913';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
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

void main() {
  final List<int> s = utf8.encode('secreto-del-soporte-de-prueba-0123456789');
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine engine;
  late MasterApi api;
  late MasterApiServer server;
  late HttpClient http;

  String qr({Set<String> scopes = const <String>{panelScopeMatch}}) => controlPairingText(
    rigSecret: s,
    matchId: engine.matchId,
    panels: <Uri>[Uri.parse('http://127.0.0.1:${server.port}')],
    nowS: _ahoraS,
    scopes: scopes,
  );

  String token({Set<String> scopes = const <String>{panelScopeMatch}}) =>
      PanelPairing.parse(qr(scopes: scopes))!.token;

  Future<(int, Map<String, Object?>)> pedir(
    String method,
    String route, {
    String? bearer,
    Object? body,
    String? key,
    Map<String, String>? query,
  }) async {
    final HttpClientRequest r = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}/api/v1/$route').replace(queryParameters: query),
    );
    if (bearer != null) {
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (key != null) {
      r.headers.set('Idempotency-Key', key);
    }
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    final HttpClientResponse res = await r.close();
    final String texto = await res.transform(utf8.decoder).join();
    return (res.statusCode, texto.isEmpty ? <String, Object?>{} : jsonDecode(texto) as Map<String, Object?>);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ios62');
    reloj = _Reloj();
    engine = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(3));
    api = MasterApi(
      engine: engine,
      monotonicMs: () => reloj.ms,
      wallS: () => _ahoraS,
      controlSecret: deriveControlSecret(s, engine.matchId),
      operatorPin: _pin,
      longPollTimeout: const Duration(seconds: 2),
      commandTimeout: const Duration(milliseconds: 200),
    );
    server = await MasterApiServer.start(api, address: InternetAddress.loopbackIPv4, port: 0);
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.close();
    dir.deleteSync(recursive: true);
  });

  group('con PanelControl', () {
    late PanelControl control;
    setUp(() {
      control = PanelControl(
        pairing: PanelPairing.parse(qr())!,
        deviceName: 'Móvil de Ana',
        retryWindow: const Duration(milliseconds: 600),
        retryDelay: const Duration(milliseconds: 50),
        reconnectDelay: const Duration(milliseconds: 50),
      );
    });
    tearDown(() => control.dispose());

    test('trae el partido, apunta un gol y ve el de otro mando', () async {
      control.start();
      await _until(() => control.match != null);
      expect(control.match!.scopes, <String>{panelScopeMatch});
      expect((await control.goal(MatchTeam.home, 1)).outcome, CommandOutcome.applied);
      expect(engine.homeGoals, 1);
      engine.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      await _until(() => control.match!.away.goals == 1);
      expect(api.devices().single.name, 'Móvil de Ana');
    });

    test('409 si otro mando se adelantó, con el marcador bueno', () async {
      control.start();
      await _until(() => control.match != null);
      engine.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      // El mando aún cree 0-0 si la espera larga no ha vuelto: se fuerza el choque por HTTP.
      final (int st, Map<String, Object?> j) = await pedir(
        'POST', 'match/goal', bearer: token(), body: <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0},
      );
      expect(st, 409);
      expect(((j['state']! as Map<String, Object?>)['home']! as Map<String, Object?>)['goals'], 1);
      expect(j['type'], 'about:blank');
      expect((j['state']! as Map<String, Object?>)['scopes'], <String>['match']);
    });

    test('sin permiso de emitir: 403 y no se reintenta', () async {
      control.start();
      await _until(() => control.match != null);
      expect((await control.setStreaming(on: true)).outcome, CommandOutcome.forbidden);
    });
  });

  test('un reintento con la misma clave se aplica una vez', () async {
    final Map<String, Object?> gol = <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0};
    final (int a, _) = await pedir('POST', 'match/goal', bearer: token(), body: gol, key: 'k-1');
    final (int b, Map<String, Object?> j) = await pedir('POST', 'match/goal', bearer: token(), body: gol, key: 'k-1');
    expect((a, b), (200, 200));
    expect(engine.homeGoals, 1);
    expect((j['home']! as Map<String, Object?>)['goals'], 1);
    // La misma clave en otra orden es otra orden.
    final (int c, _) = await pedir('POST', 'match/clock', bearer: token(), body: <String, Object?>{'action': 'start'}, key: 'k-1');
    expect(c, 200);
    expect(engine.clock.running, isTrue);
    final (int d, _) = await pedir('POST', 'match/goal', bearer: token(), body: gol, key: 'con espacio');
    expect(d, 400);
  });

  test('la espera larga despierta en ≤100 ms', () async {
    final String since = '${engine.boot}:${engine.rev}';
    final Stopwatch t = Stopwatch();
    final Future<(int, Map<String, Object?>)> espera = pedir('GET', 'match', bearer: token(), query: <String, String>{'since': since});
    await _until(() => api.longPolls == 1);
    t.start();
    engine.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
    final (int st, Map<String, Object?> j) = await espera;
    t.stop();
    expect(st, 200);
    expect(j['rev'], engine.rev);
    expect(t.elapsedMilliseconds, lessThanOrEqualTo(100));
    expect(api.longPolls, 0);
  });

  test('503 a la novena espera; sin since contesta al momento', () async {
    final String since = '${engine.boot}:${engine.rev}';
    final List<Future<(int, Map<String, Object?>)>> esperas = <Future<(int, Map<String, Object?>)>>[
      for (int i = 0; i < apiMaxLongPolls; i++) pedir('GET', 'match', bearer: token(), query: <String, String>{'since': since}),
    ];
    await _until(() => api.longPolls == apiMaxLongPolls);
    final (int novena, Map<String, Object?> j) = await pedir('GET', 'match', bearer: token(), query: <String, String>{'since': since});
    expect(novena, 503);
    expect(j['detail'], contains('sin since'));
    final (int sinSince, _) = await pedir('GET', 'match', bearer: token());
    expect(sinSince, 200);
    engine.apply('match/clock', <String, Object?>{'action': 'start'});
    for (final Future<(int, Map<String, Object?>)> e in esperas) {
      expect((await e).$1, 200);
    }
  });

  group('la puerta', () {
    test('sin token, 401; token de otro partido, 410; caducado, 401', () async {
      expect((await pedir('GET', 'match')).$1, 401);
      final String otro = issueToken(
        deriveControlSecret(s, engine.matchId),
        const ControlClaims(matchId: 'm_otro', scopes: <String>{panelScopeMatch}, expiresS: _ahoraS + 60),
      );
      expect((await pedir('GET', 'match', bearer: otro)).$1, 410);
      final String viejo = issueToken(
        deriveControlSecret(s, engine.matchId),
        ControlClaims(matchId: engine.matchId, scopes: const <String>{panelScopeMatch}, expiresS: _ahoraS),
      );
      final (int st, Map<String, Object?> j) = await pedir('GET', 'match', bearer: viejo);
      expect(st, 401);
      expect(j['detail'], contains('caducado'));
    });

    test('un token con rig no gana rig; el PIN del operador, sí', () async {
      final String conRig = issueToken(
        deriveControlSecret(s, engine.matchId),
        ControlClaims(
          matchId: engine.matchId,
          scopes: const <String>{panelScopeMatch, controlScopeRig},
          expiresS: _ahoraS + 60,
        ),
      );
      expect((await pedir('GET', 'match', bearer: conRig)).$2['scopes'], <String>['match']);
      expect((await pedir('GET', 'match', bearer: _pin)).$2['scopes'], <String>['match', 'rig', 'stream']);
      expect((await pedir('GET', 'match', bearer: '000000')).$1, 401);
    });

    test('ruta desconocida 404, sin JSON 415, JSON roto 400', () async {
      expect((await pedir('GET', 'nada', bearer: token())).$1, 404);
      expect((await pedir('POST', 'match/nada', bearer: token(), body: <String, Object?>{})).$1, 404);
      final HttpClientRequest r = await http.postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/match/goal'));
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token()}');
      r.write('team=home');
      expect((await r.close()).statusCode, 415);
      final HttpClientRequest roto = await http.postUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/match/goal'));
      roto.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${token()}')
        ..contentType = ContentType.json;
      roto.write('{roto');
      final HttpClientResponse res = await roto.close();
      expect(res.statusCode, 400);
      expect(res.headers.contentType!.mimeType, problemContentType);
    });
  });

  group('stream/* por el relé del VPS', () {
    test('sin túnel, 503', () async {
      final (int st, _) = await pedir('POST', 'stream/start', bearer: _pin, body: <String, Object?>{});
      expect(st, 503);
    });

    test('con túnel, espera la respuesta; si no llega, 504', () async {
      final List<String> pedidas = <String>[];
      api.relay = (String accion) async => pedidas.add(accion);
      expect((await pedir('POST', 'stream/start', bearer: _pin, body: <String, Object?>{})).$1, 200);
      expect(pedidas, <String>['start']);
      api.relay = (String accion) => Completer<void>().future;
      expect((await pedir('POST', 'stream/stop', bearer: _pin, body: <String, Object?>{})).$1, 504);
    });
  });

  group('el panel local (IOS-64)', () {
    test('la página sin puerta; miniaturas y estado con token', () async {
      final MasterApi conPanel = MasterApi(
        engine: engine,
        monotonicMs: () => reloj.ms,
        wallS: () => _ahoraS,
        controlSecret: deriveControlSecret(s, engine.matchId),
        panelHtml: '<html>panel</html>',
        thumbnail: (String n) async => n == 'left' ? Uint8List.fromList(<int>[0xFF, 0xD8, 1]) : Uint8List(0),
        rigStatus: () => <String, Object?>{'link': 'connected'},
      );
      ApiRequest get(String path, {bool auth = true}) => ApiRequest(
        method: 'GET',
        path: path,
        headers: <String, String>{if (auth) 'authorization': 'Bearer ${token()}'},
      );
      final ApiResponse pagina = await conPanel.handle(get('/', auth: false));
      expect(pagina.status, 200);
      expect(utf8.decode(pagina.body), contains('panel'));
      expect((await conPanel.handle(get('/api/v1/rig/thumb/left', auth: false))).status, 401);
      final ApiResponse foto = await conPanel.handle(get('/api/v1/rig/thumb/left'));
      expect((foto.status, foto.contentType, foto.body.length), (200, 'image/jpeg', 3));
      expect((await conPanel.handle(get('/api/v1/rig/thumb/right'))).status, 404, reason: 'aún no hay');
      expect((await conPanel.handle(get('/api/v1/rig/thumb/otra'))).status, 404);
      final ApiResponse estado = await conPanel.handle(get('/api/v1/rig/status'));
      expect(jsonDecode(utf8.decode(estado.body)), <String, Object?>{'link': 'connected'});
    });

    test('la página del asset existe y lee el token del fragmento', () {
      final String html = File('assets/panel/index.html').readAsStringSync();
      expect(html, contains("get('mando')"));
      expect(html, contains('/api/v1/rig/thumb/'));
    });
  });

  group('piezas', () {
    test('parseSince y deviceName', () {
      expect(parseSince('b1:7'), ('b1', 7));
      for (final String malo in <String>['', ':7', 'b1:', 'b1:-1', 'b1:x', 'b1']) {
        expect(parseSince(malo), isNull, reason: malo);
      }
      expect(deviceName(Uri.encodeComponent('Móvil\nde Ana')), 'Móvilde Ana');
      expect(deviceName(null), 'sin nombre');
      expect(deviceName('x' * 100), hasLength(apiMaxDeviceNameChars));
    });

    test('la caché de claves caduca y está acotada', () async {
      int ahora = 0;
      int aplicadas = 0;
      final IdempotencyCache c = IdempotencyCache(nowMs: () => ahora, size: 2);
      Future<StoredResponse> r() async => StoredResponse(200, 'x', <int>[++aplicadas]);
      await c.run('a', r);
      await c.run('a', r);
      expect(aplicadas, 1);
      await c.run('b', r);
      await c.run('c', r);
      expect(c.length, 2);
      await c.run('a', r);
      expect(aplicadas, 4, reason: 'a salió por tamaño');
      ahora = apiIdempotencyTtl.inMilliseconds;
      await c.run('c', r);
      expect(aplicadas, 5, reason: 'c caducó');
    });
  });
}
