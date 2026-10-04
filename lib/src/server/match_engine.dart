/// El partido con autoridad en el maestro (IOS-60): las órdenes del mando, el
/// cronómetro y el DTO, porte de `ORDERS`/`apply_order` de `tools/live_panel.py`.
///
/// Las órdenes se validan enteras antes de tocar nada; el gol y el marcador llevan
/// `expect`, y si el partido ya no es el que vio quien mandó, 409 con el partido de
/// verdad. Cada cambio sube `rev` y se guarda. El cronómetro solo lee tiempo monótono
/// (el reloj del soporte de IOS-13, o un Stopwatch sin enlace): cambiar la hora del
/// sistema a mitad de partido no lo mueve.
library;

import 'dart:io';
import 'dart:math';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/match_record.dart';

/// Tiempo monótono en ms y el reloj al que pertenece (ADR 0023 §4).
abstract class MatchTimeSource {
  int nowMs();

  /// El `clock_domain`: dos lecturas solo se restan si es el mismo.
  String get domain;
}

/// Sin enlace: un Stopwatch, monótono, cuyo dominio muere con el proceso. Tras reiniciar
/// la app el cronómetro vuelve, por tanto, parado y con `clock_restored`.
class StopwatchTimeSource implements MatchTimeSource {
  StopwatchTimeSource({Random? random})
    : domain = 'sw${_hex(random ?? Random.secure(), 8)}',
      _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  final String domain;

  @override
  int nowMs() => _watch.elapsedMilliseconds;
}

String _hex(Random random, int bytes) =>
    List<String>.generate(bytes, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// El cronómetro: lo acumulado y, si corre, desde cuándo.
class MatchClock {
  MatchClock(this._time);

  final MatchTimeSource _time;
  int accumulatedMs = 0;
  int? startedMs;

  /// Volvió parado de un reinicio con el reloj en marcha y nadie lo ha tocado aún.
  bool restored = false;

  bool get running => startedMs != null;

  int get elapsedMs => accumulatedMs + (startedMs == null ? 0 : _time.nowMs() - startedMs!);

  void start() {
    restored = false;
    startedMs ??= _time.nowMs();
  }

  void pause() {
    restored = false;
    final int? inicio = startedMs;
    if (inicio != null) {
      accumulatedMs += _time.nowMs() - inicio;
      startedMs = null;
    }
  }

  void reset() {
    restored = false;
    accumulatedMs = 0;
    startedMs = startedMs == null ? null : _time.nowMs();
  }

  /// Adelanta o atrasa, sin dejarlo nunca en negativo.
  void nudge(int seconds) {
    restored = false;
    accumulatedMs = max(0, accumulatedMs + seconds * 1000);
  }
}

/// Una orden que no se aplica: 400 mal escrita, 404 sin con qué cumplirla, 409 el
/// partido ya no es el que vio quien la mandó (`current` lleva el de verdad).
class OrderError implements Exception {
  OrderError(this.status, this.message);

  final int status;
  final String message;
  Map<String, Object?>? current;

  @override
  String toString() => 'OrderError($status): $message';
}

class MatchEngine {
  MatchEngine._(this._file, this._time, this.clock, this.matchId, this.boot);

  /// Abre el partido guardado en `file`, o empieza uno nuevo si no hay fichero.
  /// Con el mismo `clock_domain` el cronómetro sigue en marcha; con otro vuelve
  /// parado y con `clock_restored` (ADR 0023).
  factory MatchEngine.open({
    required File file,
    required MatchTimeSource time,
    String home = 'LOCAL',
    String away = 'VISITANTE',
    Random? random,
  }) {
    final Random azar = random ?? Random.secure();
    final MatchClock reloj = MatchClock(time);
    final MatchRecord? guardado = loadRecord(file);
    final MatchEngine engine = MatchEngine._(
      file,
      time,
      reloj,
      guardado?.matchId ?? 'm_${_hex(azar, 6)}',
      _hex(azar, 8),
    );
    if (guardado == null) {
      engine
        ..home = home
        ..away = away;
      engine._save();
      return engine;
    }
    engine
      ..home = guardado.home
      ..away = guardado.away
      ..homeGoals = guardado.homeGoals
      ..awayGoals = guardado.awayGoals;
    reloj.accumulatedMs = guardado.accumulatedMs;
    if (guardado.running && guardado.clockDomain == time.domain && guardado.startedRigMs != null) {
      reloj.startedMs = guardado.startedRigMs;
    } else {
      reloj.restored = guardado.running;
    }
    return engine;
  }

  final File _file;
  final MatchTimeSource _time;
  final MatchClock clock;
  final String matchId;

  /// Identificador de este arranque: cambia en cada uno.
  final String boot;
  int rev = 0;
  String home = 'LOCAL';
  String away = 'VISITANTE';
  int homeGoals = 0;
  int awayGoals = 0;
  bool streaming = false;

  /// Si hay túnel al relé (ADR 0022): sin él, `can_stream` es false.
  bool _canStream = false;
  bool get canStream => _canStream;
  set canStream(bool value) {
    if (_canStream == value) {
      return;
    }
    _canStream = value;
    _changed();
  }

  /// Por qué ha dejado de guardarse el partido, si ha dejado.
  String? saveError;
  int? _savedAtMs;

  /// Un gol sumado: marca el clip y pide el plano de situación (ADR 0013).
  void Function(MatchTeam team)? onGoal;

  /// `clips/mark`; sin búfer de repetición no hay con qué cumplirla (404).
  void Function()? onClipMark;

  /// Aplica una orden por su ruta bajo `/api/v1/` y devuelve el partido como quedó, o
  /// lanza [OrderError] sin haber tocado nada.
  Map<String, Object?> apply(String name, Map<String, Object?> body) {
    try {
      switch (name) {
        case 'match/goal':
          _goal(body);
        case 'match/score':
          _score(body);
        case 'match/clock':
          _clock(body);
        case 'clips/mark':
          final void Function()? marca = onClipMark;
          if (marca == null) {
            throw OrderError(404, 'el maestro no tiene bufer de repeticion');
          }
          marca();
        case 'stream/start':
          if (!canStream) {
            throw OrderError(409, 'sin tunel al rele: no se puede emitir');
          }
          streaming = true;
        case 'stream/stop':
          streaming = false;
        default:
          throw OrderError(404, 'orden desconocida: $name');
      }
    } on OrderError catch (error) {
      if (error.status == HttpStatus.conflict) {
        error.current = toJson();
      }
      rethrow;
    }
    _changed();
    return toJson();
  }

  MatchTeam _team(Map<String, Object?> body) {
    for (final MatchTeam t in MatchTeam.values) {
      if (body['team'] == t.name) {
        return t;
      }
    }
    throw OrderError(400, 'team tiene que ser home o away');
  }

  int _countOf(Object? value, String name) {
    if (value is! int || value < 0) {
      throw OrderError(400, '$name tiene que ser un entero no negativo');
    }
    return value;
  }

  void _goal(Map<String, Object?> body) {
    final MatchTeam equipo = _team(body);
    final Object? delta = body['delta'];
    if (delta != 1 && delta != -1) {
      throw OrderError(400, 'delta tiene que ser 1 o -1');
    }
    final int visto = _countOf(body['expect'], 'expect');
    final int goles = equipo == MatchTeam.home ? homeGoals : awayGoals;
    if (goles != visto) {
      throw OrderError(409, '${equipo.name} tiene $goles goles, no $visto');
    }
    final int nuevo = delta == 1 ? goles + matchGoalStep : max(0, goles - matchGoalStep);
    if (equipo == MatchTeam.home) {
      homeGoals = nuevo;
    } else {
      awayGoals = nuevo;
    }
    if (delta == 1) {
      onGoal?.call(equipo);
    }
  }

  void _score(Map<String, Object?> body) {
    final Object? visto = body['expect'];
    if (visto is! Map<String, Object?>) {
      throw OrderError(400, 'expect tiene que ser {home, away}');
    }
    final int nuevoLocal = _countOf(body['home'], 'home');
    final int nuevoVisitante = _countOf(body['away'], 'away');
    final int antesLocal = _countOf(visto['home'], 'expect.home');
    final int antesVisitante = _countOf(visto['away'], 'expect.away');
    if (homeGoals != antesLocal || awayGoals != antesVisitante) {
      throw OrderError(
        409,
        'el marcador es $homeGoals-$awayGoals, no $antesLocal-$antesVisitante',
      );
    }
    homeGoals = nuevoLocal;
    awayGoals = nuevoVisitante;
  }

  void _clock(Map<String, Object?> body) {
    switch (body['action']) {
      case 'start':
        clock.start();
      case 'pause':
        clock.pause();
      case 'reset':
        clock.reset();
      case 'nudge':
        final Object? segundos = body['seconds'];
        if (segundos is! int || segundos == 0 || segundos.abs() > matchClockNudgeMaxS) {
          throw OrderError(
            400,
            'seconds tiene que ser un entero distinto de cero, hasta $matchClockNudgeMaxS',
          );
        }
        clock.nudge(segundos);
      default:
        throw OrderError(400, 'action tiene que ser start, pause, reset o nudge');
    }
  }

  void _changed() {
    rev += 1;
    _save();
  }

  /// Guarda el cronómetro si corre y toca; lo llama quien lleve el compás (1 Hz basta).
  void saveIfDue() {
    final int? ultimo = _savedAtMs;
    if (clock.running &&
        (ultimo == null || _time.nowMs() - ultimo >= matchClockSaveInterval.inMilliseconds)) {
      _save();
    }
  }

  void _save() {
    try {
      saveRecord(
        _file,
        MatchRecord(
          matchId: matchId,
          home: home,
          away: away,
          homeGoals: homeGoals,
          awayGoals: awayGoals,
          accumulatedMs: clock.accumulatedMs,
          running: clock.running,
          startedRigMs: clock.startedMs,
          clockDomain: _time.domain,
        ),
      );
      saveError = null;
      _savedAtMs = _time.nowMs();
    } on MatchRecordError catch (error) {
      // Un fallo no deshace el cambio: el marcador ya cambió. Se dice en el DTO.
      saveError = error.message;
    }
  }

  /// El `MatchStateDTO` del ADR 0017, el mismo que lee `PanelMatch.fromJson`. Las
  /// alineaciones llegan con IOS-61; `scopes` lo pone la API según el token (IOS-62).
  Map<String, Object?> toJson({Set<String> scopes = const <String>{panelScopeMatch}}) {
    Map<String, Object?> equipo(String nombre, int goles) => <String, Object?>{
      'name': nombre,
      'goals': goles,
      'formation': null,
      'players': 0,
    };
    return <String, Object?>{
      'match_id': matchId,
      'boot': boot,
      'rev': rev,
      'home': equipo(home, homeGoals),
      'away': equipo(away, awayGoals),
      'clock_ms': clock.elapsedMs,
      'clock_running': clock.running,
      'clock_restored': clock.restored,
      'lineup_on_air': null,
      'streaming': streaming,
      'can_stream': canStream,
      'formations': matchFormations,
      'save_error': saveError,
      'scopes': scopes.toList()..sort(),
    };
  }
}
