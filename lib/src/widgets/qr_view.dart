/// Un QR pintado a mano a partir de la matriz del paquete `qr` (IOS-63).
///
/// Negro sobre blanco y con su margen de cuatro módulos, aunque la app sea oscura: un QR
/// invertido o sin margen falla en la mitad de las cámaras.
library;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Módulos de margen alrededor del código (lo que pide la norma ISO/IEC 18004).
const int qrQuietZoneModules = 4;

class QrView extends StatelessWidget {
  const QrView({required this.data, this.size = 240, super.key});

  final String data;

  /// Lado en puntos, margen incluido.
  final double size;

  @override
  Widget build(BuildContext context) {
    final QrImage imagen = QrImage(
      QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium),
    );
    return Semantics(
      label: 'Código QR',
      child: CustomPaint(size: Size.square(size), painter: QrPainter(imagen)),
    );
  }
}

class QrPainter extends CustomPainter {
  QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final int lado = image.moduleCount + 2 * qrQuietZoneModules;
    final double modulo = size.shortestSide / lado;
    canvas.drawRect(Offset.zero & Size.square(modulo * lado), Paint()..color = Colors.white);
    final Paint negro = Paint()..color = Colors.black;
    for (int fila = 0; fila < image.moduleCount; fila++) {
      for (int col = 0; col < image.moduleCount; col++) {
        if (image.isDark(fila, col)) {
          canvas.drawRect(
            Rect.fromLTWH(
              (col + qrQuietZoneModules) * modulo,
              (fila + qrQuietZoneModules) * modulo,
              // Un pelo más ancho para que no queden costuras entre módulos.
              modulo + 0.5,
              modulo + 0.5,
            ),
            negro,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter oldDelegate) => oldDelegate.image != image;
}
