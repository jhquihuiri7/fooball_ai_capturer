/// El gol animado en Dart (IOS-112), portado de tools/goal_card.py del repo football-ai (ADR
/// 0032): la banda de ¡GOL! que sale sola cuando sube un gol.
///
/// Va en la capa del marcador, un poco por debajo del centro: la banda inclinada del color del
/// equipo que marcó (teal el local, blanco el visitante) con ¡GOL! y dos rayas teal→azul a cada
/// lado; debajo, la banda azul profundo con el escudo, el nombre y el marcador nuevo. La
/// referencia pinta el fotograma quieto; aquí la entrada y la salida son ese mismo dibujo
/// recortado desde el centro ([GoalBanner.reveal]), con el texto que cae a su tamaño
/// ([GoalBanner.textScale]) y fundido al irse ([GoalBanner.fade]). [goalFrame] da los tres para
/// cada instante con los tiempos de OverlaySpec.goal.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import 'gala_brand.dart';
import 'py_round.dart';

int _g(String clave) => OverlaySpec.goal[clave]!;

/// El gol que se celebra y el punto de su animación. Valor puro: decide si hay que volver a
/// rasterizar.
@immutable
class GoalBanner {
  const GoalBanner({
    required this.home,
    required this.name,
    required this.homeGoals,
    required this.awayGoals,
    this.crestRev,
    this.reveal = 1,
    this.textScale = 1,
    this.fade = 1,
  });

  /// Lo marcó el local (teal); si no, el visitante (blanco).
  final bool home;
  final String name;
  final int homeGoals;
  final int awayGoals;

  /// La versión del escudo del equipo que marcó (ADR 0028), o null con el genérico.
  final int? crestRev;

  /// Cuánto de la banda se ve, de 0 (cerrada en el centro) a 1 (entera).
  final double reveal;

  /// El tamaño de ¡GOL!, en veces el suyo: cae a 1 durante la entrada.
  final double textScale;

  /// La opacidad de todo, de 0 a 1: baja durante la salida.
  final double fade;

  String get scoreText => '$homeGoals - $awayGoals';

  @override
  bool operator ==(Object other) =>
      other is GoalBanner &&
      other.home == home &&
      other.name == name &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals &&
      other.crestRev == crestRev &&
      other.reveal == reveal &&
      other.textScale == textScale &&
      other.fade == fade;

  @override
  int get hashCode => Object.hash(home, name, homeGoals, awayGoals, crestRev, reveal, textScale, fade);
}

/// El punto de la animación a los `elapsedMs` del gol: (reveal, textScale, fade), redondeados a
/// centésimas para que dos fotogramas iguales no se rasterizen dos veces. Null si ya acabó.
(double, double, double)? goalFrame(int elapsedMs) {
  final int total = _g('show_ms'), entrada = _g('in_ms'), salida = _g('out_ms');
  if (elapsedMs < 0 || elapsedMs >= total) {
    return null;
  }
  double centesimas(double v) => (v * 100).roundToDouble() / 100;
  if (elapsedMs < entrada) {
    final double t = elapsedMs / entrada;
    final double e = 1 - math.pow(1 - t, 3).toDouble(); // ease-out cúbico
    final double desde = _g('text_from_pct') / 100;
    return (centesimas(e), centesimas(desde + (1 - desde) * e), 1);
  }
  final int aSalir = total - salida;
  if (elapsedMs < aSalir) {
    return (1, 1, 1);
  }
  final double t = (elapsedMs - aSalir) / salida;
  final double e = t * t * t; // ease-in cúbico
  return (centesimas(1 - e), 1, centesimas(1 - t));
}

/// Si el gol a los `elapsedMs` está entrando o saliendo: entonces el gráfico se pinta a
/// `anim_fps`; quieto, no.
bool goalMoving(int elapsedMs) {
  final int total = _g('show_ms');
  return elapsedMs >= 0 && elapsedMs < total && (elapsedMs < _g('in_ms') || elapsedMs >= total - _g('out_ms'));
}

/// La geometría del gol sobre un lienzo de `width`: las mismas claves que `gol` de boxes.json.
class GoalLayout {
  GoalLayout(this.width, this.banner) : s = width / OverlaySpec.refWidth {
    _measure();
  }

  final int width;
  final GoalBanner banner;
  final double s;
  final Map<String, Rect> boxes = <String, Rect>{};
  late final String visibleName;

  int px(double valor) => pyRound(valor * s);
  double g(String clave) => px(_g(clave).toDouble()).toDouble();

  TextStyle font(String nombre, {Color? color}) => switch (nombre) {
    'goal' => GalaBrand.text('display', 800, g('text_size'), color: color),
    'name' => GalaBrand.text('display', 700, g('name_size'), color: color),
    'score' => GalaBrand.text('display', 800, g('score_size'), color: color),
    _ => GalaBrand.text('display', 800, g('crest_initials_size'), color: color),
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

  /// El texto si cabe en `ancho`; si no, recortado con puntos (`_fit` de goal_card.py).
  String fit(String text, String fuente, double ancho) {
    if (textWidth(text, fuente) <= ancho) {
      return text;
    }
    String t = text;
    while (t.length > 1 && textWidth('$t…', fuente) > ancho) {
      t = t.substring(0, t.length - 1);
    }
    return '${t.trimRight()}…';
  }

  void _measure() {
    final double cx = width / 2;
    final double bh = g('band_h'), bw = g('band_w');
    final double sesgo = bh / 2 * GalaBrand.inclinacion;
    final double cy = g('band_cy');
    boxes['band'] = Rect.fromLTRB(cx - bw / 2 - sesgo, cy - bh / 2, cx + bw / 2 + sesgo, cy + bh / 2);
    final double tw = textWidth(OverlaySpec.goalText, 'goal');
    double mitad = g('text_size') / 2;
    boxes['text'] = Rect.fromLTRB(cx - tw / 2, cy - mitad, cx + tw / 2, cy + mitad);
    final double rh = g('raya_h'), rw = g('raya_w');
    final double rs = rh / 2 * GalaBrand.inclinacion;
    for (int i = 0; i < 2; i++) {
      final double hueco = g('raya_gap') + i * g('raya_step');
      final double izq = cx - bw / 2 - hueco - rw;
      final double der = cx + bw / 2 + hueco;
      boxes['raya_l$i'] = Rect.fromLTRB(izq - rs, cy - rh / 2, izq + rw + rs, cy + rh / 2);
      boxes['raya_r$i'] = Rect.fromLTRB(der - rs, cy - rh / 2, der + rw + rs, cy + rh / 2);
    }

    visibleName = fit(banner.name.toUpperCase(), 'name', g('name_max_w'));
    final double nw = textWidth(visibleName, 'name');
    final double sw = textWidth(banner.scoreText, 'score');
    final double crestW = g('crest_w');
    final double crestH = crestW * OverlaySpec.crest['box_h']! / OverlaySpec.crest['box_w']!;
    final double contenido = crestW + g('crest_gap') + nw + g('score_gap') + sw;
    final double th = g('team_h'), tcy = g('team_cy');
    final double ancho = math.max(g('team_min_w'), contenido + 2 * g('team_pad_x'));
    final double tsesgo = th / 2 * GalaBrand.inclinacion;
    boxes['team_band'] = Rect.fromLTRB(cx - ancho / 2 - tsesgo, tcy - th / 2, cx + ancho / 2 + tsesgo, tcy + th / 2);
    double x = cx - contenido / 2;
    boxes['crest'] = Rect.fromLTRB(x, tcy - crestH / 2, x + crestW, tcy + crestH / 2);
    x += crestW + g('crest_gap');
    mitad = g('name_size') / 2;
    boxes['name'] = Rect.fromLTRB(x, tcy - mitad, x + nw, tcy + mitad);
    x += nw + g('score_gap');
    mitad = g('score_size') / 2;
    boxes['score'] = Rect.fromLTRB(x, tcy - mitad, x + sw, tcy + mitad);
  }

  /// Todo lo que pinta, para recortar la entrada y la salida desde el centro.
  Rect get bounds => boxes.values.reduce((Rect a, Rect b) => a.expandToInclude(b));
}

/// Pinta el gol sobre `c` (un lienzo de `width` de ancho), en el punto de su animación.
/// `crest` es el escudo del equipo que marcó, ya decodificado, si lo tiene.
void paintGoalBanner(Canvas c, int width, GoalBanner banner, {ui.Image? crest}) {
  final GoalLayout l = GoalLayout(width, banner);
  if (banner.reveal <= 0 || banner.fade <= 0) {
    return;
  }
  final Rect todo = l.bounds;
  final double cx = width / 2;
  // La sombra asoma por debajo y a los lados: el recorte y el fundido la incluyen.
  final double aire = (OverlaySpec.scoreboard['shadow_blur']! * 1.5 + OverlaySpec.scoreboard['shadow_dy']!) * l.s;
  final Rect zona = todo.inflate(aire);
  c.save();
  c.clipRect(Rect.fromLTRB(cx - zona.width / 2 * banner.reveal, zona.top, cx + zona.width / 2 * banner.reveal, zona.bottom));
  if (banner.fade < 1) {
    c.saveLayer(zona, Paint()..color = Color.fromRGBO(0, 0, 0, banner.fade));
  }

  final Color teal = GalaBrand.token('teal-electrico'), azul = GalaBrand.token('azul-deportivo');
  final Color equipo = Color(OverlaySpec.colorsArgb[banner.home ? 'home' : 'away']!);
  Path inclinada(Rect r) {
    final double sesgo = r.height / 2 * GalaBrand.inclinacion;
    return GalaBrand.skewed(r.left + sesgo, r.top, r.width - 2 * sesgo, r.height);
  }

  final List<Path> rayas = <Path>[for (final String k in <String>['raya_l0', 'raya_l1', 'raya_r0', 'raya_r1']) inclinada(l.boxes[k]!)];
  final Path banda = inclinada(l.boxes['band']!);
  final Rect te = l.boxes['team_band']!;
  final Path bandaEquipo = inclinada(te);
  final Rect escudo = l.boxes['crest']!;
  final Path silueta = Path()
    ..addPath(banda, Offset.zero)
    ..addPath(bandaEquipo, Offset.zero);
  for (final Path r in rayas) {
    silueta.addPath(r, Offset.zero);
  }
  GalaBrand.shadow(c, silueta, OverlaySpec.scoreboard['bar_shadow_alpha_pct']! / 100, l.s);

  for (int i = 0; i < rayas.length; i++) {
    final Rect r = l.boxes[<String>['raya_l0', 'raya_l1', 'raya_r0', 'raya_r1'][i]]!;
    c.drawPath(rayas[i], GalaBrand.fill(teal, bottom: azul, box: Rect.fromLTRB(0, r.top, 1, r.bottom)));
  }
  final Rect b = l.boxes['band']!;
  final Rect altoBanda = Rect.fromLTRB(0, b.top, 1, b.bottom);
  c.drawPath(
    banda,
    banner.home
        ? GalaBrand.fill(teal, bottom: GalaBrand.token('verde-oceano'), box: altoBanda)
        : GalaBrand.fill(GalaBrand.token('blanco'), bottom: GalaBrand.token('gris-tinte'), box: altoBanda),
  );
  c.drawPath(bandaEquipo, Paint()..color = GalaBrand.token('azul-profundo').withAlpha(_g('team_alpha')));
  final double filete = l.px(OverlaySpec.scoreboard['body_edge_h']!.toDouble()).toDouble();
  final double tsesgo = te.height / 2 * GalaBrand.inclinacion;
  c.drawPath(
    GalaBrand.skewed(te.left + tsesgo, te.bottom - filete, te.width - 2 * tsesgo, filete, centerY: te.center.dy),
    Paint()..color = azul,
  );
  final bool generico = GalaBrand.paintTeamCrest(c, escudo, equipo, crest);

  // ¡GOL!, que cae a su tamaño desde su centro.
  final TextPainter gol = TextPainter(
    text: TextSpan(text: OverlaySpec.goalText, style: l.font('goal', color: GalaBrand.token('azul-profundo'))),
    textDirection: TextDirection.ltr,
  )..layout();
  c.save();
  c.translate(cx, b.center.dy);
  c.scale(banner.textScale);
  gol.paint(c, Offset(-gol.width / 2, -gol.height / 2));
  c.restore();
  gol.dispose();

  void texto(String t, String fuente, Color color, Offset at, {bool centred = false}) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: t, style: l.font(fuente, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(centred ? at.dx - tp.width / 2 : at.dx, at.dy - tp.height / 2));
    tp.dispose();
  }

  if (generico) {
    texto(GalaBrand.crestInitials(banner.name), 'crest', equipo, GalaBrand.crestInitialsCenter(escudo), centred: true);
  }
  texto(l.visibleName, 'name', GalaBrand.token('blanco'), Offset(l.boxes['name']!.left, te.center.dy));
  texto(banner.scoreText, 'score', teal, Offset(l.boxes['score']!.left, te.center.dy));

  if (banner.fade < 1) {
    c.restore();
  }
  c.restore();
}

/// El gol quieto como ui.Image del tamaño del programa, para los tests contra la referencia.
Future<ui.Image> paintGoalImage(GoalBanner banner, int width, int height, {ui.Image? crest}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  paintGoalBanner(Canvas(recorder), width, banner, crest: crest);
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
