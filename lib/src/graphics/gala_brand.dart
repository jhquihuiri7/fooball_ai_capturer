/// La marca Gala Sports del gráfico (ADR 0026), portada de tools/brand.py del repo
/// football-ai: los tokens de color, las dos familias, el corte a -30°, el escudo
/// genérico, la sombra-grafismo y el isotipo.
///
/// Todo lo que tiene número sale de OverlaySpec: aquí no se teclea ninguna medida ni
/// ningún color que exista allí.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../generated/overlay_spec.g.dart';

abstract final class GalaBrand {
  /// Un token de la paleta por su nombre en el sistema («teal-electrico»…).
  static Color token(String nombre) => Color(OverlaySpec.brandArgb[nombre]!);

  /// Px de desplazamiento horizontal por px de alto del corte (tan 30°).
  static final double inclinacion =
      math.tan(OverlaySpec.scoreboard['skew_deg']! * math.pi / 180);

  /// Eje `opsz` de Inter fijo en su valor por defecto, como el woff2 del sistema y la
  /// referencia de Pillow.
  static const double interOpticalSize = 14;

  static const String isotipoAsset = 'assets/brand/gala-sports-isotipo.png';

  /// El estilo de la marca: `display` es Barlow Condensed y `sans`, Inter variable,
  /// que necesita el eje de peso explícito (Flutter no lo deduce de `fontWeight`).
  static TextStyle text(String familia, int peso, double size, {Color? color}) {
    final FontWeight weight = FontWeight.values[(peso ~/ 100) - 1];
    return TextStyle(
      fontFamily: OverlaySpec.fontFamilies[familia],
      fontWeight: weight,
      fontSize: size,
      color: color,
      fontVariations: familia == 'sans'
          ? <ui.FontVariation>[
              ui.FontVariation('wght', peso.toDouble()),
              const ui.FontVariation('opsz', interOpticalSize),
            ]
          : null,
    );
  }

  /// La caja (x, y, w, h) cortada a -30°, como `gs-sesgo`: arriba se desplaza a la
  /// derecha y abajo a la izquierda, alrededor de `centerY` (por defecto, su centro).
  static Path skewed(double x, double y, double w, double h, {double? centerY}) {
    final double c = centerY ?? y + h / 2;
    final double arriba = (c - y) * inclinacion, abajo = (y + h - c) * inclinacion;
    return Path()
      ..addPolygon(<Offset>[
        Offset(x + arriba, y),
        Offset(x + w + arriba, y),
        Offset(x + w - abajo, y + h),
        Offset(x - abajo, y + h),
      ], true);
  }

  /// Relleno sólido, o degradado vertical de `top` a `bottom` a lo alto de `box`: el
  /// `linear-gradient(180deg, …)` del sistema, que tras el corte sigue vertical.
  static Paint fill(Color top, {Color? bottom, Rect? box}) {
    final Paint p = Paint()..color = top;
    if (bottom != null && box != null) {
      p.shader = ui.Gradient.linear(box.topCenter, box.bottomCenter, <Color>[top, bottom]);
    }
    return p;
  }

  /// La sombra-grafismo de `silueta`: negra a `alpha`, desenfocada y bajada.
  static void shadow(Canvas c, Path silueta, double alpha, double escala) {
    final Map<String, int> sb = OverlaySpec.scoreboard;
    final Paint p = Paint()
      ..color = Color.fromRGBO(0, 0, 0, alpha)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, sb['shadow_blur']! / 2 * escala);
    c.save();
    c.translate(0, (sb['shadow_dy']! * escala).roundToDouble());
    c.drawPath(silueta, p);
    c.restore();
  }

  // ---------------- el escudo genérico ----------------

  static double _escudoEscala(Rect box) => math.min(
      box.width / OverlaySpec.crest['box_w']!, box.height / OverlaySpec.crest['box_h']!);

  static Offset _escudoOrigen(Rect box, double escala) => Offset(
      (box.left + box.right - OverlaySpec.crest['box_w']! * escala) / 2,
      (box.top + box.bottom - OverlaySpec.crest['box_h']! * escala) / 2);

  /// La silueta del escudo dentro de `box`, centrada y sin deformar.
  static Path crestPath(Rect box) {
    final double e = _escudoEscala(box);
    final Offset o = _escudoOrigen(box, e);
    return Path()
      ..addPolygon(<Offset>[
        for (final (double x, double y) in OverlaySpec.crestShape) Offset(o.dx + x * e, o.dy + y * e),
      ], true);
  }

  /// El escudo: relleno azul profundo y filo del color del equipo. Las siglas, aparte.
  static void paintCrest(Canvas c, Rect box, Color edge) {
    final Path silueta = crestPath(box);
    c.drawPath(silueta, Paint()..color = token('azul-profundo'));
    c.drawPath(
      silueta,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = OverlaySpec.crest['stroke']! * _escudoEscala(box),
    );
  }

  /// Dónde van centradas las siglas del escudo dentro de `box`.
  static Offset crestInitialsCenter(Rect box) {
    final double e = _escudoEscala(box);
    return Offset(box.center.dx, _escudoOrigen(box, e).dy + OverlaySpec.crest['initials_y']! * e);
  }

  /// Las siglas: las tres primeras letras de una sola palabra, o las iniciales (hasta
  /// tres) de varias. «BELLAVISTA» → «BEL», «U. CATÓLICA» → «UC».
  static String crestInitials(String name) {
    final List<String> palabras =
        name.toUpperCase().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
    if (palabras.isEmpty) return '';
    if (palabras.length == 1) {
      final String p = palabras.first;
      return p.length <= 3 ? p : p.substring(0, 3);
    }
    final String iniciales = palabras.map((String p) => p[0]).join();
    return iniciales.length <= 3 ? iniciales : iniciales.substring(0, 3);
  }

  // ---------------- el isotipo ----------------

  static ui.Image? _isotipo;

  /// El isotipo decodificado, una vez por proceso: el marcador se repinta cada segundo.
  static Future<ui.Image> isotipo() async {
    final ui.Image? hecho = _isotipo;
    if (hecho != null) return hecho;
    final ByteData datos = await rootBundle.load(isotipoAsset);
    final ui.Codec codec = await ui.instantiateImageCodec(datos.buffer.asUint8List());
    final ui.Image imagen = (await codec.getNextFrame()).image;
    codec.dispose();
    return _isotipo = imagen;
  }
}
