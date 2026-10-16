/// El gráfico del programa en Dart (IOS-45, con la marca Gala Sports de IOS-100),
/// portado de build_overlay en tools/overlay_preview.py del repo football-ai.
///
/// El marcador es el `Scoreboard` del sistema de diseño arriba a la izquierda (ADR
/// 0026): una fila de estado (EN VIVO, la competición y el reloj) y debajo la barra
/// cortada a -30° con escudos, nombres y goles. Arriba a la derecha, el chip de
/// cámara; abajo, la franja con el isotipo, el claim y el hueco vendible.
///
/// Medir y dibujar salen de la MISMA medición (`ScoreboardLayout`), como en la
/// referencia: dos aritméticas divergirían al primer retoque. Las medidas vienen de
/// OverlaySpec; aquí no se teclea ninguna que exista allí.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import 'gala_brand.dart';
import 'py_round.dart';

/// Lo que el marcador enseña. Valor puro: dos estados iguales pintan lo mismo, y
/// es lo que decide si hay que volver a rasterizar.
@immutable
class ScoreboardState {
  const ScoreboardState({
    required this.competition,
    required this.home,
    required this.away,
    required this.homeGoals,
    required this.awayGoals,
    required this.clockS,
    required this.live,
    required this.cameraMode,
    this.stripVisible = true,
    this.stripTitle = OverlaySpec.stripTitleDefault,
    this.stripSubtitle = OverlaySpec.stripSubtitleDefault,
    this.stripImageRev,
    this.iconRev,
    this.homeCrestRev,
    this.awayCrestRev,
  });

  final String competition;
  final String home;
  final String away;
  final int homeGoals;
  final int awayGoals;
  final int clockS;
  final bool live;
  final String cameraMode;

  /// La franja fuera (ADR 0027: en el programa va oculta salvo cuando el operador la saca).
  final bool stripVisible;

  /// Lo que dice la franja (enmienda del ADR 0027 del 2026-10-16): un título y un
  /// subtítulo, que puede ir vacío.
  final String stripTitle;
  final String stripSubtitle;

  /// La versión de la imagen de la franja, o null sin imagen.
  final int? stripImageRev;

  /// La versión del icono del campeonato si hay; null sin icono. Cambiarla obliga a
  /// rasterizar de nuevo aunque lo demás sea igual.
  final int? iconRev;

  /// La versión del escudo de cada equipo (ADR 0028), o null con el genérico: como
  /// `iconRev`, cambiarla obliga a rasterizar de nuevo.
  final int? homeCrestRev;
  final int? awayCrestRev;

  String get clockText =>
      '${(clockS ~/ 60).toString().padLeft(2, '0')}:${(clockS % 60).toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is ScoreboardState &&
      other.competition == competition &&
      other.home == home &&
      other.away == away &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals &&
      other.clockS == clockS &&
      other.live == live &&
      other.cameraMode == cameraMode &&
      other.stripVisible == stripVisible &&
      other.stripTitle == stripTitle &&
      other.stripSubtitle == stripSubtitle &&
      other.stripImageRev == stripImageRev &&
      other.iconRev == iconRev &&
      other.homeCrestRev == homeCrestRev &&
      other.awayCrestRev == awayCrestRev;

  @override
  int get hashCode => Object.hash(competition, home, away, homeGoals, awayGoals, clockS, live, cameraMode,
      stripVisible, stripTitle, stripSubtitle, stripImageRev, iconRev, homeCrestRev, awayCrestRev);
}

/// Opacidad del separador del hueco vendible: el `linea` del sistema sobre oscuro.
const double _lineaAlfa = 0.28;

Color _palette(String nombre) => Color(OverlaySpec.colorsArgb[nombre]!);
int _sb(String clave) => OverlaySpec.scoreboard[clave]!;
int _st(String clave) => OverlaySpec.strip[clave]!;
final RegExp _digito = RegExp(r'\d');

/// La geometría del gráfico, medida una vez sobre el tamaño de salida.
class ScoreboardLayout {
  ScoreboardLayout._(this.width, this.height, this.state, this.sponsorSlots, this.stripImageSize, this.s);

  /// Mide el gráfico para `state` sobre un lienzo de `width`×`height`; `stripImageSize` es
  /// el tamaño de la imagen de la franja, si la hay.
  factory ScoreboardLayout.measure(
    int width,
    int height,
    ScoreboardState state, {
    bool sponsorSlots = true,
    Size? stripImageSize,
  }) {
    final ScoreboardLayout l = ScoreboardLayout._(
      width,
      height,
      state,
      sponsorSlots,
      stripImageSize,
      width / OverlaySpec.refWidth,
    );
    l._measure();
    return l;
  }

  final int width;
  final int height;
  final ScoreboardState state;
  final bool sponsorSlots;
  final Size? stripImageSize;

  /// Escala sobre 1920 de ancho.
  final double s;

  /// Cajas por elemento, en píxeles de salida: las mismas claves que boxes.json.
  final Map<String, Rect> boxes = <String, Rect>{};
  final Map<String, TextStyle> _fonts = <String, TextStyle>{};
  final Map<String, double> _v = <String, double>{};

  int px(double v) => pyRound(v * s);

  /// Una medida del marcador o de la franja de OverlaySpec, ya escalada.
  double sb(String clave) => px(_sb(clave).toDouble()).toDouble();
  double st(String clave) => px(_st(clave).toDouble()).toDouble();

  TextStyle font(String nombre) => _fonts[nombre]!;

  /// `int(draw.textlength(...))`: el avance, truncado como en la referencia.
  double textWidth(String text, String fuente) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: font(fuente)),
      textDirection: TextDirection.ltr,
    )..layout();
    final double ancho = tp.width.floorToDouble();
    tp.dispose();
    return ancho;
  }

  /// La celda de las cifras tabulares: el dígito más ancho.
  double digitCell(String fuente) {
    double celda = 0;
    for (int d = 0; d <= 9; d++) {
      celda = math.max(celda, textWidth('$d', fuente));
    }
    return celda;
  }

  /// El ancho de `text` con cada dígito en su celda, como `_tabular_width`.
  double tabularWidth(String text, String fuente) {
    final double celda = digitCell(fuente);
    double total = 0;
    for (final String c in text.split('')) {
      total += _digito.hasMatch(c) ? celda : textWidth(c, fuente);
    }
    return total;
  }

  double v(String clave) => _v[clave]!;

  String get home => state.home.toUpperCase();
  String get away => state.away.toUpperCase();
  String get competition => state.competition.toUpperCase();
  String get cameraMode => state.cameraMode.toUpperCase();

  void _measure() {
    for (final MapEntry<String, int> e in OverlaySpec.fontSizes.entries) {
      _fonts[e.key] = GalaBrand.text(OverlaySpec.fontFaces[e.key]!,
          OverlaySpec.fontWeights[e.key]!, px(e.value.toDouble()).toDouble());
    }

    // ---------------- marcador: el `Scoreboard` del sistema ----------------
    final double homeW = textWidth(home, 'team'), awayW = textWidth(away, 'team');
    final double glW = math.max(
        sb('goal_min_w'), textWidth('${state.homeGoals}', 'score') + 2 * sb('goal_pad_x'));
    final double guionW = textWidth('-', 'score');
    final double visitaW =
        guionW + sb('goal_dash_gap') + textWidth('${state.awayGoals}', 'score');
    final double gvW = math.max(sb('goal_min_w'), visitaW + 2 * sb('goal_pad_x'));
    final double gap = sb('row_gap'), crestW = sb('crest_w'), crestH = sb('crest_h');
    final double filaW =
        2 * crestW + 4 * gap + homeW + awayW + 2 * sb('goals_margin') + glW + gvW;
    final double bodyW = filaW + 2 * sb('body_pad_x');
    final double tipIn = sb('tip_w') - sb('tip_overlap');
    final double barW = bodyW + 2 * tipIn;

    final double liveW = sb('live_pad_l') +
        sb('live_dot') +
        sb('live_gap') +
        sb('live_pad_r') +
        textWidth(OverlaySpec.scoreboardTexts['live']!, 'live');
    final double compW = textWidth(competition, 'comp') + 2 * sb('chip_pad_x');
    final double clockW = tabularWidth(state.clockText, 'clock') + 2 * sb('clock_pad_x');

    // La barra se corta a -30°: abajo sobresale `sesgo` a la izquierda, y ese pico es el
    // que toca el margen.
    final double bh = sb('bar_h'), eh = sb('status_h');
    final double sesgo = bh / 2 * GalaBrand.inclinacion;
    final double x0 = sb('margin') + sesgo;
    final double yEstado = sb('top_y');
    final double yBarra = yEstado + eh + sb('status_to_bar');
    final double cy = yBarra + bh / 2;

    // Encima de la barra, la competición; el reloj, a su derecha; EN VIVO, debajo
    // (enmienda del ADR 0026 del 2026-10-16).
    final double ex = x0 + sb('status_pad_x');
    boxes['competition'] = Rect.fromLTRB(ex, yEstado, ex + compW, yEstado + eh);
    final double relojX = x0 + barW + sb('clock_gap');
    boxes['clock'] = Rect.fromLTRB(relojX - sesgo, yBarra, relojX + clockW + sesgo, yBarra + bh);
    if (state.live) {
      final double yVivo = yBarra + bh + sb('live_below');
      boxes['live'] = Rect.fromLTRB(ex, yVivo, ex + liveW, yVivo + eh);
    }

    // La esquina de arriba a la derecha: el icono de la copa y el logo de la casa.
    final double pad = sb('corner_pad');
    final int alto = px(_sb('corner_logo_h').toDouble());
    final int casaW = math.max(1, pyRound(_st('logo_src_w') * alto / _st('logo_src_h')));
    final double derecha = width - sb('margin') - pad;
    boxes['broadcaster'] = Rect.fromLTRB(derecha - casaW, yEstado + pad, derecha, yEstado + pad + alto);
    double izquierda = derecha - casaW;
    if (state.iconRev != null) {
      final double copaX1 = izquierda - sb('corner_gap');
      boxes['championship'] = Rect.fromLTRB(copaX1 - alto, yEstado + pad, copaX1, yEstado + pad + alto);
      izquierda = copaX1 - alto;
    }
    boxes['corner'] = Rect.fromLTRB(izquierda - pad, yEstado, width - sb('margin'), yEstado + alto + 2 * pad);

    final double rx = x0 + tipIn + sb('body_pad_x');
    final double homeX = rx + crestW + gap;
    final double glX = homeX + homeW + gap + sb('goals_margin');
    final double gvX = glX + glW;
    final double awayX = gvX + gvW + sb('goals_margin') + gap;
    final double crestAwayX = awayX + awayW + gap;
    final double mitadTeam = px(OverlaySpec.fontSizes['team']!.toDouble()) / 2;
    boxes['bug'] = Rect.fromLTRB(x0 - sesgo, yBarra, x0 + barW + sesgo, yBarra + bh);
    boxes['home_crest'] = Rect.fromLTRB(rx, cy - crestH / 2, rx + crestW, cy + crestH / 2);
    boxes['home_name'] = Rect.fromLTRB(homeX, cy - mitadTeam, homeX + homeW, cy + mitadTeam);
    boxes['home_score'] = Rect.fromLTRB(glX - sesgo, yBarra, glX + glW + sesgo, yBarra + bh);
    boxes['away_score'] = Rect.fromLTRB(gvX - sesgo, yBarra, gvX + gvW + sesgo, yBarra + bh);
    boxes['away_name'] = Rect.fromLTRB(awayX, cy - mitadTeam, awayX + awayW, cy + mitadTeam);
    boxes['away_crest'] =
        Rect.fromLTRB(crestAwayX, cy - crestH / 2, crestAwayX + crestW, cy + crestH / 2);
    _v.addAll(<String, double>{
      'x0': x0,
      'y_barra': yBarra,
      'bh': bh,
      'cy_barra': cy,
      'cy_estado': yEstado + eh / 2,
      'bar_w': barW,
      'body_w': bodyW,
      'tip_in': tipIn,
      'gl_x': glX,
      'gl_w': glW,
      'gv_x': gvX,
      'gv_w': gvW,
      'visita_w': visitaW,
      'guion_w': guionW,
      'home_x': homeX,
      'away_x': awayX,
      'clock_x': relojX,
      'clock_w': clockW,
    });

    // ---------------- barra de patrocinio ----------------
    if (!state.stripVisible) {
      return;
    }
    final double sh = px(OverlaySpec.stripHeight.toDouble()).toDouble();
    final double sy0 = height - sh, scy = sy0 + sh / 2;
    boxes['strip'] = Rect.fromLTRB(0, sy0, width.toDouble(), height.toDouble());

    // El hueco vendible es fijo: lo que dejan las dos zonas reservadas (el de los anuncios).
    final double sellX0 = px((OverlaySpec.margin + _st('reserved_left')).toDouble()).toDouble();
    final double sellX1 =
        width - px((OverlaySpec.margin + _st('reserved_right')).toDouble()).toDouble();
    boxes['sellable'] = Rect.fromLTRB(sellX0, sy0, sellX1, height.toDouble());
    _v.addAll(<String, double>{'strip_y': sy0, 'strip_h': sh});
    if (!sponsorSlots) {
      return; // con anuncios, el anuncio ocupa la franja: debajo solo va el fondo
    }

    // La imagen que subió el operador, si la hay, y el título y el subtítulo a su derecha
    // (enmienda del ADR 0027 del 2026-10-16).
    double x = px(OverlaySpec.margin.toDouble()).toDouble();
    final Size? img = stripImageSize;
    if (img != null) {
      final double escala = math.min(st('image_max_w') / img.width, st('image_h') / img.height);
      final double iw = math.max(1, pyRound(img.width * escala)).toDouble();
      final double ih = math.max(1, pyRound(img.height * escala)).toDouble();
      final double iy = pyRound(scy - ih / 2).toDouble();
      boxes['strip_image'] = Rect.fromLTWH(x, iy, iw, ih);
      x += iw + st('image_gap');
    }
    final double hueco = width - px(OverlaySpec.margin.toDouble()) - x;
    final bool haySub = state.stripSubtitle.trim().isNotEmpty;
    final double ty = scy + (haySub ? st('title_dy') : 0);
    final String titulo = fitWidth(state.stripTitle, 'strip_title', hueco);
    double mitad = px(OverlaySpec.fontSizes['strip_title']!.toDouble()) / 2;
    boxes['strip_title'] = Rect.fromLTRB(x, ty - mitad, x + textWidth(titulo, 'strip_title'), ty + mitad);
    _v.addAll(<String, double>{'strip_text_x': x, 'strip_title_y': ty, 'strip_text_w': hueco});
    if (haySub) {
      final String sub = fitWidth(state.stripSubtitle, 'strip_subtitle', hueco);
      final double sy = scy + st('subtitle_dy');
      mitad = px(OverlaySpec.fontSizes['strip_subtitle']!.toDouble()) / 2;
      boxes['strip_subtitle'] = Rect.fromLTRB(x, sy - mitad, x + textWidth(sub, 'strip_subtitle'), sy + mitad);
      _v['strip_subtitle_y'] = sy;
    }
  }

  /// El texto si cabe en `ancho`; si no, recortado con puntos suspensivos (`_fit_width`).
  String fitWidth(String text, String fuente, double ancho) {
    if (textWidth(text, fuente) <= ancho) {
      return text;
    }
    String t = text;
    while (t.length > 1 && textWidth('$t…', fuente) > ancho) {
      t = t.substring(0, t.length - 1);
    }
    return '${t.trimRight()}…';
  }
}

/// Pinta la capa RGBA del gráfico entera, con fondo transparente.
class ScoreboardPainter extends CustomPainter {
  ScoreboardPainter(
    this.state, {
    required this.isotipo,
    this.championship,
    this.crests = const <String, ui.Image>{},
    this.sponsorSlots = true,
    this.stripImage,
  });

  /// La imagen de la franja, ya decodificada; va si el estado dice que hay (`stripImageRev`).
  final ui.Image? stripImage;

  /// Los escudos de los equipos que los tienen, por lado (`home`, `away`), ya decodificados:
  /// sustituyen al genérico (ADR 0028).
  final Map<String, ui.Image> crests;

  final ScoreboardState state;

  /// El icono del campeonato, ya decodificado; va en el chip de la competición si el
  /// estado dice que hay (`iconRev`).
  final ui.Image? championship;

  /// El isotipo de la franja, ya decodificado (`GalaBrand.isotipo()`).
  final ui.Image isotipo;

  /// Sin ranuras cuando el panel reproduce anuncios de verdad: ocupan el hueco
  /// vendible y se superpondrían al anuncio.
  final bool sponsorSlots;

  @override
  void paint(Canvas canvas, Size size) {
    final ScoreboardLayout l = ScoreboardLayout.measure(
      size.width.round(),
      size.height.round(),
      state,
      sponsorSlots: sponsorSlots,
      stripImageSize: state.stripImageRev != null && stripImage != null
          ? Size(stripImage!.width.toDouble(), stripImage!.height.toDouble())
          : null,
    );
    _paintStatus(canvas, l);
    _paintBar(canvas, l);
    _paintCorner(canvas, l);
    if (state.stripVisible) {
      _paintStrip(canvas, l);
    }
  }

  @override
  bool shouldRepaint(ScoreboardPainter old) =>
      old.state != state ||
      old.sponsorSlots != sponsorSlots ||
      old.isotipo != isotipo ||
      old.championship != championship ||
      old.crests != crests ||
      old.stripImage != stripImage;

  static Paint _fill(Color c) => Paint()..color = c;

  static Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..strokeWidth = w
    ..style = PaintingStyle.stroke;

  static void _line(Canvas c, Offset a, Offset b, Color color, double w) =>
      c.drawLine(a, b, _stroke(color, w));

  /// Texto con el ancla de PIL: `lm` (izquierda, centro vertical) o `mm`.
  static void _text(Canvas c, ScoreboardLayout l, String text, String fuente, Color color,
      Offset at, {bool centred = false}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: l.font(fuente).copyWith(color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    final double x = centred ? at.dx - tp.width / 2 : at.dx;
    tp.paint(c, Offset(x, at.dy - tp.height / 2));
    tp.dispose();
  }

  static RRect _rrect(Rect r, double radio, {bool left = true, bool right = true}) {
    final Radius rr = Radius.circular(radio);
    return RRect.fromRectAndCorners(
      r,
      topLeft: left ? rr : Radius.zero,
      bottomLeft: left ? rr : Radius.zero,
      topRight: right ? rr : Radius.zero,
      bottomRight: right ? rr : Radius.zero,
    );
  }

  // ---------------- la competición, EN VIVO y el chip de la esquina ----------------
  void _paintStatus(Canvas c, ScoreboardLayout l) {
    final double radio = l.sb('radius');
    final double alfa = _sb('shadow_alpha_pct') / 100;
    final Color velo = _palette('chrome_soft');
    final Rect comp = l.boxes['competition']!;
    final RRect compR = _rrect(comp, radio);
    final RRect esquinaR = _rrect(l.boxes['corner']!, radio);
    final RRect? liveR = state.live ? _rrect(l.boxes['live']!, radio) : null;

    // La sombra va bajo la silueta de cada pieza, a la opacidad de su relleno, como el
    // alfa de la capa que desenfoca la referencia.
    GalaBrand.shadow(c, Path()..addRRect(compR)..addRRect(esquinaR), alfa * velo.a, l.s);
    if (liveR != null) GalaBrand.shadow(c, Path()..addRRect(liveR), alfa, l.s);

    c.drawRRect(compR, _fill(velo));
    c.drawRRect(esquinaR, _fill(velo));
    if (liveR != null) c.drawRRect(liveR, _fill(_palette('live')));

    _text(c, l, l.competition, 'comp', GalaBrand.token('gris-claro'),
        Offset(comp.left + l.sb('chip_pad_x'), l.v('cy_estado')));
    if (state.live) {
      final Rect vivo = l.boxes['live']!;
      final double punto = l.sb('live_dot');
      final double px0 = vivo.left + l.sb('live_pad_l');
      c.drawCircle(Offset(px0 + punto / 2, vivo.center.dy), punto / 2, _fill(_palette('white')));
      _text(c, l, OverlaySpec.scoreboardTexts['live']!, 'live', _palette('white'),
          Offset(px0 + punto + l.sb('live_gap'), vivo.center.dy));
    }
  }

  // ---------------- la esquina: la copa y el logo de la casa ----------------
  void _paintCorner(Canvas c, ScoreboardLayout l) {
    void imagen(ui.Image img, Rect caja) {
      final double escala = math.min(caja.width / img.width, caja.height / img.height);
      c.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromCenter(center: caja.center, width: img.width * escala, height: img.height * escala),
        Paint()..filterQuality = FilterQuality.high,
      );
    }

    final Rect casa = l.boxes['broadcaster']!;
    imagen(isotipo, casa);
    final Rect? copa = l.boxes['championship'];
    final ui.Image? icono = championship;
    if (copa != null && icono != null) {
      imagen(icono, copa);
    }
    if (copa != null) {
      final double x = (copa.right + casa.left) / 2;
      _line(c, Offset(x, copa.top), Offset(x, copa.bottom), GalaBrand.token('gris-oceanico').withValues(alpha: _lineaAlfa), math.max(1, l.s));
    }
  }

  // ---------------- la barra ----------------
  void _paintBar(Canvas c, ScoreboardLayout l) {
    final double x0 = l.v('x0'), yb = l.v('y_barra'), bh = l.v('bh'), cy = l.v('cy_barra');
    final double cuerpoX = x0 + l.v('tip_in'), cuerpoW = l.v('body_w');
    final double punta = l.sb('tip_w');
    final Color teal = GalaBrand.token('teal-electrico'), azul = GalaBrand.token('azul-deportivo');
    final Rect alto = Rect.fromLTRB(0, yb, 1, yb + bh); // los degradados van a lo alto

    final Path puntaIzq = GalaBrand.skewed(x0, yb, punta, bh);
    final Path cuerpo = GalaBrand.skewed(cuerpoX, yb, cuerpoW, bh);
    final Path puntaDer = GalaBrand.skewed(x0 + l.v('bar_w') - punta, yb, punta, bh);
    final Rect escudoL = l.boxes['home_crest']!, escudoV = l.boxes['away_crest']!;
    // La sombra sigue lo que se pinta: un escudo de verdad no tiene la silueta del genérico.
    final Path silueta = Path()
      ..addPath(puntaIzq, Offset.zero)
      ..addPath(cuerpo, Offset.zero)
      ..addPath(puntaDer, Offset.zero)
      ..addPath(GalaBrand.skewed(l.v('clock_x'), yb, l.v('clock_w'), bh), Offset.zero);
    for (final (String lado, Rect caja) in <(String, Rect)>[('home', escudoL), ('away', escudoV)]) {
      if (crests[lado] == null) {
        silueta.addPath(GalaBrand.crestPath(caja), Offset.zero);
      }
    }
    GalaBrand.shadow(c, silueta, _sb('bar_shadow_alpha_pct') / 100, l.s);

    c.drawPath(puntaIzq, GalaBrand.fill(teal, bottom: azul, box: alto));
    c.drawPath(cuerpo,
        GalaBrand.fill(_palette('chrome'), bottom: GalaBrand.token('azul-profundo'), box: alto));
    final double filete = l.sb('body_edge_h');
    c.drawPath(
        GalaBrand.skewed(cuerpoX, yb + bh - filete, cuerpoW, filete, centerY: cy), _fill(azul));
    c.drawPath(GalaBrand.skewed(l.v('gl_x'), yb, l.v('gl_w'), bh),
        GalaBrand.fill(_palette('home'), bottom: GalaBrand.token('verde-oceano'), box: alto));
    c.drawPath(GalaBrand.skewed(l.v('gv_x'), yb, l.v('gv_w'), bh), _fill(_palette('away')));
    final bool genericoL = GalaBrand.paintTeamCrest(c, escudoL, _palette('home'), crests['home']);
    final bool genericoV = GalaBrand.paintTeamCrest(c, escudoV, _palette('away'), crests['away']);
    c.drawPath(puntaDer, GalaBrand.fill(teal, bottom: azul, box: alto));
    // El reloj: una caja como el cuerpo de la barra, a su derecha y a su altura, con cifras
    // tabulares (cada dígito centrado en su celda).
    final double relojX = l.v('clock_x'), relojW = l.v('clock_w');
    c.drawPath(GalaBrand.skewed(relojX, yb, relojW, bh),
        GalaBrand.fill(_palette('chrome'), bottom: GalaBrand.token('azul-profundo'), box: alto));
    c.drawPath(GalaBrand.skewed(relojX, yb + bh - filete, relojW, filete, centerY: cy), _fill(azul));
    final double celda = l.digitCell('clock');
    double x = relojX + l.sb('clock_pad_x');
    for (final String ch in state.clockText.split('')) {
      final double a = _digito.hasMatch(ch) ? celda : l.textWidth(ch, 'clock');
      _text(c, l, ch, 'clock', _palette('white'), Offset(x + a / 2, cy), centred: true);
      x += a;
    }

    for (final (Rect caja, String nombre, String color, bool generico) in <(Rect, String, String, bool)>[
      (escudoL, l.home, 'home', genericoL),
      (escudoV, l.away, 'away', genericoV),
    ]) {
      if (!generico) {
        continue; // un escudo de verdad no lleva siglas encima
      }
      _text(c, l, GalaBrand.crestInitials(nombre), 'crest', _palette(color),
          GalaBrand.crestInitialsCenter(caja),
          centred: true);
    }
    _text(c, l, l.home, 'team', _palette('white'), Offset(l.v('home_x'), cy));
    _text(c, l, l.away, 'team', _palette('white'), Offset(l.v('away_x'), cy));
    final Color tinta = GalaBrand.token('azul-profundo');
    _text(c, l, '${state.homeGoals}', 'score', tinta, Offset(l.v('gl_x') + l.v('gl_w') / 2, cy),
        centred: true);
    double vx = l.v('gv_x') + (l.v('gv_w') - l.v('visita_w')) / 2;
    _text(c, l, '-', 'score', tinta, Offset(vx, cy));
    vx += l.v('guion_w') + l.sb('goal_dash_gap');
    _text(c, l, '${state.awayGoals}', 'score', tinta, Offset(vx, cy));
  }

  // ---------------- la franja ----------------
  void _paintStrip(Canvas c, ScoreboardLayout l) {
    final double sy0 = l.v('strip_y');
    final double width = l.width.toDouble();
    c.drawRect(l.boxes['strip']!, _fill(_palette('bar')));
    c.drawRect(Rect.fromLTWH(0, sy0, width, math.max(1, l.st('edge_h'))), _fill(_palette('edge')));

    final Rect? caja = l.boxes['strip_image'];
    final ui.Image? img = stripImage;
    if (caja != null && img != null) {
      c.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        caja,
        Paint()..filterQuality = FilterQuality.high,
      );
    }
    if (l.boxes.containsKey('strip_title')) {
      final double x = l.v('strip_text_x'), hueco = l.v('strip_text_w');
      _text(c, l, l.fitWidth(state.stripTitle, 'strip_title', hueco), 'strip_title', _palette('white'),
          Offset(x, l.v('strip_title_y')));
      if (l.boxes.containsKey('strip_subtitle')) {
        _text(c, l, l.fitWidth(state.stripSubtitle, 'strip_subtitle', hueco), 'strip_subtitle',
            _palette('dim'), Offset(x, l.v('strip_subtitle_y')));
      }
    }
  }
}

/// Atajo para quien solo quiere la imagen: pinta `state` en un ui.Image.
Future<ui.Image> paintScoreboard(
  ScoreboardState state,
  int width,
  int height, {
  bool sponsorSlots = true,
  ui.Image? championship,
  Map<String, ui.Image> crests = const <String, ui.Image>{},
  ui.Image? stripImage,
}) async {
  final ui.Image isotipo = await GalaBrand.isotipo();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  ScoreboardPainter(
    state,
    isotipo: isotipo,
    championship: championship,
    crests: crests,
    sponsorSlots: sponsorSlots,
    stripImage: stripImage,
  ).paint(canvas, Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
