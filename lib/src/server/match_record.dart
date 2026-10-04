/// El partido guardado en el maestro (IOS-60), porte de `tools/match_record.py` del
/// repo football-ai con el cronómetro del ADR 0023.
///
/// Se guarda poco: la identidad del partido, los nombres, los goles y el cronómetro. El
/// cronómetro va como {accumulated_ms, running, started_rig_ms} dentro de su
/// `clock_domain`: en el MISMO dominio sigue en marcha al volver (un relevo o un
/// reinicio de la app con el mismo reloj del soporte); en otro, vuelve parado y con
/// `clock_restored`, porque comparar dos relojes distintos daría un salto inventado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:football_ai_capture/src/constants.dart';

class MatchRecordError implements Exception {
  MatchRecordError(this.message);

  final String message;

  @override
  String toString() => 'MatchRecordError: $message';
}

/// Lo que se guarda de un partido.
class MatchRecord {
  const MatchRecord({
    required this.matchId,
    required this.home,
    required this.away,
    required this.homeGoals,
    required this.awayGoals,
    required this.accumulatedMs,
    required this.running,
    required this.startedRigMs,
    required this.clockDomain,
  });

  final String matchId;
  final String home;
  final String away;
  final int homeGoals;
  final int awayGoals;

  /// Lo que llevaba corrido el cronómetro hasta su último arranque.
  final int accumulatedMs;
  final bool running;

  /// Cuándo arrancó, en el reloj de `clockDomain`. Solo vale si `running`.
  final int? startedRigMs;

  /// El reloj en el que vale `startedRigMs` (ADR 0023 §4).
  final String clockDomain;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': matchRecordVersion,
    'match_id': matchId,
    'home': home,
    'away': away,
    'home_goals': homeGoals,
    'away_goals': awayGoals,
    // `clock_ms` y `clock_running` como en el fichero del panel: quien lea con la
    // herramienta de Python entiende lo mismo.
    'clock_ms': accumulatedMs,
    'clock_running': running,
    'started_rig_ms': startedRigMs,
    'clock_domain': clockDomain,
  };

  /// Entero o nada: un campo roto no deja un partido a medias.
  factory MatchRecord.fromJson(Object? data) {
    if (data is! Map<String, Object?>) {
      throw MatchRecordError('no es un objeto JSON');
    }
    if (data['version'] != matchRecordVersion) {
      throw MatchRecordError('version ${data['version']}, se esperaba $matchRecordVersion');
    }
    final Object? corriendo = data['clock_running'];
    if (corriendo is! bool) {
      throw MatchRecordError('clock_running tiene que ser true o false');
    }
    final Object? inicio = data['started_rig_ms'];
    if (inicio != null && (inicio is! int || inicio < 0)) {
      throw MatchRecordError('started_rig_ms tiene que ser un entero no negativo o null');
    }
    final Object? dominio = data['clock_domain'];
    if (dominio is! String) {
      throw MatchRecordError('clock_domain tiene que ser un texto');
    }
    return MatchRecord(
      matchId: _text(data, 'match_id'),
      home: _text(data, 'home'),
      away: _text(data, 'away'),
      homeGoals: _count(data, 'home_goals'),
      awayGoals: _count(data, 'away_goals'),
      accumulatedMs: _count(data, 'clock_ms'),
      running: corriendo,
      startedRigMs: inicio as int?,
      clockDomain: dominio,
    );
  }
}

String _text(Map<String, Object?> data, String key) {
  final Object? valor = data[key];
  if (valor is! String || valor.isEmpty) {
    throw MatchRecordError('$key tiene que ser un texto no vacio');
  }
  return valor;
}

int _count(Map<String, Object?> data, String key) {
  final Object? valor = data[key];
  if (valor is! int || valor < 0) {
    throw MatchRecordError('$key tiene que ser un entero no negativo');
  }
  return valor;
}

/// El partido guardado en `file`, o null si todavía no hay fichero.
MatchRecord? loadRecord(File file) {
  if (!file.existsSync()) {
    return null;
  }
  try {
    return MatchRecord.fromJson(jsonDecode(file.readAsStringSync()));
  } on MatchRecordError catch (error) {
    throw MatchRecordError('${file.path}: ${error.message}');
  } on FormatException catch (error) {
    throw MatchRecordError('no se pudo leer ${file.path}: ${error.message}');
  } on FileSystemException catch (error) {
    throw MatchRecordError('no se pudo leer ${file.path}: ${error.message}');
  }
}

/// A un temporal y de golpe: un corte a mitad de escritura no puede dejar el fichero
/// roto, que el siguiente arranque se negaría a leer justo cuando más falta hace.
void saveRecord(File file, MatchRecord record) {
  final File temporal = File('${file.path}.tmp');
  try {
    file.parent.createSync(recursive: true);
    temporal.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
    temporal.renameSync(file.path);
  } on FileSystemException catch (error) {
    try {
      temporal.deleteSync();
    } on FileSystemException {
      // Si ni se creó, no hay nada que limpiar.
    }
    throw MatchRecordError('no se pudo guardar ${file.uri.pathSegments.last}: ${error.message}');
  }
}
