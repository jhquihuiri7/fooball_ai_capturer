/// La migración única del partido local al del maestro (IOS-87, ADR 0017 enmienda).
///
/// Antes de la arquitectura B, el marcador vivía en el móvil del mando, en
/// `shared_preferences` («zero.match», lib/src/match_state.dart). Ahora el partido con
/// autoridad está en el maestro (MatchEngine). Al abrir el maestro por primera vez tras
/// actualizar, si no hay partido guardado y sí «zero.match», se pasa:
/// - marcador y nombres, tal cual;
/// - el cronómetro, PARADO y con `clock_restored`: lo acumulado más lo que corría hasta
///   ahora (la hora de pared de «zero.match» es la única que hay), con un tope; un reloj
///   de otro dominio no puede seguir en marcha (ADR 0023 §4);
/// - las plantillas `Player{número, nombre, puesto}` a la lista ordenada de
///   tools/lineup.py: el once en el orden de la formación local (portero y líneas de
///   atrás hacia delante, Formation.lineUp) y el resto de suplentes.
///
/// Decisión (anotada en PROGRESS): el MatchState local se QUEDA para un móvil que lleva
/// el marcador sin soporte (el modo de un solo móvil); la migración solo lee
/// «zero.match» y deja una marca para no repetirla.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_record.dart';

/// El `clock_domain` de un partido migrado: ninguno vivo coincide con él, así que el
/// motor lo abre parado y con `clock_restored`.
const String migratedClockDomain = 'migrado0';

/// Lo más que se suma al cronómetro por lo que corría al actualizar: un partido no dura
/// más, y una hora de pared rara no puede inventar un reloj de días.
const Duration migrationMaxRunningGap = Duration(hours: 3);

class MigrationResult {
  const MigrationResult({required this.record, required this.teams});

  final MatchRecord record;
  final Map<MatchTeam, Team> teams;
}

/// El partido del maestro a partir de «zero.match». null si no se puede leer.
/// `nowWallMs`: hora de pared, solo para lo que corría el reloj local (que guardaba
/// hora de pared).
MigrationResult? migrateLocalMatch(String raw, {required String matchId, required int nowWallMs}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final Map<String, Object?> j = decoded;
  String nombre(String k, String porDefecto) {
    final Object? v = j[k];
    return v is String && v.trim().isNotEmpty ? v.trim() : porDefecto;
  }

  int entero(String k) => j[k] is int ? max(0, j[k]! as int) : 0;

  int acumulado = entero('baseMs');
  final Object? desde = j['runningSinceMs'];
  final bool corria = desde is int;
  if (desde is int) {
    acumulado += min(max(0, nowWallMs - desde), migrationMaxRunningGap.inMilliseconds);
  }
  final String local = nombre('homeName', 'LOCAL').toUpperCase();
  final String visitante = nombre('awayName', 'VISITANTE').toUpperCase();

  final Map<MatchTeam, Team> equipos = <MatchTeam, Team>{};
  for (final MatchTeam lado in MatchTeam.values) {
    final String pre = lado == MatchTeam.home ? 'home' : 'away';
    final Object? squad = j['${pre}Squad'];
    if (squad is! List || squad.isEmpty) {
      continue;
    }
    try {
      final List<Player> jugadores = squad.cast<Map<String, Object?>>().map(Player.fromJson).toList();
      final String formacion = nombre('${pre}Formation', matchFormations[1]);
      final Formation f = formationByName(formacion);
      final List<Player> once = f.lineUp(jugadores).map((PlayerSlot s) => s.player).toList();
      final List<Player> resto = jugadores.where((Player p) => !once.contains(p)).toList();
      final String lista = <Player>[...once, ...resto].map((Player p) => '${p.number} ${p.name}').join('\n');
      equipos[lado] = buildTeam(lado == MatchTeam.home ? local : visitante, f.name, lista);
    } on Object {
      // Una plantilla que no cumple las reglas de la referencia no tumba la migración:
      // el marcador pasa igual y la plantilla se vuelve a teclear.
      continue;
    }
  }
  return MigrationResult(
    record: MatchRecord(
      matchId: matchId,
      home: local,
      away: visitante,
      homeGoals: entero('homeGoals'),
      awayGoals: entero('awayGoals'),
      accumulatedMs: acumulado,
      // «En marcha» en otro dominio: el motor lo abre parado y con clock_restored.
      running: corria,
      startedRigMs: corria ? 0 : null,
      clockDomain: migratedClockDomain,
    ),
    teams: equipos,
  );
}

/// Escribe el partido migrado en la carpeta del maestro, si todavía no hay ninguno.
/// Devuelve si migró.
bool applyMigration(Directory directory, MigrationResult m, {required String matchFileName}) {
  final File partido = File('${directory.path}/$matchFileName');
  if (partido.existsSync()) {
    return false;
  }
  saveRecord(partido, m.record);
  final LineupBook libro = LineupBook(file: File('${directory.path}/$lineupsFileName'));
  for (final MapEntry<MatchTeam, Team> e in m.teams.entries) {
    libro.set(e.key, e.value);
  }
  return true;
}

/// Importa el alineaciones.json del pod (`live_panel.py --lineups`): el mismo formato
/// que LineupBook. Sustituye las plantillas del maestro y pasa los nombres al marcador.
Map<MatchTeam, Team> readPodLineups(File file) => LineupBook.load(file).teams;
