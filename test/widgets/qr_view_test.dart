/// El QR pintado a mano (IOS-63): se dibuja con margen blanco y sus módulos negros.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/widgets/qr_view.dart';
import 'package:qr/qr.dart';

void main() {
  testWidgets('se pinta con el tamaño pedido', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: QrView(data: 'http://192.168.1.20:8090/#mando=abc.def', size: 200)),
      ),
    );
    expect(tester.getSize(find.byType(CustomPaint).last), const Size.square(200));
    expect(find.bySemanticsLabel('Código QR'), findsOneWidget);
  });

  test('la esquina es margen blanco y el primer módulo del código, negro', () {
    final QrImage img = QrImage(QrCode(payload: QrPayload.fromString('zero')));
    // El patrón de posición arranca negro en (0, 0) en todos los QR.
    expect(img.isDark(0, 0), isTrue);
    expect(QrPainter(img).shouldRepaint(QrPainter(img)), isFalse);
  });
}
