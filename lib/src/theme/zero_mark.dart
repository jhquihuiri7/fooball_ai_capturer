/// La marca Zero: dos anillos que se solapan.
///
/// Son dos lentes que se funden en una imagen, que es exactamente lo que hace el
/// sistema. La geometría no es decorativa y no se ajusta «a ojo»:
///
/// - cada anillo es un círculo de diámetro `D` con trazo `0.18 · D` y sin relleno;
/// - el marco de la marca mide **`1.7 · D` de ancho por `D` de alto**, con el anillo
///   izquierdo pegado al borde izquierdo y el derecho al derecho. Ese solape del 30 %
///   **es** el logo: en un marco cuadrado los dos anillos se apilarían y la marca
///   desaparecería;
/// - el anillo derecho se pinta encima del izquierdo, y no al revés: el teal cruzando
///   por delante del hueso es lo que se reconoce a tamaño de icono.
///
/// Se dibuja, no se importa: un PNG del logo dentro de la app se ve blando en el
/// tamaño de 12 px de la barra inferior y pesado en el de 22 px de la cabecera.
library;

import 'package:flutter/widgets.dart';

import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';

/// Proporción del ancho del marco frente al diámetro de un anillo.
const double _markAspect = 1.7;

/// Grosor del trazo como fracción del diámetro.
const double _strokeRatio = 0.18;

/// Los dos anillos, sin la palabra. Es lo que va en el icono de la app y en la barra
/// inferior.
class ZeroMark extends StatelessWidget {
  const ZeroMark({
    required this.diameter,
    this.left = ZeroColors.ink,
    this.right = ZeroColors.accent,
    super.key,
  });

  /// Diámetro de un anillo. El widget ocupa `1.7 · diameter` de ancho.
  final double diameter;

  /// Anillo izquierdo. Sobre fondo claro va `#151A1D`; sobre fondo teal, `#0B0F10`.
  final Color left;

  /// Anillo derecho, el que se pinta encima. Sobre fondo claro va `#00695F` —el teal
  /// puro no contrasta sobre arena—; sobre fondo teal, `#FAFAF7`.
  final Color right;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: diameter * _markAspect,
      height: diameter,
      child: CustomPaint(
        painter: _ZeroMarkPainter(left: left, right: right),
        // La marca es la marca, no un adorno: quien lee la pantalla con VoiceOver
        // necesita saber en qué app está.
        child: const ExcludeSemantics(child: SizedBox.expand()),
      ),
    );
  }
}

class _ZeroMarkPainter extends CustomPainter {
  const _ZeroMarkPainter({required this.left, required this.right});

  final Color left;
  final Color right;

  @override
  void paint(Canvas canvas, Size size) {
    final double d = size.height;
    final double stroke = _strokeRatio * d;
    // El trazo se pinta centrado sobre la circunferencia, así que el radio de la línea
    // media es (D − trazo) / 2. Usar D / 2 sacaría medio trazo fuera del marco.
    final double radius = (d - stroke) / 2;
    final double cy = d / 2;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..isAntiAlias = true;

    canvas.drawCircle(Offset(d / 2, cy), radius, paint..color = left);
    canvas.drawCircle(Offset(size.width - d / 2, cy), radius, paint..color = right);
  }

  @override
  bool shouldRepaint(_ZeroMarkPainter old) => old.left != left || old.right != right;
}

/// La marca con la palabra al lado. Es la cabecera de las tres pantallas.
class ZeroLockup extends StatelessWidget {
  const ZeroLockup({
    required this.diameter,
    this.left = ZeroColors.ink,
    this.right = ZeroColors.accent,
    this.word = ZeroColors.ink,
    super.key,
  });

  final double diameter;
  final Color left;
  final Color right;
  final Color word;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Zero',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ZeroMark(diameter: diameter, left: left, right: right),
          SizedBox(width: 0.45 * diameter),
          Text(
            'zero',
            style: ZeroType.archivo(
              // La palabra crece con la marca: el lockup se pide una sola vez, por
              // diámetro, y nadie tiene que acordarse del cuerpo que le toca.
              size: diameter,
              weight: FontWeight.w500,
              color: word,
              letterSpacing: -0.04 * diameter,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
