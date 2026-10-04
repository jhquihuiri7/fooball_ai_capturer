/// La tarjeta SIN SEÑAL (IOS-46): dorado propio, la misma imagen que Python y una
/// sola rasterización.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';
import 'package:football_ai_capture/src/graphics/slate_painter.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';

void main() {
  setUpAll(() async {
    final FontLoader loader = FontLoader(ZeroType.display);
    final Uint8List bytes = File('assets/fonts/Archivo-Bold.ttf').readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  });

  testWidgets('dorado propio', (WidgetTester tester) async {
    final ui.Image imagen = (await tester.runAsync(
        () => paintSlate(OverlaySpec.programWidth, OverlaySpec.programHeight)))!;
    await expectLater(imagen, matchesGoldenFile('goldens/slate.png'));
    imagen.dispose();
  });

  testWidgets('el fondo y el texto de la referencia', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(
          File('test/graphics/reference/slate.png').readAsBytesSync());
      final ui.Image python = (await codec.getNextFrame()).image;
      final ui.Image dart = await paintSlate(OverlaySpec.programWidth, OverlaySpec.programHeight);
      final Uint8List a =
          (await dart.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      final Uint8List b =
          (await python.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      int distintos = 0;
      for (int i = 0; i < a.length; i += 4) {
        if ((a[i] - b[i]).abs() > 24 || (a[i + 1] - b[i + 1]).abs() > 24) distintos++;
      }
      // Fuera del texto, el mismo casi negro; el texto cambia de tipografía.
      expect(distintos / (a.length ~/ 4), lessThanOrEqualTo(0.03));
      expect(a.sublist(0, 4), <int>[0x12, 0x12, 0x12, 255]);
      dart.dispose();
      python.dispose();
    });
  });

  testWidgets('se pinta una sola vez', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final CardRaster tarjetas = CardRaster();
      final OverlayFrame a = await tarjetas.slate();
      final OverlayFrame b = await tarjetas.slate();
      expect(identical(a, b), isTrue);
      expect(tarjetas.rasterCount, 1);
    });
  });
}
