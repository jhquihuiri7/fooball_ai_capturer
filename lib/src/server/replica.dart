/// La pizarra replicada (IOS-82, ADR 0023 §7): lo que el maestro manda al esclavo (y,
/// con IOS-65, al VPS) para que el partido sobreviva a su caída.
///
/// Un JSON de ≤64 KiB, SIN secretos (el del mando se deriva en los dos móviles): el
/// partido (MatchRecord), las alineaciones, el estado del DTO (boot, rev), el term y un
/// `seq` que sube con cada réplica dentro del term, el instante y su `clock_domain`, y las
/// claves de idempotencia recientes. Manda la más fresca: se compara (term, seq).
library;

import 'dart:convert';
import 'dart:io';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/idempotency.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/match_record.dart';

/// Versión del formato de la réplica.
const int replicaVersion = 1;

class StateReplica {
  const StateReplica({
    required this.matchId,
    required this.term,
    required this.seq,
    required this.rigMs,
    required this.clockDomain,
    required this.boot,
    required this.rev,
    required this.match,
    required this.lineups,
    required this.idempotency,
  });

  final String matchId;
  final int term;
  final int seq;
  final int rigMs;
  final String clockDomain;
  final String boot;
  final int rev;
  final MatchRecord match;
  final Map<String, Object?> lineups;
  final List<Map<String, Object?>> idempotency;

  /// Más fresca que `other` (ADR 0023 §7): por term y, dentro del mismo term, por `seq`
  /// si es el mismo arranque del maestro. Un maestro que reinicia la app vuelve a empezar
  /// `seq` en 1 con el mismo term: entre arranques manda el `rig_ms`, que en el mismo
  /// dominio de reloj sigue corriendo; con otro dominio no hay con qué comparar y gana la
  /// que llega (lo contrario dejaba al esclavo con el marcador viejo hasta superar el
  /// `seq` de antes).
  bool fresherThan(StateReplica? other) {
    if (other == null || term != other.term) {
      return other == null || term > other.term;
    }
    if (boot == other.boot) {
      return seq > other.seq;
    }
    return clockDomain != other.clockDomain || rigMs > other.rigMs;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': replicaVersion,
    'match_id': matchId,
    'term': term,
    'seq': seq,
    'rig_ms': rigMs,
    'clock_domain': clockDomain,
    'boot': boot,
    'rev': rev,
    'match': match.toJson(),
    'lineups': lineups,
    'calib': null,
    'idempotency': idempotency,
  };

  String encode() => jsonEncode(toJson());

  static StateReplica? decode(String raw) {
    if (raw.length > replicaMaxBytes) {
      return null;
    }
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map<String, Object?> || j['version'] != replicaVersion) {
        return null;
      }
      return StateReplica(
        matchId: j['match_id']! as String,
        term: j['term']! as int,
        seq: j['seq']! as int,
        rigMs: j['rig_ms']! as int,
        clockDomain: j['clock_domain']! as String,
        boot: j['boot']! as String,
        rev: j['rev']! as int,
        match: MatchRecord.fromJson(j['match']),
        lineups: (j['lineups'] as Map<String, Object?>?) ?? <String, Object?>{},
        idempotency: ((j['idempotency'] as List<Object?>?) ?? <Object?>[]).cast<Map<String, Object?>>(),
      );
    } on Object {
      return null;
    }
  }

  /// La réplica del maestro ahora. `seq` lo lleva quien replica.
  static StateReplica fromEngine(
    MatchEngine engine, {
    required int term,
    required int seq,
    required int rigMs,
    required String clockDomain,
    IdempotencyCache? idempotency,
  }) {
    final List<Map<String, Object?>> claves = <Map<String, Object?>>[];
    if (idempotency != null) {
      idempotency
          .recent(windowMs: idempotencyReplicaWindow.inMilliseconds, max: idempotencyReplicaMax)
          .forEach((String k, (int, StoredResponse) v) {
            final Object? cuerpo = _json(v.$2.body);
            claves.add(<String, Object?>{
              'key': k,
              'status': v.$2.status,
              'rev': cuerpo is Map<String, Object?> ? cuerpo['rev'] : null,
            });
          });
    }
    return StateReplica(
      matchId: engine.matchId,
      term: term,
      seq: seq,
      rigMs: rigMs,
      clockDomain: clockDomain,
      boot: engine.boot,
      rev: engine.rev,
      match: engine.record(),
      lineups: <String, Object?>{
        for (final MapEntry<MatchTeam, Team> e in engine.lineups.teams.entries) e.key.name: e.value.toJson(),
        'on_air': engine.lineups.onAirSide?.name,
      },
      idempotency: claves,
    );
  }

  static Object? _json(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on Object {
      return null;
    }
  }
}

/// Lo que el esclavo guarda de la pizarra: la más fresca, en memoria y en disco.
class ReplicaStore {
  ReplicaStore(this.file) {
    if (file.existsSync()) {
      try {
        _latest = StateReplica.decode(file.readAsStringSync());
      } on FileSystemException {
        _latest = null;
      }
    }
  }

  final File file;
  StateReplica? _latest;
  int accepted = 0;
  int stale = 0;

  StateReplica? get latest => _latest;

  /// Se queda con `raw` si es más fresca; devuelve si la aceptó.
  bool accept(String raw) {
    final StateReplica? r = StateReplica.decode(raw);
    if (r == null || !r.fresherThan(_latest)) {
      stale += 1;
      return false;
    }
    _latest = r;
    accepted += 1;
    final File tmp = File('${file.path}.tmp');
    try {
      file.parent.createSync(recursive: true);
      tmp.writeAsStringSync(raw, flush: true);
      tmp.renameSync(file.path);
    } on FileSystemException {
      // En memoria sigue valiendo; el disco es la red de seguridad.
    }
    return true;
  }
}
