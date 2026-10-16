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

import 'mp4_fixture.dart';

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

/// El `data` de un mensaje de los dorados del túnel (`tools/nube/protocol.py`, NUBE-05).
Map<String, Object?> _tunnelData(String name) {
  final Map<String, Object?> golden =
      jsonDecode(File('test/golden/tunnel.json').readAsStringSync()) as Map<String, Object?>;
  final Map<String, Object?> caso = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((Map<String, Object?> c) => c['name'] == name);
  final String texto = (caso['inputs']! as Map<String, Object?>)['text']! as String;
  return (jsonDecode(texto) as Map<String, Object?>)['data']! as Map<String, Object?>;
}

/// Un proxy TCP entre el mando y el maestro que tira la vuelta de las primeras
/// [dropPosts] órdenes cuando el maestro ya las ha aplicado: Starlink que corta a mitad.
class _CutProxy {
  _CutProxy._(this._socket, this._target);

  static Future<_CutProxy> start(int target) async {
    final ServerSocket socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final _CutProxy proxy = _CutProxy._(socket, target);
    socket.listen((Socket client) => unawaited(proxy._pipe(client)));
    return proxy;
  }

  final ServerSocket _socket;
  final int _target;
  int dropPosts = 0;

  /// Órdenes que pasaron hacia el maestro, reintentos incluidos.
  int posts = 0;

  int get port => _socket.port;

  Future<void> close() => _socket.close();

  Future<void> _pipe(Socket client) async {
    final Socket maestro = await Socket.connect(InternetAddress.loopbackIPv4, _target);
    bool cortar = false;
    client.listen(
      (Uint8List datos) {
        if (datos.length >= 5 && String.fromCharCodes(datos.sublist(0, 5)) == 'POST ') {
          posts++;
          if (dropPosts > 0) {
            dropPosts--;
            cortar = true;
          }
        }
        maestro.add(datos);
      },
      onDone: maestro.destroy,
      onError: (Object _) => maestro.destroy(),
    );
    maestro.listen(
      (Uint8List datos) {
        if (cortar) {
          client.destroy();
          maestro.destroy();
          return;
        }
        client.add(datos);
      },
      onDone: client.destroy,
      onError: (Object _) => client.destroy(),
    );
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

  String qr({Set<String> scopes = const <String>{panelScopeMatch}, int? port}) => controlPairingText(
    rigSecret: s,
    matchId: engine.matchId,
    panels: <Uri>[Uri.parse('http://127.0.0.1:${port ?? server.port}')],
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

    PanelControl mando(String nombre, {int? port}) {
      final PanelControl m = PanelControl(
        pairing: PanelPairing.parse(qr(port: port))!,
        deviceName: nombre,
        retryWindow: const Duration(milliseconds: 600),
        retryDelay: const Duration(milliseconds: 50),
        reconnectDelay: const Duration(milliseconds: 50),
      );
      addTearDown(m.dispose);
      return m;
    }

    test('aceptación: dos mandos apuntan el mismo gol a la vez; entra uno y el otro, 409', () async {
      final PanelControl luis = mando('Móvil de Luis');
      control.start();
      luis.start();
      await _until(() => control.match != null && luis.match != null);
      // Los dos vieron 0-0: el segundo que llega choca con `expect`.
      final List<CommandResult> r = await Future.wait(<Future<CommandResult>>[
        control.goal(MatchTeam.home, 1),
        luis.goal(MatchTeam.home, 1),
      ]);
      expect(r.map((CommandResult x) => x.outcome).toSet(), <CommandOutcome>{
        CommandOutcome.applied,
        CommandOutcome.conflict,
      });
      expect(engine.homeGoals, 1);
      // El que chocó enseña ya el marcador bueno, el del 409.
      expect((control.match!.home.goals, luis.match!.home.goals), (1, 1));
      expect(api.devices().map((ControlDevice d) => d.name).toSet(), <String>{'Móvil de Ana', 'Móvil de Luis'});
    });

    test('aceptación: la vuelta se pierde tras aplicar; el reintento con la misma clave no suma otro', () async {
      final _CutProxy proxy = await _CutProxy.start(server.port);
      addTearDown(proxy.close);
      final PanelControl cortado = mando('Móvil por Starlink', port: proxy.port);
      cortado.start();
      await _until(() => cortado.match != null);
      proxy.dropPosts = 1;
      expect((await cortado.goal(MatchTeam.home, 1)).outcome, CommandOutcome.applied);
      expect(proxy.posts, 2, reason: 'la primera se aplicó y su vuelta se perdió');
      expect(engine.homeGoals, 1);
      expect(cortado.match!.home.goals, 1);
    });

    test('aceptación: la espera larga de PanelControl despierta en ≤100 ms', () async {
      control.start();
      await _until(() => control.match != null && api.longPolls == 1);
      final Completer<void> visto = Completer<void>();
      final Stopwatch t = Stopwatch();
      control.addListener(() {
        if (!visto.isCompleted && control.match!.away.goals == 1) {
          t.stop();
          visto.complete();
        }
      });
      t.start();
      engine.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      await visto.future.timeout(const Duration(seconds: 2));
      expect(t.elapsedMilliseconds, lessThanOrEqualTo(100));
    });

    test('aceptación: el noveno mando recibe 503 y sigue con el partido sin since', () async {
      final List<PanelControl> ocho = <PanelControl>[
        for (int i = 0; i < apiMaxLongPolls; i++) mando('Mando $i')..start(),
      ];
      await _until(() => api.longPolls == apiMaxLongPolls);
      final PanelControl noveno = mando('Mando 8');
      final List<String> problemas = <String>[];
      noveno.addListener(() {
        final String? p = noveno.problem;
        if (p != null) {
          problemas.add(p);
        }
      });
      noveno.start();
      await _until(() => problemas.any((String p) => p.contains('sin since')));
      expect(noveno.match, isNotNull);
      engine.apply('match/clock', <String, Object?>{'action': 'start'});
      await _until(() => <PanelControl>[...ocho, noveno].every((PanelControl m) => m.match!.clockRunning));
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

  group('por el túnel (el command de IOS-65)', () {
    Map<String, Object?> gol(String bearer, {String? key}) => <String, Object?>{
      'method': 'POST',
      'path': '/api/v1/match/goal',
      // Sin content-type a propósito: el cuerpo de un command ya es JSON.
      'headers': <String, Object?>{
        'authorization': 'Bearer $bearer',
        'idempotency-key': ?key,
        'x-zero-device': 'ipad-banda',
      },
      'principal': 'bearer',
      'body': <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0},
    };

    test('el panel remoto (principal operator) entra sin Authorization con los tres ámbitos', () async {
      final CommandReply r = await api.command(ApiRequest.fromCommand(_tunnelData('valido_command_del_panel')));
      expect(r.response.status, 200);
      expect(r.state, isNull, reason: 'un GET no sube rev');
      final Map<String, Object?> dorado = _tunnelData('valido_response_del_maestro');
      expect(r.responseData.keys, dorado.keys);
      expect(r.responseData['headers'], dorado['headers']);
      expect((r.responseData['body']! as Map<String, Object?>)['scopes'], <String>['match', 'rig', 'stream']);
      expect(api.devices(), isEmpty, reason: 'el panel remoto sin nombre no es un mando');
    });

    test('una orden que sube rev trae el state, sin scopes, para mandarlo antes que la respuesta', () async {
      final CommandReply r = await api.command(ApiRequest.fromCommand(gol(token(), key: 'k-tunel')));
      expect(r.response.status, 200);
      final Map<String, Object?> body = r.responseData['body']! as Map<String, Object?>;
      expect(r.state!['rev'], body['rev']);
      expect(body['scopes'], <String>['match']);
      // El state del dorado: el DTO sin scopes (un state con scopes es bad_field).
      expect(r.state!.keys.toSet(), _tunnelData('valido_state').keys.toSet());
      expect(api.devices().single.name, 'ipad-banda');

      // El reintento con la misma clave, por el túnel o por la LAN: lo mismo, sin state.
      final CommandReply otra = await api.command(ApiRequest.fromCommand(gol(token(), key: 'k-tunel')));
      expect(otra.state, isNull);
      expect(otra.responseData, r.responseData);
      final (int lan, Map<String, Object?> j) = await pedir(
        'POST', 'match/goal', bearer: token(), body: gol(token())['body'], key: 'k-tunel',
      );
      expect((lan, j['rev']), (200, body['rev']));
      expect(engine.homeGoals, 1);

      // 409: no sube rev, así que no hay state; el partido bueno va en el problema.
      final CommandReply choque = await api.command(ApiRequest.fromCommand(gol(token())));
      expect(choque.state, isNull);
      expect(choque.response.status, 409);
      expect(choque.responseData['headers'], <String, String>{'content-type': problemContentType});
      final Map<String, Object?> problema = choque.responseData['body']! as Map<String, Object?>;
      expect(((problema['state']! as Map<String, Object?>)['home']! as Map<String, Object?>)['goals'], 1);
    });

    test('un command nunca espera: el since no se atiende', () async {
      final CommandReply r = await api
          .command(ApiRequest.fromCommand(<String, Object?>{
            'method': 'GET',
            'path': '/api/v1/match',
            'query': 'since=${Uri.encodeQueryComponent('${engine.boot}:${engine.rev}')}',
            'headers': <String, Object?>{'authorization': 'Bearer ${token()}'},
            'principal': 'bearer',
            'body': null,
          }))
          .timeout(const Duration(milliseconds: 500));
      expect(r.response.status, 200);
      expect(api.longPolls, 0);
    });

    test('ni stream/* ni las miniaturas; el token del dorado no abre', () async {
      ApiRequest operador(String method, String path) => ApiRequest.fromCommand(<String, Object?>{
        'method': method,
        'path': path,
        'headers': <String, Object?>{},
        'principal': 'operator',
        'body': method == 'POST' ? <String, Object?>{} : null,
      });
      api.relay = (String accion) async => fail('stream/* lo atiende el VPS');
      expect((await api.command(operador('POST', '/api/v1/stream/start'))).response.status, 404);
      expect((await api.command(operador('GET', '/api/v1/rig/thumb/left'))).response.status, 404);
      // Por la LAN no hay principal: sin Authorization, 401 aunque sea el mismo GET.
      expect((await pedir('GET', 'match')).$1, 401);
      final CommandReply ajeno = await api.command(ApiRequest.fromCommand(_tunnelData('valido_command_del_mando')));
      expect(ajeno.response.status, 401);
      expect(engine.homeGoals, 0);
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

  group('del mando: equipos, entretiempo, franja e icono (ADR 0027)', () {
    const String once = '1 Dida\n2 Cafu\n3 Maldini\n4 Gattuso\n13 Nesta\n21 Pirlo\n8 Seedorf\n'
        '22 Kaka\n10 Rui Costa\n7 Shevchenko\n11 Gilardino\n';
    // Un PNG de verdad para el olfato: la firma y un trozo cualquiera detrás.
    final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List<int>.filled(200, 7)];

    Future<(int, Map<String, Object?>)> subir(List<int> bytes, {String? bearer, String tipo = 'image/png'}) async {
      final HttpClientRequest r = await http.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/$championshipAssetRoute'),
      );
      if (bearer != null) {
        r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      r.headers.contentType = ContentType.parse(tipo);
      r.contentLength = bytes.length; // como el navegador al subir un fichero
      r.add(bytes);
      final HttpClientResponse res = await r.close();
      final String texto = await res.transform(utf8.decoder).join();
      return (res.statusCode, texto.isEmpty ? <String, Object?>{} : jsonDecode(texto) as Map<String, Object?>);
    }

    test('los nombres de los equipos', () async {
      final (int ok, Map<String, Object?> partido) = await pedir(
        'POST',
        'match/teams',
        bearer: token(),
        body: <String, Object?>{'home': ' Santa Cruz ', 'away': 'San Cristóbal'},
      );
      expect(ok, 200);
      expect((partido['home']! as Map<String, Object?>)['name'], 'Santa Cruz');
      expect((partido['away']! as Map<String, Object?>)['name'], 'San Cristóbal');
      for (final Map<String, Object?> malo in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'home': '   '},
        <String, Object?>{'away': 'x' * (matchTeamNameMaxChars + 1)},
        <String, Object?>{'home': 'dos\nlineas'},
      ]) {
        expect((await pedir('POST', 'match/teams', bearer: token(), body: malo)).$1, 400, reason: '$malo');
      }
      expect(engine.home, 'Santa Cruz');
    });

    test('el entretiempo y la alineación se quitan el sitio', () async {
      engine.saveLineup(MatchTeam.home, 'Milan', '4-4-2', once);
      await pedir('POST', 'match/lineup', bearer: token(), body: <String, Object?>{'team': 'home', 'on_air': true});
      final (int ok, Map<String, Object?> descanso) =
          await pedir('POST', 'graphics/halftime', bearer: token(), body: <String, Object?>{'on_air': true});
      expect(ok, 200);
      expect((descanso['halftime_on_air'], descanso['lineup_on_air']), (true, null));
      final (_, Map<String, Object?> alin) =
          await pedir('POST', 'match/lineup', bearer: token(), body: <String, Object?>{'team': 'home', 'on_air': true});
      expect((alin['halftime_on_air'], alin['lineup_on_air']), (false, 'home'));
      expect((await pedir('POST', 'graphics/halftime', bearer: token(), body: <String, Object?>{'on_air': 'si'})).$1, 400);
    });

    test('la franja sale 15 s y se va sola', () async {
      final (_, Map<String, Object?> fuera) =
          await pedir('POST', 'graphics/strip', bearer: token(), body: <String, Object?>{});
      expect(fuera['strip_remaining_ms'], stripShowDefaultS * 1000);
      reloj.ms += 10000;
      expect(engine.stripVisible, isTrue);
      expect(engine.toJson()['strip_remaining_ms'], 5000);
      reloj.ms += 6000;
      expect(engine.stripVisible, isFalse);
      expect(engine.toJson()['strip_remaining_ms'], 0);
      await pedir('POST', 'graphics/strip', bearer: token(), body: <String, Object?>{'show_s': 30});
      final (_, Map<String, Object?> oculta) =
          await pedir('POST', 'graphics/strip', bearer: token(), body: <String, Object?>{'show_s': 0});
      expect(oculta['strip_remaining_ms'], 0);
      expect((await pedir('POST', 'graphics/strip', bearer: token(), body: <String, Object?>{'show_s': 500})).$1, 400);
    });

    test('los textos de la franja se guardan y sobreviven al partido', () async {
      final Map<String, Object?> textos = <String, Object?>{
        'claim': <String>['VAMOS', 'GALÁPAGOS'],
        'slots': <List<String>>[
          <String>['FARMACIA ISLA', 'ABIERTO 24 HORAS'],
          <String>['', ''],
          <String>['RADIO MAR', '99.1 FM'],
        ],
      };
      final (int ok, Map<String, Object?> partido) =
          await pedir('POST', 'graphics/strip_texts', bearer: token(), body: textos);
      expect(ok, 200);
      expect(partido['strip_texts'], textos);
      final MatchEngine otro =
          MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, matchId: 'm_otro');
      expect(otro.toJson()['strip_texts'], textos, reason: 'del campeonato, no del partido');
      final Map<String, Object?> largo = <String, Object?>{
        ...textos,
        'claim': <String>['x' * 40, 'B'],
      };
      expect((await pedir('POST', 'graphics/strip_texts', bearer: token(), body: largo)).$1, 400);
      expect(
        (await pedir('POST', 'graphics/strip_texts', bearer: token(), body: <String, Object?>{'claim': 'no'})).$1,
        400,
      );
    });

    test('el icono del campeonato: subirlo, verlo y quitarlo', () async {
      expect((await subir(png)).$1, 401, reason: 'sin token no se lee ni un byte');
      expect(engine.graphics.hasIcon, isFalse);
      final (int ok, Map<String, Object?> partido) = await subir(png, bearer: token());
      expect(ok, 200);
      expect(partido['championship_icon'], 1);

      final HttpClientRequest r =
          await http.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/$championshipAssetRoute'));
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token()}');
      final HttpClientResponse res = await r.close();
      expect((res.statusCode, res.headers.contentType?.mimeType), (200, 'image/png'));
      expect(await res.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b)), png);

      expect((await subir(utf8.encode('<svg/>'), bearer: token(), tipo: 'image/svg+xml')).$1, 415);
      expect((await subir(List<int>.filled(championshipIconMaxBytes + 1, 0), bearer: token())).$1, 413);
      expect(engine.graphics.iconRev, 1, reason: 'lo que no vale no toca el que había');
      expect(engine.graphics.uploadFile.existsSync(), isFalse);

      final (int quitado, Map<String, Object?> sin) = await pedir('DELETE', championshipAssetRoute, bearer: token());
      expect((quitado, sin['championship_icon']), (200, null));
      expect((await pedir('GET', championshipAssetRoute, bearer: token())).$1, 404);
    });
  });

  group('los escudos de los equipos (ADR 0028)', () {
    // Un PNG de verdad para el olfato: la firma y un trozo cualquiera detrás.
    final List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List<int>.filled(120, 3)];

    Future<int> subir(String lado, List<int> bytes, {String? bearer}) async {
      final HttpClientRequest r = await http.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/$teamCrestAssetRoute/$lado'),
      );
      if (bearer != null) {
        r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      r.headers.contentType = ContentType.parse('image/png');
      r.contentLength = bytes.length;
      r.add(bytes);
      final HttpClientResponse res = await r.close();
      await res.drain<void>();
      return res.statusCode;
    }

    Object? escudo(Map<String, Object?> partido, String lado) => (partido[lado]! as Map<String, Object?>)['crest'];

    test('subirlo, verlo y quitarlo, y que vaya con el nombre del equipo', () async {
      await pedir('POST', 'match/teams', bearer: token(), body: <String, Object?>{'home': 'Bellavista', 'away': 'Progreso'});
      expect(await subir('home', png), 401, reason: 'sin token no se lee ni un byte');
      expect(await subir('home', png, bearer: token()), 200);
      expect(await subir('away', utf8.encode('<svg/>'), bearer: token()), 415);
      expect(await subir('away', List<int>.filled(teamCrestMaxBytes + 1, 0), bearer: token()), 413);
      expect(await subir('centro', png, bearer: token()), 405, reason: 'solo home y away');

      Map<String, Object?> partido = engine.toJson();
      final Object? version = escudo(partido, 'home');
      expect(version, isA<int>());
      expect(escudo(partido, 'away'), isNull);
      final HttpClientRequest r =
          await http.getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/$teamCrestAssetRoute/home'));
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token()}');
      final HttpClientResponse res = await r.close();
      expect((res.statusCode, res.headers.contentType?.mimeType), (200, 'image/png'));
      expect(await res.fold<List<int>>(<int>[], (List<int> a, List<int> b) => a..addAll(b)), png);
      expect((await pedir('GET', '$teamCrestAssetRoute/away', bearer: token())).$1, 404);

      // Va con el equipo: si Bellavista juega de visitante, su escudo va con él…
      await pedir('POST', 'match/teams', bearer: token(), body: <String, Object?>{'home': 'Progreso', 'away': ' bellavista '});
      partido = engine.toJson();
      expect((escudo(partido, 'home'), escudo(partido, 'away')), (null, version));
      // …y sobrevive al partido, como el icono del campeonato.
      final MatchEngine otro = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, matchId: 'm_otro');
      expect(otro.graphics.crestFor('BELLAVISTA'), isNotNull);

      final (int quitado, Map<String, Object?> sin) = await pedir('DELETE', '$teamCrestAssetRoute/away', bearer: token());
      expect((quitado, escudo(sin, 'away')), (200, null));
      expect(engine.graphics.crestUploadFile.existsSync(), isFalse);
    });
  });

  group('los vídeos del mando (ADR 0027)', () {
    Future<(int, Map<String, Object?>)> subir(String nombre, List<int> bytes, {String? bearer}) async {
      final HttpClientRequest r = await http.openUrl(
        'PUT',
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/$videosRoute/${Uri.encodeComponent(nombre)}'),
      );
      if (bearer != null) {
        r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      r.headers.contentType = ContentType.parse('video/mp4');
      r.contentLength = bytes.length;
      r.add(bytes);
      final HttpClientResponse res = await r.close();
      final String texto = await res.transform(utf8.decoder).join();
      return (res.statusCode, texto.isEmpty ? <String, Object?>{} : jsonDecode(texto) as Map<String, Object?>);
    }

    List<Object?> lista(Map<String, Object?> json) => json['videos']! as List<Object?>;

    test('subir, listar, pasar, parar y borrar', () async {
      final List<int> mp4 = fakeMp4(durationMs: 20000);
      expect((await subir('anuncio.mp4', mp4)).$1, 401, reason: 'sin token no se lee ni un byte');
      final (int ok, Map<String, Object?> info) = await subir('Gol de Kaká.mp4', mp4, bearer: token());
      expect(ok, 200);
      expect(info, <String, Object?>{'name': 'Gol de Kaká.mp4', 'bytes': mp4.length, 'duration_ms': 20000});
      expect((await subir('falso.mp4', utf8.encode('hola'), bearer: token())).$1, 415);
      expect((await subir('..mp4', mp4, bearer: token())).$1, 400);

      final (int listado, Map<String, Object?> videos) = await pedir('GET', videosRoute, bearer: token());
      expect((listado, lista(videos).length), (200, 1));

      final (int suena, Map<String, Object?> partido) =
          await pedir('POST', 'video/play', bearer: token(), body: <String, Object?>{'name': 'Gol de Kaká.mp4'});
      expect(suena, 200);
      expect(partido['video'], <String, Object?>{'name': 'Gol de Kaká.mp4', 'remaining_ms': 20000});
      reloj.ms += videoStartLeadMs + 5000;
      expect((engine.toJson()['video']! as Map<String, Object?>)['remaining_ms'], 15000);
      expect((await subir('Gol de Kaká.mp4', mp4, bearer: token())).$1, 409, reason: 'no se cambia el que suena');
      expect((await pedir('DELETE', '$videosRoute/Gol%20de%20Kak%C3%A1.mp4', bearer: token())).$1, 409);

      final (_, Map<String, Object?> parado) = await pedir('POST', 'video/stop', bearer: token(), body: <String, Object?>{});
      expect(parado['video'], isNull);
      final (int borrado, _) = await pedir('DELETE', '$videosRoute/Gol%20de%20Kak%C3%A1.mp4', bearer: token());
      expect(borrado, 200);
      expect(lista((await pedir('GET', videosRoute, bearer: token())).$2), isEmpty);
      expect((await pedir('POST', 'video/play', bearer: token(), body: <String, Object?>{'name': 'Gol de Kaká.mp4'})).$1, 404);
    });

    test('al acabar vuelve el programa: con el aviso o, si no llega, con el margen', () async {
      await subir('a.mp4', fakeMp4(durationMs: 4000), bearer: token());
      await pedir('POST', 'video/play', bearer: token(), body: <String, Object?>{'name': 'a.mp4'});
      final int primero = engine.video!.id;
      await pedir('POST', 'video/play', bearer: token(), body: <String, Object?>{'name': 'a.mp4'});
      final int segundo = engine.video!.id;
      expect(segundo, isNot(primero), reason: 'volver a pasarlo es otra reproducción');
      final int antes = engine.rev;
      engine.videoFinished(primero);
      expect((engine.video?.id, engine.rev), (segundo, antes), reason: 'el aviso de la vieja no quita la nueva');
      engine.videoFinished(segundo);
      expect(engine.video, isNull);
      expect(engine.rev, antes + 1);

      await pedir('POST', 'video/play', bearer: token(), body: <String, Object?>{'name': 'a.mp4'});
      reloj.ms += videoStartLeadMs + 4000 + videoEndGraceMs;
      expect(engine.video, isNotNull);
      reloj.ms += 1;
      expect(engine.video, isNull, reason: 'sin aviso, el margen lo da por acabado');
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
