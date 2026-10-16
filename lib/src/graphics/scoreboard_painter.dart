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
  });

  final String competition;
  final String home;
  final String away;
  final int homeGoals;
  final int awayGoals;
  final int clockS;
  final bool live;
  final String cameraMode;

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
      other.cameraMode == cameraMode;

  @override
  int get hashCode =>
      Object.hash(competition, home, away, homeGoals, awayGoals, clockS, live, cameraMode);
}

// Textos fijos y colores de la maqueta que REF-32 no exporta porque solo los usa el
// dibujo (overlay_preview.py: SLOT_TEXTS, AI_TEXT y CLAIM_LINES).
const String _aiText = 'Transmisión automática con IA';
const List<String> _claimLines = <String>['EL DEPORTE', 'TAMBIÉN CONSERVA'];
const List<(String, String, Color)> _slotTexts = <(String, String, Color)>[
  ('GALÁPAGOS', 'SIEMPRE CONTIGO', Color(0xFFDDE7E4)),
  ('NUESTRAS ISLAS', 'NUESTRO FUTURO', Color(0xFF7FC4DC)),
  ('ENERGÍA LIMPIA', 'PARA UN MEJOR MAÑANA', Color(0xFFF5C542)),
];
const List<String> _slotIcons = <String>['mountain', 'waves', 'sun'];
const List<Color> _waveShades = <Color>[Color(0xFF7FC4DC), Color(0xFF4E93B4), Color(0xFF31708F)];

/// Opacidad del separador del hueco vendible: el `linea` del sistema sobre oscuro.
const double _lineaAlfa = 0.28;

Color _palette(String nombre) => Color(OverlaySpec.colorsArgb[nombre]!);
int _sb(String clave) => OverlaySpec.scoreboard[clave]!;
int _st(String clave) => OverlaySpec.strip[clave]!;
final RegExp _digito = RegExp(r'\d');

/// La geometría del gráfico, medida una vez sobre el tamaño de salida.
class ScoreboardLayout {
  ScoreboardLayout._(this.width, this.height, this.state, this.sponsorSlots, this.s);

  /// Mide el gráfico para `state` sobre un lienzo de `width`×`height`.
  factory ScoreboardLayout.measure(
    int width,
    int height,
    ScoreboardState state, {
    bool sponsorSlots = true,
  }) {
    final ScoreboardLayout l =
        ScoreboardLayout._(width, height, state, sponsorSlots, width / OverlaySpec.refWidth);
    l._measure();
    return l;
  }

  final int width;
  final int height;
  final ScoreboardState state;
  final bool sponsorSlots;

  /// Escala sobre 1920 de ancho.
  final double s;

  /// Cajas por elemento, en píxeles de salida: las mismas claves que boxes.json.
  final Map<String, Rect> boxes = <String, Rect>{};
  final Map<String, TextStyle> _fonts = <String, TextStyle>{};
  final Map<String, double> _v = <String, double>{};
  final List<(double, double)> _slotXs = <(double, double)>[];

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

    final double liveW = state.live
        ? sb('live_pad_l') +
            sb('live_dot') +
            sb('live_gap') +
            sb('live_pad_r') +
            textWidth(OverlaySpec.scoreboardTexts['live']!, 'live')
        : 0;
    final double compW = textWidth(competition, 'comp') + 2 * sb('chip_pad_x');
    final double clockW = tabularWidth(state.clockText, 'clock') + 2 * sb('chip_pad_x');
    final double estadoW = 2 * sb('status_pad_x') + liveW + compW + sb('status_gap') + clockW;
    final double ancho = math.max(barW, estadoW);

    // La barra se corta a -30°: abajo sobresale `sesgo` a la izquierda, y ese pico es el
    // que toca el margen.
    final double bh = sb('bar_h'), eh = sb('status_h');
    final double sesgo = bh / 2 * GalaBrand.inclinacion;
    final double x0 = sb('margin') + sesgo;
    final double yEstado = sb('top_y');
    final double yBarra = yEstado + eh + sb('status_to_bar');
    final double cy = yBarra + bh / 2;

    final double ex = x0 + sb('status_pad_x');
    if (state.live) boxes['live'] = Rect.fromLTRB(ex, yEstado, ex + liveW, yEstado + eh);
    boxes['competition'] = Rect.fromLTRB(ex + liveW, yEstado, ex + liveW + compW, yEstado + eh);
    final double relojX = x0 + ancho - sb('status_pad_x') - clockW;
    boxes['clock'] = Rect.fromLTRB(relojX, yEstado, relojX + clockW, yEstado + eh);

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
    });

    // ---------------- chip de cámara ----------------
    final double camLabelW = textWidth(OverlaySpec.scoreboardTexts['camera']!, 'cam');
    final double camW = 2 * sb('chip_pad_x') +
        2 * sb('cam_icon_r') +
        2 * sb('chip_gap') +
        camLabelW +
        textWidth(cameraMode, 'cam');
    final double camX = width - sb('margin') - camW;
    boxes['camera'] = Rect.fromLTRB(camX, yEstado, camX + camW, yEstado + eh);
    _v['cam_label_w'] = camLabelW;

    // ---------------- barra de patrocinio ----------------
    final double sh = px(OverlaySpec.stripHeight.toDouble()).toDouble();
    final double sy0 = height - sh, scy = sy0 + sh / 2;
    boxes['strip'] = Rect.fromLTRB(0, sy0, width.toDouble(), height.toDouble());

    final int logoH = px(_st('logo_h').toDouble());
    final int logoW = math.max(1, pyRound(_st('logo_src_w') * logoH / _st('logo_src_h')));
    final double lx = px(OverlaySpec.margin.toDouble()).toDouble();
    final double ly = pyRound(scy - logoH / 2).toDouble();
    boxes['logo'] = Rect.fromLTWH(lx, ly, logoW.toDouble(), logoH.toDouble());
    final double claimX = lx + logoW + st('logo_gap');
    final double claimW =
        math.max(textWidth(_claimLines[0], 'claim'), textWidth(_claimLines[1], 'claim'));
    boxes['claim'] = Rect.fromLTRB(lx, sy0, claimX + claimW, height.toDouble());

    // El hueco vendible es fijo: lo que dejan las dos zonas reservadas.
    final double sellX0 = px((OverlaySpec.margin + _st('reserved_left')).toDouble()).toDouble();
    final double sellX1 =
        width - px((OverlaySpec.margin + _st('reserved_right')).toDouble()).toDouble();
    boxes['sellable'] = Rect.fromLTRB(sellX0, sy0, sellX1, height.toDouble());
    _v.addAll(<String, double>{
      'strip_y': sy0,
      'strip_h': sh,
      'claim_x': claimX,
      'divider_x': sellX0,
    });

    double cursor = sellX0 + st('slot_gap');
    if (sponsorSlots) {
      for (int i = 0; i < _slotTexts.length; i++) {
        final (String title, String sub, Color _) = _slotTexts[i];
        final double textX = cursor + st('slot_icon_r') * 2 + px(13);
        final double a = math.max(textWidth(title, 'slot'), textWidth(sub, 'sub'));
        boxes['slot_$i'] = Rect.fromLTRB(cursor, sy0, textX + a, height.toDouble());
        _slotXs.add((cursor, textX));
        cursor = textX + a + st('slot_gap');
      }
    }

    final double aiW = textWidth(_aiText, 'ai');
    final double ax = width - px(OverlaySpec.margin.toDouble()) - aiW;
    final double mitadAi = px(OverlaySpec.fontSizes['ai']!.toDouble()) / 2;
    boxes['ai'] = Rect.fromLTRB(ax, scy - mitadAi, ax + aiW, scy + mitadAi);
    _v['ai_x'] = ax;
  }
}

/// Pinta la capa RGBA del gráfico entera, con fondo transparente.
class ScoreboardPainter extends CustomPainter {
  ScoreboardPainter(this.state, {required this.isotipo, this.sponsorSlots = true});

  final ScoreboardState state;

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
    );
    _paintStatus(canvas, l);
    _paintBar(canvas, l);
    _paintCamera(canvas, l);
    _paintStrip(canvas, l);
  }

  @override
  bool shouldRepaint(ScoreboardPainter old) =>
      old.state != state || old.sponsorSlots != sponsorSlots || old.isotipo != isotipo;

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

  // ---------------- la fila de estado ----------------
  void _paintStatus(Canvas c, ScoreboardLayout l) {
    final double radio = l.sb('radius');
    final double alfa = _sb('shadow_alpha_pct') / 100;
    final Color velo = _palette('chrome_soft');
    final Rect comp = l.boxes['competition']!, reloj = l.boxes['clock']!;
    // EN VIVO y la competición forman una sola pieza: solo redondea por fuera.
    final RRect compR = _rrect(comp, radio, left: !state.live);
    final RRect relojR = _rrect(reloj, radio);
    final RRect? liveR = state.live ? _rrect(l.boxes['live']!, radio, right: false) : null;

    // La sombra va bajo la silueta de cada pieza, a la opacidad de su relleno, como el
    // alfa de la capa que desenfoca la referencia.
    final Path veladas = Path()
      ..addRRect(compR)
      ..addRRect(relojR)
      ..addRRect(_rrect(l.boxes['camera']!, radio));
    GalaBrand.shadow(c, veladas, alfa * velo.a, l.s);
    if (liveR != null) GalaBrand.shadow(c, Path()..addRRect(liveR), alfa, l.s);

    if (liveR != null) c.drawRRect(liveR, _fill(_palette('live')));
    c.drawRRect(compR, _fill(velo));
    c.drawRRect(relojR, _fill(velo));
    c.drawDRRect(relojR, relojR.deflate(l.sb('clock_ring')), _fill(_palette('dim')));

    final double ecy = l.v('cy_estado');
    final double pad = l.sb('chip_pad_x');
    if (state.live) {
      final double punto = l.sb('live_dot');
      final double px0 = l.boxes['live']!.left + l.sb('live_pad_l');
      c.drawCircle(Offset(px0 + punto / 2, ecy), punto / 2, _fill(_palette('white')));
      _text(c, l, OverlaySpec.scoreboardTexts['live']!, 'live', _palette('white'),
          Offset(px0 + punto + l.sb('live_gap'), ecy));
    }
    _text(c, l, l.competition, 'comp', GalaBrand.token('gris-claro'),
        Offset(comp.left + pad, ecy));

    // El reloj con cifras tabulares: cada dígito centrado en su celda.
    final double celda = l.digitCell('clock');
    double x = reloj.left + pad;
    for (final String ch in state.clockText.split('')) {
      final double a = _digito.hasMatch(ch) ? celda : l.textWidth(ch, 'clock');
      _text(c, l, ch, 'clock', _palette('white'), Offset(x + a / 2, ecy), centred: true);
      x += a;
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
    final Path silueta = Path()
      ..addPath(puntaIzq, Offset.zero)
      ..addPath(cuerpo, Offset.zero)
      ..addPath(puntaDer, Offset.zero)
      ..addPath(GalaBrand.crestPath(escudoL), Offset.zero)
      ..addPath(GalaBrand.crestPath(escudoV), Offset.zero);
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
    GalaBrand.paintCrest(c, escudoL, _palette('home'));
    GalaBrand.paintCrest(c, escudoV, _palette('away'));
    c.drawPath(puntaDer, GalaBrand.fill(teal, bottom: azul, box: alto));

    for (final (Rect caja, String nombre, String color) in <(Rect, String, String)>[
      (escudoL, l.home, 'home'),
      (escudoV, l.away, 'away'),
    ]) {
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

  // ---------------- el chip de cámara ----------------
  void _paintCamera(Canvas c, ScoreboardLayout l) {
    final Rect caja = l.boxes['camera']!;
    final double ecy = l.v('cy_estado');
    c.drawRRect(_rrect(caja, l.sb('radius')), _fill(_palette('chrome_soft')));
    final double k = l.sb('cam_icon_r');
    final double iconX = caja.left + l.sb('chip_pad_x') + k;
    final double trazo = math.max(1, l.sb('cam_icon_line'));
    final Color teal = _palette('home');
    for (final (int sx, int sy) in const <(int, int)>[(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final Offset esquina = Offset(iconX + sx * k, ecy + sy * k);
      _line(c, esquina, Offset(iconX + sx * k * 0.35, ecy + sy * k), teal, trazo);
      _line(c, esquina, Offset(iconX + sx * k, ecy + sy * k * 0.35), teal, trazo);
    }
    c.drawCircle(Offset(iconX, ecy), l.px(3).toDouble(), _stroke(teal, trazo));
    double tx = iconX + k + l.sb('chip_gap');
    _text(c, l, OverlaySpec.scoreboardTexts['camera']!, 'cam', _palette('dim'), Offset(tx, ecy));
    tx += l.v('cam_label_w') + l.sb('chip_gap');
    _text(c, l, l.cameraMode, 'cam', _palette('white'), Offset(tx, ecy));
  }

  // ---------------- la franja ----------------
  void _paintStrip(Canvas c, ScoreboardLayout l) {
    final double sh = l.v('strip_h'), sy0 = l.v('strip_y'), mid = sy0 + sh / 2;
    final double width = l.width.toDouble(), height = l.height.toDouble();
    c.drawRect(l.boxes['strip']!, _fill(_palette('bar')));
    c.drawRect(Rect.fromLTWH(0, sy0, width, math.max(1, l.st('edge_h'))), _fill(_palette('edge')));

    c.drawImageRect(
      isotipo,
      Rect.fromLTWH(0, 0, isotipo.width.toDouble(), isotipo.height.toDouble()),
      l.boxes['logo']!,
      Paint()..filterQuality = FilterQuality.high,
    );
    final double claimX = l.v('claim_x');
    final double mitadLinea = l.st('claim_line_h') / 2;
    _text(c, l, _claimLines[0], 'claim', _palette('white'), Offset(claimX, mid - mitadLinea));
    _text(c, l, _claimLines[1], 'claim', _palette('white'), Offset(claimX, mid + mitadLinea));
    final double dx = l.v('divider_x'), pad = l.st('divider_pad');
    _line(c, Offset(dx, sy0 + pad), Offset(dx, height - pad),
        GalaBrand.token('gris-oceanico').withValues(alpha: _lineaAlfa), math.max(1, l.px(1)).toDouble());

    if (sponsorSlots) {
      for (int i = 0; i < l._slotXs.length; i++) {
        final (double iconX, double textX) = l._slotXs[i];
        final (String title, String sub, Color colour) = _slotTexts[i];
        _paintSponsorIcon(
            c, _slotIcons[i], iconX, mid, l.st('slot_icon_r'), colour, math.max(1, l.px(2)).toDouble());
        _text(c, l, title, 'slot', _palette('white'), Offset(textX, mid - l.px(11)));
        _text(c, l, sub, 'sub', _palette('dim'), Offset(textX, mid + l.px(13)));
      }
    }

    final double ax = l.v('ai_x');
    final double rw = l.st('raya_w'), rh = l.st('raya_h');
    final double rx = ax - l.st('raya_gap') - rw;
    c.drawPath(
      GalaBrand.skewed(rx, mid - rh / 2, rw, rh),
      GalaBrand.fill(GalaBrand.token('teal-electrico'),
          bottom: GalaBrand.token('azul-deportivo'), box: Rect.fromLTWH(rx, mid - rh / 2, rw, rh)),
    );
    _text(c, l, _aiText, 'ai', _palette('dim'), Offset(ax, mid));
  }

  /// Montaña, olas y sol: formas que se leen a 28 px, el tamaño en emisión.
  static void _paintSponsorIcon(
      Canvas c, String kind, double x, double cy, double r, Color colour, double width) {
    switch (kind) {
      case 'mountain':
        c.drawPath(
          Path()
            ..moveTo(x, cy + r)
            ..lineTo(x + r * 0.85, cy - r * 0.75)
            ..lineTo(x + r * 1.25, cy - r * 0.1)
            ..lineTo(x + r * 1.6, cy - r * 0.6)
            ..lineTo(x + r * 2, cy + r)
            ..close(),
          _fill(colour),
        );
      case 'waves':
        for (int i = 0; i < _waveShades.length; i++) {
          final double y = cy - r * 0.55 + i * r * 0.6;
          final Path ola = Path();
          for (int k = 0; k < 13; k++) {
            final double px = x + r * 2 * k / 12;
            final double py = y - r * 0.22 * ((k ~/ 3).isOdd ? 1 : -1);
            k == 0 ? ola.moveTo(px, py) : ola.lineTo(px, py);
          }
          c.drawPath(ola, _stroke(_waveShades[i], width)..strokeJoin = StrokeJoin.round);
        }
      default:
        c.drawOval(Rect.fromLTRB(x + r * 0.55, cy - r * 0.45, x + r * 1.45, cy + r * 0.45),
            _fill(colour));
        for (int k = 0; k < 8; k++) {
          final double a = math.pi * k / 4;
          _line(c, Offset(x + r + math.cos(a) * r * 0.65, cy + math.sin(a) * r * 0.65),
              Offset(x + r + math.cos(a) * r, cy + math.sin(a) * r), colour, width);
        }
    }
  }
}

/// Atajo para quien solo quiere la imagen: pinta `state` en un ui.Image.
Future<ui.Image> paintScoreboard(ScoreboardState state, int width, int height,
    {bool sponsorSlots = true}) async {
  final ui.Image isotipo = await GalaBrand.isotipo();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  ScoreboardPainter(state, isotipo: isotipo, sponsorSlots: sponsorSlots)
      .paint(canvas, Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
