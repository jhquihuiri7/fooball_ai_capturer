/// La tarjeta de alineación en Dart (IOS-46), portada de build_lineup_card y
/// slot_positions de tools/lineup_card.py del repo football-ai.
///
/// Lista numerada a la izquierda, campo en perspectiva con las camisetas a la
/// derecha y el DT abajo, en el color del equipo. Opaca de arriba abajo salvo la
/// franja de anuncios, que queda transparente: tapa el marcador, no el anuncio.
/// Todas las medidas salen de OverlaySpec (REF-32 e IOS-46).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import '../theme/zero_type.dart';
import 'py_round.dart';
import 'scoreboard_painter.dart';

/// Un jugador tal como sale en la tarjeta.
@immutable
class LineupEntry {
  const LineupEntry(this.number, this.name);

  final int number;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is LineupEntry && other.number == number && other.name == name;

  @override
  int get hashCode => Object.hash(number, name);
}

/// Lo que la tarjeta necesita de un equipo. `lines` es la formación de atrás hacia
/// delante (4-4-2 → [4, 4, 2]); `starters`, el portero primero y luego por líneas.
@immutable
class LineupCardTeam {
  const LineupCardTeam({
    required this.name,
    required this.lines,
    required this.starters,
    this.substitutes = const <LineupEntry>[],
    this.coach = '',
  });

  final String name;
  final List<int> lines;
  final List<LineupEntry> starters;
  final List<LineupEntry> substitutes;
  final String coach;

  @override
  bool operator ==(Object other) =>
      other is LineupCardTeam &&
      other.name == name &&
      other.coach == coach &&
      listEquals(other.lines, lines) &&
      listEquals(other.starters, starters) &&
      listEquals(other.substitutes, substitutes);

  @override
  int get hashCode => Object.hash(
      name, coach, Object.hashAll(lines), Object.hashAll(starters), Object.hashAll(substitutes));
}

double _g(String clave) => OverlaySpec.lineupGeometry[clave]!;
int _l(String clave) => OverlaySpec.lineup[clave]!;

/// Dónde va cada titular, como (u, t): u de izquierda a derecha y t de fondo (0) a
/// delante (1). El orden es el de la lista: portero primero.
List<(double, double)> slotPositions(List<int> lines) {
  final List<(double, double)> posiciones = <(double, double)>[(0.5, _g('keeper_t'))];
  final double back = _g('back_t'), front = _g('front_t');
  for (int i = 0; i < lines.length; i++) {
    final int cuantos = lines[i];
    final double t = lines.length == 1 ? back : back - i * (back - front) / (lines.length - 1);
    final double paso =
        cuantos == 1 ? 0.0 : math.min(_g('line_spread') / (cuantos - 1), _g('max_slot_gap'));
    for (int j = 0; j < cuantos; j++) {
      posiciones.add((0.5 + (j - (cuantos - 1) / 2) * paso, t));
    }
  }
  return posiciones;
}

/// El color multiplicado por k (<1 oscurece), redondeado como Python.
Color _shade(Color c, double k) => Color.fromARGB(
    255, pyRound(_r(c) * k), pyRound(_gr(c) * k), pyRound(_b(c) * k));

/// El color llevado hacia el blanco en una fracción k.
Color _lighten(Color c, double k) => Color.fromARGB(255, pyRound(_r(c) + (255 - _r(c)) * k),
    pyRound(_gr(c) + (255 - _gr(c)) * k), pyRound(_b(c) + (255 - _b(c)) * k));

int _r(Color c) => (c.r * 255).round();
int _gr(Color c) => (c.g * 255).round();
int _b(Color c) => (c.b * 255).round();

const Color _white = Color(0xFFFFFFFF);

/// Formas SIN antialiasing, como ImageDraw de la referencia: con él, cada borde de
/// píldora, camiseta y raya sale distinto del PNG de Python sin que el ojo lo vea.
Paint _paint() => Paint()..isAntiAlias = false;

/// El color de la tarjeta de cada lado: el de su barra en el marcador.
Color lineupColour(bool home) => Color(OverlaySpec.colorsArgb[home ? 'home' : 'away']!);

class LineupCardPainter extends CustomPainter {
  LineupCardPainter(this.team, this.colour);

  final LineupCardTeam team;
  final Color colour;

  @override
  bool shouldRepaint(LineupCardPainter old) => old.team != team || old.colour != colour;

  @override
  void paint(Canvas canvas, Size size) {
    _Card(canvas, size.width.round(), size.height.round(), team, colour).paint();
  }
}

/// Una pasada de pintado: las medidas de un tamaño de salida y el lienzo.
class _Card {
  _Card(this.c, this.width, this.height, this.team, this.colour)
      : s = width / OverlaySpec.refWidth {
    alto = height - px(OverlaySpec.stripHeight.toDouble());
    ink = _shade(colour, _g('ink_k'));
    sombra = _shade(colour, _g('shadow_k'));
  }

  final Canvas c;
  final int width;
  final int height;
  final LineupCardTeam team;
  final Color colour;
  final double s;
  late final int alto;
  late final Color ink;
  late final Color sombra;

  int px(double v) => pyRound(v * s);

  TextStyle _font(int size, Color color) => TextStyle(
        fontFamily: ZeroType.display,
        fontWeight: FontWeight.w700,
        fontSize: size.toDouble(),
        color: color,
      );

  double _textWidth(String text, TextStyle style) {
    final TextPainter tp =
        TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
          ..layout();
    final double w = tp.width.floorToDouble();
    tp.dispose();
    return w;
  }

  /// Ancla de PIL: `mm` centrado, `lt` arriba a la izquierda.
  void _text(String text, TextStyle style, Offset at, {bool centred = true}) {
    final TextPainter tp =
        TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)
          ..layout();
    tp.paint(c, centred ? at - Offset(tp.width / 2, tp.height / 2) : at);
    tp.dispose();
  }

  /// El texto si cabe; si no, el apellido; si tampoco, recortado con puntos.
  String _fit(String text, TextStyle style, double ancho) {
    String candidato = text;
    final List<String> partes = text.split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
    for (final String prueba in <String>[text, if (partes.isNotEmpty) partes.last]) {
      candidato = prueba;
      if (_textWidth(prueba, style) <= ancho) return prueba;
    }
    while (candidato.length > 1 && _textWidth('$candidato…', style) > ancho) {
      candidato = candidato.substring(0, candidato.length - 1);
    }
    return '$candidato…';
  }

  /// Reparte `a, b, c` en renglones sin partir ningún elemento.
  List<String> _wrap(List<String> items, TextStyle style, double ancho) {
    final List<String> renglones = <String>[];
    String actual = '';
    for (final String item in items) {
      final String prueba = actual.isNotEmpty ? '$actual, $item' : item;
      if (actual.isNotEmpty && _textWidth(prueba, style) > ancho) {
        renglones.add('$actual,');
        actual = item;
      } else {
        actual = prueba;
      }
    }
    if (actual.isNotEmpty) renglones.add(actual);
    return renglones;
  }

  void _pill(Rect r, Color fill) => c.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)), _paint()..color = fill);

  void _numberedPill(double x, double y, double w, double h, int number, String text, int size) {
    final double dy = px(_l('shadow_dy').toDouble()).toDouble();
    _pill(Rect.fromLTRB(x, y + dy, x + w, y + h + dy), sombra);
    _pill(Rect.fromLTRB(x, y, x + w, y + h), _white);
    c.drawOval(Rect.fromLTRB(x, y, x + h, y + h), _paint()..color = ink);
    _text('$number', _font(size, _white), Offset(x + h / 2, y + h / 2));
    final TextStyle estilo = _font(size, ink);
    _text(_fit(text.toUpperCase(), estilo, w - h - px(16)), estilo,
        Offset(x + h + (w - h) / 2, y + h / 2));
  }

  void paint() {
    _background();
    _list();
    _pitch();
    _shirts();
    _header();
    if (team.coach.isNotEmpty) _coach();
  }

  /// Degradado vertical del color del equipo, fila a fila como np.linspace().round().
  void _background() {
    final Color top = _shade(colour, _g('bg_top_k'));
    final Color bottom = _shade(colour, _g('bg_bottom_k'));
    final int filas = math.max(1, alto);
    final Paint p = _paint();
    for (int y = 0; y < alto; y++) {
      final double f = filas == 1 ? 0 : y / (filas - 1);
      int canal(int a, int b) => pyRound(a + (b - a) * f);
      p.color = Color.fromARGB(255, canal(_r(top), _r(bottom)), canal(_gr(top), _gr(bottom)),
          canal(_b(top), _b(bottom)));
      c.drawRect(Rect.fromLTWH(0, y.toDouble(), width.toDouble(), 1), p);
    }
  }

  void _list() {
    final double mx = px(_l('margin_x').toDouble()).toDouble();
    _text(OverlaySpec.lineupTexts['title']!, _font(px(_l('title_size').toDouble()), _white),
        Offset(mx, px(_l('title_y').toDouble()).toDouble()),
        centred: false);
    for (int i = 0; i < team.starters.length; i++) {
      final LineupEntry j = team.starters[i];
      _numberedPill(
        mx,
        px(_l('list_y') + i * _l('row_step').toDouble()).toDouble(),
        px(_l('list_w').toDouble()).toDouble(),
        px(_l('row_h').toDouble()).toDouble(),
        j.number,
        j.name,
        px(_l('row_text_size').toDouble()),
      );
    }
    if (team.substitutes.isEmpty) return;
    final int y = px(_l('subs_y').toDouble());
    final int tituloSize = px(_l('subs_title_size').toDouble());
    _text(OverlaySpec.lineupTexts['subs_title']!, _font(tituloSize, _white),
        Offset(mx, y.toDouble()),
        centred: false);
    final TextStyle estilo = _font(px(_l('subs_size').toDouble()), _white);
    final int lineH = px(_l('subs_line_h').toDouble());
    final int caben = math.max(0, (alto - px(_l('bottom_pad').toDouble()) - y - tituloSize) ~/ lineH);
    List<String> renglones = _wrap(
      <String>[for (final LineupEntry p in team.substitutes) '${p.number}. ${p.name.toUpperCase()}'],
      estilo,
      px((_l('list_w') + _l('margin_x')).toDouble()).toDouble(),
    );
    if (renglones.length > caben) {
      renglones = renglones.sublist(0, caben);
      if (renglones.isNotEmpty) {
        final String ultimo = renglones.removeLast();
        renglones.add('${ultimo.endsWith(',') ? ultimo.substring(0, ultimo.length - 1) : ultimo} …');
      }
    }
    for (int k = 0; k < renglones.length; k++) {
      _text(renglones[k], estilo, Offset(mx, (y + tituloSize + px(8) + k * lineH).toDouble()),
          centred: false);
    }
  }

  // ---------------- el campo ----------------

  late final double _top = px(_g('pitch_top')).toDouble();
  late final double _bottom = px(_g('pitch_bottom')).toDouble();
  late final double _cx = px(_g('pitch_cx')).toDouble();

  double _widthAt(double t) =>
      px(_g('pitch_top_w')) + (px(_g('pitch_bottom_w')) - px(_g('pitch_top_w'))) * t;

  Offset _project(double u, double t) =>
      Offset(_cx + (u - 0.5) * _widthAt(t), _top + (_bottom - _top) * t);

  Path _quad(double u0, double u1, double t0, double t1) => Path()
    ..addPolygon(
        <Offset>[_project(u0, t0), _project(u1, t0), _project(u1, t1), _project(u0, t1)], true);

  void _pitch() {
    final Offset baseIzq = _project(0, 1), baseDer = _project(1, 1);
    final double slab = _bottom + px(_g('slab_h'));
    c.drawPath(
      Path()
        ..addPolygon(<Offset>[baseIzq, baseDer, Offset(baseDer.dx, slab), Offset(baseIzq.dx, slab)],
            true),
      _paint()..color = _shade(colour, _g('slab_k')),
    );
    final int franjas = _g('pitch_stripes').toInt();
    for (int k = 0; k < franjas; k++) {
      final Color tono = k.isOdd ? _lighten(colour, _g('stripe_lighten')) : colour;
      c.drawPath(_quad(0, 1, k / franjas, (k + 1) / franjas), _paint()..color = tono);
    }

    // Las rayas van en una capa aparte con alfa, recortada al césped: en la
    // referencia se pintan opacas sobre una capa y luego se mezclan, así que donde
    // dos rayas se cruzan no se oscurece el doble.
    c.save();
    c.clipPath(_quad(0, 1, 0, 1));
    c.saveLayer(null, _paint()..color = Color.fromARGB(_g('line_alpha').toInt(), 255, 255, 255));
    final Paint tiza = _paint()
      ..color = _white
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = math.max(1, px(_g('line_w'))).toDouble();
    c.drawPath(_quad(_g('touch_u0'), _g('touch_u1'), _g('touch_t0'), _g('touch_t1')), tiza);
    c.drawLine(_project(_g('touch_u0'), _g('halfway_t')), _project(_g('touch_u1'), _g('halfway_t')),
        tiza);
    _arc(0.5, _g('halfway_t'), _g('circle_ru'), _g('circle_rt'), tiza);
    c.drawPath(_quad(_g('box_u0'), _g('box_u1'), _g('box_t0'), _g('box_t1')), tiza);
    c.drawPath(_quad(_g('goal_box_u0'), _g('goal_box_u1'), _g('goal_box_t0'), _g('goal_box_t1')),
        tiza);
    // La media luna: lo del círculo que queda fuera del área.
    _arc(0.5, _g('spot_t'), _g('d_ru'), _g('d_rt'), tiza, maxT: _g('box_t0'));
    c.restore();
    c.restore();
  }

  /// Elipse en coordenadas de campo; con maxT, solo lo que queda por detrás.
  void _arc(double cu, double ct, double ru, double rt, Paint tiza, {double maxT = 1.0}) {
    final int muestras = _g('arc_samples').toInt();
    final List<Offset> puntos = <Offset>[];
    for (int a = 0; a <= muestras; a++) {
      final double ang = 2 * math.pi * a / muestras;
      final double u = cu + ru * math.cos(ang), t = ct + rt * math.sin(ang);
      if (t <= maxT) puntos.add(_project(u, t));
    }
    if (puntos.length > 1) c.drawPath(Path()..addPolygon(puntos, false), tiza);
  }

  void _shirts() {
    final List<(double, double)> huecos = slotPositions(team.lines);
    final int n = math.min(huecos.length, team.starters.length);
    final int labelSize = px(_g('label_text_size'));
    final Color shirt = Color(OverlaySpec.lineupColorsArgb['shirt']!);
    final Color keeper = Color(OverlaySpec.lineupColorsArgb['keeper_shirt']!);
    for (int i = 0; i < n; i++) {
      final (double u, double t) = huecos[i];
      final LineupEntry jugador = team.starters[i];
      final Offset p = _project(u, t);
      final double escala = _widthAt(t) / px(_g('pitch_bottom_w')); // lo del fondo, más pequeño
      final double w = px(_g('shirt_w')) * escala;
      final double h = w / _g('shirt_aspect');
      final double y0 = p.dy - h / 2;
      final Color tela = i == 0 ? keeper : shirt;
      c.drawPath(
        Path()
          ..addPolygon(<Offset>[
            for (final (double sx, double sy) in OverlaySpec.lineupShirtShape)
              Offset(p.dx + sx * w, y0 + sy * h),
          ], true),
        _paint()..color = tela,
      );
      final Paint raya = _paint()
        ..color = _lighten(tela, _g('shirt_lighten'))
        ..strokeWidth = math.max(1, pyRound(h * 0.04)).toDouble();
      final double cuerpo = _g('shirt_body');
      for (final double sy in OverlaySpec.lineupShirtStripes) {
        c.drawLine(Offset(p.dx - cuerpo * w, y0 + sy * h), Offset(p.dx + cuerpo * w, y0 + sy * h),
            raya);
      }
      final double lw = px(_g('label_w')) * escala, lh = px(_g('label_h')) * escala;
      final double ly = y0 + h + px(_g('label_gap')) * escala;
      _pill(Rect.fromLTRB(p.dx - lw / 2, ly, p.dx + lw / 2, ly + lh), _white);
      c.drawOval(Rect.fromLTRB(p.dx - lw / 2, ly, p.dx - lw / 2 + lh, ly + lh), _paint()..color = ink);
      _text('${jugador.number}', _font(labelSize, _white), Offset(p.dx - lw / 2 + lh / 2, ly + lh / 2));
      final TextStyle estilo = _font(labelSize, ink);
      _text(_fit(jugador.name.toUpperCase(), estilo, lw - lh - px(12)), estilo,
          Offset(p.dx + lh / 2, ly + lh / 2));
    }
  }

  void _header() {
    final double hw = px(_l('header_w').toDouble()).toDouble();
    final double hx0 = px(_g('pitch_cx')) - hw / 2;
    final double hy0 = px(_l('header_y').toDouble()).toDouble();
    final double hh = px(_l('header_h').toDouble()).toDouble();
    final double dy = px(_l('shadow_dy').toDouble()).toDouble();
    _pill(Rect.fromLTRB(hx0, hy0 + dy, hx0 + hw, hy0 + hh + dy), sombra);
    _pill(Rect.fromLTRB(hx0, hy0, hx0 + hw, hy0 + hh), _white);
    final double cr = px(_l('crest_r').toDouble()).toDouble();
    final double ccx = hx0 + cr * 0.6, ccy = hy0 + hh / 2;
    final TextStyle estilo = _font(px(_l('header_text_size').toDouble()), ink);
    _text(_fit(team.name, estilo, hw - cr * 2 - px(24)), estilo, Offset(hx0 + hw / 2 + cr / 2, ccy));
    c.drawCircle(Offset(ccx, ccy), cr, _paint()..color = _white);
    c.drawCircle(Offset(ccx, ccy), cr * 0.84, _paint()..color = ink);
    c.drawCircle(
        Offset(ccx, ccy), cr * 0.74, _paint()..color = Color(OverlaySpec.lineupColorsArgb['crest_fill']!));
    paintTurtle(c, ccx, ccy + cr * 0.08, cr * 0.42);
  }

  void _coach() {
    final double cw = px(_g('coach_w')).toDouble(), ch = px(_g('coach_h')).toDouble();
    final double cx = px(_g('pitch_cx')).toDouble();
    final double x0 = cx - cw / 2, y0 = px(_g('coach_y')).toDouble();
    final double dy = px(_l('shadow_dy').toDouble()).toDouble();
    _pill(Rect.fromLTRB(x0, y0 + dy, x0 + cw, y0 + ch + dy), sombra);
    _pill(Rect.fromLTRB(x0, y0, x0 + cw, y0 + ch), _white);
    final TextStyle estilo = _font(px(_g('coach_text_size')), ink);
    _text(_fit(team.coach.toUpperCase(), estilo, cw - ch), estilo, Offset(cx, y0 + ch / 2));
    final double ry0 = y0 + ch + px(_g('role_gap'));
    final double rw = px(_g('role_w')).toDouble(), rh = px(_g('role_h')).toDouble();
    _pill(Rect.fromLTRB(cx - rw / 2, ry0, cx + rw / 2, ry0 + rh), ink);
    _text(OverlaySpec.lineupTexts['role']!, _font(px(_g('role_text_size')), _white),
        Offset(cx, ry0 + rh / 2));
  }
}

/// La tarjeta como ui.Image del tamaño del programa.
Future<ui.Image> paintLineupCard(LineupCardTeam team, Color colour, int width, int height) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  LineupCardPainter(team, colour)
      .paint(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
