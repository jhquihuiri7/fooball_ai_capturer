/// La tarjeta de entretiempo en Dart (IOS-102), portada de tools/halftime_card.py del repo
/// football-ai (ADR 0027): el marcador del partido a pantalla completa.
///
/// Tapa la pantalla entera, franja incluida, con un velo translúcido: detrás se ve la
/// cancha, que el compositor nativo desenfoca mientras la tarjeta está fuera (enmienda del
/// ADR 0027 del 2026-10-16). Comparte capa con la alineación. Lleva el título, la
/// competición, el icono del campeonato grande en
/// el centro (el isotipo de Gala Sports si no hay), los dos escudos con sus nombres y el
/// marcador con las cajas inclinadas. Las medidas salen de OverlaySpec.halftime.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import 'gala_brand.dart';
import 'py_round.dart';
import 'scoreboard_painter.dart';

int _h(String clave) => OverlaySpec.halftime[clave]!;

/// El próximo partido para su tarjeta (ADR 0029): los equipos, cuándo y dónde.
@immutable
class NextMatchCard {
  const NextMatchCard({required this.home, required this.away, required this.when, this.venue = ''});

  final String home;
  final String away;
  final String when;
  final String venue;

  @override
  bool operator ==(Object other) =>
      other is NextMatchCard && other.home == home && other.away == away && other.when == when && other.venue == venue;

  @override
  int get hashCode => Object.hash(home, away, when, venue);
}

/// La geometría de la tarjeta sobre un lienzo de `width` de ancho: las mismas claves que
/// `halftime` de boxes.json. Con `title`, la de final (`fulltime`); con `next`, la de
/// próximo partido (`next_match`), que lleva sus equipos y el cuándo y el dónde en lugar
/// del marcador (ADR 0029).
class HalftimeLayout {
  HalftimeLayout(this.width, this.state, {String? title, this.next})
    : title = title ?? (next != null ? OverlaySpec.nextMatchTitle : OverlaySpec.halftimeTitle),
      s = width / OverlaySpec.refWidth {
    _measure();
  }

  final int width;
  final ScoreboardState state;
  final String title;
  final NextMatchCard? next;
  final double s;
  final Map<String, Rect> boxes = <String, Rect>{};
  final Map<String, double> v = <String, double>{};

  int px(double valor) => pyRound(valor * s);
  double h(String clave) => px(_h(clave).toDouble()).toDouble();

  TextStyle font(String nombre, {Color? color}) => switch (nombre) {
    'title' => GalaBrand.text('display', 800, h('title_size'), color: color),
    'comp' => GalaBrand.text('display', 600, h('comp_size'), color: color),
    'name' => GalaBrand.text('display', 700, h('name_size'), color: color),
    'score' => GalaBrand.text('display', 800, h('score_size'), color: color),
    'when' => GalaBrand.text('display', 800, h('when_size'), color: color),
    'venue' => GalaBrand.text('display', 600, h('venue_size'), color: color),
    _ => GalaBrand.text('display', 800, h('crest_initials_size'), color: color),
  };

  double textWidth(String text, String fuente) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: font(fuente)),
      textDirection: TextDirection.ltr,
    )..layout();
    final double ancho = tp.width.floorToDouble();
    tp.dispose();
    return ancho;
  }

  /// El texto si cabe; si no, la última palabra; si tampoco, recortado con puntos
  /// (`_fit` de lineup_card.py).
  String fit(String text, String fuente, double ancho) {
    String candidato = text;
    final List<String> partes = text.split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
    for (final String prueba in <String>[text, if (partes.isNotEmpty) partes.last]) {
      candidato = prueba;
      if (textWidth(prueba, fuente) <= ancho) return prueba;
    }
    while (candidato.length > 1 && textWidth('$candidato…', fuente) > ancho) {
      candidato = candidato.substring(0, candidato.length - 1);
    }
    return '$candidato…';
  }

  String nombre(String lado) {
    final NextMatchCard? n = next;
    final String crudo = lado == 'home' ? (n?.home ?? state.home) : (n?.away ?? state.away);
    return crudo.toUpperCase();
  }

  void _measure() {
    final double cx = width / 2;
    final double tituloW = textWidth(title, 'title');
    double mitad = h('title_size') / 2;
    boxes['title'] = Rect.fromLTRB(cx - tituloW / 2, h('title_y') - mitad, cx + tituloW / 2, h('title_y') + mitad);
    final double compW = textWidth(state.competition.toUpperCase(), 'comp');
    mitad = h('comp_size') / 2;
    boxes['competition'] = Rect.fromLTRB(cx - compW / 2, h('comp_y') - mitad, cx + compW / 2, h('comp_y') + mitad);
    final double lado = h('icon_box');
    boxes['icon'] = Rect.fromLTRB(cx - lado / 2, h('icon_cy') - lado / 2, cx + lado / 2, h('icon_cy') + lado / 2);

    final double crestW = h('crest_w');
    final double crestH = crestW * OverlaySpec.crest['box_h']! / OverlaySpec.crest['box_w']!;
    for (final (String clave, int signo) in const <(String, int)>[('home', -1), ('away', 1)]) {
      final double ccx = cx + signo * h('crest_dx');
      boxes['${clave}_crest'] =
          Rect.fromLTRB(ccx - crestW / 2, h('crest_cy') - crestH / 2, ccx + crestW / 2, h('crest_cy') + crestH / 2);
      final double ancho = textWidth(fit(nombre(clave), 'name', h('name_max_w')), 'name');
      mitad = h('name_size') / 2;
      boxes['${clave}_name'] = Rect.fromLTRB(ccx - ancho / 2, h('name_y') - mitad, ccx + ancho / 2, h('name_y') + mitad);
    }

    final NextMatchCard? n = next;
    if (n != null) {
      // El cuándo en la caja inclinada donde va el marcador; el dónde, debajo.
      final double cajaW = math.max(h('when_min_w'), textWidth(n.when.toUpperCase(), 'when') + 2 * h('when_pad_x'));
      final double alto = h('when_h');
      final double sesgo = alto / 2 * GalaBrand.inclinacion;
      final double x0 = cx - cajaW / 2, y0 = h('when_y') - alto / 2;
      boxes['when'] = Rect.fromLTRB(x0 - sesgo, y0, x0 + cajaW + sesgo, y0 + alto);
      v.addAll(<String, double>{'when_x': x0, 'when_w': cajaW, 'when_y': y0, 'when_h': alto});
      if (n.venue.trim().isNotEmpty) {
        final double ancho = textWidth(n.venue.toUpperCase(), 'venue');
        mitad = h('venue_size') / 2;
        boxes['venue'] = Rect.fromLTRB(cx - ancho / 2, h('venue_y') - mitad, cx + ancho / 2, h('venue_y') + mitad);
      }
      return;
    }
    final double glW = math.max(h('goal_min_w'), textWidth('${state.homeGoals}', 'score') + 2 * h('goal_pad_x'));
    final double guionW = textWidth('-', 'score');
    final double visitaW = guionW + h('goal_dash_gap') + textWidth('${state.awayGoals}', 'score');
    final double gvW = math.max(h('goal_min_w'), visitaW + 2 * h('goal_pad_x'));
    final double alto = h('score_h');
    final double sesgo = alto / 2 * GalaBrand.inclinacion;
    final double x0 = cx - (glW + gvW) / 2;
    final double y0 = h('score_y') - alto / 2;
    boxes['home_score'] = Rect.fromLTRB(x0 - sesgo, y0, x0 + glW + sesgo, y0 + alto);
    boxes['away_score'] = Rect.fromLTRB(x0 + glW - sesgo, y0, x0 + glW + gvW + sesgo, y0 + alto);
    v.addAll(<String, double>{
      'gl_x': x0,
      'gl_w': glW,
      'gv_x': x0 + glW,
      'gv_w': gvW,
      'score_y': y0,
      'score_h': alto,
      'visita_w': visitaW,
      'guion_w': guionW,
    });
  }
}

class HalftimeCardPainter extends CustomPainter {
  HalftimeCardPainter(
    this.state, {
    required this.isotipo,
    this.icon,
    this.crests = const <String, ui.Image>{},
    this.title,
    this.next,
  });

  /// El título: el del entretiempo si no se dice otro (la de final lleva el suyo).
  final String? title;

  /// El próximo partido: con él, la tarjeta es la suya (ADR 0029).
  final NextMatchCard? next;

  final ScoreboardState state;
  final ui.Image isotipo;

  /// El icono del campeonato; sin él, el isotipo.
  final ui.Image? icon;

  /// Los escudos de los equipos que los tienen, por lado (ADR 0028).
  final Map<String, ui.Image> crests;

  @override
  bool shouldRepaint(HalftimeCardPainter old) =>
      old.state != state || old.icon != icon || old.crests != crests || old.title != title || old.next != next;

  void _text(Canvas c, HalftimeLayout l, String text, String fuente, Color color, Offset at, {bool centred = true}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: l.font(fuente, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(centred ? at.dx - tp.width / 2 : at.dx, at.dy - tp.height / 2));
    tp.dispose();
  }

  void _image(Canvas c, ui.Image imagen, Rect caja) {
    final double escala = math.min(caja.width / imagen.width, caja.height / imagen.height);
    final Size tam = Size(imagen.width * escala, imagen.height * escala);
    final Rect destino = Rect.fromCenter(center: caja.center, width: tam.width, height: tam.height);
    c.drawImageRect(
      imagen,
      Rect.fromLTWH(0, 0, imagen.width.toDouble(), imagen.height.toDouble()),
      destino,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  void paint(Canvas c, Size size) {
    final HalftimeLayout l = HalftimeLayout(size.width.round(), state, title: title, next: next);
    c.drawRect(
      Offset.zero & size,
      Paint()..color = GalaBrand.token('azul-profundo').withAlpha(OverlaySpec.halftime['veil_alpha']!),
    );
    final Color blanco = GalaBrand.token('blanco');
    final Color teal = Color(OverlaySpec.colorsArgb['home']!);
    final Color visita = Color(OverlaySpec.colorsArgb['away']!);
    final double cx = size.width / 2;

    // ---------------- título y competición ----------------
    final Rect titulo = l.boxes['title']!;
    _text(c, l, l.title, 'title', blanco, Offset(cx, l.h('title_y')));
    final double rw = l.h('title_raya_w'), rh = l.h('title_raya_h'), gap = l.h('title_raya_gap');
    for (final double x in <double>[titulo.left - gap - rw, titulo.right + gap]) {
      final Rect caja = Rect.fromLTWH(x, l.h('title_y') - rh / 2, rw, rh);
      c.drawPath(
        GalaBrand.skewed(caja.left, caja.top, rw, rh),
        GalaBrand.fill(GalaBrand.token('teal-electrico'), bottom: GalaBrand.token('azul-deportivo'), box: caja),
      );
    }
    _text(c, l, state.competition.toUpperCase(), 'comp', GalaBrand.token('gris-oceanico'), Offset(cx, l.h('comp_y')));

    // ---------------- el icono del campeonato, o el isotipo ----------------
    final ui.Image? propio = icon;
    if (propio != null) {
      _image(c, propio, l.boxes['icon']!);
    } else {
      final double ih = l.h('isotipo_h');
      final double iw = (isotipo.width * ih / isotipo.height).roundToDouble();
      _image(c, isotipo, Rect.fromCenter(center: l.boxes['icon']!.center, width: iw, height: ih));
    }

    // ---------------- los equipos ----------------
    for (final (String clave, Color color) in <(String, Color)>[('home', teal), ('away', visita)]) {
      final Rect escudo = l.boxes['${clave}_crest']!;
      if (GalaBrand.paintTeamCrest(c, escudo, color, crests[clave])) {
        _text(c, l, GalaBrand.crestInitials(l.nombre(clave)), 'crest', color, GalaBrand.crestInitialsCenter(escudo));
      }
      final String visible = l.fit(l.nombre(clave), 'name', l.h('name_max_w'));
      _text(c, l, visible, 'name', blanco, Offset(l.boxes['${clave}_name']!.center.dx, l.h('name_y')));
    }

    // ---------------- el próximo partido: cuándo y dónde ----------------
    final NextMatchCard? n = next;
    if (n != null) {
      final double y = l.v['when_y']!, h = l.v['when_h']!;
      c.drawPath(
        GalaBrand.skewed(l.v['when_x']!, y, l.v['when_w']!, h),
        GalaBrand.fill(teal, bottom: GalaBrand.token('verde-oceano'), box: Rect.fromLTRB(0, y, 1, y + h)),
      );
      _text(c, l, n.when.toUpperCase(), 'when', GalaBrand.token('azul-profundo'), Offset(cx, y + h / 2));
      final Rect? lugar = l.boxes['venue'];
      if (lugar != null) {
        _text(c, l, n.venue.toUpperCase(), 'venue', GalaBrand.token('gris-claro'), lugar.center);
      }
      return;
    }

    // ---------------- el marcador ----------------
    final double y = l.v['score_y']!, h = l.v['score_h']!, scy = y + h / 2;
    final Rect alto2 = Rect.fromLTRB(0, y, 1, y + h);
    c.drawPath(GalaBrand.skewed(l.v['gl_x']!, y, l.v['gl_w']!, h),
        GalaBrand.fill(teal, bottom: GalaBrand.token('verde-oceano'), box: alto2));
    c.drawPath(GalaBrand.skewed(l.v['gv_x']!, y, l.v['gv_w']!, h), Paint()..color = visita);
    final Color tinta = GalaBrand.token('azul-profundo');
    _text(c, l, '${state.homeGoals}', 'score', tinta, Offset(l.v['gl_x']! + l.v['gl_w']! / 2, scy));
    double vx = l.v['gv_x']! + (l.v['gv_w']! - l.v['visita_w']!) / 2;
    _text(c, l, '-', 'score', tinta, Offset(vx, scy), centred: false);
    vx += l.v['guion_w']! + l.h('goal_dash_gap');
    _text(c, l, '${state.awayGoals}', 'score', tinta, Offset(vx, scy), centred: false);
  }
}

/// La tarjeta como ui.Image del tamaño del programa.
Future<ui.Image> paintHalftimeCard(
  ScoreboardState state,
  int width,
  int height, {
  ui.Image? icon,
  Map<String, ui.Image> crests = const <String, ui.Image>{},
  String? title,
  NextMatchCard? next,
}) async {
  final ui.Image isotipo = await GalaBrand.isotipo();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  HalftimeCardPainter(state, isotipo: isotipo, icon: icon, crests: crests, title: title, next: next)
      .paint(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
