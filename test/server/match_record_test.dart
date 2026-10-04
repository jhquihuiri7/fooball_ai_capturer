/// El fichero del partido (IOS-60): ida y vuelta, rechazos y escritura atómica.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/server/match_record.dart';

const MatchRecord _registro = MatchRecord(
  matchId: 'm_a1b2c3',
  home: 'BELLAVISTA',
  away: 'PROGRESO',
  homeGoals: 2,
  awayGoals: 1,
  accumulatedMs: 754000,
  running: true,
  startedRigMs: 1200,
  clockDomain: 'soporte1',
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ios60r'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('ida y vuelta, y sin temporal suelto', () {
    final File f = File('${dir.path}/match.json');
    saveRecord(f, _registro);
    final MatchRecord leido = loadRecord(f)!;
    expect(leido.toJson(), _registro.toJson());
    expect(File('${f.path}.tmp').existsSync(), isFalse);
    // Los campos del panel de Python siguen ahí: clock_ms y clock_running.
    final Map<String, Object?> crudo = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    expect(crudo['clock_ms'], 754000);
    expect(crudo['clock_running'], isTrue);
  });

  test('sin fichero, null', () {
    expect(loadRecord(File('${dir.path}/no.json')), isNull);
  });

  test('rechaza otra versión y campos rotos, nombrando el campo', () {
    final Map<String, Object?> base = _registro.toJson();
    for (final (String campo, Object? valor) in <(String, Object?)>[
      ('version', 2),
      ('home', ''),
      ('home_goals', -1),
      ('clock_running', 'si'),
      ('started_rig_ms', -5),
      ('clock_domain', 3),
    ]) {
      final Map<String, Object?> roto = Map<String, Object?>.of(base)..[campo] = valor;
      expect(
        () => MatchRecord.fromJson(roto),
        throwsA(isA<MatchRecordError>().having((MatchRecordError e) => e.message, 'mensaje', contains(campo))),
        reason: campo,
      );
    }
  });

  test('un JSON roto en disco da un error legible', () {
    final File f = File('${dir.path}/match.json')..writeAsStringSync('{roto');
    expect(() => loadRecord(f), throwsA(isA<MatchRecordError>()));
  });
}
