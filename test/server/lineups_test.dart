/// Las alineaciones en el maestro (IOS-61) contra los dorados de `tools/lineup.py`, y la
/// orden `match/lineup` como la aplica `tools/live_panel.py`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_state.dart' show MatchTeam;
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

List<Map<String, Object?>> _cases(String fn) {
  final Map<String, Object?> golden =
      jsonDecode(File('test/golden/lineups.json').readAsStringSync()) as Map<String, Object?>;
  return <Map<String, Object?>>[
    for (final Object? c in golden['cases']! as List<Object?>)
      if ((c! as Map<String, Object?>)['fn'] == fn) c as Map<String, Object?>,
  ];
}

MatchTeam _side(Object? name) => MatchTeam.values.byName(name! as String);

Team _team(Map<String, Object?> i) => buildTeam(
  i['name']! as String,
  i['formation']! as String,
  i['roster']! as String,
  coach: (i['coach'] ?? '') as String,
);

const String _milan = '1 Dida\n2 Cafu\n3 Maldini\n4 Gattuso\n13 Nesta\n21 Pirlo\n8 Seedorf\n'
    '22 Kaka\n10 Rui Costa\n7 Shevchenko\n11 Gilardino\n25 Abbiati\n27 Serginho\n';

class _Reloj implements MatchTimeSource {
  @override
  int nowMs() => 0;
  @override
  String get domain => 'soporte1';
}

void main() {
  group('dorados', () {
    final List<Map<String, Object?>> equipos = _cases('lineup.build_team');
    final List<Map<String, Object?>> alAire = _cases('lineup.on_air');

    test('hay casos', () {
      expect(equipos, hasLength(greaterThanOrEqualTo(5)));
      expect(alAire, isNotEmpty);
    });

    for (final Map<String, Object?> c in equipos) {
      test('build_team ${c['name']}', () {
        final Map<String, Object?> esperado = c['expected']! as Map<String, Object?>;
        Map<String, Object?> resultado;
        try {
          final Team t = _team(c['inputs']! as Map<String, Object?>);
          resultado = <String, Object?>{'team': t.toJson(), 'lines': t.lines};
        } on LineupError catch (e) {
          resultado = <String, Object?>{'error': e.message};
        }
        expect(resultado, esperado);
      });
    }

    for (final Map<String, Object?> c in alAire) {
      test('on_air ${c['name']}', () {
        final LineupBook libro = LineupBook();
        final List<String?> traza = <String?>[];
        for (final Object? e in (c['inputs']! as Map<String, Object?>)['events']! as List<Object?>) {
          final Map<String, Object?> evento = e! as Map<String, Object?>;
          if (evento.containsKey('set_on_air')) {
            libro.setOnAir(evento['set_on_air'] == null ? null : _side(evento['set_on_air']));
          } else if (evento.containsKey('toggle')) {
            libro.toggle(_side(evento['toggle']));
          } else {
            final Map<String, Object?> s = evento['set']! as Map<String, Object?>;
            libro.set(_side(s['side']), _team(s));
          }
          traza.add(libro.onAirSide?.name);
        }
        expect(
          <String, Object?>{'on_air_trace': traza, 'summary': libro.summary()},
          c['expected'],
        );
      });
    }
  });

  group('la lista', () {
    test('separadores, BOM, CRLF y comillas de CSV', () {
      final List<RosterPlayer> p = parseRoster('﻿1. "Juan  Pérez"\r\n4, Luis Mora\r\n10;Carlos Díaz;DEL\n07 Siete');
      expect(p, const <RosterPlayer>[
        RosterPlayer(1, 'Juan Pérez'), RosterPlayer(4, 'Luis Mora'), RosterPlayer(10, 'Carlos Díaz'), RosterPlayer(7, 'Siete'),
      ]);
    });

    test('una línea sin dorsal en mitad de la lista se señala con su número', () {
      expect(
        () => parseRoster('1 Juan\n\nportero suplente'),
        throwsA(isA<LineupError>().having((LineupError e) => e.message, 'mensaje', startsWith('linea 3:'))),
      );
      expect(
        () => parseRoster('1 Juan\n123 Largo'),
        throwsA(isA<LineupError>().having((LineupError e) => e.message, 'mensaje', contains("llego '123 Largo'"))),
      );
    });

    test('formaciones fuera de reglas', () {
      for (final String f in <String>['4-4-4', '6-3-1', '1-1-1-1-1-1', '1-1-1', 'cuatro', '']) {
        expect(() => parseFormation(f), throwsA(isA<LineupError>()), reason: f);
      }
      expect(parseFormation(' 3-2-1 '), <int>[3, 2, 1]);
    });

    test('nombres largos se cuentan por caracteres, no por unidades UTF-16', () {
      final String justo = 'Ñ' * lineupMaxNameChars;
      expect(Team(name: justo, formation: '2-2', starters: <RosterPlayer>[
        for (int i = 1; i <= 5; i++) RosterPlayer(i, 'J$i'),
      ]).name, justo);
    });

    test('rosterText vuelve a dar el mismo equipo', () {
      final Team t = buildTeam('Milan', '4-4-2', _milan, coach: 'Ancelotti');
      expect(buildTeam(t.name, t.formation, rosterText(t), coach: t.coach).toJson(), t.toJson());
    });
  });

  group('el libro en disco', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ios61'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('ida y vuelta', () {
      final File f = File('${dir.path}/lineups.json');
      LineupBook(file: f).set(MatchTeam.away, buildTeam('Milan', '4-4-2', _milan));
      final LineupBook leido = LineupBook.load(f);
      expect(leido.teams[MatchTeam.away]!.players, 13);
      expect(leido.summary()['persistent'], isTrue);
      expect(File('${f.path}.tmp').existsSync(), isFalse);
    });
  });

  group('match/lineup en el motor', () {
    late Directory dir;
    late MatchEngine m;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ios61m');
      m = MatchEngine.open(file: File('${dir.path}/match.json'), time: _Reloj(), random: Random(2));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('sin alineación guardada es 409; mal escrita, 400', () {
      expect(_error(() => m.apply('match/lineup', <String, Object?>{'team': 'home', 'on_air': true})).status, 409);
      m.saveLineup(MatchTeam.home, 'Milan', '4-4-2', _milan);
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{'team': 'home'},
        <String, Object?>{'team': 'home', 'formation': 442},
        <String, Object?>{'team': 'home', 'on_air': 'si'},
        <String, Object?>{'team': 'home', 'formation': '9-9'},
        <String, Object?>{'team': 'casa', 'on_air': true},
      ]) {
        expect(_error(() => m.apply('match/lineup', body)).status, 400, reason: '$body');
      }
    });

    test('el editor pone el nombre en el marcador y el DTO cuenta jugadores', () {
      m.saveLineup(MatchTeam.home, 'Milan', '4-4-2', _milan);
      final PanelMatch p = PanelMatch.fromJson(m.toJson());
      expect(p.home.name, 'MILAN');
      expect(p.home.formation, '4-4-2');
      expect(p.home.players, 13);
    });

    test('recolocar y sacar al aire; ocultar la propia no toca la del rival', () {
      m
        ..saveLineup(MatchTeam.home, 'Milan', '4-4-2', _milan)
        ..saveLineup(MatchTeam.away, 'Liverpool', '4-3-3', _milan);
      final int antes = m.rev;
      m.apply('match/lineup', <String, Object?>{'team': 'home', 'formation': '4-3-3', 'on_air': true});
      expect(m.lineups.teams[MatchTeam.home]!.lines, <int>[4, 3, 3]);
      expect(m.toJson()['lineup_on_air'], 'home');
      expect(m.rev, antes + 1);
      m.apply('match/lineup', <String, Object?>{'team': 'away', 'on_air': true});
      m.apply('match/lineup', <String, Object?>{'team': 'home', 'on_air': false});
      expect(m.toJson()['lineup_on_air'], 'away');
    });

    test('las alineaciones sobreviven a reabrir; un fichero roto no impide arrancar', () {
      m.saveLineup(MatchTeam.away, 'Milan', '4-4-2', _milan);
      final MatchEngine otra = MatchEngine.open(file: File('${dir.path}/match.json'), time: _Reloj());
      expect(otra.lineups.teams[MatchTeam.away]!.name, 'MILAN');
      File('${dir.path}/lineups.json').writeAsStringSync('{roto');
      final MatchEngine rota = MatchEngine.open(file: File('${dir.path}/match.json'), time: _Reloj());
      expect(rota.lineups.teams, isEmpty);
      expect(rota.lineupsError, isNotNull);
      expect(File('${dir.path}/lineups.json.roto').existsSync(), isTrue);
    });
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
