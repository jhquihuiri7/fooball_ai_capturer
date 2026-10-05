/// Las alineaciones en el maestro (IOS-61), porte de la parte de `tools/lineup.py` que usa
/// la API: leer la lista que teclea el operador, montar el equipo, recolocarlo por
/// formación y cuál está al aire. Los mensajes de error son los de Python, en ASCII.
///
/// La lista es una línea por jugador, `dorsal nombre`, con el separador que traiga
/// (`1 Juan`, `4, Luis`, `10;Carlos`). Los N primeros son el once, en el orden en que se
/// pintan; el resto, suplentes. N sale de la formación (`4-4-2` son 1 + 10).
///
/// No es identificación de jugadores: es texto del operador que nunca se cruza con una
/// detección (ADR 0010).
library;

import 'dart:convert';
import 'dart:io';

import 'package:football_ai_capture/src/match_state.dart';

/// Líneas de campo como mucho, portero aparte (`MAX_FORMATION_LINES`).
const int lineupMaxFormationLines = 5;

/// Jugadores por línea como mucho (`MAX_PER_LINE`).
const int lineupMaxPerLine = 5;

/// Titulares, portero incluido: de fútbol sala a fútbol 11 (`MIN_STARTERS`, `MAX_STARTERS`).
const int lineupMinStarters = 5;
const int lineupMaxStarters = 11;

/// Suplentes como mucho (`MAX_SUBSTITUTES`).
const int lineupMaxSubstitutes = 12;

/// Dorsal más alto: dos cifras, lo que cabe en el círculo (`MAX_NUMBER`).
const int lineupMaxNumber = 99;

/// Largo máximo de un nombre, en caracteres (`MAX_NAME_CHARS`).
const int lineupMaxNameChars = 28;

/// Largo máximo de la lista entera (`MAX_ROSTER_CHARS`).
const int lineupMaxRosterChars = 4000;

/// Lo que se cita de una línea rota en el error.
const int _quotedLineChars = 40;

final RegExp _rosterLine = RegExp(r'^(\d{1,2})(?!\d)\s*[.,;:\-]?\s*(.*)$');
final RegExp _formation = RegExp(r'^\d(-\d)*$');

/// Separadores de columna de un CSV o una hoja pegada; lo que va tras el nombre se ignora.
final RegExp _columns = RegExp('[,;\t]');

/// Los saltos de línea de `str.splitlines` de Python.
final RegExp _lineBreaks = RegExp('\r\n|[\n\r\u000b\u000c\u001c\u001d\u001e\u0085  ]');
final RegExp _anyDigit = RegExp(r'\p{Nd}', unicode: true);

class LineupError implements Exception {
  LineupError(this.message);

  /// Para el operador, en ASCII.
  final String message;

  @override
  String toString() => 'LineupError: $message';
}

class RosterPlayer {
  const RosterPlayer(this.number, this.name);

  final int number;
  final String name;

  Map<String, Object?> toJson() => <String, Object?>{'number': number, 'name': name};

  @override
  bool operator ==(Object other) => other is RosterPlayer && other.number == number && other.name == name;

  @override
  int get hashCode => Object.hash(number, name);
}

/// Una alineación válida: se valida al construirla, no existe una a medias.
class Team {
  Team({
    required this.name,
    required this.formation,
    required List<RosterPlayer> starters,
    List<RosterPlayer> substitutes = const <RosterPlayer>[],
    this.coach = '',
  }) : starters = List<RosterPlayer>.unmodifiable(starters),
       substitutes = List<RosterPlayer>.unmodifiable(substitutes) {
    _checkName(name, 'el nombre del equipo');
    if (coach.isNotEmpty) {
      _checkName(coach, 'el nombre del DT');
    }
    final int esperados = parseFormation(formation).fold(0, (int a, int b) => a + b) + 1;
    if (this.starters.length != esperados) {
      throw LineupError(
        'la formacion $formation pide $esperados titulares y hay ${this.starters.length}',
      );
    }
    if (this.substitutes.length > lineupMaxSubstitutes) {
      throw LineupError(
        'como mucho $lineupMaxSubstitutes suplentes; hay ${this.substitutes.length}',
      );
    }
    final Set<int> vistos = <int>{};
    for (final RosterPlayer p in <RosterPlayer>[...this.starters, ...this.substitutes]) {
      if (p.number < 1 || p.number > lineupMaxNumber) {
        throw LineupError('dorsal ${p.number} fuera de rango (1-$lineupMaxNumber)');
      }
      if (!vistos.add(p.number)) {
        throw LineupError('el dorsal ${p.number} esta repetido');
      }
      _checkName(p.name, 'el nombre del ${p.number}');
    }
  }

  factory Team.fromJson(Object? data) {
    if (data is! Map<String, Object?>) {
      throw LineupError('cada equipo tiene que ser un objeto');
    }
    final Object? titulares = data['starters'];
    final Object suplentes = data['substitutes'] ?? <Object?>[];
    if (data['name'] is! String ||
        data['formation'] is! String ||
        titulares is! List<Object?> ||
        suplentes is! List<Object?>) {
      throw LineupError('equipo mal formado');
    }
    return Team(
      name: data['name']! as String,
      formation: data['formation']! as String,
      coach: (data['coach'] ?? '').toString(),
      starters: titulares.map(_player).toList(),
      substitutes: suplentes.map(_player).toList(),
    );
  }

  final String name;
  final String formation;
  final List<RosterPlayer> starters;
  final List<RosterPlayer> substitutes;
  final String coach;

  List<int> get lines => parseFormation(formation);

  int get players => starters.length + substitutes.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'formation': formation,
    'coach': coach,
    'starters': <Map<String, Object?>>[for (final RosterPlayer p in starters) p.toJson()],
    'substitutes': <Map<String, Object?>>[for (final RosterPlayer p in substitutes) p.toJson()],
  };
}

RosterPlayer _player(Object? data) {
  if (data is! Map<String, Object?>) {
    throw LineupError('cada jugador tiene que ser un objeto');
  }
  final Object? numero = data['number'];
  final Object? nombre = data['name'];
  if (numero is! int || nombre is! String) {
    throw LineupError('equipo mal formado: jugador $data');
  }
  return RosterPlayer(numero, nombre);
}

/// Los primeros `n` caracteres (puntos de código, como en Python).
String _head(String text, int n) => String.fromCharCodes(text.runes.take(n));

void _checkName(String name, String what) {
  if (name.trim().isEmpty) {
    throw LineupError('falta $what');
  }
  if (name.runes.length > lineupMaxNameChars) {
    throw LineupError(
      '$what pasa de $lineupMaxNameChars caracteres: ${_head(name, lineupMaxNameChars)}...',
    );
  }
}

/// Espacios colapsados y sin comillas de CSV alrededor (`_clean`).
String _clean(String text) {
  final String colapsado = text.trim().split(RegExp(r'\s+')).where((String s) => s.isNotEmpty).join(' ');
  return colapsado.replaceAll(RegExp('^["\']+|["\']+\$'), '').trim();
}

/// `"4-2-3-1"` → `[4, 2, 3, 1]`, de atrás hacia delante, o [LineupError].
List<int> parseFormation(String text) {
  final String limpio = text.trim();
  if (!_formation.hasMatch(limpio)) {
    throw LineupError("formacion no valida: '$text' (ejemplo: 4-4-2)");
  }
  final List<int> lineas = limpio.split('-').map(int.parse).toList();
  if (lineas.length > lineupMaxFormationLines ||
      !lineas.every((int n) => n >= 1 && n <= lineupMaxPerLine)) {
    throw LineupError(
      "formacion no valida: '$text' (hasta $lineupMaxFormationLines lineas "
      'de 1 a $lineupMaxPerLine jugadores)',
    );
  }
  final int total = lineas.fold(0, (int a, int b) => a + b) + 1;
  if (total < lineupMinStarters || total > lineupMaxStarters) {
    throw LineupError(
      "formacion no valida: '$text' (de $lineupMinStarters a $lineupMaxStarters jugadores)",
    );
  }
  return lineas;
}

/// La lista del operador, en orden. Los errores dicen la línea. Se saltan las vacías y,
/// solo si es la primera, una sin cifras (la cabecera de un CSV).
List<RosterPlayer> parseRoster(String text) {
  if (text.runes.length > lineupMaxRosterChars) {
    throw LineupError(
      'la lista pasa de $lineupMaxRosterChars caracteres: no parece una plantilla',
    );
  }
  final List<RosterPlayer> jugadores = <RosterPlayer>[];
  bool primera = true;
  String cuerpo = text;
  while (cuerpo.startsWith('﻿')) {
    cuerpo = cuerpo.substring(1);
  }
  final List<String> lineas = cuerpo.split(_lineBreaks);
  for (int i = 0; i < lineas.length; i++) {
    final String linea = lineas[i].trim();
    if (linea.isEmpty) {
      continue;
    }
    if (primera && !_anyDigit.hasMatch(linea)) {
      primera = false;
      continue;
    }
    primera = false;
    final RegExpMatch? m = _rosterLine.firstMatch(linea);
    if (m == null) {
      throw LineupError(
        "linea ${i + 1}: se espera 'dorsal nombre' y llego '${_head(linea, _quotedLineChars)}'",
      );
    }
    final String nombre = _clean(m.group(2)!.split(_columns).first);
    if (nombre.isEmpty) {
      throw LineupError('linea ${i + 1}: falta el nombre del ${m.group(1)}');
    }
    jugadores.add(RosterPlayer(int.parse(m.group(1)!), nombre));
  }
  return jugadores;
}

/// La alineación a partir de lo que llega del editor. Los N primeros, titulares.
Team buildTeam(String name, String formation, String roster, {String coach = ''}) {
  final int titulares = parseFormation(formation).fold(0, (int a, int b) => a + b) + 1;
  final List<RosterPlayer> jugadores = parseRoster(roster);
  if (jugadores.length < titulares) {
    throw LineupError(
      'la formacion ${formation.trim()} pide $titulares titulares '
      'y la lista trae ${jugadores.length}',
    );
  }
  return Team(
    name: _clean(name).toUpperCase(),
    formation: formation.trim(),
    starters: jugadores.sublist(0, titulares),
    substitutes: jugadores.sublist(titulares),
    coach: _clean(coach),
  );
}

/// La lista tal como la escribiría el operador; [buildTeam] la lee de vuelta igual.
String rosterText(Team team) =>
    <RosterPlayer>[...team.starters, ...team.substitutes].map((RosterPlayer p) => '${p.number} ${p.name}').join('\n');

/// El mismo equipo con otra formación: los mismos jugadores en el mismo orden, y los
/// titulares los que pida la nueva (lo que hace `match/lineup` con `formation`).
Team relineup(Team team, String formation) =>
    buildTeam(team.name, formation, rosterText(team), coach: team.coach);

/// Las dos alineaciones y cuál está al aire. Con `file`, cada cambio se escribe a disco
/// antes de aplicarse (temporal y renombrado); sin él, se pierde al reiniciar.
class LineupBook {
  LineupBook({this.file});

  /// Lee el fichero del partido; que no exista es lo normal en el primer arranque.
  factory LineupBook.load(File file) {
    final LineupBook libro = LineupBook(file: file);
    if (!file.existsSync()) {
      return libro;
    }
    final Object? datos;
    try {
      datos = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw LineupError('no se pudo leer ${file.path}: ${e.message}');
    } on FileSystemException catch (e) {
      throw LineupError('no se pudo leer ${file.path}: ${e.message}');
    }
    if (datos is! Map<String, Object?>) {
      throw LineupError('${file.path} no es un objeto JSON');
    }
    for (final MatchTeam lado in MatchTeam.values) {
      if (datos[lado.name] != null) {
        libro._teams[lado] = Team.fromJson(datos[lado.name]);
      }
    }
    return libro;
  }

  final File? file;
  final Map<MatchTeam, Team> _teams = <MatchTeam, Team>{};
  MatchTeam? _onAir;

  Map<MatchTeam, Team> get teams => Map<MatchTeam, Team>.unmodifiable(_teams);

  MatchTeam? get onAirSide => _onAir;

  /// La tarjeta al aire, si hay una.
  (MatchTeam, Team)? get onAir => _onAir == null ? null : (_onAir!, _teams[_onAir]!);

  void set(MatchTeam side, Team team) {
    final Map<MatchTeam, Team> nuevos = <MatchTeam, Team>{..._teams, side: team};
    _save(nuevos);
    _teams
      ..clear()
      ..addAll(nuevos);
  }

  /// Muestra u oculta la tarjeta de un equipo. Solo una a la vez; sin alineación, nada.
  void toggle(MatchTeam side) => setOnAir(_onAir == side ? null : side);

  /// Saca al aire la de `side`, o ninguna con null. Sin interruptor: con dos mandos,
  /// repetir la orden no la deshace. Sin alineación de ese equipo no hace nada.
  void setOnAir(MatchTeam? side) {
    if (side == null || _teams.containsKey(side)) {
      _onAir = side;
    }
  }

  /// Lo que la página necesita: poco, sin las listas (`summary`).
  Map<String, Object?> summary() => <String, Object?>{
    for (final MatchTeam lado in MatchTeam.values)
      lado.name: switch (_teams[lado]) {
        null => null,
        final Team t => <String, Object?>{'formation': t.formation, 'players': t.players},
      },
    'on_air': _onAir?.name,
    'persistent': file != null,
  };

  void _save(Map<MatchTeam, Team> teams) {
    final File? destino = file;
    if (destino == null) {
      return;
    }
    final File temporal = File('${destino.path}.tmp');
    try {
      destino.parent.createSync(recursive: true);
      temporal.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          for (final MapEntry<MatchTeam, Team> e in teams.entries) e.key.name: e.value.toJson(),
        }),
        flush: true,
      );
      temporal.renameSync(destino.path);
    } on FileSystemException catch (e) {
      try {
        temporal.deleteSync();
      } on FileSystemException {
        // Si ni se creó, no hay nada que limpiar.
      }
      throw LineupError('no se pudo guardar ${destino.uri.pathSegments.last}: ${e.message}');
    }
  }
}
