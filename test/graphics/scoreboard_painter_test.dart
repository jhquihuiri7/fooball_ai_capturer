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
      // Enmienda del ADR 0026 del 2026-10-16: la competición encima, el reloj al lado, EN
      // VIVO debajo, la esquina con el logo de la casa, y sin chip de cámara.
      expect(l.boxes['competition']!.left, closeTo(125.94, 0.01));
      expect((l.boxes['competition']!.top, l.boxes['competition']!.bottom), (44, 88));
      // El reloj va tras la barra, que mide con el texto: se mira contra ella, no contra Python.
      expect(
        l.boxes['clock']!.left,
        closeTo(bug.right + OverlaySpec.scoreboard['clock_gap']! - 76 * GalaBrand.inclinacion, 1e-9),
      );
      expect((l.boxes['clock']!.top, l.boxes['clock']!.bottom), (106, 182));
      final ui.Rect vivo = l.boxes['live']!;
      expect(vivo.left, closeTo(125.94, 0.01));
      expect((vivo.top, vivo.bottom), (200, 244));
      expect(l.boxes['corner'], const ui.Rect.fromLTRB(1774, 44, 1872, 132));
      expect(l.boxes['broadcaster'], const ui.Rect.fromLTRB(1786, 56, 1860, 120));
      expect(l.boxes.containsKey('camera'), isFalse);
      expect(l.boxes['strip'], const ui.Rect.fromLTRB(0, 948, 1920, 1080)); // 132 px (ADR 0032)
      expect(l.boxes['sellable'], const ui.Rect.fromLTRB(408, 948, 1572, 1080));
      // La franja: el título y el subtítulo desde el margen (enmienda del ADR 0027).
      expect(l.boxes['strip_title']!.left, 48);
      expect((l.boxes['strip_title']!.top, l.boxes['strip_title']!.bottom), (977, 1017));
      expect((l.boxes['strip_subtitle']!.top, l.boxes['strip_subtitle']!.bottom), (1026, 1050));
      expect(l.boxes.containsKey('logo'), isFalse);
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

    test('sin directo no hay EN VIVO y la competición no se mueve; con anuncios, la franja vacía', () {
      final ScoreboardLayout sin = medir(inicio);
      expect(sin.boxes.containsKey('live'), isFalse);
      expect(sin.boxes['competition']!.left, medir(directo).boxes['competition']!.left);
      final ScoreboardLayout anuncios = medir(directo, slots: false);
      expect(anuncios.boxes['sellable'], medir(directo).boxes['sellable']);
      for (final String clave in <String>['strip_title', 'strip_subtitle', 'strip_image']) {
        expect(anuncios.boxes.containsKey(clave), isFalse, reason: clave);
      }
    });

    test('las siglas de los escudos', () {
      expect(GalaBrand.crestInitials('BELLAVISTA'), 'BEL');
      expect(GalaBrand.crestInitials('U. CATÓLICA'), 'UC');
      expect(GalaBrand.crestInitials('Independiente del Valle'), 'IDV');
      expect(GalaBrand.crestInitials('LDU'), 'LDU');
    });
  });

  group('el icono, la franja oculta y sus textos (ADR 0027)', () {
    ScoreboardState con({bool franja = true, int? icono, String? titulo, int? imagen}) => ScoreboardState(
      competition: directo.competition,
      home: directo.home,
      away: directo.away,
      homeGoals: directo.homeGoals,
      awayGoals: directo.awayGoals,
      clockS: directo.clockS,
      live: true,
      cameraMode: 'AUTO',
      stripVisible: franja,
      iconRev: icono,
      stripTitle: titulo ?? OverlaySpec.stripTitleDefault,
      stripImageRev: imagen,
    );
    ScoreboardLayout medir(ScoreboardState s, {ui.Size? imagen}) =>
        ScoreboardLayout.measure(OverlaySpec.programWidth, OverlaySpec.programHeight, s, stripImageSize: imagen);

    test('el icono de la copa va en la esquina, junto al logo de la casa, donde en Python', () {
      final ScoreboardLayout sin = medir(con());
      final ScoreboardLayout l = medir(con(icono: 1, franja: false));
      // `directo_icono` de boxes.json (enmienda del ADR 0026 del 2026-10-16).
      expect(l.boxes['championship'], const ui.Rect.fromLTRB(1698, 56, 1762, 120));
      expect(l.boxes['corner'], const ui.Rect.fromLTRB(1686, 44, 1872, 132));
      expect(sin.boxes.containsKey('championship'), isFalse);
      expect(l.boxes['bug'], sin.boxes['bug']);
      expect(l.boxes['competition'], sin.boxes['competition']);
    });

    test('sin franja no se mide ni se pinta nada abajo', () {
      final ScoreboardLayout l = medir(con(franja: false));
      for (final String clave in <String>['strip', 'sellable', 'strip_title', 'strip_subtitle', 'strip_image']) {
        expect(l.boxes.containsKey(clave), isFalse, reason: clave);
      }
    });

    test('los textos editados de la franja cambian lo que se mide', () {
      final double antes = medir(con()).boxes['strip_title']!.width;
      final double despues = medir(con(titulo: 'VAMOS')).boxes['strip_title']!.width;
      expect(despues, lessThan(antes));
    });

    test('la imagen de la franja va contenida a la izquierda, donde en Python, y empuja el título', () {
      // `directo_franja` de boxes.json: el isotipo de 97×84 a 108 de alto (franja de 132).
      final ScoreboardLayout l = medir(con(imagen: 1), imagen: const ui.Size(97, 84));
      expect(l.boxes['strip_image'], const ui.Rect.fromLTRB(48, 960, 173, 1068));
      expect(l.boxes['strip_title']!.left, 201);
      final ScoreboardLayout ancha = medir(con(imagen: 1), imagen: const ui.Size(800, 200));
      expect(ancha.boxes['strip_image']!.width, OverlaySpec.strip['image_max_w']);
    });

    testWidgets('la franja con su imagen: ≤3 % de píxeles distintos de directo_franja.png', (WidgetTester t) async {
      await t.runAsync(() async {
        final ui.Image iso = await GalaBrand.isotipo();
        final OverlayFrame f = await OverlayRaster().render(con(imagen: 1), stripImage: iso);
        final double fraccion = await _distintosDePython(f.rgba, 'directo_franja.png');
        // ignore: avoid_print
        print('franja con imagen: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
      });
    });

    testWidgets('sin franja, la parte de abajo queda transparente', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final OverlayFrame frame = await OverlayRaster().render(con(franja: false));
        int alfa(int x, int y) => frame.rgba[(y * frame.width + x) * 4 + 3];
        expect(alfa(960, 1050), 0);
        expect(alfa(300, 120), greaterThan(200), reason: 'el marcador sigue');
      });
    });
  });

  group('los escudos de los equipos (ADR 0028)', () {
    testWidgets('sustituyen al genérico: ≤3 % de píxeles distintos de directo_escudos.png', (WidgetTester t) async {
      await t.runAsync(() async {
        // El render de Python lleva el isotipo de escudo en los dos lados y la franja fuera.
        final ui.Image iso = await GalaBrand.isotipo();
        final ScoreboardState estado = ScoreboardState(
          competition: directo.competition,
          home: directo.home,
          away: directo.away,
          homeGoals: directo.homeGoals,
          awayGoals: directo.awayGoals,
          clockS: directo.clockS,
          live: true,
          cameraMode: 'AUTO',
          stripVisible: false,
          homeCrestRev: 1,
          awayCrestRev: 1,
        );
        final OverlayFrame f = await OverlayRaster().render(estado, crests: <String, ui.Image>{'home': iso, 'away': iso});
        final double fraccion = await _distintosDePython(f.rgba, 'directo_escudos.png');
        // ignore: avoid_print
        print('marcador con escudos: ${(fraccion * 100).toStringAsFixed(2)} % de píxeles distintos');
        expect(fraccion, lessThanOrEqualTo(0.03));
      });
    });

    test('la versión del escudo cuenta en el estado: otro escudo, otro raster', () {
      const ScoreboardState a = ScoreboardState(
        competition: 'L', home: 'A', away: 'B', homeGoals: 0, awayGoals: 0, clockS: 0, live: false,
        cameraMode: 'AUTO', homeCrestRev: 1,
      );
      const ScoreboardState b = ScoreboardState(
        competition: 'L', home: 'A', away: 'B', homeGoals: 0, awayGoals: 0, clockS: 0, live: false,
        cameraMode: 'AUTO', homeCrestRev: 2,
      );
      expect(a == b, isFalse);
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

/// Fracción de píxeles con algún canal a más de 64 del PNG de Python de `reference/`.
Future<double> _distintosDePython(Uint8List dart, String png) async {
  final ui.Codec codec = await ui.instantiateImageCodec(File('test/graphics/reference/$png').readAsBytesSync());
  final ui.Image python = (await codec.getNextFrame()).image;
  final Uint8List b = (await python.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
  python.dispose();
  int distintos = 0;
  for (int i = 0; i < dart.length; i += 4) {
    for (int k = 0; k < 4; k++) {
      if ((dart[i + k] - b[i + k]).abs() > 64) {
        distintos++;
        break;
      }
    }
  }
  return distintos / (dart.length ~/ 4);
}
