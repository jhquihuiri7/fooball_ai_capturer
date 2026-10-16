/// El gráfico del programa del maestro (IOS-47): del partido al marcador y la tarjeta,
/// publicados solo cuando cambian.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/program_graphics.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

import '../zero_fonts.dart';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

class _Sink implements OverlaySink {
  final List<String> calls = <String>[];

  @override
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation) async {
    expect(rgba.length, width * height * 4);
    calls.add('set $layer');
  }

  @override
  Future<void> clearOverlay(int layer) async => calls.add('clear $layer');

  @override
  Future<void> setBackdropBlur(bool on) async => calls.add(on ? 'blur on' : 'blur off');
}

const String _milan = '1 Dida\n2 Cafu\n3 Maldini\n4 Gattuso\n13 Nesta\n21 Pirlo\n8 Seedorf\n'
    '22 Kaka\n10 Rui Costa\n7 Shevchenko\n11 Gilardino\n';

void main() {
  setUpAll(loadZeroFonts);

  testWidgets('marcador al cambiar y una vez por segundo; la alineación al aire y fuera', (WidgetTester t) async {
    await t.runAsync(() async {
      final Directory dir = Directory.systemTemp.createTempSync('ios47');
      final _Reloj reloj = _Reloj();
      final MatchEngine m = MatchEngine.open(
        file: File('${dir.path}/match.json'), time: reloj, home: 'BELLAVISTA', away: 'PROGRESO', random: Random(4),
      );
      final _Sink sink = _Sink();
      final ProgramGraphics g = ProgramGraphics(engine: m, bridge: OverlayBridge(sink));

      await g.refresh();
      await g.refresh();
      expect(sink.calls, <String>['set 2', 'set 0'], reason: 'SIN SEÑAL una vez; sin cambios no se repite');

      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      await g.refresh();
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 400;
      await g.refresh();
      expect(sink.calls.where((String c) => c == 'set 0').length, 2, reason: 'el gol sí; 0,4 s de reloj no');
      reloj.ms = 1000;
      await g.refresh();
      expect(sink.calls.where((String c) => c == 'set 0').length, 3, reason: 'el segundo sí');

      m.saveLineup(MatchTeam.home, 'Milan', '4-4-2', _milan);
      m.apply('match/lineup', <String, Object?>{'team': 'home', 'on_air': true});
      await g.refresh();
      expect(sink.calls.last, 'set 1');
      m.apply('match/lineup', <String, Object?>{'team': 'home', 'on_air': false});
      await g.refresh();
      expect(sink.calls.last, 'clear 1');
      expect(g.scoreboardState().home, 'MILAN', reason: 'el editor pone el nombre en el marcador');

      // ADR 0027: el entretiempo va en la capa de tarjetas, pide la cancha desenfocada y
      // quita el marcador, que se vería a través del velo; al salir, todo vuelve.
      int desde = sink.calls.length;
      m.apply('graphics/halftime', <String, Object?>{'on_air': true});
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 1', 'blur on', 'clear 0']);
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), isEmpty, reason: 'con el entretiempo fuera, cada segundo no manda nada');
      m.apply('graphics/halftime', <String, Object?>{'on_air': false});
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['blur off', 'set 0', 'clear 1']);
      // La franja va oculta y sale con la orden, hasta que se le acaba el tiempo.
      expect(g.scoreboardState().stripVisible, isFalse);
      m.apply('graphics/strip', <String, Object?>{'show_s': 15});
      expect(g.scoreboardState().stripVisible, isTrue);
      reloj.ms += 16000;
      expect(g.scoreboardState().stripVisible, isFalse);
      dir.deleteSync(recursive: true);
    });
  });
}
