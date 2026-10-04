/// El marcador del programa en Dart (IOS-45), portado de build_overlay en
/// tools/overlay_preview.py del repo football-ai.
///
/// Medir y dibujar salen de la MISMA medición (`ScoreboardLayout`), como en la
/// referencia: dos aritméticas divergirían al primer retoque. Las medidas vienen de
/// OverlaySpec, generado por REF-32; aquí no se teclea ninguna que exista allí.
///
/// La tipografía es la de Zero, empaquetada: Archivo en negrita donde la maqueta
/// usaba Arial Narrow Bold e IBM Plex Sans donde usaba Arial Narrow. Los textos no
/// casan al píxel con la maqueta, y no tienen que hacerlo: la geometría sí.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import '../theme/zero_type.dart';

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

  String get scoreText => '$homeGoals - $awayGoals';

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
// dibujo (overlay_preview.py: SLOT_TEXTS, AI_TEXT, CLAIM_LINES y los tonos sueltos).
const String _aiText = 'Transmisión automática con IA';
const List<String> _claimLines = <String>['EL DEPORTE', 'TAMBIÉN CONSERVA'];
const String _liveText = 'EN VIVO';
const String _cameraLabel = 'CÁMARA IA';
const List<(String, String, Color)> _slotTexts = <(String, String, Color)>[
  ('GALÁPAGOS', 'SIEMPRE CONTIGO', Color(0xFFDDE7E4)),
  ('NUESTRAS ISLAS', 'NUESTRO FUTURO', Color(0xFF7FC4DC)),
  ('ENERGÍA LIMPIA', 'PARA UN MEJOR MAÑANA', Color(0xFFF5C542)),
];
const List<String> _slotIcons = <String>['mountain', 'waves', 'sun'];
const Color _textSoft = Color(0xFFD9E3E1);
const Color _aiColor = Color(0xFFC9D5D3);
const Color _shellLight = Color(0xFF8ACF4D);
const Color _shellDark = Color(0xFF4E8B27);
const Color _stripLine = Color(0x12FFFFFF);
const Color _divider = Color(0x28FFFFFF);
const List<Color> _waveShades = <Color>[Color(0xFF7FC4DC), Color(0xFF4E93B4), Color(0xFF31708F)];

/// Los nombres de fuente que la maqueta pinta con la regular; el resto, negrita.
const Set<String> _regularFonts = <String>{'sub', 'ai'};

Color _palette(String nombre) => Color(OverlaySpec.colorsArgb[nombre]!);

/// `round()` de Python: a mitad, al par. 4,5 px son 4, no 5.
int _roundHalfEven(double v) {
  final double suelo = v.floorToDouble();
  final double resto = v - suelo;
  if (resto > 0.5) return suelo.toInt() + 1;
  if (resto < 0.5) return suelo.toInt();
  return suelo.toInt().isEven ? suelo.toInt() : suelo.toInt() + 1;
}

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

  int px(double v) => _roundHalfEven(v * s);

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

  double v(String clave) => _v[clave]!;

  void _measure() {
    for (final MapEntry<String, int> e in OverlaySpec.fontSizes.entries) {
      final bool regular = _regularFonts.contains(e.key);
      _fonts[e.key] = TextStyle(
        fontFamily: regular ? ZeroType.sans : ZeroType.display,
        fontWeight: regular ? FontWeight.w400 : FontWeight.w700,
        fontSize: px(e.value.toDouble()).toDouble(),
        height: 1.0,
      );
    }
    final Map<String, int> sb = OverlaySpec.scoreboard;

    // ---------------- marcador ----------------
    final double homeW = textWidth(state.home, 'team');
    final double awayW = textWidth(state.away, 'team');
    final double scoreW = textWidth(state.scoreText, 'score');
    final int gap = px(26), barW = px(7), barPad = px(12), clockW = px(150), inner = px(12);
    final int crestW = px(sb['crest_w']!.toDouble());
    final double needed = crestW + barPad + barW + inner + homeW + gap + scoreW + gap + awayW +
        inner + barW + barPad + clockW.toDouble();
    final int bx = px(sb['margin']!.toDouble());
    final int by = px(sb['margin']! - 4.0);
    final double bw = math.max(px(sb['bug_w']!.toDouble()).toDouble(), needed);
    final int bh = px(sb['bug_h']!.toDouble());
    final double bodyX = (bx + crestW).toDouble();
    final double bodyW = bw - crestW;
    final int compH = px(30);
    final double rowY = by + compH + (bh - compH) / 2;
    final double teamsW = bw - crestW - clockW;
    final double content =
        barPad + barW + inner + homeW + gap + scoreW + gap + awayW + inner + barW + barPad.toDouble();
    final double slack = math.max(0.0, (teamsW - content) / 2);
    final double homeBarX = bodyX + barPad + slack;
    final double homeTextX = homeBarX + barW + inner;
    final double scoreX = homeTextX + homeW + gap;
    final double awayTextX = scoreX + scoreW + gap;
    final double awayBarX = awayTextX + awayW + inner;
    final double mitadTeam = px(OverlaySpec.fontSizes['team']!.toDouble()) / 2;
    final double mitadScore = px(OverlaySpec.fontSizes['score']!.toDouble()) / 2;

    boxes['bug'] = Rect.fromLTRB(bx.toDouble(), by.toDouble(), bx + bw, (by + bh).toDouble());
    boxes['crest'] =
        Rect.fromLTRB(bx.toDouble(), by.toDouble(), (bx + crestW).toDouble(), (by + bh).toDouble());
    boxes['competition'] = Rect.fromLTRB(bodyX, by.toDouble(), bx + bw, (by + compH).toDouble());
    boxes['clock'] =
        Rect.fromLTRB(bx + bw - clockW, (by + compH).toDouble(), bx + bw, (by + bh).toDouble());
    boxes['home_bar'] = Rect.fromLTRB(homeBarX, rowY - px(18), homeBarX + barW, rowY + px(18));
    boxes['home_name'] =
        Rect.fromLTRB(homeTextX, rowY - mitadTeam, homeTextX + homeW, rowY + mitadTeam);
    boxes['score'] = Rect.fromLTRB(scoreX, rowY - mitadScore, scoreX + scoreW, rowY + mitadScore);
    boxes['away_name'] =
        Rect.fromLTRB(awayTextX, rowY - mitadTeam, awayTextX + awayW, rowY + mitadTeam);
    boxes['away_bar'] = Rect.fromLTRB(awayBarX, rowY - px(18), awayBarX + barW, rowY + px(18));
    _v.addAll(<String, double>{
      'bx': bx.toDouble(),
      'by': by.toDouble(),
      'bw': bw,
      'bh': bh.toDouble(),
      'ch': px(sb['bug_chamfer']!.toDouble()).toDouble(),
      'crest_w': crestW.toDouble(),
      'body_x': bodyX,
      'body_w': bodyW,
      'comp_h': compH.toDouble(),
      'clock_w': clockW.toDouble(),
      'row_y': rowY,
      'bar_w': barW.toDouble(),
      'home_bar_x': homeBarX,
      'home_text_x': homeTextX,
      'score_x': scoreX,
      'away_text_x': awayTextX,
      'away_bar_x': awayBarX,
    });

    // ---------------- EN VIVO ----------------
    if (state.live) {
      final int lh = px(sb['live_h']!.toDouble());
      final double lw = textWidth(_liveText, 'live') + px(42);
      final int ly = px(sb['live_y']!.toDouble());
      final double x0 = px(sb['margin']!.toDouble()).toDouble();
      boxes['live'] = Rect.fromLTRB(x0, ly.toDouble(), x0 + lw, (ly + lh).toDouble());
      _v.addAll(<String, double>{'live_w': lw, 'live_y': ly.toDouble(), 'live_h': lh.toDouble()});
    }

    // ---------------- indicador de cámara ----------------
    final double labelW = textWidth(_cameraLabel, 'cam');
    final double cw = labelW + textWidth(state.cameraMode, 'cam') + px(70);
    final double cx0 = width - px(sb['margin']!.toDouble()) - cw;
    final int cy0 = px(sb['cam_y']!.toDouble()), chh = px(sb['cam_h']!.toDouble());
    boxes['camera'] = Rect.fromLTRB(cx0, cy0.toDouble(), cx0 + cw, (cy0 + chh).toDouble());
    _v.addAll(<String, double>{
      'cam_w': cw,
      'cam_x': cx0,
      'cam_y': cy0.toDouble(),
      'cam_h': chh.toDouble(),
      'cam_label_w': labelW,
    });

    // ---------------- barra de patrocinio ----------------
    final int sh = px(OverlaySpec.stripHeight.toDouble());
    final double sy0 = (height - sh).toDouble();
    boxes['strip'] = Rect.fromLTRB(0, sy0, width.toDouble(), height.toDouble());
    final double leafX = px(OverlaySpec.margin.toDouble()).toDouble();
    final int leafR = px(10);
    final double claimX = leafX + leafR * 2 + px(10);
    final double claimW = math.max(textWidth(_claimLines[1], 'claim'), textWidth(_claimLines[0], 'claim'));
    boxes['claim'] = Rect.fromLTRB(leafX, sy0, claimX + claimW, height.toDouble());
    final double dividerX = claimX + claimW + px(26);
    final double slotsX = dividerX + px(26);
    _v.addAll(<String, double>{
      'strip_y': sy0,
      'strip_h': sh.toDouble(),
      'leaf_x': leafX,
      'leaf_r': leafR.toDouble(),
      'claim_x': claimX,
      'divider_x': dividerX,
      'slots_x': slotsX,
    });

    double cursor = slotsX;
    if (sponsorSlots) {
      for (int i = 0; i < _slotTexts.length; i++) {
        final (String title, String sub, Color _) = _slotTexts[i];
        final int ir = px(14);
        final double textX = cursor + ir * 2 + px(13);
        final double ancho = math.max(textWidth(title, 'slot'), textWidth(sub, 'sub'));
        boxes['slot_$i'] = Rect.fromLTRB(cursor, sy0, textX + ancho, height.toDouble());
        _slotXs.add((cursor, textX));
        cursor = textX + ancho + px(40);
      }
    }

    final double aiW = textWidth(_aiText, 'ai');
    final double ax = width - px(OverlaySpec.margin.toDouble()) - aiW;
    final double mitadAi = px(OverlaySpec.fontSizes['ai']!.toDouble()) / 2;
    boxes['ai'] = Rect.fromLTRB(ax, sy0 + sh / 2 - mitadAi, ax + aiW, sy0 + sh / 2 + mitadAi);
    // El hueco vendible: lo que los anuncios de Remotion pueden ocupar.
    boxes['sellable'] = Rect.fromLTRB(slotsX, sy0, ax - px(26), height.toDouble());
    _v.addAll(<String, double>{'ai_x': ax, 'ai_w': aiW});
  }
}

/// Pinta la capa RGBA del gráfico entera, con fondo transparente.
class ScoreboardPainter extends CustomPainter {
  ScoreboardPainter(this.state, {this.sponsorSlots = true});

  final ScoreboardState state;

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
    _paintBug(canvas, l);
    if (state.live) _paintLive(canvas, l);
    _paintCamera(canvas, l);
    _paintStrip(canvas, l);
  }

  @override
  bool shouldRepaint(ScoreboardPainter old) =>
      old.state != state || old.sponsorSlots != sponsorSlots;

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

  void _paintBug(Canvas c, ScoreboardLayout l) {
    final double bx = l.v('bx'), by = l.v('by'), bw = l.v('bw'), bh = l.v('bh'), ch = l.v('ch');
    final double hairline = math.max(1, l.px(1)).toDouble();
    final Path bug = Path()
      ..moveTo(bx, by)
      ..lineTo(bx + bw, by)
      ..lineTo(bx + bw, by + (bh * 0.62).truncateToDouble())
      ..lineTo(bx + bw - ch, by + bh)
      ..lineTo(bx, by + bh)
      ..close();
    c.drawPath(bug, _fill(_palette('chrome')));

    final double crestW = l.v('crest_w');
    _line(c, Offset(bx + crestW, by), Offset(bx + crestW, by + bh), _palette('edge'), hairline);
    _paintTurtle(c, bx + crestW / 2, by + bh / 2, l.px(26).toDouble(), l);

    final double bodyX = l.v('body_x'), bodyW = l.v('body_w'), compH = l.v('comp_h');
    final double clockW = l.v('clock_w'), rowY = l.v('row_y');
    _text(c, l, state.competition, 'comp', _textSoft, Offset(bodyX + bodyW / 2, by + compH / 2),
        centred: true);
    _line(c, Offset(bodyX, by + compH), Offset(bx + bw, by + compH), _palette('edge'), hairline);
    _line(c, Offset(bx + bw - clockW, by + compH), Offset(bx + bw - clockW, by + bh),
        _palette('edge'), hairline);
    _text(c, l, state.clockText, 'clock', _palette('white'), Offset(bx + bw - clockW / 2, rowY),
        centred: true);

    c.drawRect(l.boxes['home_bar']!, _fill(_palette('home')));
    _text(c, l, state.home, 'team', _palette('white'), Offset(l.v('home_text_x'), rowY));
    _text(c, l, state.scoreText, 'score', _palette('white'), Offset(l.v('score_x'), rowY));
    _text(c, l, state.away, 'team', _palette('white'), Offset(l.v('away_text_x'), rowY));
    c.drawRect(l.boxes['away_bar']!, _fill(_palette('away')));
  }

  /// La tortuga de Galápagos, emblema de la liga.
  static void _paintTurtle(Canvas c, double cx, double cy, double r, ScoreboardLayout l) {
    Rect oval(double x0, double y0, double x1, double y1) => Rect.fromLTRB(x0, y0, x1, y1);
    for (final (double dx, double dy) in const <(double, double)>[
      (-0.62, -0.18),
      (0.62, -0.18),
      (-0.52, 0.42),
      (0.52, 0.42),
    ]) {
      c.drawOval(
        oval(cx + (dx - 0.22) * r, cy + (dy - 0.14) * r, cx + (dx + 0.22) * r, cy + (dy + 0.14) * r),
        _fill(_shellLight),
      );
    }
    c.drawOval(oval(cx - 0.28 * r, cy - 1.15 * r, cx + 0.28 * r, cy - 0.6 * r), _fill(_shellLight));
    c.drawOval(oval(cx - r, cy - 0.8 * r, cx + r, cy + 0.8 * r), _fill(_palette('leaf')));
    c.drawOval(oval(cx - 0.45 * r, cy - 0.36 * r, cx + 0.45 * r, cy + 0.36 * r), _fill(_shellDark));
    // Nervaduras: sin ellas el caparazón se lee como un óvalo verde.
    final double w = math.max(1, (r * 0.07).truncate()).toDouble();
    for (final int ang in const <int>[-60, -20, 20, 60]) {
      final double rad = ang * math.pi / 180;
      final double cs = math.cos(rad), sn = math.sin(rad);
      _line(c, Offset(cx + cs * 0.42 * r, cy + sn * 0.34 * r),
          Offset(cx + cs * 0.95 * r, cy + sn * 0.76 * r), _shellDark, w);
      _line(c, Offset(cx - cs * 0.42 * r, cy - sn * 0.34 * r),
          Offset(cx - cs * 0.95 * r, cy - sn * 0.76 * r), _shellDark, w);
    }
  }

  void _paintLive(Canvas c, ScoreboardLayout l) {
    final Rect caja = l.boxes['live']!;
    c.drawRRect(RRect.fromRectAndRadius(caja, Radius.circular(l.px(3).toDouble())),
        _fill(_palette('live')));
    final double dotR = l.px(4.5).toDouble();
    final double x0 = l.px(OverlaySpec.margin.toDouble()).toDouble();
    c.drawCircle(Offset(x0 + l.px(14), caja.center.dy), dotR, _fill(_palette('white')));
    _text(c, l, _liveText, 'live', _palette('white'), Offset(x0 + l.px(28), caja.center.dy));
  }

  void _paintCamera(Canvas c, ScoreboardLayout l) {
    final Rect caja = l.boxes['camera']!;
    c.drawRRect(RRect.fromRectAndRadius(caja, Radius.circular(l.px(4).toDouble())),
        _fill(_palette('chrome_soft')));
    final double iconX = caja.left + l.px(16), iconCy = caja.center.dy, k = l.px(9).toDouble();
    final double lw = math.max(1, l.px(2)).toDouble();
    for (final (int sx, int sy) in const <(int, int)>[(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
      final Offset esquina = Offset(iconX + sx * k, iconCy + sy * k);
      _line(c, esquina, Offset(iconX + sx * k * 0.35, iconCy + sy * k), _textSoft, lw);
      _line(c, esquina, Offset(iconX + sx * k, iconCy + sy * k * 0.35), _textSoft, lw);
    }
    c.drawCircle(Offset(iconX, iconCy), l.px(3).toDouble(), _stroke(_palette('away'), lw));
    final double tx = iconX + l.px(16);
    _text(c, l, _cameraLabel, 'cam', _textSoft, Offset(tx, iconCy));
    _text(c, l, state.cameraMode, 'cam', _palette('white'),
        Offset(tx + l.v('cam_label_w') + l.px(10), iconCy));
  }

  void _paintStrip(Canvas c, ScoreboardLayout l) {
    final double sh = l.v('strip_h'), sy0 = l.v('strip_y'), mid = sy0 + sh / 2;
    final double width = l.width.toDouble(), height = l.height.toDouble();
    final double hairline = math.max(1, l.px(1)).toDouble();
    c.drawRect(l.boxes['strip']!, _fill(_palette('bar')));
    _line(c, Offset(0, sy0), Offset(width, sy0), _stripLine, hairline);

    final double leafR = l.v('leaf_r'), leafX = l.v('leaf_x');
    c.drawOval(Rect.fromLTRB(leafX, mid - leafR, leafX + leafR * 2, mid + leafR),
        _fill(_palette('leaf')));
    final double claimX = l.v('claim_x');
    _text(c, l, _claimLines[0], 'claim', _palette('white'), Offset(claimX, mid - l.px(13)));
    _text(c, l, _claimLines[1], 'claim', _palette('white'), Offset(claimX, mid + l.px(13)));
    final double dx = l.v('divider_x');
    _line(c, Offset(dx, sy0 + l.px(26)), Offset(dx, height - l.px(26)), _divider, hairline);

    if (sponsorSlots) {
      for (int i = 0; i < l._slotXs.length; i++) {
        final (double iconX, double textX) = l._slotXs[i];
        final (String title, String sub, Color colour) = _slotTexts[i];
        _paintSponsorIcon(c, _slotIcons[i], iconX, mid, l.px(14).toDouble(), colour,
            math.max(1, l.px(2)).toDouble());
        _text(c, l, title, 'slot', _palette('white'), Offset(textX, mid - l.px(11)));
        _text(c, l, sub, 'sub', _palette('dim'), Offset(textX, mid + l.px(11)));
      }
    }

    final double ax = l.v('ai_x');
    _text(c, l, _aiText, 'ai', _aiColor, Offset(ax, mid));
    _text(c, l, '/', 'claim', _palette('away'), Offset(ax - l.px(20), mid), centred: true);
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
    {bool sponsorSlots = true}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  ScoreboardPainter(state, sponsorSlots: sponsorSlots)
      .paint(canvas, Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
