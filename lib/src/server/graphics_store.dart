/// Lo que el operador cambia del gráfico desde el mando y es del campeonato, no de un
/// partido (ADR 0027): los textos de la franja y el icono del campeonato.
///
/// Vive en la carpeta del partido, en `grafico.json` y `campeonato.img`, pero no se aparta
/// con el partido viejo: el partido siguiente del mismo campeonato los conserva.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';

/// Un cambio del gráfico que no se acepta, con el porqué para el mando.
class GraphicsError implements Exception {
  GraphicsError(this.message);

  final String message;

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
        }
      } on Object {
        strip = StripTexts.defaults();
        iconMime = null;
      }
    }
    iconRev = iconMime == null ? 0 : 1;
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

  void setStrip(StripTexts texts) {
    strip = texts;
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
    tmp.writeAsStringSync(jsonEncode(<String, Object?>{'strip': strip.toJson(), 'icon_mime': iconMime}));
    tmp.renameSync(_file.path);
  }
}
