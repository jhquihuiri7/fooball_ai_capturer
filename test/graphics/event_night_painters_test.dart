/// Los painters nuevos (IOS-111 a IOS-113; ADR 0031 y 0032): el gol, el gráfico del
/// espectáculo con su rótulo y la tarjeta de resultados. La geometría de la referencia de
/// Python (boxes.json) donde no depende del texto, y ≤3 % de píxeles distintos de sus renders.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/fixtures_card_painter.dart';
import 'package:football_ai_capture/src/graphics/gala_brand.dart';
import 'package:football_ai_capture/src/graphics/goal_banner_painter.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';

import '../zero_fonts.dart';

Future<Uint8List> _rgba(ui.Image imagen) async =>
    (await imagen.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();

/// La fracción de píxeles que difieren en más de 64 en algún canal del render de Python.
Future<double> _distintos(Uint8List a, String png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(File('test/graphics/reference/$png').readAsBytesSync());
  final ui.Image python = (await codec.getNextFrame()).image;
  final Uint8List b = await _rgba(python);
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

/// GOAL_RENDER de tools/export_overlay_spec.py.
const GoalBanner gol = GoalBanner(home: true, name: 'Bellavista', homeGoals: 2, awayGoals: 1);

/// RENDER_STATES['directo'] con el rótulo de LOWER_THIRD_RENDER, sin marcador ni franja.
const ScoreboardState espectaculo = ScoreboardState(
  competition: 'LIGA BARRIAL GALÁPAGOS',
  home: 'BELLAVISTA',
  away: 'PROGRESO',
  homeGoals: 1,
  awayGoals: 0,
  clockS: 4044,
  live: true,
  cameraMode: 'AUTO',
  stripVisible: false,
  iconRev: 1,
  scoreboard: false,
  lowerThirdTitle: 'Presentación artística: Los Ángeles del Cielo',
  lowerThirdSubtitle: 'Cantado por Jonathan Quiwi',
);

void main() {
  setUpAll(loadZeroFonts);

  group('el gol (ADR 0032)', () {
    test('la geometría de gol en boxes.json', () {
      final GoalLayout l = GoalLayout(OverlaySpec.programWidth, gol);
      final ui.Rect banda = l.boxes['band']!;
      expect(banda.left, closeTo(461.5, 0.01));
      expect(banda.right, closeTo(1458.5, 0.01));
      expect((banda.top, banda.bottom), (576, 744));
      expect(l.boxes['team_band']!.top, 754);
      expect(l.boxes['team_band']!.bottom, 826);
      expect(l.boxes['raya_l0']!.left, closeTo(433.36, 0.01));
      expect(l.boxes['raya_r1']!.right, closeTo(1520.64, 0.01));
      expect(l.boxes['crest']!.top, closeTo(763.17, 0.01));
      // Lo que mide con el texto, centrado como en Python aunque el ancho difiera un poco.
      final ui.Rect escudo = l.boxes['crest']!, marcador = l.boxes['score']!;
      expect((escudo.left + marcador.right) / 2, closeTo(960, 1e-6));
    });

    test('la animación: entra desde el centro, se queda y se va fundiéndose', () {
      expect(goalFrame(0), (0, OverlaySpec.goal['text_from_pct']! / 100, 1));
      final (double, double, double) medio = goalFrame(OverlaySpec.goal['in_ms']! ~/ 2)!;
      expect(medio.$1, inExclusiveRange(0.5, 1), reason: 'ease-out: va por delante');
      expect(goalFrame(OverlaySpec.goal['in_ms']!), (1, 1, 1));
      expect(goalFrame(3000), (1, 1, 1));
      final int salida = OverlaySpec.goal['show_ms']! - OverlaySpec.goal['out_ms']!;
      final (double, double, double) yendose = goalFrame(salida + OverlaySpec.goal['out_ms']! ~/ 2)!;
      expect(yendose.$3, closeTo(0.5, 0.01));
      expect(goalFrame(OverlaySpec.goal['show_ms']!), isNull);
      expect(goalMoving(100), isTrue);
      expect(goalMoving(3000), isFalse);
      expect(goalMoving(salida + 1), isTrue);
    });

    testWidgets('quieto: ≤3 % de píxeles distintos de gol.png', (WidgetTester t) async {
      await t.runAsync(() async {
        final ui.Image img = await paintGoalImage(gol, OverlaySpec.programWidth, OverlaySpec.programHeight);
        final double fraccion = await _distintos(await _rgba(img), 'gol.png');
        // ignore: avoid_print
        print('gol: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
        img.dispose();
      });
    });

    testWidgets('cerrado no pinta nada y a medias, solo el centro', (WidgetTester t) async {
      await t.runAsync(() async {
        Future<Uint8List> pintar(GoalBanner b) async =>
            _rgba(await paintGoalImage(b, OverlaySpec.programWidth, OverlaySpec.programHeight));
        final Uint8List cerrado = await pintar(const GoalBanner(home: true, name: 'A', homeGoals: 1, awayGoals: 0, reveal: 0));
        expect(cerrado.every((int v) => v == 0), isTrue);
        final Uint8List medio = await pintar(const GoalBanner(home: true, name: 'A', homeGoals: 1, awayGoals: 0, reveal: 0.3));
        int alfa(int x, int y) => medio[(y * OverlaySpec.programWidth + x) * 4 + 3];
        expect(alfa(960, 600), 255, reason: 'el centro de la banda ya se ve');
        expect(alfa(560, 600), 0, reason: 'la punta izquierda todavía no');
      });
    });
  });

  group('el espectáculo (ADR 0031)', () {
    test('sin marcador, EN VIVO arriba a la izquierda y el rótulo donde en Python', () {
      final ScoreboardLayout l = ScoreboardLayout.measure(OverlaySpec.programWidth, OverlaySpec.programHeight, espectaculo);
      for (final String fuera in <String>['bug', 'clock', 'competition', 'home_crest', 'strip']) {
        expect(l.boxes.containsKey(fuera), isFalse, reason: fuera);
      }
      expect(l.boxes['live']!.left, 48);
      expect((l.boxes['live']!.top, l.boxes['live']!.bottom), (66, 110));
      expect(l.boxes['corner'], const ui.Rect.fromLTRB(1686, 44, 1872, 132));
      expect(l.boxes['lt_tip']!.left, closeTo(76.87, 0.01));
      expect((l.boxes['lt_title_bar']!.top, l.boxes['lt_title_bar']!.bottom), (794, 870));
      expect((l.boxes['lt_sub_bar']!.top, l.boxes['lt_sub_bar']!.bottom), (870, 920));
      expect(l.boxes['lt_sub_bar']!.left, closeTo(58, 1e-9));
      // El ancho del cuerpo sale del texto: se mira contra sus topes, no contra Python.
      final double cuerpo = l.boxes['lt_title_bar']!.width - 76 * GalaBrand.inclinacion;
      expect(cuerpo, inInclusiveRange(OverlaySpec.lowerThird['min_w']!, OverlaySpec.lowerThird['max_w']!));
      final ScoreboardLayout corto = ScoreboardLayout.measure(
        OverlaySpec.programWidth,
        OverlaySpec.programHeight,
        const ScoreboardState(
          competition: '',
          home: '',
          away: '',
          homeGoals: 0,
          awayGoals: 0,
          clockS: 0,
          live: false,
          cameraMode: '',
          stripVisible: false,
          scoreboard: false,
          lowerThirdTitle: 'Hola',
        ),
      );
      expect(corto.boxes.containsKey('lt_sub_bar'), isFalse);
      expect(corto.boxes['lt_title_bar']!.bottom, 920);
      expect(corto.boxes.containsKey('live'), isFalse);
    });

    testWidgets('≤3 % de píxeles distintos de espectaculo.png', (WidgetTester t) async {
      await t.runAsync(() async {
        final ui.Image iso = await GalaBrand.isotipo();
        final OverlayFrame f = await OverlayRaster().render(espectaculo, championship: iso);
        final double fraccion = await _distintos(f.rgba, 'espectaculo.png');
        // ignore: avoid_print
        print('espectáculo: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
      });
    });
  });

  group('los resultados (ADR 0032)', () {
    /// RESULTS_RENDER de tools/export_overlay_spec.py.
    const List<FixtureCard> resultados = <FixtureCard>[
      FixtureCard(home: 'Bellavista', away: 'Progreso', time: '16:00', subtitle: 'Final', homeGoals: 2, awayGoals: 1),
      FixtureCard(
        home: 'Santa Cruz',
        away: 'San Cristóbal',
        time: '14:00',
        subtitle: 'Tercer y cuarto lugar',
        homeGoals: 0,
        awayGoals: 0,
      ),
      FixtureCard(home: 'Puerto Ayora FC', away: 'Galápagos', time: 'Sáb 11:00'),
    ];

    test('el título es RESULTADOS y las filas no se mueven', () {
      final FixturesLayout l = FixturesLayout(OverlaySpec.programWidth, 'LIGA BARRIAL GALÁPAGOS', resultados, results: true);
      final FixturesLayout jornada = FixturesLayout(OverlaySpec.programWidth, 'LIGA BARRIAL GALÁPAGOS', resultados);
      expect(l.title, OverlaySpec.resultsTitle);
      expect(l.boxes['0_time'], jornada.boxes['0_time']);
      expect(l.boxes['title']!.width, greaterThan(jornada.boxes['title']!.width));
      expect(resultados.first.scoreText, '2 - 1');
      expect(resultados.last.played, isFalse);
    });

    testWidgets('≤3 % de píxeles distintos de resultados.png', (WidgetTester t) async {
      await t.runAsync(() async {
        final ui.Image iso = await GalaBrand.isotipo();
        final ui.Image img = await paintFixturesCard(
          'LIGA BARRIAL GALÁPAGOS',
          resultados,
          OverlaySpec.programWidth,
          OverlaySpec.programHeight,
          crests: <String, ui.Image>{fixtureCrestKey('Bellavista'): iso},
          results: true,
        );
        final double fraccion = await _distintos(await _rgba(img), 'resultados.png');
        // ignore: avoid_print
        print('resultados: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
        img.dispose();
      });
    });
  });
}
