/// La tarjeta SIN SEÑAL (IOS-46), portada de no_signal_card en tools/live_panel.py
/// (§21.6): fondo casi negro y el texto centrado. Sale al aire mientras no llega la
/// cámara, con el marcador compuesto encima, así que el cronómetro sigue en pantalla.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../generated/overlay_spec.g.dart';
import '../theme/zero_type.dart';

class SlatePainter extends CustomPainter {
  const SlatePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(OverlaySpec.slateBackgroundArgb));
    // `max(1, int(alto · fracción))`, como la referencia.
    final double tamano = math.max(1, (size.height * OverlaySpec.slateTextHeight).truncate()).toDouble();
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: OverlaySpec.slateText,
        style: TextStyle(
          fontFamily: ZeroType.display,
          fontWeight: FontWeight.w700,
          fontSize: tamano,
          color: const Color(OverlaySpec.slateForegroundArgb),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // El centro entero del frame, como `(width // 2, height // 2)` en Python.
    final Offset centro = Offset((size.width ~/ 2).toDouble(), (size.height ~/ 2).toDouble());
    tp.paint(canvas, centro - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(SlatePainter old) => false;
}

/// La tarjeta como ui.Image del tamaño del programa.
Future<ui.Image> paintSlate(int width, int height) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  const SlatePainter().paint(Canvas(recorder), Size(width.toDouble(), height.toDouble()));
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(width, height).whenComplete(picture.dispose);
}
