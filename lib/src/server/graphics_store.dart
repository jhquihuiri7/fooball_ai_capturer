/// Lo que el operador cambia del gráfico desde el mando y es del campeonato, no de un
/// partido (ADR 0027): los textos de la franja y el icono del campeonato; y los escudos de
/// los equipos, por su nombre (ADR 0028).
///
/// Vive en la carpeta del partido, en `grafico.json`, `campeonato.img` y `escudos/`, pero no
/// se aparta con el partido viejo: el partido siguiente del mismo campeonato los conserva.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';

/// Un cambio del gráfico que no se acepta, con el código HTTP y el porqué para el mando.
class GraphicsError implements Exception {
  GraphicsError(this.message, {this.status = 400});

  final String message;
  final int status;

  @override
  String toString() => 'GraphicsError: $message';
}

/// Lo que se edita de la franja: las dos líneas del claim y el título y el subtítulo de
/// cada uno de los tres mensajes del centro (`StripTexts` de overlay_preview.py).
@immutable
class StripTexts {
  StripTexts({required List<String> claim, required List<(String, String)> slots})
    : claim = List<String>.unmodifiable(claim),
      slots = List<(String, String)>.unmodifiable(slots) {
    if (claim.length != 2 || slots.length != OverlaySpec.stripSlotsDefault.length) {
      throw GraphicsError(
        'la franja lleva 2 líneas de claim y ${OverlaySpec.stripSlotsDefault.length} mensajes',
      );
    }
    for (final String texto in <String>[...claim, for (final (String a, String b) in slots) ...<String>[a, b]]) {
      if (texto.length > OverlaySpec.stripTextMaxChars || texto.contains('\n')) {
        throw GraphicsError(
          'cada texto de la franja, hasta ${OverlaySpec.stripTextMaxChars} caracteres y sin saltos',
        );
      }
    }
  }

  /// Los de la maqueta, mientras el operador no los cambie.
  factory StripTexts.defaults() =>
      StripTexts(claim: OverlaySpec.stripClaimDefault, slots: OverlaySpec.stripSlotsDefault);

  /// Lee `{"claim": [a, b], "slots": [[t, s], …]}`; [GraphicsError] si no vale.
  factory StripTexts.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('se espera {claim, slots}');
    }
    final Object? claim = json['claim'];
    final Object? slots = json['slots'];
    if (claim is! List<Object?> || claim.any((Object? t) => t is! String)) {
      throw GraphicsError('claim tiene que ser una lista de 2 textos');
    }
    if (slots is! List<Object?> ||
        slots.any((Object? m) => m is! List<Object?> || m.length != 2 || m.any((Object? t) => t is! String))) {
      throw GraphicsError('slots tiene que ser una lista de [título, subtítulo]');
    }
    return StripTexts(
      claim: claim.cast<String>(),
      slots: <(String, String)>[
        for (final Object? m in slots) _par(m! as List<Object?>),
      ],
    );
  }

  static (String, String) _par(List<Object?> m) => (m[0]! as String, m[1]! as String);

  final List<String> claim;
  final List<(String, String)> slots;

  Map<String, Object?> toJson() => <String, Object?>{
    'claim': claim,
    'slots': <List<String>>[for (final (String t, String s) in slots) <String>[t, s]],
  };

  @override
  bool operator ==(Object other) =>
      other is StripTexts && listEquals(other.claim, claim) && listEquals(other.slots, slots);

  @override
  int get hashCode => Object.hash(Object.hashAll(claim), Object.hashAll(slots));
}

/// Un texto de 1 a `max` caracteres (o de 0 si `vacio`), sin saltos de línea y sin
/// espacios de sobra en los bordes; [GraphicsError] si no.
String _texto(Object? valor, String campo, int max, {bool vacio = false}) {
  final String limpio = valor is String ? valor.trim() : '';
  if (valor is! String || (limpio.isEmpty && !vacio) || limpio.length > max || limpio.contains('\n')) {
    throw GraphicsError('$campo: ${vacio ? 'hasta' : 'de 1 a'} $max caracteres, sin saltos');
  }
  return limpio;
}

/// El próximo partido (ADR 0029): los dos equipos, cuándo y dónde, en texto libre.
@immutable
class NextMatch {
  const NextMatch({required this.home, required this.away, required this.when, this.venue = ''});

  /// Lee `{home, away, when, venue}`; [GraphicsError] si no vale.
  factory NextMatch.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('se espera {home, away, when, venue}');
    }
    return NextMatch(
      home: _texto(json['home'], 'home', matchTeamNameMaxChars),
      away: _texto(json['away'], 'away', matchTeamNameMaxChars),
      when: _texto(json['when'], 'when', OverlaySpec.nextTextMaxChars),
      venue: _texto(json['venue'] ?? '', 'venue', OverlaySpec.nextTextMaxChars, vacio: true),
    );
  }

  final String home;
  final String away;
  final String when;
  final String venue;

  Map<String, Object?> toJson() => <String, Object?>{'home': home, 'away': away, 'when': when, 'venue': venue};
}

/// Un partido de la jornada (ADR 0030): los equipos, la hora y la fase, en texto libre.
@immutable
class Fixture {
  const Fixture({required this.home, required this.away, required this.time, this.subtitle = ''});

  /// Lee `{home, away, time, subtitle}`; [GraphicsError] si no vale.
  factory Fixture.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('cada partido es {home, away, time, subtitle}');
    }
    return Fixture(
      home: _texto(json['home'], 'home', matchTeamNameMaxChars),
      away: _texto(json['away'], 'away', matchTeamNameMaxChars),
      time: _texto(json['time'], 'time', OverlaySpec.fixtures['time_max_chars']!),
      subtitle: _texto(json['subtitle'] ?? '', 'subtitle', OverlaySpec.fixtures['subtitle_max_chars']!, vacio: true),
    );
  }

  /// La jornada entera de `{matches: [...]}`: de 1 a `OverlaySpec.fixtures['max']` partidos.
  static List<Fixture> listFromJson(Object? json) {
    final Object? partidos = json is Map<String, Object?> ? json['matches'] : null;
    final int tope = OverlaySpec.fixtures['max']!;
    if (partidos is! List<Object?> || partidos.isEmpty || partidos.length > tope) {
      throw GraphicsError('matches: de 1 a $tope partidos');
    }
    return <Fixture>[for (final Object? p in partidos) Fixture.fromJson(p)];
  }

  final String home;
  final String away;
  final String time;
  final String subtitle;

  Map<String, Object?> toJson() => <String, Object?>{'home': home, 'away': away, 'time': time, 'subtitle': subtitle};

  @override
  bool operator ==(Object other) =>
      other is Fixture && other.home == home && other.away == away && other.time == time && other.subtitle == subtitle;

  @override
  int get hashCode => Object.hash(home, away, time, subtitle);
}

/// Quién habla en la sección de entrevistas y su cargo (ADR 0030); los dos pueden ir vacíos.
@immutable
class Interview {
  const Interview({this.name = '', this.role = ''});

  /// Lee `{name, role}`; [GraphicsError] si no vale.
  factory Interview.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('se espera {name, role}');
    }
    return Interview(
      name: _texto(json['name'] ?? '', 'name', OverlaySpec.nextTextMaxChars, vacio: true),
      role: _texto(json['role'] ?? '', 'role', OverlaySpec.nextTextMaxChars, vacio: true),
    );
  }

  final String name;
  final String role;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'role': role};

  @override
  bool operator ==(Object other) => other is Interview && other.name == name && other.role == role;

  @override
  int get hashCode => Object.hash(name, role);
}

/// Una franja guardada (ADR 0029): su nombre y sus textos.
@immutable
class StripPreset {
  const StripPreset(this.name, this.texts);

  /// Lee `{name, claim, slots}`; [GraphicsError] si no vale.
  factory StripPreset.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('se espera {name, claim, slots}');
    }
    return StripPreset(_texto(json['name'], 'name', stripPresetNameMaxChars), StripTexts.fromJson(json));
  }

  final String name;
  final StripTexts texts;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, ...texts.toJson()};
}

/// El escudo de un equipo (ADR 0028): su fichero, PNG o JPEG, y su versión, que cambia con
/// cada subida para que el gráfico y el mando sepan que hay que volver a leerlo.
@immutable
class TeamCrest {
  const TeamCrest({required this.mime, required this.file, required this.rev});

  final String mime;
  final File file;
  final int rev;
}

class GraphicsStore {
  /// Lee lo guardado en `directory`; un fichero roto no impide arrancar: se empieza con
  /// los textos de partida y sin icono.
  GraphicsStore(this.directory) {
    final File f = _file;
    if (f.existsSync()) {
      try {
        final Object? json = jsonDecode(f.readAsStringSync());
        if (json is Map<String, Object?>) {
          strip = StripTexts.fromJson(json['strip']);
          final Object? tipo = json['icon_mime'];
          iconMime = tipo is String && iconFile.existsSync() ? tipo : null;
          final Object? jornada = json['fixtures'];
          if (jornada is List<Object?> && jornada.isNotEmpty) {
            fixtures = Fixture.listFromJson(<String, Object?>{'matches': jornada});
          }
          final Object? entrevista = json['interview'];
          if (entrevista != null) {
            interview = Interview.fromJson(entrevista);
          }
          final Object? proximo = json['next_match'];
          nextMatch = proximo == null ? null : NextMatch.fromJson(proximo);
          final Object? franjas = json['strip_presets'];
          if (franjas is List<Object?>) {
            stripPresets = <StripPreset>[for (final Object? f in franjas) StripPreset.fromJson(f)];
          }
          final Object? puesta = json['strip_preset'];
          stripPreset = puesta is String && _preset(puesta) != null ? puesta : null;
          final Object? escudos = json['crests'];
          if (escudos is Map<String, Object?>) {
            for (final MapEntry<String, Object?> e in escudos.entries) {
              final Object? mime = e.value;
              if (mime is String && _crestFile(e.key).existsSync()) {
                _crests[e.key] = TeamCrest(mime: mime, file: _crestFile(e.key), rev: ++_crestSeq);
              }
            }
          }
        }
      } on Object {
        strip = StripTexts.defaults();
        iconMime = null;
        _crests.clear();
        nextMatch = null;
        fixtures = const <Fixture>[];
        interview = const Interview();
        stripPresets = <StripPreset>[];
        stripPreset = null;
      }
    }
    iconRev = iconMime == null ? 0 : 1;
    if (stripPresets.isEmpty) {
      // Sin ninguna guardada, la de partida lleva los textos que hubiera (ADR 0029).
      stripPresets = <StripPreset>[StripPreset(stripPresetDefaultName, strip)];
      stripPreset = stripPresetDefaultName;
    }
  }

  /// El próximo partido, si el operador lo guardó (ADR 0029).
  NextMatch? nextMatch;

  /// Los partidos de la jornada (ADR 0030), vacía si no se cargó.
  List<Fixture> fixtures = const <Fixture>[];

  /// Quién habla en la sección de entrevistas (ADR 0030).
  Interview interview = const Interview();

  void setFixtures(List<Fixture> partidos) {
    fixtures = List<Fixture>.unmodifiable(partidos);
    _save();
  }

  void setInterview(Interview entrevista) {
    interview = entrevista;
    _save();
  }

  /// Las franjas guardadas, en el orden del mando, y el nombre de la que está puesta (null
  /// si los textos se editaron a mano).
  List<StripPreset> stripPresets = <StripPreset>[];
  String? stripPreset;

  StripPreset? _preset(String name) {
    final String clave = name.trim().toUpperCase();
    for (final StripPreset p in stripPresets) {
      if (p.name.toUpperCase() == clave) {
        return p;
      }
    }
    return null;
  }

  void setNextMatch(NextMatch next) {
    nextMatch = next;
    _save();
  }

  /// Guarda una franja: sustituye a la del mismo nombre o a `previousName` (renombrarla), o
  /// la añade al final. Si es la que está puesta, la franja cambia con ella.
  void savePreset(StripPreset preset, {String? previousName}) {
    final StripPreset? vieja = _preset(previousName ?? preset.name);
    final StripPreset? choca = _preset(preset.name);
    if (choca != null && choca != vieja) {
      throw GraphicsError('ya hay una franja que se llama ${choca.name}', status: 409);
    }
    if (vieja == null && stripPresets.length >= stripPresetsMax) {
      throw GraphicsError('caben $stripPresetsMax franjas: borra una antes', status: 409);
    }
    if (vieja == null) {
      stripPresets = <StripPreset>[...stripPresets, preset];
    } else {
      stripPresets = <StripPreset>[for (final StripPreset p in stripPresets) p == vieja ? preset : p];
      if (stripPreset != null && stripPreset!.toUpperCase() == vieja.name.toUpperCase()) {
        stripPreset = preset.name;
        strip = preset.texts;
      }
    }
    _save();
  }

  /// Borra la franja `name`; false si no existía. Los textos puestos se quedan.
  bool deletePreset(String name) {
    final StripPreset? p = _preset(name);
    if (p == null) {
      return false;
    }
    stripPresets = <StripPreset>[for (final StripPreset q in stripPresets) if (q != p) q];
    if (stripPreset != null && stripPreset!.toUpperCase() == p.name.toUpperCase()) {
      stripPreset = null;
    }
    _save();
    return true;
  }

  /// Pone los textos de la franja `name`; false si no existe.
  bool selectPreset(String name) {
    final StripPreset? p = _preset(name);
    if (p == null) {
      return false;
    }
    strip = p.texts;
    stripPreset = p.name;
    _save();
    return true;
  }

  /// Los escudos por la clave de su equipo (`crestKey`), y la última versión dada.
  final Map<String, TeamCrest> _crests = <String, TeamCrest>{};
  int _crestSeq = 0;

  /// La clave de un equipo: su nombre en mayúsculas y sin espacios de sobra. «Bellavista »
  /// y «BELLAVISTA» son el mismo; «Bellavista FC», otro.
  static String crestKey(String teamName) =>
      teamName.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).join(' ').toUpperCase();

  /// El fichero del escudo de una clave: sus bytes UTF-8 en hexadecimal, que valen de nombre
  /// en cualquier sistema de ficheros aunque el equipo lleve tildes o eñes.
  File _crestFile(String key) => File(
    '${directory.path}/$teamCrestDirName/'
    '${utf8.encode(key).map((int b) => b.toRadixString(16).padLeft(2, '0')).join()}.img',
  );

  /// El escudo del equipo que se llama `teamName`, o null si va el genérico.
  TeamCrest? crestFor(String teamName) => _crests[crestKey(teamName)];

  /// Dónde se escribe un escudo mientras llega: se renombra al acabar bien.
  File get crestUploadFile => File('${directory.path}/$teamCrestDirName/escudo.subida');

  /// Adopta el escudo recién subido a [crestUploadFile] como el del equipo `teamName`.
  void adoptCrest(String teamName, String mime) {
    final String clave = crestKey(teamName);
    final File destino = _crestFile(clave);
    crestUploadFile.renameSync(destino.path);
    _crests[clave] = TeamCrest(mime: mime, file: destino, rev: ++_crestSeq);
    _save();
  }

  /// Quita el escudo del equipo `teamName`: vuelve el genérico.
  void deleteCrest(String teamName) {
    final TeamCrest? previo = _crests.remove(crestKey(teamName));
    if (previo != null && previo.file.existsSync()) {
      previo.file.deleteSync();
    }
    _save();
  }

  final Directory directory;
  StripTexts strip = StripTexts.defaults();

  /// `image/png` o `image/jpeg` si hay icono; null si no.
  String? iconMime;

  /// Sube con cada icono nuevo o borrado: el gráfico y el mando saben así que cambió.
  int iconRev = 0;

  File get _file => File('${directory.path}/$graphicsFileName');

  File get iconFile => File('${directory.path}/$championshipIconFileName');

  bool get hasIcon => iconMime != null;

  /// Dónde se escribe una subida mientras llega: se renombra al acabar bien.
  File get uploadFile => File('${directory.path}/$championshipIconFileName.subida');

  /// Los textos de la franja editados a mano (`graphics/strip_texts`): ya no son los de
  /// ninguna franja guardada.
  void setStrip(StripTexts texts) {
    strip = texts;
    stripPreset = null;
    _save();
  }

  /// Adopta el icono recién subido a [uploadFile].
  void adoptIcon(String mime) {
    uploadFile.renameSync(iconFile.path);
    iconMime = mime;
    iconRev += 1;
    _save();
  }

  void deleteIcon() {
    if (iconFile.existsSync()) {
      iconFile.deleteSync();
    }
    iconMime = null;
    iconRev += 1;
    _save();
  }

  /// El tipo de imagen por sus primeros bytes: PNG o JPEG, o null si no es ninguno.
  static String? sniff(List<int> cabeza) {
    const List<int> png = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (cabeza.length >= png.length && listEquals(cabeza.sublist(0, png.length), png)) {
      return 'image/png';
    }
    if (cabeza.length >= 3 && cabeza[0] == 0xFF && cabeza[1] == 0xD8 && cabeza[2] == 0xFF) {
      return 'image/jpeg';
    }
    return null;
  }

  void _save() {
    directory.createSync(recursive: true);
    final File tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(<String, Object?>{
      'strip': strip.toJson(),
      'icon_mime': iconMime,
      'crests': <String, String>{for (final MapEntry<String, TeamCrest> e in _crests.entries) e.key: e.value.mime},
      'next_match': nextMatch?.toJson(),
      'fixtures': <Map<String, Object?>>[for (final Fixture f in fixtures) f.toJson()],
      'interview': interview.toJson(),
      'strip_presets': <Map<String, Object?>>[for (final StripPreset p in stripPresets) p.toJson()],
      'strip_preset': stripPreset,
    }));
    tmp.renameSync(_file.path);
  }
}
