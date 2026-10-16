/// La tarjeta de entretiempo en Dart (IOS-102, ADR 0027): la geometría de la referencia de
/// Python, el velo translúcido en toda la pantalla, un dorado propio y ≤3 % de píxeles
/// distintos del PNG de Python.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/gala_brand.dart';
import 'package:football_ai_capture/src/graphics/halftime_card_painter.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';

import '../zero_fonts.dart';

/// El estado «directo» de RENDER_STATES (tools/export_overlay_spec.py): el de halftime.png.
const ScoreboardState directo = ScoreboardState(
  competition: 'LIGA BARRIAL GALÁPAGOS',
  home: 'BELLAVISTA',
  away: 'PROGRESO',
  homeGoals: 1,
  awayGoals: 0,
  clockS: 4044,
  live: true,
  cameraMode: 'AUTO',
);

Future<Uint8List> _rgba(ui.Image imagen) async =>
    (await imagen.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();

void main() {
  setUpAll(loadZeroFonts);

  test('lo que no depende del texto cae donde en Python', () {
    final HalftimeLayout l = HalftimeLayout(OverlaySpec.programWidth, directo);
    // Las cifras de `halftime` en tests/golden/v1/overlay/boxes.json de football-ai.
    expect(l.boxes['icon'], const ui.Rect.fromLTRB(820, 290, 1100, 570));
    for (final (String clave, double x0) in const <(String, double)>[('home_crest', 352), ('away_crest', 1392)]) {
      final ui.Rect r = l.boxes[clave]!;
      expect(r.left, x0, reason: clave);
      expect(r.top, closeTo(307.33, 0.01), reason: clave);
      expect(r.bottom, closeTo(512.67, 0.01), reason: clave);
    }
    final ui.Rect local = l.boxes['home_score']!, visita = l.boxes['away_score']!;
    expect((local.top, local.bottom), (705, 835));
    expect((local.left + visita.right) / 2, closeTo(960, 1e-9), reason: 'el marcador va centrado');
  });

  test('un nombre largo se recorta a su ancho', () {
    final HalftimeLayout l = HalftimeLayout(OverlaySpec.programWidth, const ScoreboardState(
      competition: 'LIGA',
      home: 'CLUB DEPORTIVO INDEPENDIENTE DEL VALLE',
      away: 'PROGRESO',
      homeGoals: 0,
      awayGoals: 0,
      clockS: 0,
      live: false,
      cameraMode: 'AUTO',
    ));
    expect(l.boxes['home_name']!.width, lessThanOrEqualTo(OverlaySpec.halftime['name_max_w']!));
  });

  testWidgets('el velo cubre toda la pantalla, franja incluida, y deja ver la cancha', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ui.Image img = await paintHalftimeCard(directo, 480, 270);
      final Uint8List rgba = await _rgba(img);
      int alfa(int x, int y) => rgba[(y * 480 + x) * 4 + 3];
      final int velo = OverlaySpec.halftime['veil_alpha']!;
      expect(velo, inExclusiveRange(0, 255));
      for (final (int x, int y) in const <(int, int)>[(2, 2), (477, 2), (2, 267), (477, 267), (240, 265)]) {
        expect(alfa(x, y), velo, reason: '($x, $y)');
      }
      img.dispose();
    });
  });

  testWidgets('con escudos: ≤3 % de píxeles distintos de halftime_escudos.png (ADR 0028)', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ui.Image iso = await GalaBrand.isotipo();
      final ui.Codec codec =
          await ui.instantiateImageCodec(File('test/graphics/reference/halftime_escudos.png').readAsBytesSync());
      final ui.Image python = (await codec.getNextFrame()).image;
      final ui.Image dart = await paintHalftimeCard(
        directo,
        OverlaySpec.programWidth,
        OverlaySpec.programHeight,
        crests: <String, ui.Image>{'home': iso, 'away': iso},
      );
      final Uint8List a = await _rgba(dart), b = await _rgba(python);
      int distintos = 0;
      for (int i = 0; i < a.length; i += 4) {
        for (int k = 0; k < 4; k++) {
          if ((a[i + k] - b[i + k]).abs() > 64) {
            distintos++;
            break;
          }
        }
      }
      final double fraccion = distintos / (a.length ~/ 4);
      // ignore: avoid_print
      print('entretiempo con escudos: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
      expect(fraccion, lessThanOrEqualTo(0.03));
      dart.dispose();
      python.dispose();
    });
  });

  // ADR 0029: el próximo partido de los renders de referencia (NEXT_MATCH_RENDER).
  const NextMatchCard proximo =
      NextMatchCard(home: 'Progreso', away: 'Bellavista', when: 'Sábado 25 oct · 16:00', venue: 'Estadio Municipal');

  test('el próximo partido: el cuándo centrado donde iba el marcador, y el dónde debajo', () {
    final HalftimeLayout l = HalftimeLayout(OverlaySpec.programWidth, directo, next: proximo);
    expect(l.title, OverlaySpec.nextMatchTitle);
    expect(l.boxes.containsKey('home_score'), isFalse);
    final ui.Rect cuando = l.boxes['when']!, lugar = l.boxes['venue']!;
    expect(cuando.center.dx, closeTo(960, 1e-9));
    expect(lugar.top, greaterThan(cuando.bottom));
    expect(l.nombre('home'), 'PROGRESO');
    final HalftimeLayout sinLugar = HalftimeLayout(
      OverlaySpec.programWidth,
      directo,
      next: const NextMatchCard(home: 'A', away: 'B', when: 'HOY'),
    );
    expect(sinLugar.boxes.containsKey('venue'), isFalse);
    expect(sinLugar.boxes['when']!.width, greaterThanOrEqualTo(OverlaySpec.halftime['when_min_w']!));
  });

  for (final (String png, String? titulo, NextMatchCard? siguiente) in <(String, String?, NextMatchCard?)>[
    ('fulltime.png', OverlaySpec.fulltimeTitle, null),
    ('next_match.png', null, proximo),
  ]) {
    testWidgets('≤3 % de píxeles distintos frente a $png (ADR 0029)', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final ui.Codec codec = await ui.instantiateImageCodec(File('test/graphics/reference/$png').readAsBytesSync());
        final ui.Image python = (await codec.getNextFrame()).image;
        final ui.Image dart = await paintHalftimeCard(
          directo,
          OverlaySpec.programWidth,
          OverlaySpec.programHeight,
          title: titulo,
          next: siguiente,
        );
        final Uint8List a = await _rgba(dart), b = await _rgba(python);
        int distintos = 0;
        for (int i = 0; i < a.length; i += 4) {
          for (int k = 0; k < 4; k++) {
            if ((a[i + k] - b[i + k]).abs() > 64) {
              distintos++;
              break;
            }
          }
        }
        final double fraccion = distintos / (a.length ~/ 4);
        // ignore: avoid_print
        print('$png: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
        dart.dispose();
        python.dispose();
      });
    });
  }

  testWidgets('dorado propio', (WidgetTester tester) async {
    final ui.Image imagen = (await tester.runAsync(
      () => paintHalftimeCard(directo, OverlaySpec.programWidth, OverlaySpec.programHeight),
    ))!;
    await expectLater(imagen, matchesGoldenFile('goldens/halftime.png'));
    imagen.dispose();
  });

  testWidgets('≤3 % de píxeles distintos frente al PNG de Python', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final ui.Codec codec =
          await ui.instantiateImageCodec(File('test/graphics/reference/halftime.png').readAsBytesSync());
      final ui.Image python = (await codec.getNextFrame()).image;
      final ui.Image dart = await paintHalftimeCard(directo, OverlaySpec.programWidth, OverlaySpec.programHeight);
      final Uint8List a = await _rgba(dart), b = await _rgba(python);
      int distintos = 0;
      for (int i = 0; i < a.length; i += 4) {
        for (int k = 0; k < 4; k++) {
          if ((a[i + k] - b[i + k]).abs() > 64) {
            distintos++;
            break;
          }
        }
      }
      final double fraccion = distintos / (a.length ~/ 4);
      // ignore: avoid_print
      print('entretiempo: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
      expect(fraccion, lessThanOrEqualTo(0.03));
      dart.dispose();
      python.dispose();
    });
  });
}
