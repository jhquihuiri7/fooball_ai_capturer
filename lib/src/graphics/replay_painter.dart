/// La repetición al aire en Dart (IOS-119), portada de tools/replay_card.py del repo
/// football-ai (ADR 0034): la cortinilla de la copa y la casa y el rótulo REPETICIÓN.
///
/// La cortinilla tapa el corte del directo a la repetición, y el de vuelta. Entran de izquierda a
/// derecha dos bandas inclinadas a -30° (teal y azul deportivo) y detrás de ellas el azul
/// profundo, que tapa la pantalla. En el centro, en grande, la esquina de arriba a la derecha:
/// el icono de la copa y el isotipo de la casa en su chip, con «REPETICIÓN» debajo a la entrada.
/// Se queda tapada (el corte va en el centro) y las bandas siguen y destapan lo nuevo.
/// [stingerAt] da su punto en cada instante con los tiempos de OverlaySpec.replay.
///
/// El rótulo sale encima de la repetición mientras dura, abajo a la derecha, por encima de la
/// zona de la franja: ahí no tapa nada de lo que la repetición lleva dentro.
///
/// Van en la capa de encima (la 3), que el nativo mezcla sobre todo, también sobre la franja.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import 'gala_brand.dart';
import 'py_round.dart';

int _r(String clave) => OverlaySpec.replay[clave]!;

/// Ms de una cortinilla entera: entrada, tapado y salida.
int get replayTransitionMs => 2 * _r('wipe_ms') + _r('cover_ms');

/// Ms desde que empieza una cortinilla hasta su corte, en el centro del tapado.
int get replayCutMs => _r('wipe_ms') + _r('cover_ms') ~/ 2;

/// Un fotograma de la cortinilla: si las bandas entran y tapan (si no, salen y destapan), su
/// recorrido de 0 a 1 ya suavizado, y el tamaño (en veces el suyo) y la opacidad del chip.
@immutable
class Stinger {
  const Stinger(this.covering, this.sweep, this.chipScale, this.chipAlpha);

  final bool covering;
  final double sweep;
  final double chipScale;
  final double chipAlpha;

  @override
  bool operator ==(Object other) =>
      other is Stinger &&
      other.covering == covering &&
      other.sweep == sweep &&
      other.chipScale == chipScale &&
      other.chipAlpha == chipAlpha;

  @override
  int get hashCode => Object.hash(covering, sweep, chipScale, chipAlpha);

  @override
  String toString() => 'Stinger($covering, $sweep, $chipScale, $chipAlpha)';
}

/// Tapada entera: el instante del corte.
const Stinger stingerCovered = Stinger(true, 1, 1, 1);

double _centesimas(double v) => (v * 100).roundToDouble() / 100;

/// Cúbica que acelera y frena (ease-in-out).
double _suave(double t) => t < 0.5 ? 4 * t * t * t : 1 - math.pow(2 - 2 * t, 3) / 2;

double _entre0y1(double v) => math.min(1, math.max(0, v));

/// La cortinilla a los `elapsedMs` de empezar, o null si no está (antes o después): `stinger_at`
/// de replay_card.py, redondeada a centésimas para no rasterizar dos veces lo mismo.
Stinger? stingerAt(int elapsedMs) {
  final int entrada = _r('wipe_ms'), tapado = _r('cover_ms');
  if (elapsedMs < 0 || elapsedMs >= replayTransitionMs) {
    return null;
  }
  if (elapsedMs < entrada) {
    final double t = elapsedMs / entrada;
    final double desde = _r('chip_from_pct') / 100;
    final double c = _entre0y1((t - desde) / (1 - desde));
    final double inicio = _r('chip_scale_from_pct') / 100;
    final double escala = inicio + (1 - inicio) * (1 - math.pow(1 - c, 3));
    return Stinger(true, _centesimas(_suave(t)), _centesimas(escala), _centesimas(c));
  }
  if (elapsedMs < entrada + tapado) {
    return stingerCovered;
  }
  final double t = (elapsedMs - entrada - tapado) / entrada;
  final double c = _entre0y1(t / (_r('chip_out_pct') / 100));
  final double escala = 1 + (_r('chip_scale_to_pct') / 100 - 1) * c;
  return Stinger(false, _centesimas(_suave(t)), _centesimas(escala), _centesimas(1 - c));
}

/// Si la cortinilla a los `elapsedMs` se mueve: entonces el gráfico se pinta a `anim_fps`.
bool stingerMoving(int elapsedMs) {
  final int entrada = _r('wipe_ms'), tapado = _r('cover_ms');
  return elapsedMs >= 0 && elapsedMs < replayTransitionMs && (elapsedMs < entrada || elapsedMs >= entrada + tapado);
}

/// Lo que va en la capa de la repetición en un instante: la cortinilla (con su título o sin él)
/// y el rótulo. Valor puro: decide si hay que volver a rasterizar.
@immutable
class ReplayGraphic {
  const ReplayGraphic({this.stinger, this.title = false, this.bug = false, this.iconRev});

  final Stinger? stinger;

  /// La cortinilla lleva «REPETICIÓN»: a la entrada sí y a la vuelta no.
  final bool title;

  /// Sale el rótulo: mientras el programa enseña la repetición.
  final bool bug;

  /// La versión del icono del campeonato que va en el chip, o null sin icono.
  final int? iconRev;

  bool get isEmpty => stinger == null && !bug;

  @override
  bool operator ==(Object other) =>
      other is ReplayGraphic &&
      other.stinger == stinger &&
      other.title == title &&
      other.bug == bug &&
      other.iconRev == iconRev;

  @override
  int get hashCode => Object.hash(stinger, title, bug, iconRev);
}

/// La geometría de la repetición sobre un lienzo de `width × height`: las mismas claves que
/// `repeticion` de boxes.json (el chip, la copa, la casa, el título, la raya y el rótulo).
class ReplayLayout {
  ReplayLayout(this.width, this.height, {required this.icon, this.title = true}) : s = width / OverlaySpec.refWidth {
    _measure();
  }

  final int width;
  final int height;
  final bool icon;
  final bool title;
  final double s;
  final Map<String, Rect> boxes = <String, Rect>{};

  int px(double valor) => pyRound(valor * s);
  double r(String clave) => px(_r(clave).toDouble()).toDouble();

  TextStyle font(String nombre, {Color? color}) => switch (nombre) {
    'title' => GalaBrand.text('display', 800, r('title_size'), color: color),
    _ => GalaBrand.text('display', 700, r('bug_text_size'), color: color),
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

  /// El ancho del isotipo a `alto` px, como `brand.isotipo` de Python.
  int isotipoWidth(int alto) =>
      math.max(1, pyRound(OverlaySpec.strip['logo_src_w']! * alto / OverlaySpec.strip['logo_src_h']!));

  void _measure() {
    final double cx = width / 2;
    final int alto = px(_r('chip_logo_h').toDouble());
    final double pad = r('chip_pad'), hueco = r('chip_gap');
    final int casaW = isotipoWidth(alto);
    final double contenido = icon ? alto + hueco + casaW : casaW.toDouble();
    final double cy = r('chip_cy');
    double x = cx - contenido / 2;
    boxes['chip'] = Rect.fromLTRB(x - pad, cy - alto / 2 - pad, x + contenido + pad, cy + alto / 2 + pad);
    if (icon) {
      boxes['championship'] = Rect.fromLTRB(x, cy - alto / 2, x + alto, cy + alto / 2);
      x += alto + hueco;
    }
    boxes['broadcaster'] = Rect.fromLTRB(x, cy - alto / 2, x + casaW, cy + alto / 2);
    if (title) {
      final double tw = textWidth(OverlaySpec.replayTitle, 'title');
      final double mitad = r('title_size') / 2;
      final double tcy = r('title_cy');
      boxes['title'] = Rect.fromLTRB(cx - tw / 2, tcy - mitad, cx + tw / 2, tcy + mitad);
      final double rw = r('rule_w'), rh = r('rule_h'), ry = r('rule_y');
      boxes['rule'] = GalaBrand.skewed(cx - rw / 2, ry, rw, rh).getBounds();
    }

    // El rótulo: su esquina de arriba a la derecha toca el margen.
    final double bh = r('bug_h');
    final double abajo = height - px(OverlaySpec.stripHeight.toDouble()) - px(OverlaySpec.lowerThird['gap']!.toDouble()).toDouble();
    final double arriba = abajo - bh;
    final double sesgo = bh / 2 * GalaBrand.inclinacion;
    final double textoW = textWidth(OverlaySpec.replayTitle, 'bug');
    final double cuerpoW = textoW + 2 * r('bug_pad_x');
    final double cuerpoX = width - px(OverlaySpec.margin.toDouble()) - sesgo - cuerpoW;
    final double puntaW = px(OverlaySpec.scoreboard['tip_w']!.toDouble()).toDouble();
    final double puntaX = cuerpoX - puntaW + px(OverlaySpec.scoreboard['tip_overlap']!.toDouble());
    boxes['bug_tip'] = GalaBrand.skewed(puntaX, arriba, puntaW, bh).getBounds();
    boxes['bug_bar'] = GalaBrand.skewed(cuerpoX, arriba, cuerpoW, bh).getBounds();
    final double mitad = r('bug_text_size') / 2;
    final double tx = cuerpoX + r('bug_pad_x');
    final double bcy = arriba + bh / 2;
    boxes['bug_text'] = Rect.fromLTRB(tx, bcy - mitad, tx + textoW, bcy + mitad);
  }
}

/// Las bandas visibles de un fotograma de la cortinilla: `body` (el azul profundo), `blue` y
/// `teal`, como `band_polygons` de replay_card.py. Cada una es la caja de todo el alto cortada
/// a -30° por su centro; las que no se ven no salen.
Map<String, Path> stingerBands(int width, int height, Stinger stinger) {
  final double s = width / OverlaySpec.refWidth;
  final double sesgo = height / 2 * GalaBrand.inclinacion;
  final double teal = pyRound(_r('band_teal_w') * s).toDouble(), azul = pyRound(_r('band_blue_w') * s).toDouble();
  final double recorrido = width + 2 * sesgo + teal + azul;
  final List<(String, double, double)> piezas;
  if (stinger.covering) {
    final double frente = -sesgo + stinger.sweep * recorrido;
    final double cuerpoX = -2 * sesgo;
    piezas = <(String, double, double)>[
      ('body', cuerpoX, frente - teal - azul - cuerpoX),
      ('blue', frente - teal - azul, azul),
      ('teal', frente - teal, teal),
    ];
  } else {
    final double cola = -sesgo - teal - azul + stinger.sweep * recorrido;
    final double cuerpoX = cola + teal + azul;
    piezas = <(String, double, double)>[
      ('body', cuerpoX, width + 2 * sesgo - cuerpoX),
      ('blue', cola + teal, azul),
      ('teal', cola, teal),
    ];
  }
  return <String, Path>{
    for (final (String nombre, double x, double w) in piezas)
      if (w > 0 && x - sesgo < width && x + w + sesgo > 0) nombre: GalaBrand.skewed(x, 0, w, height.toDouble()),
  };
}

/// Pinta la capa de la repetición sobre `c` (un lienzo de `width × height`): primero el rótulo y
/// encima la cortinilla. `icon` es el icono del campeonato, si lo hay; `isotipo`, el de la casa.
void paintReplay(Canvas c, int width, int height, ReplayGraphic g, {required ui.Image isotipo, ui.Image? icon}) {
  if (g.bug) {
    _paintBug(c, ReplayLayout(width, height, icon: false, title: false));
  }
  final Stinger? st = g.stinger;
  if (st != null) {
    _paintStinger(c, width, height, st, isotipo: isotipo, icon: icon, title: g.title);
  }
}

void _paintStinger(
  Canvas c,
  int width,
  int height,
  Stinger st, {
  required ui.Image isotipo,
  ui.Image? icon,
  required bool title,
}) {
  final Map<String, Path> bandas = stingerBands(width, height, st);
  final Rect alto = Rect.fromLTRB(0, 0, 1, height.toDouble());
  final Path? cuerpo = bandas['body'], azul = bandas['blue'], teal = bandas['teal'];
  if (cuerpo != null) c.drawPath(cuerpo, Paint()..color = GalaBrand.token('azul-profundo'));
  if (azul != null) c.drawPath(azul, Paint()..color = GalaBrand.token('azul-deportivo'));
  if (teal != null) {
    c.drawPath(teal, GalaBrand.fill(GalaBrand.token('teal-electrico'), bottom: GalaBrand.token('verde-oceano'), box: alto));
  }
  if (st.chipAlpha <= 0) {
    return;
  }

  final ReplayLayout l = ReplayLayout(width, height, icon: icon != null, title: title);
  final double cx = width / 2, cy = l.r('chip_cy');
  c.save();
  if (st.chipAlpha < 1) {
    c.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, st.chipAlpha));
  }
  // Crece o encoge alrededor del centro del chip: lo que estaba en (cx, cy) sigue ahí.
  if (st.chipScale != 1) {
    c
      ..translate(cx, cy)
      ..scale(st.chipScale)
      ..translate(-cx, -cy);
  }
  final Rect chip = l.boxes['chip']!;
  c.drawRRect(
    RRect.fromRectAndRadius(chip, Radius.circular(l.r('chip_radius'))),
    Paint()..color = GalaBrand.token('azul-marino'),
  );
  void imagen(ui.Image img, Rect caja) {
    final double e = math.min(caja.width / img.width, caja.height / img.height);
    c.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromCenter(center: caja.center, width: img.width * e, height: img.height * e),
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  final Rect casa = l.boxes['broadcaster']!;
  imagen(isotipo, casa);
  final Rect? copa = l.boxes['championship'];
  if (copa != null && icon != null) {
    imagen(icon, copa);
    final double x = (copa.right + casa.left) / 2;
    c.drawLine(
      Offset(x, copa.top),
      Offset(x, copa.bottom),
      Paint()
        ..color = GalaBrand.token('gris-oceanico').withValues(alpha: _lineaAlfa)
        ..strokeWidth = l.r('chip_line_w'),
    );
  }
  if (title) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: OverlaySpec.replayTitle, style: l.font('title', color: GalaBrand.token('blanco'))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(cx - tp.width / 2, l.boxes['title']!.center.dy - tp.height / 2));
    tp.dispose();
    final double rw = l.r('rule_w'), rh = l.r('rule_h'), ry = l.r('rule_y');
    c.drawPath(
      GalaBrand.skewed(cx - rw / 2, ry, rw, rh),
      GalaBrand.fill(GalaBrand.token('teal-electrico'),
          bottom: GalaBrand.token('verde-oceano'), box: Rect.fromLTRB(0, ry, 1, ry + rh)),
    );
  }
  if (st.chipAlpha < 1) {
    c.restore();
  }
  c.restore();
}

/// La opacidad del filete entre la copa y la casa: la de `brand.LINEA`.
const double _lineaAlfa = 0.28;

void _paintBug(Canvas c, ReplayLayout l) {
  final Rect barra = l.boxes['bug_bar']!, punta = l.boxes['bug_tip']!;
  final double bh = barra.height;
  final double sesgo = bh / 2 * GalaBrand.inclinacion;
  final Path pico = GalaBrand.skewed(punta.left + sesgo, punta.top, punta.width - 2 * sesgo, bh);
  final Path cuerpo = GalaBrand.skewed(barra.left + sesgo, barra.top, barra.width - 2 * sesgo, bh);
  GalaBrand.shadow(
    c,
    Path()
      ..addPath(pico, Offset.zero)
      ..addPath(cuerpo, Offset.zero),
    OverlaySpec.scoreboard['bar_shadow_alpha_pct']! / 100,
    l.s,
  );
  final Rect alto = Rect.fromLTRB(0, barra.top, 1, barra.bottom);
  c.drawPath(pico, GalaBrand.fill(GalaBrand.token('teal-electrico'), bottom: GalaBrand.token('azul-deportivo'), box: alto));
  c.drawPath(cuerpo, GalaBrand.fill(GalaBrand.token('azul-marino'), bottom: GalaBrand.token('azul-profundo'), box: alto));
  final double filete = l.px(OverlaySpec.scoreboard['body_edge_h']!.toDouble()).toDouble();
  c.drawPath(
    GalaBrand.skewed(barra.left + sesgo, barra.bottom - filete, barra.width - 2 * sesgo, filete, centerY: barra.center.dy),
    Paint()..color = GalaBrand.token('azul-deportivo'),
  );
  final TextPainter tp = TextPainter(
    text: TextSpan(text: OverlaySpec.replayTitle, style: l.font('bug', color: GalaBrand.token('blanco'))),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset(l.boxes['bug_text']!.left, barra.center.dy - tp.height / 2));
  tp.dispose();
}

/// La capa de la repetición como ui.Image del tamaño del programa.
Future<ui.Image> paintReplayImage(ReplayGraphic g, int width, int height, {ui.Image? icon}) async {
  final ui.Image isotipo = await GalaBrand.isotipo();
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  paintReplay(Canvas(recorder), width, height, g, isotipo: isotipo, icon: icon);
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
