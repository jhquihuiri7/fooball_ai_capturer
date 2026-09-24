/// El móvil como mando del panel (ADR 0017 del repo football-ai).
///
/// Dos cosas, las dos por HTTP normal para poder probarlas sin iPhone:
///
/// - **Estar al día.** Un bucle de espera larga (`GET /api/v1/match?since=`) trae el
///   partido en cuanto cambia, lo cambie este móvil, otro o el operador en la web.
/// - **Mandar órdenes.** Cada toque es una orden con su `Idempotency-Key`. Si la respuesta
///   no llega, se reintenta con la misma clave durante `panelCommandRetryWindow`: el
///   panel no la aplica dos veces. Pasado ese plazo se da por fallida y se olvida; no hay
///   cola de órdenes, porque un «Parar reloj» que llega 40 s tarde es peor que uno que
///   falla a la vista.
///
/// **Lo que se enseña es lo aplicado.** Este objeto no toca el partido por su cuenta: solo
/// guarda lo que el panel contesta, y solo si es más nuevo que lo que ya tenía.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';

/// Cómo está el enlace con el panel.
enum PanelLink {
  /// Aún no ha contestado nunca.
  connecting,

  /// La última pregunta tuvo respuesta.
  online,

  /// La red falla; se sigue intentando solo.
  offline,

  /// El panel contestó 410: esta transmisión terminó. Hay que escanear el QR nuevo.
  ended,

  /// El panel no acepta el token (401): caducó o no vale. Hay que escanear otra vez.
  unauthorized,
}

/// Qué pasó con una orden.
enum CommandOutcome {
  /// El panel la aplicó; el partido ya es el de la respuesta.
  applied,

  /// El partido ya no era el que se vio (409): otro mando se adelantó. El partido ya es
  /// el de verdad; la pantalla tiene que enseñarlo, no reintentar.
  conflict,

  /// Este mando no tiene permiso para eso (403).
  forbidden,

  /// La orden está mal o el panel no puede cumplirla (400, 404).
  rejected,

  /// La transmisión terminó (410) o el token no vale (401).
  unpaired,

  /// No hubo respuesta en `panelCommandRetryWindow`. No se sabe si llegó.
  unreachable,
}

class CommandResult {
  const CommandResult(this.outcome, [this.detail]);

  final CommandOutcome outcome;

  /// Lo que dijo el panel, para la pantalla, si dijo algo.
  final String? detail;

  bool get applied => outcome == CommandOutcome.applied;
}

class PanelControl extends ChangeNotifier {
  PanelControl({
    required this.pairing,
    required this.deviceName,
    HttpClient? client,
    math.Random? random,
    this.longPollTimeout = panelLongPollTimeout,
    this.requestTimeout = panelRequestTimeout,
    this.retryWindow = panelCommandRetryWindow,
    this.retryDelay = panelCommandRetryDelay,
    this.reconnectDelay = panelReconnectDelay,
  }) : _client = client ?? HttpClient(),
       _random = random ?? math.Random.secure();

  final PanelPairing pairing;

  /// Cómo se llama este móvil en la tarjeta Mando del panel.
  final String deviceName;

  final Duration longPollTimeout;
  final Duration requestTimeout;
  final Duration retryWindow;
  final Duration retryDelay;
  final Duration reconnectDelay;

  final HttpClient _client;
  final math.Random _random;

  PanelMatch? _match;
  PanelLink _link = PanelLink.connecting;
  String? _problem;
  bool _running = false;
  bool _disposed = false;

  /// Reloj monótono desde la última respuesta del panel: la pantalla hace avanzar el
  /// cronómetro con él y cuenta el silencio con él. Nunca la hora de pared.
  final Stopwatch _sinceAnswer = Stopwatch();

  /// El partido tal y como lo contó el panel la última vez; `null` hasta la primera.
  PanelMatch? get match => _match;

  PanelLink get link => _link;

  /// Lo último que falló, para la pantalla; `null` si nada.
  String? get problem => _problem;

  /// Cuánto hace que el panel no contesta nada. Cero con el enlace bien.
  Duration get silence =>
      _link == PanelLink.online ? Duration.zero : _sinceAnswer.elapsed;

  /// El cronómetro ahora: el de la última respuesta más lo que ha corrido desde entonces,
  /// si corría. Sin respuesta todavía, `null`.
  int? get clockMsNow {
    final PanelMatch? match = _match;
    if (match == null) {
      return null;
    }
    return match.clockMs +
        (match.clockRunning ? _sinceAnswer.elapsedMilliseconds : 0);
  }

  /// Arranca el bucle de espera larga. Llamarlo dos veces no abre dos bucles.
  void start() {
    if (_running || _disposed) {
      return;
    }
    _running = true;
    unawaited(_watch());
  }

  // ------------------------------------------------------------------------- //
  // Órdenes (las rutas de `ORDERS` en `tools/live_panel.py`)
  // ------------------------------------------------------------------------- //

  /// Un gol más o uno menos. `expect` sale del partido que se está viendo: sin partido
  /// no hay nada que ver, y la orden no sale.
  Future<CommandResult> goal(MatchTeam team, int delta) async {
    final PanelMatch? seen = _match;
    if (seen == null) {
      return _notYet;
    }
    return _command('match/goal', {
      'team': team.name,
      'delta': delta,
      'expect': seen.team(team).goals,
    });
  }

  /// El marcador a mano; con 0-0, reiniciarlo.
  Future<CommandResult> setScore(int home, int away) async {
    final PanelMatch? seen = _match;
    if (seen == null) {
      return _notYet;
    }
    return _command('match/score', {
      'home': home,
      'away': away,
      'expect': {'home': seen.home.goals, 'away': seen.away.goals},
    });
  }

  static const CommandResult _notYet = CommandResult(
    CommandOutcome.rejected,
    'todavía no se ha visto el partido del panel',
  );

  Future<CommandResult> startClock() =>
      _command('match/clock', {'action': 'start'});

  Future<CommandResult> pauseClock() =>
      _command('match/clock', {'action': 'pause'});

  Future<CommandResult> resetClock() =>
      _command('match/clock', {'action': 'reset'});

  Future<CommandResult> nudgeClock(Duration by) =>
      _command('match/clock', {'action': 'nudge', 'seconds': by.inSeconds});

  Future<CommandResult> setFormation(MatchTeam team, String formation) =>
      _command('match/lineup', {'team': team.name, 'formation': formation});

  Future<CommandResult> showLineup(MatchTeam team, {required bool onAir}) =>
      _command('match/lineup', {'team': team.name, 'on_air': onAir});

  Future<CommandResult> markClip() => _command('clips/mark', {});

  Future<CommandResult> setStreaming({required bool on}) =>
      _command(on ? 'stream/start' : 'stream/stop', {});

  // ------------------------------------------------------------------------- //
  // Por dentro
  // ------------------------------------------------------------------------- //

  Future<void> _watch() async {
    bool fromScratch = true;
    while (!_disposed &&
        _link != PanelLink.ended &&
        _link != PanelLink.unauthorized) {
      final String? since = fromScratch ? null : _match?.since;
      try {
        final _Reply reply = await _send(
          'GET',
          pairing.endpoint('match', since == null ? null : {'since': since}),
          timeout: longPollTimeout,
        );
        if (reply.status == HttpStatus.ok) {
          _accept(PanelMatch.fromJson(reply.json));
          fromScratch = false;
          continue;
        }
        if (_unpaired(reply)) {
          return;
        }
        // 503: demasiados mandos esperando. Se pregunta de cero, sin esperar turno.
        fromScratch = reply.status == HttpStatus.serviceUnavailable;
        _lost(reply.detail ?? 'el panel contestó ${reply.status}');
      } on FormatException catch (error) {
        // Contesta, pero no se le entiende: un panel de otra versión.
        _lost('el panel habla otra versión: ${error.message}');
      } on Exception {
        _lost('sin conexión con el panel');
      }
      if (!_disposed) {
        await Future<void>.delayed(reconnectDelay);
      }
    }
  }

  Future<CommandResult> _command(
    String route,
    Map<String, Object?> body,
  ) async {
    final String key = _idempotencyKey();
    final Stopwatch trying = Stopwatch()..start();
    while (!_disposed) {
      try {
        final _Reply reply = await _send(
          'POST',
          pairing.endpoint(route),
          body: body,
          idempotencyKey: key,
          timeout: requestTimeout,
        );
        switch (reply.status) {
          case HttpStatus.ok:
            _accept(PanelMatch.fromJson(reply.json));
            return const CommandResult(CommandOutcome.applied);
          case HttpStatus.conflict:
            final Object? current = reply.json['state'];
            if (current != null) {
              _accept(PanelMatch.fromJson(current));
            }
            return CommandResult(CommandOutcome.conflict, reply.detail);
          case HttpStatus.forbidden:
            return CommandResult(CommandOutcome.forbidden, reply.detail);
          case HttpStatus.gone || HttpStatus.unauthorized:
            _unpaired(reply);
            return CommandResult(CommandOutcome.unpaired, reply.detail);
          case >= HttpStatus.internalServerError:
            break; // el panel no pudo ahora: se reintenta como un corte
          default:
            return CommandResult(CommandOutcome.rejected, reply.detail);
        }
      } on FormatException catch (error) {
        return CommandResult(
          CommandOutcome.rejected,
          'respuesta ilegible: ${error.message}',
        );
      } on Exception {
        // Sin respuesta: puede que llegara y se perdiera la vuelta. La misma clave hace
        // que reintentar sea seguro.
      }
      if (trying.elapsed + retryDelay > retryWindow) {
        break;
      }
      await Future<void>.delayed(retryDelay);
    }
    return const CommandResult(CommandOutcome.unreachable, 'no llegó al panel');
  }

  /// Se queda con un partido solo si es más nuevo: una respuesta que se cruzó con otra
  /// no puede devolver la pantalla a un marcador viejo.
  void _accept(PanelMatch next) {
    final PanelMatch? current = _match;
    final bool newer =
        current == null ||
        next.matchId != current.matchId ||
        next.boot != current.boot ||
        next.rev >= current.rev;
    _sinceAnswer
      ..reset()
      ..start();
    if (newer) {
      _match = next;
    }
    _link = PanelLink.online;
    _problem = null;
    _notify();
  }

  void _lost(String problem) {
    _link = PanelLink.offline;
    _problem = problem;
    _notify();
  }

  /// 410 y 401 cortan el enlace del todo: con este QR ya no hay nada que hacer.
  bool _unpaired(_Reply reply) {
    final PanelLink? cut = switch (reply.status) {
      HttpStatus.gone => PanelLink.ended,
      HttpStatus.unauthorized => PanelLink.unauthorized,
      _ => null,
    };
    if (cut == null) {
      return false;
    }
    _link = cut;
    _problem = reply.detail;
    _notify();
    return true;
  }

  Future<_Reply> _send(
    String method,
    Uri uri, {
    required Duration timeout,
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) async {
    final HttpClientRequest request = await _client
        .openUrl(method, uri)
        .timeout(timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${pairing.token}')
      ..set(panelDeviceHeader, Uri.encodeComponent(deviceName));
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    if (body != null) {
      final List<int> bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final HttpClientResponse response = await request.close().timeout(timeout);
    final String text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    Map<String, Object?> json = const <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        json = decoded;
      }
    } on FormatException {
      // Un 401 del operador llega sin cuerpo; con el código basta.
    }
    return _Reply(response.statusCode, json);
  }

  /// Un UUID v4: aleatorio, así que dos toques nunca comparten clave.
  String _idempotencyKey() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // A la fuerza: corta también la espera larga que esté abierta.
    _client.close(force: true);
    super.dispose();
  }
}

/// Una respuesta del panel: el código y el JSON, si traía.
class _Reply {
  const _Reply(this.status, this.json);

  final int status;
  final Map<String, Object?> json;

  /// El `detail` de un error RFC 7807, si lo hay. Sin `as`: un cast que falla es un
  /// `Error`, no una `Exception`, y mataría el bucle de espera larga.
  String? get detail {
    final Object? detail = json['detail'];
    return detail is String ? detail : null;
  }
}
