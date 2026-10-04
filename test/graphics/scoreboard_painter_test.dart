/// El marcador en Dart (IOS-45): dorados de imagen de 4 estados, la geometría de la
/// maqueta de Python y un raster por cambio de contenido.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
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
Future<void> _loadZeroFonts() async {
  final Map<String, List<String>> familias = <String, List<String>>{
    ZeroType.display: <String>['Archivo-Bold.ttf'],
    ZeroType.sans: <String>['IBMPlexSans-Regular.ttf'],
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
  setUpAll(_loadZeroFonts);

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

  group('la geometría de la maqueta (boxes.json de REF-32)', () {
    ScoreboardLayout medir(ScoreboardState s, {bool slots = true}) => ScoreboardLayout.measure(
        OverlaySpec.programWidth, OverlaySpec.programHeight, s, sponsorSlots: slots);

    test('lo que no depende del texto cae donde en Python', () {
      final ScoreboardLayout l = medir(directo);
      // Archivo es más ancha que la Arial Narrow de la maqueta: el marcador puede
      // estirarse (la maqueta lo hace con nombres largos), pero nunca encoger, y lo
      // demás va anclado a él.
      final ui.Rect bug = l.boxes['bug']!;
      expect(bug.left, 48);
      expect(bug.top, 44);
      expect(bug.bottom, 132);
      expect(bug.width, greaterThanOrEqualTo(704));
      expect(l.boxes['crest'], const ui.Rect.fromLTRB(48, 44, 134, 132));
      expect(l.boxes['clock'], ui.Rect.fromLTRB(bug.right - 150, 74, bug.right, 132));
      expect(l.boxes['competition'], ui.Rect.fromLTRB(134, 44, bug.right, 74));
      expect(l.boxes['strip'], const ui.Rect.fromLTRB(0, 972, 1920, 1080));
      expect(l.boxes['live']!.top, 148);
      expect(l.boxes['live']!.bottom, 178);
      expect(l.boxes['camera']!.top, 44);
      expect(l.boxes['camera']!.bottom, 82);
      expect(l.boxes['camera']!.right, 1872);
      expect(l.boxes['ai']!.right, 1872);
      expect(l.boxes['claim']!.left, 48);
    });

    test('los nombres largos estiran el marcador hacia la derecha', () {
      final ScoreboardLayout corto = medir(directo);
      final ScoreboardLayout largo = medir(finalLargo);
      expect(largo.boxes['bug']!.width, greaterThan(corto.boxes['bug']!.width));
      expect(largo.boxes['bug']!.left, corto.boxes['bug']!.left);
      // El reloj sigue pegado al borde derecho del marcador.
      expect(largo.boxes['clock']!.right, largo.boxes['bug']!.right);
    });

    test('sin directo no hay EN VIVO, y sin ranuras el hueco vendible sigue', () {
      expect(medir(inicio).boxes.containsKey('live'), isFalse);
      final ScoreboardLayout anuncios = medir(directo, slots: false);
      expect(anuncios.boxes.keys.where((String k) => k.startsWith('slot_')), isEmpty);
      expect(anuncios.boxes['sellable'], medir(directo).boxes['sellable']);
      expect(anuncios.boxes['sellable']!.left, greaterThan(anuncios.boxes['claim']!.right));
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
        expect(alfa(60, 60), greaterThan(200), reason: 'el marcador');
      });
    });
  });
}
