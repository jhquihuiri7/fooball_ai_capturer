/// La migración del partido local al del maestro (IOS-87) y las plantillas por la API.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/match_migration.dart';
import 'package:football_ai_capture/src/server/master_host.dart';

class _Reloj implements MatchTimeSource {
  @override
  int nowMs() => 5000;
  @override
  String get domain => 'soporte1';
}

/// Un «zero.match» de verdad, como lo escribe MatchState.toJson: 2-1 en el 44:00 y dos
/// plantillas de 14 con sus puestos.
String _zeroMatch({int? runningSinceMs}) {
  List<Map<String, Object?>> plantilla(int base) => <Map<String, Object?>>[
    for (final (int i, PlayerRole r) in <(int, PlayerRole)>[
      (1, PlayerRole.gk), (2, PlayerRole.rb), (4, PlayerRole.cb), (5, PlayerRole.cb), (3, PlayerRole.lb),
      (6, PlayerRole.dm), (8, PlayerRole.cm), (10, PlayerRole.am), (7, PlayerRole.rw), (9, PlayerRole.st),
      (11, PlayerRole.lw), (12, PlayerRole.gk), (13, PlayerRole.cb), (14, PlayerRole.st),
    ])
      <String, Object?>{'number': i, 'name': 'Jugador ${base + i}', 'role': r.name},
  ];
  return jsonEncode(<String, Object?>{
    'homeName': 'Bellavista', 'awayName': 'Progreso', 'homeGoals': 2, 'awayGoals': 1,
    'homeFormation': '4-3-3', 'awayFormation': '4-3-3', 'lineupTeam': 'home', 'streaming': false,
    'baseMs': 44 * 60 * 1000, 'runningSinceMs': runningSinceMs,
    'homeSquad': plantilla(100), 'awaySquad': plantilla(200),
  });
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ios87'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('2-1 en el 44:00 y dos plantillas: abre con eso y el reloj parado', () {
    final MigrationResult m = migrateLocalMatch(_zeroMatch(), matchId: 'm_1', nowWallMs: 0)!;
    expect(applyMigration(dir, m, matchFileName: matchFileName), isTrue);
    final MatchEngine e = MatchEngine.open(file: File('${dir.path}/$matchFileName'), time: _Reloj());
    expect((e.homeGoals, e.awayGoals, e.home, e.away), (2, 1, 'BELLAVISTA', 'PROGRESO'));
    expect(e.clock.elapsedMs, 44 * 60 * 1000);
    expect(e.clock.running, isFalse);
    final Team local = e.lineups.teams[MatchTeam.home]!;
    expect(local.formation, '4-3-3');
    expect(local.starters.first.number, 1, reason: 'el portero primero');
    expect(local.starters, hasLength(11));
    expect(local.substitutes.map((RosterPlayer p) => p.number), <int>[12, 13, 14]);
    expect(applyMigration(dir, m, matchFileName: matchFileName), isFalse, reason: 'una sola vez');
  });

  test('un reloj en marcha migra parado, con lo que corrió y clock_restored', () {
    final MigrationResult m = migrateLocalMatch(_zeroMatch(runningSinceMs: 1000), matchId: 'm_2', nowWallMs: 61000)!;
    applyMigration(dir, m, matchFileName: matchFileName);
    final MatchEngine e = MatchEngine.open(file: File('${dir.path}/$matchFileName'), time: _Reloj());
    expect(e.clock.running, isFalse);
    expect(e.clock.restored, isTrue);
    expect(e.clock.elapsedMs, 45 * 60 * 1000);
  });

  test('basura no migra', () {
    expect(migrateLocalMatch('{roto', matchId: 'm', nowWallMs: 0), isNull);
    expect(migrateLocalMatch('[1]', matchId: 'm', nowWallMs: 0), isNull);
  });

  test('MasterHost migra al abrir si no hay partido', () async {
    final MasterHost h = MasterHost(
      directory: dir, controlSecret: (_) async => '', announceMatch: (_) async {},
      peerAddress: () async => '', operatorPin: () async => '', port: 0,
      legacyMatch: () async => _zeroMatch(),
    );
    await h.becomeMaster('m_3');
    expect(h.migrated, isTrue);
    expect(h.engine!.homeGoals, 2);
    await h.stepDown();
  });

  test('match/roster pide rig, lee CSV y pasa el nombre al marcador; el pod se importa', () async {
    final MatchEngine e = MatchEngine.open(file: File('${dir.path}/$matchFileName'), time: _Reloj(), random: Random(9));
    final List<int> s = utf8.encode('s' * 40);
    final MasterApi api = MasterApi(
      engine: e, monotonicMs: () => 0, wallS: () => 1000, controlSecret: deriveControlSecret(s, e.matchId),
      operatorPin: '123456',
    );
    ApiRequest post(String bearer, Map<String, Object?> body) => ApiRequest(
      method: 'POST', path: '/api/v1/match/roster',
      headers: <String, String>{'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
      body: utf8.encode(jsonEncode(body)),
    );
    final String token = issueToken(
      deriveControlSecret(s, e.matchId),
      ControlClaims(matchId: e.matchId, scopes: const <String>{panelScopeMatch}, expiresS: 2000),
    );
    final Map<String, Object?> cuerpo = <String, Object?>{
      'team': 'away', 'name': 'Milan', 'formation': '4-4-2', 'coach': 'Ancelotti',
      'roster': 'Dorsal,Nombre\n1,Dida\n2,Cafu\n3,Maldini\n4,Gattuso\n13,Nesta\n21,Pirlo\n8,Seedorf\n22,Kaka\n10,Rui Costa\n7,Sheva\n11,Gila\n',
    };
    expect((await api.handle(post(token, cuerpo))).status, 403, reason: 'el QR Mando no edita plantillas');
    final ApiResponse ok = await api.handle(post('123456', cuerpo));
    expect(ok.status, 200);
    expect(e.away, 'MILAN');
    expect(e.lineups.teams[MatchTeam.away]!.coach, 'Ancelotti');
    expect((await api.handle(post('123456', <String, Object?>{...cuerpo, 'roster': '1 Solo'}))).status, 400);

    // El alineaciones.json del pod, el mismo formato que LineupBook.
    final File pod = File('${dir.path}/pod.json');
    LineupBook(file: pod).set(MatchTeam.home, buildTeam('Inter', '4-4-2', cuerpo['roster']! as String));
    e.importLineups(readPodLineups(pod));
    expect(e.home, 'INTER');
    expect(e.lineups.teams[MatchTeam.home]!.players, 11);
  });
}
