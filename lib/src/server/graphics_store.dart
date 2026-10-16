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
  StripTexts({required this.title, this.subtitle = ''}) {
    for (final (String texto, String clave) in <(String, String)>[(title, 'title'), (subtitle, 'subtitle')]) {
      final int tope = OverlaySpec.strip['${clave}_max_chars']!;
      if (texto.length > tope || texto.contains('\n')) {
        throw GraphicsError('$clave de la franja: hasta $tope caracteres y sin saltos');
      }
    }
  }

  /// Los de partida, mientras el operador no los cambie.
  factory StripTexts.defaults() =>
      StripTexts(title: OverlaySpec.stripTitleDefault, subtitle: OverlaySpec.stripSubtitleDefault);

  /// Lee `{"title", "subtitle"}` (enmienda del ADR 0027 del 2026-10-16); [GraphicsError] si
  /// no vale.
  factory StripTexts.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw GraphicsError('se espera {title, subtitle}');
    }
    final Object? titulo = json['title'];
    final Object sub = json['subtitle'] ?? '';
    if (titulo is! String || sub is! String) {
      throw GraphicsError('title y subtitle tienen que ser textos');
    }
    return StripTexts(title: titulo.trim(), subtitle: sub.trim());
  }

  final String title;
  final String subtitle;

  Map<String, Object?> toJson() => <String, Object?>{'title': title, 'subtitle': subtitle};

  @override
  bool operator ==(Object other) => other is StripTexts && other.title == title && other.subtitle == subtitle;

  @override
  int get hashCode => Object.hash(title, subtitle);
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

/// La imagen de una franja guardada (enmienda del ADR 0027 del 2026-10-16): como un escudo,
/// su fichero y su versión.
typedef StripImage = TeamCrest;

/// Lee una parte de `grafico.json`: si no vale, null, y el resto se lee igual (un formato
/// viejo de la franja no se lleva el icono ni los escudos).
T? _parte<T>(T Function() leer) {
  try {
    return leer();
  } on Object {
    return null;
  }
}

class GraphicsStore {
  /// Lee lo guardado en `directory`; un fichero roto no impide arrancar: se empieza con
  /// los textos de partida y sin icono.
  GraphicsStore(this.directory) {
    final File f = _file;
    final Object? json = f.existsSync() ? _parte(() => jsonDecode(f.readAsStringSync())) : null;
    if (json is Map<String, Object?>) {
      strip = _parte(() => StripTexts.fromJson(json['strip'])) ?? StripTexts.defaults();
      final Object? tipo = json['icon_mime'];
      iconMime = tipo is String && iconFile.existsSync() ? tipo : null;
      final Object? jornada = json['fixtures'];
      if (jornada is List<Object?> && jornada.isNotEmpty) {
        fixtures = _parte(() => Fixture.listFromJson(<String, Object?>{'matches': jornada})) ?? fixtures;
      }
      interview = _parte(() => Interview.fromJson(json['interview'])) ?? interview;
      nextMatch = _parte(() => NextMatch.fromJson(json['next_match']));
      final Object? franjas = json['strip_presets'];
      if (franjas is List<Object?>) {
        stripPresets = <StripPreset>[
          for (final Object? f in franjas)
            if (_parte(() => StripPreset.fromJson(f)) case final StripPreset p) p,
        ];
      }
      final Object? puesta = json['strip_preset'];
      stripPreset = puesta is String && _preset(puesta) != null ? puesta : null;
      for (final (String clave, Map<String, TeamCrest> destino, File Function(String) fichero, bool franja)
          in <(String, Map<String, TeamCrest>, File Function(String), bool)>[
            ('crests', _crests, _crestFile, false),
            ('strip_images', _stripImages, _stripImageFile, true),
          ]) {
        final Object? guardadas = json[clave];
        if (guardadas is! Map<String, Object?>) {
          continue;
        }
        for (final MapEntry<String, Object?> e in guardadas.entries) {
          final Object? mime = e.value;
          if (mime is String && fichero(e.key).existsSync()) {
            destino[e.key] = TeamCrest(mime: mime, file: fichero(e.key), rev: franja ? ++_stripSeq : ++_crestSeq);
          }
        }
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
      _moveStripImage(vieja.name, preset.name);
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
    final StripImage? img = _stripImages.remove(p.name.toUpperCase());
    if (img != null && img.file.existsSync()) {
      img.file.deleteSync();
    }
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

  /// Las imágenes de las franjas guardadas, por la clave de su nombre, y la última versión.
  final Map<String, StripImage> _stripImages = <String, StripImage>{};
  int _stripSeq = 0;

  File _stripImageFile(String key) => File(
    '${directory.path}/$stripImageDirName/'
    '${utf8.encode(key).map((int b) => b.toRadixString(16).padLeft(2, '0')).join()}.img',
  );

  /// La imagen de la franja guardada `name`, o null.
  StripImage? stripImageFor(String name) => _stripImages[name.trim().toUpperCase()];

  /// La imagen de la franja que está puesta, o null (sin franja guardada puesta, o sin imagen).
  StripImage? get activeStripImage {
    final String? puesta = stripPreset;
    return puesta == null ? null : stripImageFor(puesta);
  }

  /// Dónde se escribe la imagen de una franja mientras llega.
  File get stripImageUploadFile => File('${directory.path}/$stripImageDirName/imagen.subida');

  /// Adopta la imagen recién subida como la de la franja guardada `name`.
  void adoptStripImage(String name, String mime) {
    final String clave = name.trim().toUpperCase();
    final File destino = _stripImageFile(clave);
    stripImageUploadFile.renameSync(destino.path);
    _stripImages[clave] = StripImage(mime: mime, file: destino, rev: ++_stripSeq);
    _save();
  }

  /// Quita la imagen de la franja guardada `name`.
  void deleteStripImage(String name) {
    final StripImage? previa = _stripImages.remove(name.trim().toUpperCase());
    if (previa != null && previa.file.existsSync()) {
      previa.file.deleteSync();
    }
    _save();
  }

  /// La imagen de una franja se va con ella: al renombrarla, a su nombre nuevo.
  void _moveStripImage(String de, String a) {
    final String origen = de.trim().toUpperCase(), destino = a.trim().toUpperCase();
    final StripImage? img = _stripImages.remove(origen);
    if (img == null || origen == destino) {
      if (img != null) _stripImages[origen] = img;
      return;
    }
    final File nuevo = _stripImageFile(destino);
    img.file.renameSync(nuevo.path);
    _stripImages[destino] = StripImage(mime: img.mime, file: nuevo, rev: ++_stripSeq);
  }

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
      'strip_images': <String, String>{
        for (final MapEntry<String, StripImage> e in _stripImages.entries) e.key: e.value.mime,
      },
      'next_match': nextMatch?.toJson(),
      'fixtures': <Map<String, Object?>>[for (final Fixture f in fixtures) f.toJson()],
      'interview': interview.toJson(),
      'strip_presets': <Map<String, Object?>>[for (final StripPreset p in stripPresets) p.toJson()],
      'strip_preset': stripPreset,
    }));
    tmp.renameSync(_file.path);
  }
}
