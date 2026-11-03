/// La cortinilla y el rótulo de la repetición (IOS-119, ADR 0034) contra la referencia de Python
/// (tools/replay_card.py): el punto en cada instante, la geometría de boxes.json donde no depende
/// del texto, ≤3 % de píxeles distintos de sus renders, y la capa 3 en el programa, también en el
/// vóley.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/graphics/gala_brand.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/program_graphics.dart';
import 'package:football_ai_capture/src/graphics/replay_painter.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/replay.dart';

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

class _Reloj implements MatchTimeSource {
  int ms = 100000;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

class _Sink implements OverlaySink {
  final List<String> calls = <String>[];

  @override
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation) async =>
      calls.add('set $layer');

  @override
  Future<void> clearOverlay(int layer) async => calls.add('clear $layer');

  @override
  Future<void> setBackdropBlur(bool on) async => calls.add(on ? 'blur on' : 'blur off');
}

void main() {
  setUpAll(loadZeroFonts);

  test('el punto de la cortinilla es el de stinger_at de Python', () {
    expect(stingerAt(-1), isNull);
    expect(stingerAt(replayTransitionMs), isNull);
    expect(replayTransitionMs, 1400);
    expect(replayCutMs, 700);
    // Los de tools/replay_card.py, a centésimas.
    expect(stingerAt(0), const Stinger(true, 0, 0.6, 0));
    expect(stingerAt(250), const Stinger(true, 0.5, 0.77, 0.17));
    expect(stingerAt(400), const Stinger(true, 0.97, 0.99, 0.67));
    expect(stingerAt(700), stingerCovered);
    expect(stingerAt(1000), const Stinger(false, 0.03, 1.06, 0.6));
    expect(stingerAt(1150), const Stinger(false, 0.5, 1.15, 0));
    expect(stingerMoving(450), isTrue);
    expect(stingerMoving(700), isFalse, reason: 'tapada, quieta');
    expect(stingerMoving(1000), isTrue);
  });

  test('las bandas empiezan fuera, tapan en el corte y acaban fuera', () {
    expect(stingerBands(1920, 1080, const Stinger(true, 0, 1, 0)).values.every((Path p) => p.getBounds().right <= 0), isTrue);
    final Rect cuerpo = stingerBands(1920, 1080, stingerCovered)['body']!.getBounds();
    expect(cuerpo.left, lessThanOrEqualTo(-311));
    expect(cuerpo.right, greaterThanOrEqualTo(1920 + 311));
    expect(stingerBands(1920, 1080, const Stinger(false, 1, 1, 0)).values.every((Path p) => p.getBounds().left >= 1920), isTrue);
  });

  test('la geometría es la de boxes.json (repeticion) donde no depende del texto', () {
    final ReplayLayout l = ReplayLayout(1920, 1080, icon: true);
    // Las cifras son las de tests/golden/v1/overlay/boxes.json de football-ai.
    expect(l.boxes['chip'], const Rect.fromLTRB(681, 323, 1239, 587));
    expect(l.boxes['championship'], const Rect.fromLTRB(717, 359, 909, 551));
    expect(l.boxes['broadcaster'], const Rect.fromLTRB(981, 359, 1203, 551));
    final Rect raya = l.boxes['rule']!;
    expect(raya.left, closeTo(777.11, 0.01));
    expect(raya.top, 745);
    expect(raya.bottom, 755);
    final Rect barra = l.boxes['bug_bar']!;
    expect(barra.right, 1872, reason: 'su esquina de arriba toca el margen');
    expect((barra.top, barra.bottom), (856.0, 920.0));
    expect(barra.left, closeTo(1617.05, 3), reason: 'depende del ancho del texto');
    final ReplayLayout sinIcono = ReplayLayout(1920, 1080, icon: false, title: false);
    expect(sinIcono.boxes.containsKey('championship'), isFalse);
    expect(sinIcono.boxes['broadcaster']!.center.dx, 960);
  });

  testWidgets('tapada, a mitad de la entrada y el rótulo: ≤3 % de píxeles distintos de Python', (WidgetTester t) async {
    await t.runAsync(() async {
      final ui.Image icono = await GalaBrand.isotipo();
      final List<(ReplayGraphic, String)> casos = <(ReplayGraphic, String)>[
        (const ReplayGraphic(stinger: stingerCovered, title: true, iconRev: 1), 'repeticion.png'),
        (ReplayGraphic(stinger: stingerAt(250), title: true, iconRev: 1), 'repeticion_entrada.png'),
        (const ReplayGraphic(bug: true), 'repeticion_rotulo.png'),
      ];
      for (final (ReplayGraphic g, String png) in casos) {
        final ui.Image imagen = await paintReplayImage(g, 1920, 1080, icon: g.iconRev == null ? null : icono);
        final double fraccion = await _distintos(await _rgba(imagen), png);
        imagen.dispose();
        expect(fraccion, lessThanOrEqualTo(0.03), reason: png);
      }
    });
  });

  testWidgets('el programa lleva la capa 3 durante la repetición, también en el vóley', (WidgetTester t) async {
    await t.runAsync(() async {
      final Directory dir = Directory.systemTemp.createTempSync('ios119g');
      final _Reloj reloj = _Reloj();
      final MatchEngine m = MatchEngine.open(
        file: File('${dir.path}/voley.json'), time: reloj, random: Random(3), eventKind: EventKind.volleyball,
      );
      final _Sink sink = _Sink();
      final ProgramGraphics g = ProgramGraphics(engine: m, bridge: OverlayBridge(sink));
      await g.refresh();
      expect(sink.calls, contains('clear 3'), reason: 'la capa de un maestro anterior se quita al empezar');
      expect(sink.calls.where((String c) => c == 'set 3'), isEmpty);

      m.setReplayBuffer((oldestRigMs: 0, newestRigMs: reloj.ms));
      final ReplayRequest r = m.replayRequest(<String, Object?>{'seconds': 5});
      m.replayArmed((id: r.id, fromRigMs: r.fromRigMs, toRigMs: r.toRigMs, cutRigMs: reloj.ms + replayLeadToCutMs));
      final ReplayOnAir a = m.replay.onAir!;
      sink.calls.clear();
      reloj.ms = a.startMs + 200;
      expect(g.animating, isTrue);
      await g.refresh();
      expect(sink.calls.where((String c) => c == 'set 3').length, 1, reason: 'la cortinilla en el vóley');
      reloj.ms = a.cutInMs + 2000;
      expect(g.animating, isFalse, reason: 'con el rótulo quieto no se rasteriza a 20 fps');
      await g.refresh();
      expect(sink.calls.where((String c) => c == 'set 3').length, 2, reason: 'el rótulo');
      reloj.ms = a.endMs;
      expect(g.animating, isTrue, reason: 'acabada, hace falta un raster más que la quite');
      await g.refresh();
      expect(sink.calls.last, 'clear 3');
      expect(g.animating, isFalse);
      dir.deleteSync(recursive: true);
    });
  });
}
