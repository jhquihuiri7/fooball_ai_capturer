/// La pestaña Partido del maestro (IOS-87): la misma pantalla, sobre el partido del motor.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/master_board.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

const String _milan = '1 Dida\n2 Cafu\n3 Maldini\n4 Gattuso\n13 Nesta\n21 Pirlo\n8 Seedorf\n'
    '22 Kaka\n10 Rui Costa\n7 Shevchenko\n11 Gilardino\n';

void main() {
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine m;
  late MasterBoard b;
  late int avisos;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ios87');
    reloj = _Reloj();
    m = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(1));
    b = MasterBoard(m);
    avisos = 0;
    b.addListener(() => avisos++);
  });

  tearDown(() {
    b.dispose();
    dir.deleteSync(recursive: true);
  });

  test('los botones son órdenes del motor, y lo que manda un mando se ve aquí', () {
    b.addGoal(MatchTeam.home, 1);
    expect(m.homeGoals, 1);
    expect(avisos, greaterThan(0));
    m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
    expect(b.awayGoals, 1, reason: 'un gol del mando por la LAN');
    b.startClock();
    reloj.ms = 5000;
    b.nudgeClock(1);
    expect(b.elapsed, const Duration(seconds: 65));
    expect(b.running, isTrue);
    b.stopClock();
    b.resetScore();
    expect((b.homeGoals, b.awayGoals), (0, 0));
    expect(b.message, isNull);
  });

  test('lo que el motor rechaza queda dicho con sus palabras', () {
    expect(b.visibleLineupOnAir, isNull);
    expect(b.lineupNote, isNotNull);
    b.setFormation('4-3-3');
    expect(b.message, contains('no tiene alineacion'));
    b.toggleStreaming();
    expect(b.message, contains('sin tunel'));
    expect(b.canStream, isFalse);
    b.addGoal(MatchTeam.home, 1);
    expect(b.message, isNull, reason: 'la siguiente que va bien lo borra');
  });

  test('la alineación guardada se ve, se recoloca y sale al aire', () {
    m.saveLineup(MatchTeam.home, 'Milan', '4-4-2', _milan);
    final List<PlayerSlot> once = b.visibleLineup;
    expect(once, hasLength(11));
    expect(once.first.position, 'POR');
    expect(once.first.player.name, 'Dida');
    expect(once.where((PlayerSlot s) => s.position == 'DEF'), hasLength(4));
    expect(once.where((PlayerSlot s) => s.position == 'DEL').map((PlayerSlot s) => s.player.number), <int>[7, 11]);
    expect(b.visibleTeamName, 'MILAN');
    expect(b.lineupNote, isNull);
    b.setFormation('4-3-3');
    expect(b.visibleFormation, '4-3-3');
    expect(b.visibleLineup.where((PlayerSlot s) => s.position == 'DEL'), hasLength(3));
    b.toggleLineupOnAir();
    expect(m.lineups.onAirSide, MatchTeam.home);
    expect(b.visibleLineupOnAir, isTrue);
    b.showLineup(MatchTeam.away);
    expect(b.visibleLineupOnAir, isNull, reason: 'el visitante no tiene alineación');
    b.showLineup(MatchTeam.home);
    b.toggleLineupOnAir();
    expect(m.lineups.onAirSide, isNull);
  });
}
