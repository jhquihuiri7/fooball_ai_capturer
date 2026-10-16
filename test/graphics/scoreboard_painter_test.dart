/// El gráfico en Dart (IOS-45, con la marca Gala Sports de IOS-100): dorados de
/// imagen de 4 estados, la geometría de la referencia de Python y un raster por cambio
/// de contenido.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/gala_brand.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Los estados de RENDER_STATES de tools/export_overlay_spec.py, más el modo con
/// anuncios de verdad (sin ranuras), que es el cuarto.
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
const ScoreboardState inicio = ScoreboardState(
  competition: 'LIGA BARRIAL GALÁPAGOS',
  home: 'BELLAVISTA',
  away: 'PROGRESO',
  homeGoals: 0,
  awayGoals: 0,
  clockS: 0,
  live: false,
  cameraMode: 'MANUAL',
);
const ScoreboardState finalLargo = ScoreboardState(
  competition: 'LIGA BARRIAL GALÁPAGOS',
  home: 'INDEPENDIENTE DEL VALLE',
  away: 'U. CATÓLICA',
  homeGoals: 3,
  awayGoals: 2,
  clockS: 5640,
  live: true,
  cameraMode: 'AUTO',
);

/// flutter test no carga las fuentes del pubspec: sin esto todo saldría en Ahem.
/// Son las de la marca Gala Sports (IOS-100), las mismas que pinta Python.
Future<void> _loadBrandFonts() async {
  final Map<String, List<String>> familias = <String, List<String>>{
    'Barlow Condensed': <String>[
      'BarlowCondensed-SemiBold.ttf',
      'BarlowCondensed-Bold.ttf',
      'BarlowCondensed-ExtraBold.ttf',
    ],
    'Inter': <String>['Inter-Variable.ttf'],
  };
  for (final MapEntry<String, List<String>> f in familias.entries) {
    final FontLoader loader = FontLoader(f.key);
    for (final String fichero in f.value) {
      final Uint8List bytes = File('assets/fonts/$fichero').readAsBytesSync();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadBrandFonts);

  group('dorados de imagen', () {
    final Map<String, (ScoreboardState, bool)> estados = <String, (ScoreboardState, bool)>{
      'inicio': (inicio, true),
      'directo': (directo, true),
      'final_largo': (finalLargo, true),
      'con_anuncios': (directo, false),
    };
    for (final MapEntry<String, (ScoreboardState, bool)> e in estados.entries) {
      testWidgets(e.key, (WidgetTester tester) async {
        final ui.Image imagen = (await tester.runAsync(() => paintScoreboard(
              e.value.$1,
              OverlaySpec.programWidth,
              OverlaySpec.programHeight,
              sponsorSlots: e.value.$2,
            )))!;
        await expectLater(imagen, matchesGoldenFile('goldens/${e.key}.png'));
        imagen.dispose();
      });
    }
  });

  group('la geometría de la referencia (boxes.json de REF-56/57)', () {
    ScoreboardLayout medir(ScoreboardState s, {bool slots = true}) => ScoreboardLayout.measure(
        OverlaySpec.programWidth, OverlaySpec.programHeight, s, sponsorSlots: slots);

    test('lo que no depende del texto cae donde en Python', () {
      final ScoreboardLayout l = medir(directo);
      // Las cifras son las de tests/golden/v1/overlay/boxes.json de football-ai.
      final ui.Rect bug = l.boxes['bug']!;
      expect(bug.left, closeTo(48, 1e-9)); // el pico de la punta, cortada a -30°
      expect(bug.top, 106);
      expect(bug.bottom, 182);
      expect(l.boxes['home_crest']!.left, closeTo(107.94, 0.01));
      expect(l.boxes['home_crest']!.top, closeTo(94, 1e-9));
      expect(l.boxes['away_crest']!.bottom, closeTo(194, 1e-9));
      expect(l.boxes['live']!.left, closeTo(125.94, 0.01));
      for (final String clave in <String>['live', 'competition', 'clock', 'camera']) {
        expect(l.boxes[clave]!.top, 44, reason: clave);
        expect(l.boxes[clave]!.bottom, 88, reason: clave);
      }
      expect(l.boxes['camera']!.right, 1872);
      expect(l.boxes['strip'], const ui.Rect.fromLTRB(0, 972, 1920, 1080));
      expect(l.boxes['logo'], const ui.Rect.fromLTRB(48, 1002, 103, 1050));
      expect(l.boxes['sellable'], const ui.Rect.fromLTRB(408, 972, 1572, 1080));
      expect(l.boxes['ai']!.right, 1872);
      expect(l.boxes['claim']!.left, 48);
    });

    test('el reloj no cambia de ancho con los dígitos', () {
      ui.Rect reloj(int segundos) => medir(ScoreboardState(
            competition: directo.competition,
            home: directo.home,
            away: directo.away,
            homeGoals: 0,
            awayGoals: 0,
            clockS: segundos,
            live: true,
            cameraMode: 'AUTO',
          )).boxes['clock']!;
      expect(<double>{for (final int t in <int>[0, 671, 4044, 5640]) reloj(t).width}, hasLength(1));
    });

    test('los nombres largos estiran la barra sin mover su arranque', () {
      final ScoreboardLayout corto = medir(directo);
      final ScoreboardLayout largo = medir(finalLargo);
      expect(largo.boxes['bug']!.width, greaterThan(corto.boxes['bug']!.width));
      expect(largo.boxes['bug']!.left, corto.boxes['bug']!.left);
      // El reloj va al final de la fila de estado, que crece con la barra.
      expect(largo.boxes['clock']!.right, greaterThan(corto.boxes['clock']!.right));
    });

    test('sin directo la competición ocupa el sitio de EN VIVO', () {
      final ScoreboardLayout sin = medir(inicio);
      expect(sin.boxes.containsKey('live'), isFalse);
      expect(sin.boxes['competition']!.left, medir(directo).boxes['live']!.left);
      final ScoreboardLayout anuncios = medir(directo, slots: false);
      expect(anuncios.boxes.keys.where((String k) => k.startsWith('slot_')), isEmpty);
      expect(anuncios.boxes['sellable'], medir(directo).boxes['sellable']);
      expect(anuncios.boxes['sellable']!.left, greaterThan(anuncios.boxes['claim']!.right));
    });

    test('las siglas de los escudos', () {
      expect(GalaBrand.crestInitials('BELLAVISTA'), 'BEL');
      expect(GalaBrand.crestInitials('U. CATÓLICA'), 'UC');
      expect(GalaBrand.crestInitials('Independiente del Valle'), 'IDV');
      expect(GalaBrand.crestInitials('LDU'), 'LDU');
    });
  });

  group('el raster', () {
    testWidgets('solo rasteriza cuando cambia el contenido', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final OverlayRaster raster = OverlayRaster();
        // Un segundo de programa a 30 fps con el reloj quieto: un raster.
        OverlayFrame? frame;
        for (int i = 0; i < 30; i++) {
          frame = await raster.render(directo);
        }
        expect(raster.rasterCount, 1);
        expect(frame!.rgba.length, OverlaySpec.programWidth * OverlaySpec.programHeight * 4);
        // Tres segundos de reloj en marcha a 30 fps: tres rasters, uno por segundo.
        for (int f = 0; f < 90; f++) {
          final ScoreboardState ahora = ScoreboardState(
            competition: directo.competition,
            home: directo.home,
            away: directo.away,
            homeGoals: directo.homeGoals,
            awayGoals: directo.awayGoals,
            clockS: directo.clockS + 1 + f ~/ 30,
            live: true,
            cameraMode: directo.cameraMode,
          );
          await raster.render(ahora);
        }
        expect(raster.rasterCount, 4);
      });
    });

    testWidgets('la capa es transparente fuera del gráfico', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final OverlayFrame frame = await OverlayRaster().render(directo);
        int alfa(int x, int y) => frame.rgba[(y * frame.width + x) * 4 + 3];
        expect(alfa(960, 540), 0, reason: 'el centro del campo se ve');
        expect(alfa(960, 1050), greaterThan(200), reason: 'la franja es casi opaca');
        expect(alfa(300, 120), greaterThan(200), reason: 'la barra del marcador');
      });
    });
  });
}
