/// El mando contra un panel de mentira en el propio test (ADR 0017 de football-ai).
///
/// El panel falso habla lo mismo que `/api/v1/` en `tools/live_panel.py`: espera larga con
/// `since`, órdenes con `expect` e `Idempotency-Key`, errores RFC 7807. Lo que se prueba es
/// lo que pasa en la banda: otro mando que se adelanta, Starlink que corta a mitad de una
/// orden, un panel que se reinicia o un QR de otro partido.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';

const String _token = 'eyJtIjoibV8xIn0.firma';

/// Un panel mínimo con el partido de un solo marcador y un reloj.
class _FakePanel {
  _FakePanel._(this._server);

  static Future<_FakePanel> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakePanel panel = _FakePanel._(server);
    server.listen(panel._handle);
    return panel;
  }

  final HttpServer _server;

  int rev = 0;
  int home = 1;
  int away = 0;
  int clockMs = 0;
  bool clockRunning = false;
  Set<String> scopes = <String>{'match'};

  /// Órdenes aplicadas de verdad, reintentos aparte.
  int applied = 0;

  /// Cuántas respuestas a órdenes se cortan a propósito después de aplicarlas.
  int dropNext = 0;

  /// Si está puesto, todo se contesta con este error.
  int? forceStatus;

  /// Un partido viejo que la siguiente espera larga devuelve, como si se hubiera cruzado.
  Map<String, Object?>? _stale;

  /// Si ese partido viejo ya salió hacia el mando.
  bool staleServed = false;

  /// El nombre con el que se presentó el último mando.
  String? lastDevice;

  final Map<String, (int, Map<String, Object?>)> _answered =
      <String, (int, Map<String, Object?>)>{};
  final List<Completer<void>> _waiting = <Completer<void>>[];

  PanelPairing get pairing =>
      PanelPairing.parse('http://127.0.0.1:${_server.port}/#mando=$_token')!;

  Future<void> close() => _server.close(force: true);

  Map<String, Object?> dto() => <String, Object?>{
    'match_id': 'm_prueba',
    'boot': 'b1',
    'rev': rev,
    'home': <String, Object?>{
      'name': 'BELLAVISTA',
      'goals': home,
      'formation': null,
      'players': 0,
    },
    'away': <String, Object?>{
      'name': 'PROGRESO',
      'goals': away,
      'formation': null,
      'players': 0,
    },
    'clock_ms': clockMs,
    'clock_running': clockRunning,
    'clock_restored': false,
    'lineup_on_air': null,
    'streaming': false,
    'can_stream': true,
    'formations': <String>['4-4-2'],
    'save_error': null,
    'scopes': scopes.toList(),
  };

  /// Otro mando, o el operador en la web, apunta un gol.
  void goalElsewhere({bool tell = true}) {
    home++;
    rev++;
    if (tell) {
      _wakeAll();
    }
  }

  void replyStale(Map<String, Object?> old) {
    _stale = old;
    _wakeAll();
  }

  void _wakeAll() {
    for (final Completer<void> waiting in List<Completer<void>>.of(_waiting)) {
      if (!waiting.isCompleted) {
        waiting.complete();
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final String text = await utf8.decoder.bind(request).join();
    lastDevice = Uri.decodeComponent(
      request.headers.value('X-Zero-Device') ?? '',
    );
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $_token') {
      return _problem(request, HttpStatus.unauthorized, 'token no valido');
    }
    final int? forced = forceStatus;
    if (forced != null) {
      return _problem(request, forced, 'forzado $forced');
    }
    final String route = request.uri.path.replaceFirst('/api/v1/', '');
    if (request.method == 'GET' && route == 'match') {
      if (request.uri.queryParameters['since'] == 'b1:$rev') {
        final Completer<void> change = Completer<void>();
        _waiting.add(change);
        await change.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        _waiting.remove(change);
      }
      final Map<String, Object?>? stale = _stale;
      _stale = null;
      staleServed = staleServed || stale != null;
      return _json(request, HttpStatus.ok, stale ?? dto());
    }
    final String key = request.headers.value('Idempotency-Key') ?? '';
    final (int, Map<String, Object?>)? done = _answered[key];
    if (done != null) {
      return _json(request, done.$1, done.$2);
    }
    final Map<String, Object?> body = jsonDecode(text) as Map<String, Object?>;
    final (int, Map<String, Object?>) answer = _apply(route, body);
    _answered[key] = answer;
    if (answer.$1 == HttpStatus.ok && dropNext > 0) {
      dropNext--;
      // Aplicada y sin respuesta: el mando no sabe si llegó.
      await request.response.detachSocket().then((Socket s) => s.destroy());
      return;
    }
    return _json(request, answer.$1, answer.$2);
  }

  (int, Map<String, Object?>) _apply(String route, Map<String, Object?> body) {
    switch (route) {
      case 'match/goal':
        final int goals = body['team'] == 'home' ? home : away;
        if (body['expect'] != goals) {
          return (
            HttpStatus.conflict,
            <String, Object?>{
              'status': 409,
              'detail': 'ya tiene $goals',
              'state': dto(),
            },
          );
        }
        if (body['team'] == 'home') {
          home += body['delta']! as int;
        } else {
          away += body['delta']! as int;
        }
      case 'match/clock':
        clockRunning = body['action'] == 'start';
      case 'stream/start':
        if (!scopes.contains('stream')) {
          return (
            HttpStatus.forbidden,
            <String, Object?>{
              'status': 403,
              'detail': 'este mando no tiene permiso de stream',
            },
          );
        }
      default:
        return (HttpStatus.notFound, <String, Object?>{'status': 404});
    }
    applied++;
    rev++;
    _wakeAll();
    return (HttpStatus.ok, dto());
  }

  Future<void> _problem(HttpRequest request, int status, String detail) =>
      _json(request, status, <String, Object?>{
        'status': status,
        'detail': detail,
      });

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }
}

/// Espera a que se cumpla algo que llega por la red, sin dormir de más.
Future<void> _until(bool Function() condition) async {
  final Stopwatch waited = Stopwatch()..start();
  while (!condition()) {
    if (waited.elapsed > const Duration(seconds: 5)) {
      fail('no llegó a tiempo');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late _FakePanel panel;
  late PanelControl control;

  PanelControl mando({PanelPairing? pairing}) => PanelControl(
    pairing: pairing ?? panel.pairing,
    deviceName: 'Móvil de Ana',
    retryWindow: const Duration(milliseconds: 600),
    retryDelay: const Duration(milliseconds: 50),
    reconnectDelay: const Duration(milliseconds: 50),
  );

  setUp(() async {
    panel = await _FakePanel.start();
    control = mando();
  });

  tearDown(() async {
    control.dispose();
    await panel.close();
  });

  Future<void> conectado() async {
    control.start();
    await _until(() => control.match != null);
  }

  test('al arrancar trae el partido y se presenta con su nombre', () async {
    await conectado();

    expect(control.link, PanelLink.online);
    expect(control.match!.home.goals, 1);
    expect(panel.lastDevice, 'Móvil de Ana');
  });

  test('se entera de un gol que apunta otro mando sin pedir nada', () async {
    await conectado();

    panel.goalElsewhere();

    await _until(() => control.match!.home.goals == 2);
  });

  test('un gol aplicado deja el partido de la respuesta', () async {
    await conectado();

    final CommandResult result = await control.goal(MatchTeam.home, 1);

    expect(result.applied, isTrue);
    expect(control.match!.home.goals, 2);
    expect(panel.applied, 1);
  });

  test(
    'si otro mando se adelantó, es un conflicto con el marcador bueno',
    () async {
      await conectado();
      panel.goalElsewhere(tell: false); // este móvil aún ve 1-0

      final CommandResult result = await control.goal(MatchTeam.home, 1);

      expect(result.outcome, CommandOutcome.conflict);
      expect(control.match!.home.goals, 2);
      expect(panel.home, 2); // no 3
    },
  );

  test('un corte tras aplicar: el reintento no suma otro gol', () async {
    await conectado();
    panel.dropNext = 1;

    final CommandResult result = await control.goal(MatchTeam.home, 1);

    expect(result.applied, isTrue);
    expect(panel.applied, 1);
    expect(panel.home, 2);
  });

  test('sin panel, la orden se da por perdida y no se queda en cola', () async {
    await conectado();
    await panel.close();

    final CommandResult result = await control.startClock();

    expect(result.outcome, CommandOutcome.unreachable);
  });

  test('sin panel, el enlace lo dice y cuenta el silencio', () async {
    await conectado();
    await panel.close();
    panel.goalElsewhere(); // suelta la espera larga abierta

    await _until(() => control.link == PanelLink.offline);
    expect(control.problem, isNotNull);
    expect(control.silence, greaterThan(Duration.zero));
  });

  test('un QR de otro partido corta el enlace y lo dice', () async {
    panel.forceStatus = HttpStatus.gone;

    control.start();

    await _until(() => control.link == PanelLink.ended);
    expect(control.problem, 'forzado 410');
    expect((await control.startClock()).outcome, CommandOutcome.unpaired);
  });

  test('un token que no vale deja el mando sin emparejar', () async {
    final PanelPairing otro = PanelPairing.parse(
      '${panel.pairing.panel}/#mando=otro.token',
    )!;
    control.dispose();
    control = mando(pairing: otro);

    control.start();

    await _until(() => control.link == PanelLink.unauthorized);
  });

  test('sin permiso de emitir, el panel lo niega y no se reintenta', () async {
    await conectado();

    final CommandResult result = await control.setStreaming(on: true);

    expect(result.outcome, CommandOutcome.forbidden);
    expect(result.detail, contains('stream'));
    expect(control.match!.mayStream, isFalse);
  });

  test(
    'una respuesta vieja que se cruza no devuelve un marcador viejo',
    () async {
      await conectado();
      final Map<String, Object?> viejo = panel.dto();
      await control.goal(MatchTeam.home, 1); // rev 1, 2-0

      panel.replyStale(viejo); // rev 0, 1-0

      await _until(() => panel.staleServed);
      // Lo que llegue tras la respuesta vieja ya lo habrá procesado el mando.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(control.match!.home.goals, 2);
      expect(control.match!.rev, 1);
    },
  );

  test('antes de ver el partido no sale ningún gol', () async {
    final CommandResult result = await control.goal(MatchTeam.home, 1);

    expect(result.outcome, CommandOutcome.rejected);
    expect(panel.applied, 0);
  });

  test(
    'con el reloj en marcha, el cronómetro avanza entre respuestas',
    () async {
      panel
        ..clockMs = 1000
        ..clockRunning = true;
      await conectado();

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(control.clockMsNow, greaterThanOrEqualTo(1100));
    },
  );

  test('con el reloj parado, el cronómetro es el del panel', () async {
    panel.clockMs = 5000;
    await conectado();

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(control.clockMsNow, 5000);
  });
}
