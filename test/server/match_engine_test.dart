/// El partido con autoridad en el maestro (IOS-60): las órdenes de live_panel, el
/// cronómetro por dominio de reloj y el DTO que lee PanelMatch.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

class _Reloj implements MatchTimeSource {
  _Reloj(this.domain);
  int ms = 0;
  @override
  final String domain;
  @override
  int nowMs() => ms;
}

void main() {
  late Directory dir;
  late File fichero;
  late _Reloj reloj;
  late MatchEngine m;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ios60');
    fichero = File('${dir.path}/match.json');
    reloj = _Reloj('soporte1');
    m = MatchEngine.open(file: fichero, time: reloj, home: 'BELLAVISTA', away: 'PROGRESO', random: Random(1));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('gol', () {
    test('suma con expect, avisa del gol y sube rev', () {
      final List<MatchTeam> goles = <MatchTeam>[];
      m.onGoal = goles.add;
      final Map<String, Object?> dto = m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      expect((dto['home']! as Map<String, Object?>)['goals'], 1);
      expect(goles, <MatchTeam>[MatchTeam.home]);
      expect(m.rev, 1);
    });

    test('409 si el marcador no es el que vio, con el partido de verdad', () {
      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      final OrderError e = _error(() => m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0}));
      expect(e.status, 409);
      expect(((e.current!)['away']! as Map<String, Object?>)['goals'], 1);
      expect(m.awayGoals, 1, reason: 'no se tocó nada');
    });

    test('restar no baja de cero y no avisa de gol', () {
      bool avisado = false;
      m.onGoal = (_) => avisado = true;
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': -1, 'expect': 0});
      expect(m.homeGoals, 0);
      expect(avisado, isFalse);
    });

    test('400 con team, delta o expect mal', () {
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{'team': 'casa', 'delta': 1, 'expect': 0},
        <String, Object?>{'team': 'home', 'delta': 2, 'expect': 0},
        <String, Object?>{'team': 'home', 'delta': true, 'expect': 0},
        <String, Object?>{'team': 'home', 'delta': 1, 'expect': -1},
        <String, Object?>{'team': 'home', 'delta': 1},
      ]) {
        expect(_error(() => m.apply('match/goal', body)).status, 400, reason: '$body');
      }
      expect(m.rev, 0);
    });
  });

  test('marcador con expect de los dos lados', () {
    m.apply('match/score', <String, Object?>{'home': 2, 'away': 1, 'expect': <String, Object?>{'home': 0, 'away': 0}});
    expect((m.homeGoals, m.awayGoals), (2, 1));
    final OrderError e = _error(() => m.apply('match/score', <String, Object?>{
      'home': 3, 'away': 1, 'expect': <String, Object?>{'home': 0, 'away': 0},
    }));
    expect(e.status, 409);
    expect(_error(() => m.apply('match/score', <String, Object?>{'home': 1, 'away': 1})).status, 400);
  });

  group('cronómetro', () {
    test('start y pause idempotentes, con tiempo monótono', () {
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 5000;
      m.apply('match/clock', <String, Object?>{'action': 'start'});  // no reinicia
      reloj.ms = 10000;
      m.apply('match/clock', <String, Object?>{'action': 'pause'});
      m.apply('match/clock', <String, Object?>{'action': 'pause'});
      reloj.ms = 99999;
      expect(m.clock.elapsedMs, 10000);
      expect(m.clock.running, isFalse);
    });

    test('nudge con sus límites y sin bajar de cero', () {
      m.apply('match/clock', <String, Object?>{'action': 'nudge', 'seconds': matchClockNudgeMaxS});
      expect(m.clock.elapsedMs, matchClockNudgeMaxS * 1000);
      m.apply('match/clock', <String, Object?>{'action': 'nudge', 'seconds': -matchClockNudgeMaxS});
      m.apply('match/clock', <String, Object?>{'action': 'nudge', 'seconds': -60});
      expect(m.clock.elapsedMs, 0);
      for (final Object? s in <Object?>[0, matchClockNudgeMaxS + 1, 1.5, '60', null]) {
        expect(_error(() => m.apply('match/clock', <String, Object?>{'action': 'nudge', 'seconds': s})).status, 400);
      }
      expect(_error(() => m.apply('match/clock', <String, Object?>{'action': 'parar'})).status, 400);
    });

    test('reset en marcha vuelve a cero y sigue corriendo', () {
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 7000;
      m.apply('match/clock', <String, Object?>{'action': 'reset'});
      reloj.ms = 9000;
      expect(m.clock.elapsedMs, 2000);
    });

    test('cambiar la hora del sistema no lo mueve', () {
      // El motor solo lee su fuente monótona; en el código no hay DateTime.now().
      for (final String f in <String>['lib/src/server/match_engine.dart', 'lib/src/server/match_record.dart']) {
        expect(File(f).readAsStringSync().contains('DateTime.now'), isFalse, reason: f);
      }
    });
  });

  group('reinicio', () {
    test('mismo dominio: sigue en marcha', () {
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 60000;
      final MatchEngine otra = MatchEngine.open(file: fichero, time: reloj);
      expect(otra.clock.running, isTrue);
      expect(otra.clock.elapsedMs, 60000);
      expect(otra.clock.restored, isFalse);
      expect(otra.matchId, m.matchId);
    });

    test('otro dominio: vuelve parado y con clock_restored', () {
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 30000;
      m.saveIfDue();
      final MatchEngine otra = MatchEngine.open(file: fichero, time: _Reloj('otro'));
      expect(otra.clock.running, isFalse);
      expect(otra.clock.restored, isTrue);
      expect(otra.toJson()['clock_restored'], isTrue);
      otra.apply('match/clock', <String, Object?>{'action': 'start'});
      expect(otra.clock.restored, isFalse, reason: 'tocarlo cuenta como revisado');
    });

    test('el marcador sobrevive', () {
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      final MatchEngine otra = MatchEngine.open(file: fichero, time: reloj);
      expect((otra.homeGoals, otra.home), (1, 'BELLAVISTA'));
      expect(otra.boot, isNot(m.boot), reason: 'cada arranque, otro boot');
    });
  });

  test('clips/mark sin búfer es 404; con él, marca', () {
    expect(_error(() => m.apply('clips/mark', <String, Object?>{})).status, 404);
    int marcas = 0;
    m.onClipMark = () => marcas++;
    m.apply('clips/mark', <String, Object?>{});
    expect(marcas, 1);
  });

  test('emitir sin túnel es 409; con túnel emite y para', () {
    expect(_error(() => m.apply('stream/start', <String, Object?>{})).status, 409);
    m.canStream = true;
    m.apply('stream/start', <String, Object?>{});
    expect(m.streaming, isTrue);
    m.apply('stream/stop', <String, Object?>{});
    expect(m.streaming, isFalse);
    expect(_error(() => m.apply('match/lo-que-sea', <String, Object?>{})).status, 404);
  });

  test('PanelMatch.fromJson lee el DTO', () {
    m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
    final PanelMatch p = PanelMatch.fromJson(m.toJson(scopes: <String>{panelScopeMatch, panelScopeStream}));
    expect(p.matchId, m.matchId);
    expect(p.home.goals, 1);
    expect(p.home.name, 'BELLAVISTA');
    expect(p.rev, m.rev);
    expect(p.mayStream, isTrue);
    expect(p.formations, matchFormations);
  });
}

OrderError _error(void Function() f) {
  try {
    f();
  } on OrderError catch (e) {
    return e;
  }
  fail('se esperaba un OrderError');
}
