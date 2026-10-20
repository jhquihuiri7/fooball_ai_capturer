/// El gráfico del programa del maestro (IOS-47): del partido al marcador y la tarjeta,
/// publicados solo cuando cambian.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/event_kind.dart';
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

      // El marcador a mano (un gol trae su animación, que se mira aparte).
      m.apply('match/score', <String, Object?>{
        'home': 1,
        'away': 0,
        'expect': <String, Object?>{'home': 0, 'away': 0},
      });
      await g.refresh();
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 400;
      await g.refresh();
      expect(sink.calls.where((String c) => c == 'set 0').length, 2, reason: 'el marcador sí; 0,4 s de reloj no');
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
      // ADR 0029: la de final y la de próximo partido van igual que el entretiempo.
      desde = sink.calls.length;
      m.apply('graphics/fulltime', <String, Object?>{'on_air': true});
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 1', 'blur on', 'clear 0']);
      m.apply('match/next', <String, Object?>{'home': 'A', 'away': 'B', 'when': 'HOY', 'venue': ''});
      m.apply('graphics/next_match', <String, Object?>{'on_air': true});
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 1'], reason: 'otra tarjeta en la misma capa');
      m.apply('graphics/next_match', <String, Object?>{'on_air': false});
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['blur off', 'set 0', 'clear 1']);

      // ADR 0030: la jornada y las entrevistas, en la misma capa.
      m.apply('match/fixtures', <String, Object?>{
        'matches': <Map<String, Object?>>[<String, Object?>{'home': 'A', 'away': 'B', 'time': '10:00'}],
      });
      m.apply('graphics/fixtures', <String, Object?>{'on_air': true});
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 1', 'blur on', 'clear 0']);
      m.apply('graphics/interview', <String, Object?>{'on_air': true});
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 1']);
      m.apply('graphics/interview', <String, Object?>{'on_air': false});
      await g.refresh();

      // ADR 0028: el escudo del equipo vuelve a pintar el marcador, y va con su nombre.
      m.graphics.crestUploadFile.parent.createSync(recursive: true);
      File('assets/brand/gala-sports-isotipo.png').copySync(m.graphics.crestUploadFile.path);
      m.adoptTeamCrest(MatchTeam.home, 'image/png');
      desde = sink.calls.length;
      await g.refresh();
      expect(sink.calls.sublist(desde), <String>['set 0']);
      expect(g.scoreboardState().homeCrestRev, isNotNull);
      m.apply('match/teams', <String, Object?>{'home': 'OTRO'});
      await g.refresh();
      expect(g.scoreboardState().homeCrestRev, isNull, reason: 'OTRO no tiene escudo');
      // La franja va oculta y sale con la orden, hasta que se le acaba el tiempo.
      expect(g.scoreboardState().stripVisible, isFalse);
      m.apply('graphics/strip', <String, Object?>{'show_s': 15});
      expect(g.scoreboardState().stripVisible, isTrue);
      reloj.ms += 16000;
      expect(g.scoreboardState().stripVisible, isFalse);
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('el gol sale solo, se pinta a fps mientras entra y sale, y se va (ADR 0032)', (WidgetTester t) async {
    await t.runAsync(() async {
      final Directory dir = Directory.systemTemp.createTempSync('ios112');
      final _Reloj reloj = _Reloj();
      final MatchEngine m = MatchEngine.open(
        file: File('${dir.path}/match.json'), time: reloj, home: 'BELLAVISTA', away: 'PROGRESO', random: Random(4),
      );
      final _Sink sink = _Sink();
      final ProgramGraphics g = ProgramGraphics(engine: m, bridge: OverlayBridge(sink));
      await g.refresh();
      expect(g.animating, isFalse);
      int sets() => sink.calls.where((String c) => c == 'set 0').length;

      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      expect(g.scoreboardState().goal, isNotNull);
      expect(g.scoreboardState().goal!.home, isTrue);
      expect(g.animating, isTrue, reason: 'entrando');
      await g.refresh();
      final int alEntrar = sets();
      reloj.ms = 200;
      await g.refresh();
      expect(sets(), alEntrar + 1, reason: 'cada fotograma de la entrada es otro raster');
      reloj.ms = 1000;
      expect(g.animating, isFalse, reason: 'quieto');
      await g.refresh();
      final int quieto = sets();
      reloj.ms = 2000;
      await g.refresh();
      expect(sets(), quieto, reason: 'quieto y sin reloj, no se vuelve a pintar');
      expect(g.scoreboardState().goal!.reveal, 1);
      reloj.ms = 4800;
      expect(g.animating, isTrue, reason: 'saliendo');
      await g.refresh();
      reloj.ms = 5200;
      expect(g.scoreboardState().goal, isNull);
      expect(g.animating, isTrue, reason: 'hace falta un raster que lo quite');
      await g.refresh();
      expect(g.animating, isFalse);

      // Un −1 del mismo equipo mientras está fuera lo quita: era un error.
      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      expect(g.scoreboardState().goal!.home, isFalse);
      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': -1, 'expect': 1});
      expect(g.scoreboardState().goal, isNull);

      // El marcador a demanda: fuera, la barra y el reloj; EN VIVO arriba.
      m.apply('graphics/scoreboard', <String, Object?>{'on_air': false});
      expect(g.scoreboardState().scoreboard, isFalse);
      m.apply('graphics/scoreboard', <String, Object?>{'on_air': true});
      expect(g.scoreboardState().scoreboard, isTrue);

      // La tanda de franjas: la que está fuera cambia con el tiempo, sin hueco entre dos.
      m.apply('graphics/strip_save', <String, Object?>{'name': 'B', 'title': 'SEGUNDA'});
      m.apply('graphics/strip_all', <String, Object?>{'show_s': 10});
      expect(g.scoreboardState().stripTitle, m.graphics.stripPresets.first.texts.title);
      reloj.ms += 10000;
      expect(g.scoreboardState().stripVisible, isTrue);
      expect(g.scoreboardState().stripTitle, 'SEGUNDA');
      reloj.ms += 10000;
      expect(g.scoreboardState().stripVisible, isFalse, reason: 'al acabar la tanda, se oculta');
      dir.deleteSync(recursive: true);
    });
  });

  testWidgets('el espectáculo va sin marcador ni tarjetas, con su rótulo; el vóley, sin nada (ADR 0031)', (
    WidgetTester t,
  ) async {
    await t.runAsync(() async {
      final Directory dir = Directory.systemTemp.createTempSync('ios111');
      final _Reloj reloj = _Reloj();
      final MatchEngine m = MatchEngine.open(
        file: File('${dir.path}/match.json'), time: reloj, random: Random(4), eventKind: EventKind.show,
      );
      final _Sink sink = _Sink();
      final ProgramGraphics g = ProgramGraphics(engine: m, bridge: OverlayBridge(sink));
      expect(g.scoreboardState().scoreboard, isFalse);
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      expect(g.scoreboardState().goal, isNull, reason: 'sin gol animado fuera del fútbol');
      m.apply('graphics/caption_save', <String, Object?>{
        'name': 'Ángeles',
        'title': 'Presentación artística: Los Ángeles del Cielo',
        'subtitle': 'Cantado por Jonathan Quiwi',
      });
      m.apply('graphics/caption', <String, Object?>{'name': 'ángeles', 'show_s': 10});
      expect(g.scoreboardState().lowerThirdTitle, 'Presentación artística: Los Ángeles del Cielo');
      expect(g.scoreboardState().lowerThirdSubtitle, 'Cantado por Jonathan Quiwi');
      m.apply('graphics/halftime', <String, Object?>{'on_air': true});
      await g.refresh();
      expect(sink.calls, <String>['set 2', 'set 0'], reason: 'ni tarjeta ni desenfoque: el marcador con su rótulo');
      reloj.ms = 11000;
      expect(g.scoreboardState().lowerThirdTitle, isNull, reason: 'los 10 s pasaron');

      final MatchEngine voley = MatchEngine.open(
        file: File('${dir.path}/voley.json'), time: reloj, random: Random(5), eventKind: EventKind.volleyball,
      );
      final _Sink otro = _Sink();
      await ProgramGraphics(engine: voley, bridge: OverlayBridge(otro)).refresh();
      expect(otro.calls, <String>['set 2'], reason: 'solo SIN SEÑAL, que sale cuando no hay cámara');
      dir.deleteSync(recursive: true);
    });
  });
}
