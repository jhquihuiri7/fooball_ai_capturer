/// La jornada y las entrevistas en Dart (IOS-107, ADR 0030): la geometría de la referencia de
/// Python y ≤3 % de píxeles distintos de sus renders.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/fixtures_card_painter.dart';
import 'package:football_ai_capture/src/graphics/gala_brand.dart';
import 'package:football_ai_capture/src/graphics/halftime_card_painter.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';

import '../zero_fonts.dart';

/// FIXTURES_RENDER de tools/export_overlay_spec.py.
const List<FixtureCard> jornada = <FixtureCard>[
  FixtureCard(home: 'Bellavista', away: 'Progreso', time: '16:00', subtitle: 'Final'),
  FixtureCard(home: 'Santa Cruz', away: 'San Cristóbal', time: '14:00', subtitle: 'Tercer y cuarto lugar'),
  FixtureCard(home: 'Puerto Ayora FC', away: 'Galápagos', time: 'Sáb 11:00'),
];
const String competicion = 'LIGA BARRIAL GALÁPAGOS';

Future<Uint8List> _rgba(ui.Image imagen) async =>
    (await imagen.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();

Future<double> _distintos(ui.Image dart, String png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(File('test/graphics/reference/$png').readAsBytesSync());
  final ui.Image python = (await codec.getNextFrame()).image;
  final Uint8List a = await _rgba(dart), b = await _rgba(python);
  python.dispose();
  int distintos = 0;
  for (int i = 0; i < a.length; i += 4) {
    for (int k = 0; k < 4; k++) {
      if ((a[i + k] - b[i + k]).abs() > 64) {
        distintos++;
        break;
      }
    }
  }
  return distintos / (a.length ~/ 4);
}

void main() {
  setUpAll(loadZeroFonts);

  test('las filas se centran en el hueco y cada una va simétrica', () {
    final FixturesLayout l = FixturesLayout(OverlaySpec.programWidth, competicion, jornada);
    final ui.Rect primera = l.boxes['0_band']!, ultima = l.boxes['2_band']!;
    expect((primera.top + ultima.bottom) / 2, closeTo(OverlaySpec.fixtures['list_cy']!, 1));
    expect(primera.top, greaterThan(l.boxes['competition']!.bottom));
    final ui.Rect hora = l.boxes['0_time']!;
    expect(hora.center.dx, closeTo(960, 1e-9));
    expect(960 - l.boxes['0_home_crest']!.right, closeTo(l.boxes['0_away_crest']!.left - 960, 1e-9));
    expect(l.boxes.containsKey('0_subtitle'), isTrue);
    expect(l.boxes.containsKey('2_subtitle'), isFalse);
    expect(l.boxes['2_time']!.center.dy, closeTo(l.boxes['2_band']!.center.dy, 1e-9), reason: 'sin subtítulo, al centro');
    final FixturesLayout muchos = FixturesLayout(
      OverlaySpec.programWidth,
      competicion,
      List<FixtureCard>.filled(OverlaySpec.fixtures['max']! + 3, jornada.first),
    );
    expect(muchos.fixtures.length, OverlaySpec.fixtures['max']);
  });

  testWidgets('la jornada: ≤3 % de píxeles distintos de fixtures.png', (WidgetTester t) async {
    await t.runAsync(() async {
      final ui.Image iso = await GalaBrand.isotipo();
      final ui.Image img = await paintFixturesCard(
        competicion,
        jornada,
        OverlaySpec.programWidth,
        OverlaySpec.programHeight,
        crests: <String, ui.Image>{fixtureCrestKey('Bellavista'): iso},
      );
      final double fraccion = await _distintos(img, 'fixtures.png');
      // ignore: avoid_print
      print('jornada: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
      expect(fraccion, lessThanOrEqualTo(0.03));
      img.dispose();
    });
  });

  testWidgets('las entrevistas: ≤3 % de píxeles distintos de interview.png', (WidgetTester t) async {
    await t.runAsync(() async {
      const ScoreboardState estado = ScoreboardState(
        competition: competicion,
        home: 'BELLAVISTA',
        away: 'PROGRESO',
        homeGoals: 1,
        awayGoals: 0,
        clockS: 4044,
        live: true,
        cameraMode: 'AUTO',
      );
      const InterviewCard entrevista = InterviewCard(name: 'Juan Pérez', role: 'DT de Bellavista');
      final HalftimeLayout l = HalftimeLayout(OverlaySpec.programWidth, estado, interview: entrevista);
      expect(l.boxes.keys.toSet(), <String>{'title', 'competition', 'icon', 'guest', 'role'});
      final ui.Image img = await paintHalftimeCard(
        estado,
        OverlaySpec.programWidth,
        OverlaySpec.programHeight,
        interview: entrevista,
      );
      final double fraccion = await _distintos(img, 'interview.png');
      // ignore: avoid_print
      print('entrevistas: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
      expect(fraccion, lessThanOrEqualTo(0.03));
      img.dispose();
    });
  });
}
