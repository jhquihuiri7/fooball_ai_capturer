/// La tarjeta de la jornada en Dart (IOS-107), portada de tools/fixtures_card.py del repo
/// football-ai (ADR 0030): todos los partidos de la fecha, a pantalla completa.
///
/// De la familia del entretiempo: el velo en toda la pantalla (detrás, la cancha que
/// desenfoca el compositor), el título JORNADA con sus rayas y la competición. Debajo, una
/// fila por partido: la banda azul profundo inclinada con el escudo y el nombre de cada
/// equipo, la hora en la caja teal del centro y el subtítulo encima, si lo hay. Las medidas
/// salen de OverlaySpec.fixtures; las del título, de OverlaySpec.halftime.
///
/// Con `results`, la de los resultados de la fecha (IOS-113, ADR 0032): el título RESULTADOS,
/// el marcador de cada partido jugado en la caja teal y la hora de los que faltan en una azul
/// deportivo.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import 'gala_brand.dart';
import 'py_round.dart';

int _f(String clave) => OverlaySpec.fixtures[clave]!;
int _h(String clave) => OverlaySpec.halftime[clave]!;

/// Un partido de la jornada para la tarjeta.
@immutable
class FixtureCard {
  const FixtureCard({
    required this.home,
    required this.away,
    required this.time,
    this.subtitle = '',
    this.homeGoals,
    this.awayGoals,
  });

  final String home;
  final String away;
  final String time;
  final String subtitle;

  /// El marcador (ADR 0032): del partido jugado, o del que se juega; null si falta.
  final int? homeGoals;
  final int? awayGoals;

  bool get played => homeGoals != null && awayGoals != null;

  String get scoreText => '$homeGoals - $awayGoals';

  @override
  bool operator ==(Object other) =>
      other is FixtureCard &&
      other.home == home &&
      other.away == away &&
      other.time == time &&
      other.subtitle == subtitle &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals;

  @override
  int get hashCode => Object.hash(home, away, time, subtitle, homeGoals, awayGoals);
}

/// La clave del escudo de un equipo (`GraphicsStore.crestKey`, `crest_key` de Python).
String fixtureCrestKey(String name) =>
    name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).join(' ').toUpperCase();

/// La geometría de la tarjeta: las mismas claves que `fixtures` de boxes.json.
class FixturesLayout {
  FixturesLayout(this.width, this.competition, List<FixtureCard> fixtures, {this.results = false})
    : fixtures = fixtures.take(OverlaySpec.fixtures['max']!).toList(),
      s = width / OverlaySpec.refWidth {
    _measure();
  }

  final int width;
  final String competition;

  /// La de los resultados de la fecha (ADR 0032).
  final bool results;

  String get title => results ? OverlaySpec.resultsTitle : OverlaySpec.fixturesTitle;
  final List<FixtureCard> fixtures;
  final double s;
  final Map<String, Rect> boxes = <String, Rect>{};

  int px(double valor) => pyRound(valor * s);
  double f(String clave) => px(_f(clave).toDouble()).toDouble();
  double h(String clave) => px(_h(clave).toDouble()).toDouble();

  TextStyle font(String nombre, {Color? color}) => switch (nombre) {
    'title' => GalaBrand.text('display', 800, h('title_size'), color: color),
    'comp' => GalaBrand.text('display', 600, h('comp_size'), color: color),
    'name' => GalaBrand.text('display', 700, f('name_size'), color: color),
    'time' => GalaBrand.text('display', 800, f('time_size'), color: color),
    'subtitle' => GalaBrand.text('display', 700, f('subtitle_size'), color: color),
    _ => GalaBrand.text('display', 800, f('crest_initials_size'), color: color),
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

  /// El texto si cabe; si no, la última palabra; si tampoco, recortado con puntos.
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

  void _measure() {
    final double cx = width / 2;
    final double tituloW = textWidth(title, 'title');
    double mitad = h('title_size') / 2;
    boxes['title'] = Rect.fromLTRB(cx - tituloW / 2, h('title_y') - mitad, cx + tituloW / 2, h('title_y') + mitad);
    final double compW = textWidth(competition.toUpperCase(), 'comp');
    mitad = h('comp_size') / 2;
    boxes['competition'] = Rect.fromLTRB(cx - compW / 2, h('comp_y') - mitad, cx + compW / 2, h('comp_y') + mitad);

    final double paso = f('row_pitch');
    final double primera = f('list_cy') - paso * (fixtures.length - 1) / 2;
    final double crestW = f('crest_w');
    final double crestH = crestW * OverlaySpec.crest['box_h']! / OverlaySpec.crest['box_w']!;
    for (int i = 0; i < fixtures.length; i++) {
      final FixtureCard partido = fixtures[i];
      final double cy = primera + i * paso;
      final double bh = f('band_h');
      boxes['${i}_band'] = Rect.fromLTRB(cx - f('band_half_w'), cy - bh / 2, cx + f('band_half_w'), cy + bh / 2);
      final bool haySub = partido.subtitle.trim().isNotEmpty;
      final double ty = cy + (haySub ? f('time_dy_with_subtitle') : 0);
      final double th = f('time_h'), tw = f('time_w');
      final double sesgo = th / 2 * GalaBrand.inclinacion;
      boxes['${i}_time'] = Rect.fromLTRB(cx - tw / 2 - sesgo, ty - th / 2, cx + tw / 2 + sesgo, ty + th / 2);
      if (haySub) {
        final double sw = textWidth(partido.subtitle.toUpperCase(), 'subtitle');
        final double sy = cy + f('subtitle_dy'), sh = f('subtitle_size') / 2;
        boxes['${i}_subtitle'] = Rect.fromLTRB(cx - sw / 2, sy - sh, cx + sw / 2, sy + sh);
      }
      final double borde = tw / 2 + sesgo + f('crest_gap');
      mitad = f('name_size') / 2;
      for (final (String lado, int signo) in const <(String, int)>[('home', -1), ('away', 1)]) {
        final double cerca = cx + signo * borde, lejos = cerca + signo * crestW;
        boxes['${i}_${lado}_crest'] =
            Rect.fromLTRB(math.min(cerca, lejos), cy - crestH / 2, math.max(cerca, lejos), cy + crestH / 2);
        final String nombre = (lado == 'home' ? partido.home : partido.away).toUpperCase();
        final double ancho = textWidth(fit(nombre, 'name', f('name_max_w')), 'name');
        final double inicio = lejos + signo * f('name_gap');
        boxes['${i}_${lado}_name'] = signo < 0
            ? Rect.fromLTRB(inicio - ancho, cy - mitad, inicio, cy + mitad)
            : Rect.fromLTRB(inicio, cy - mitad, inicio + ancho, cy + mitad);
      }
    }
  }
}

class FixturesCardPainter extends CustomPainter {
  FixturesCardPainter(this.competition, this.fixtures, {this.crests = const <String, ui.Image>{}, this.results = false});

  final String competition;
  final List<FixtureCard> fixtures;

  /// La de los resultados de la fecha (ADR 0032).
  final bool results;

  /// Los escudos de los equipos que los tienen, por [fixtureCrestKey] (ADR 0028).
  final Map<String, ui.Image> crests;

  @override
  bool shouldRepaint(FixturesCardPainter old) =>
      old.competition != competition ||
      !listEquals(old.fixtures, fixtures) ||
      old.crests != crests ||
      old.results != results;

  void _text(Canvas c, FixturesLayout l, String text, String fuente, Color color, Offset centro) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: l.font(fuente, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(centro.dx - tp.width / 2, centro.dy - tp.height / 2));
    tp.dispose();
  }

  @override
  void paint(Canvas c, Size size) {
    final FixturesLayout l = FixturesLayout(size.width.round(), competition, fixtures, results: results);
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
    _text(c, l, competition.toUpperCase(), 'comp', GalaBrand.token('gris-oceanico'), Offset(cx, l.h('comp_y')));

    // ---------------- un partido por fila ----------------
    final Color banda = GalaBrand.token('azul-profundo').withAlpha(l.f('band_alpha').round());
    for (int i = 0; i < l.fixtures.length; i++) {
      final FixtureCard partido = l.fixtures[i];
      final Rect b = l.boxes['${i}_band']!;
      c.drawPath(GalaBrand.skewed(b.left, b.top, b.width, b.height), Paint()..color = banda);
      final Rect t = l.boxes['${i}_time']!;
      final double sesgo = t.height / 2 * GalaBrand.inclinacion;
      // En los resultados, el marcador de los jugados va en la caja teal y la hora de los que
      // faltan, en una azul deportivo.
      final bool pendiente = results && !partido.played;
      final Path caja = GalaBrand.skewed(t.left + sesgo, t.top, t.width - 2 * sesgo, t.height);
      c.drawPath(
        caja,
        pendiente
            ? (Paint()..color = GalaBrand.token('azul-deportivo'))
            : GalaBrand.fill(teal, bottom: GalaBrand.token('verde-oceano'), box: Rect.fromLTRB(0, t.top, 1, t.bottom)),
      );
      _text(
        c,
        l,
        results && partido.played ? partido.scoreText : partido.time.toUpperCase(),
        'time',
        pendiente ? GalaBrand.token('blanco') : GalaBrand.token('azul-profundo'),
        Offset(cx, t.center.dy),
      );
      final Rect? sub = l.boxes['${i}_subtitle'];
      if (sub != null) {
        _text(c, l, partido.subtitle.toUpperCase(), 'subtitle', GalaBrand.token('teal-electrico'), Offset(cx, sub.center.dy));
      }
      for (final (String lado, Color color) in <(String, Color)>[('home', teal), ('away', visita)]) {
        final String nombre = (lado == 'home' ? partido.home : partido.away).toUpperCase();
        final Rect escudo = l.boxes['${i}_${lado}_crest']!;
        if (GalaBrand.paintTeamCrest(c, escudo, color, crests[fixtureCrestKey(nombre)])) {
          _text(c, l, GalaBrand.crestInitials(nombre), 'crest', color, GalaBrand.crestInitialsCenter(escudo));
        }
        final String visible = l.fit(nombre, 'name', l.f('name_max_w'));
        _text(c, l, visible, 'name', blanco, Offset(l.boxes['${i}_${lado}_name']!.center.dx, b.center.dy));
      }
    }
  }
}

/// La tarjeta como ui.Image del tamaño del programa.
Future<ui.Image> paintFixturesCard(
  String competition,
  List<FixtureCard> fixtures,
  int width,
  int height, {
  Map<String, ui.Image> crests = const <String, ui.Image>{},
  bool results = false,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  FixturesCardPainter(competition, fixtures, crests: crests, results: results)
      .paint(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
