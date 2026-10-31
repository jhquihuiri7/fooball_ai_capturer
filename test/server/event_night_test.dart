/// Lo nuevo del motor del maestro (ADR 0031 y 0032 del repo football-ai): el tipo de evento,
/// el gol animado, el marcador a demanda, las tandas de franjas, rótulos y vídeos, el partido
/// de la jornada con «Finalizar» y la tarjeta de resultados.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/server/graphics_store.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

import 'mp4_fixture.dart';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  String get domain => 'soporte1';
  @override
  int nowMs() => ms;
}

const String _milan = '1 Dida\n2 Cafu\n3 Maldini\n4 Gattuso\n13 Nesta\n21 Pirlo\n8 Seedorf\n'
    '22 Kaka\n10 Rui Costa\n7 Shevchenko\n11 Gilardino\n';

void main() {
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine m;

  MatchEngine abrir({EventKind kind = EventKind.football, String nombre = 'match.json'}) => MatchEngine.open(
    file: File('${dir.path}/$nombre'),
    time: reloj,
    home: 'BELLAVISTA',
    away: 'PROGRESO',
    random: Random(1),
    eventKind: kind,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noche');
    reloj = _Reloj();
    m = abrir();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> jornada(List<(String, String, String)> partidos) => <String, Object?>{
    'matches': <Map<String, Object?>>[
      for (final (String a, String b, String hora) in partidos) <String, Object?>{'home': a, 'away': b, 'time': hora},
    ],
  };

  group('el tipo de evento (ADR 0031)', () {
    test('va en el estado y el mando nativo lo lee; sin el campo es fútbol', () {
      expect(m.toJson()['event_kind'], 'football');
      final MatchEngine show = abrir(kind: EventKind.show, nombre: 'show.json');
      final Map<String, Object?> dto = show.toJson();
      expect(dto['event_kind'], 'show');
      expect(PanelMatch.fromJson(dto).eventKind, EventKind.show);
      expect(PanelMatch.fromJson(<String, Object?>{...m.toJson()}..remove('event_kind')).eventKind, EventKind.football);
      expect(EventKind.fromWire('otra cosa'), EventKind.football);
    });
  });

  group('el gol animado (ADR 0032)', () {
    test('sale con +1, dura show_ms, y un −1 del mismo equipo lo quita', () {
      expect(m.goal, isNull);
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      expect(m.goal?.team, MatchTeam.home);
      final Map<String, Object?> gol = m.toJson()['goal']! as Map<String, Object?>;
      expect(gol, <String, Object?>{'team': 'home', 'remaining_ms': OverlaySpec.goal['show_ms']});
      reloj.ms = OverlaySpec.goal['show_ms']!;
      expect(m.goal, isNull);
      expect(m.toJson()['goal'], isNull);

      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': -1, 'expect': 1});
      expect(m.goal?.team, MatchTeam.away, reason: 'el −1 del otro equipo no lo quita');
      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': -1, 'expect': 1});
      expect(m.goal, isNull);
    });

    test('tick sube rev al acabar, para que los mandos lo vean', () {
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      final int rev = m.rev;
      expect(m.tick(), isFalse);
      reloj.ms = OverlaySpec.goal['show_ms']! + 10;
      expect(m.tick(), isTrue);
      expect(m.rev, rev + 1);
      expect(m.tick(), isFalse, reason: 'una vez');
    });

    test('fuera del fútbol no sale', () {
      final MatchEngine show = abrir(kind: EventKind.show, nombre: 'show.json');
      show.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      expect(show.goal, isNull);
    });
  });

  test('el marcador a demanda va en el estado y no se guarda', () {
    expect(m.toJson()['scoreboard_on_air'], isTrue);
    m.apply('graphics/scoreboard', <String, Object?>{'on_air': false});
    expect(m.toJson()['scoreboard_on_air'], isFalse);
    expect(_error(() => m.apply('graphics/scoreboard', <String, Object?>{'on_air': 'no'})).status, 400);
    expect(abrir().scoreboardOnAir, isTrue, reason: 'tras reiniciar vuelve');
  });

  test('cada elemento del gráfico se apaga por su nombre, va en el estado y no se guarda', () {
    final Map<String, Object?> todos = m.toJson()['elements_on_air']! as Map<String, Object?>;
    expect(todos.keys, onAirElements, reason: 'los seis, en su orden');
    expect(todos.values, everyElement(isTrue));
    m.apply('graphics/element', <String, Object?>{'element': 'clock', 'on_air': false});
    final Map<String, Object?> dto =
        m.apply('graphics/element', <String, Object?>{'element': 'championship', 'on_air': false});
    expect(m.hiddenElements, <String>{'clock', 'championship'});
    expect((dto['elements_on_air']! as Map<String, Object?>)['clock'], isFalse);
    m.apply('graphics/element', <String, Object?>{'element': 'clock', 'on_air': true});
    expect(m.hiddenElements, <String>{'championship'});
    for (final Map<String, Object?> mala in <Map<String, Object?>>[
      <String, Object?>{'element': 'tortuga', 'on_air': false},
      <String, Object?>{'element': 'clock', 'on_air': 'no'},
      <String, Object?>{'on_air': false},
    ]) {
      expect(_error(() => m.apply('graphics/element', mala)).status, 400, reason: '$mala');
    }
    expect(m.hiddenElements, <String>{'championship'}, reason: 'una orden mala no toca nada');
    expect(abrir().hiddenElements, isEmpty, reason: 'tras reiniciar vuelven');
  });

  group('las tandas (ADR 0032)', () {
    test('pasar todas las franjas: una tras otra, sin hueco, y al final se ocultan', () {
      m.apply('graphics/strip_save', <String, Object?>{'name': 'Radio', 'title': 'RADIO MAR'});
      m.apply('graphics/strip_save', <String, Object?>{'name': 'Banco', 'title': 'BANCO DEL PACÍFICO'});
      m.apply('graphics/strip_all', <String, Object?>{'show_s': 10});
      Map<String, Object?> dto = m.toJson();
      expect(dto['strip_preset'], stripPresetDefaultName);
      expect(dto['strip_queue'], <String>['Radio', 'Banco']);
      expect(m.stripRemainingMs, 10000);
      reloj.ms = 10000;
      expect(m.stripVisible, isTrue);
      expect(m.stripTexts.title, 'RADIO MAR');
      expect(m.toJson()['strip_queue'], <String>['Banco']);
      expect(m.tick(), isTrue, reason: 'cambió la que está fuera');
      reloj.ms = 25000;
      expect(m.stripTexts.title, 'BANCO DEL PACÍFICO');
      expect(m.stripRemainingMs, 5000);
      reloj.ms = 30000;
      expect(m.stripVisible, isFalse);
      expect(m.tick(), isTrue);
      dto = m.toJson();
      expect(dto['strip_queue'], isEmpty);
      expect(dto['strip_remaining_ms'], 0);
    });

    test('ocultar la franja corta la tanda; borrar la que está fuera pasa a la siguiente', () {
      m.apply('graphics/strip_save', <String, Object?>{'name': 'Radio', 'title': 'RADIO MAR'});
      m.apply('graphics/strip_all', <String, Object?>{'show_s': 10});
      m.apply('graphics/strip_delete', <String, Object?>{'name': stripPresetDefaultName});
      expect(m.stripTexts.title, 'RADIO MAR');
      expect(m.stripRemainingMs, 10000, reason: 'la siguiente empieza entera');
      m.apply('graphics/strip', <String, Object?>{'show_s': 0});
      expect(m.stripVisible, isFalse);
      expect(m.stripQueue, isEmpty);
      m.apply('graphics/strip_delete', <String, Object?>{'name': 'Radio'});
      expect(_error(() => m.apply('graphics/strip_all', <String, Object?>{})).status, 409, reason: 'sin franjas');
      expect(_error(() => m.apply('graphics/strip_all', <String, Object?>{'show_s': 0})).status, 400);
    });

    test('pasar todos los vídeos: en el orden de la lista, el siguiente al acabar el de antes', () {
      m.videos.directory.createSync(recursive: true);
      for (final String n in <String>['b.mp4', 'a.mp4', 'c.mp4']) {
        m.videos.file(n).writeAsBytesSync(fakeMp4(durationMs: 8000));
      }
      m.apply('video/play_all', <String, Object?>{});
      expect(m.video?.name, 'a.mp4');
      expect(m.toJson()['video_queue'], <String>['b.mp4', 'c.mp4']);
      m.videoFinished(m.video!.id);
      expect(m.video?.name, 'b.mp4');
      // Si el programa no avisa, el tiempo lo da por acabado y suena el siguiente.
      reloj.ms = 8000 + videoStartLeadMs + videoEndGraceMs + 1;
      expect(m.tick(), isTrue);
      expect(m.video?.name, 'c.mp4');
      m.apply('video/stop', <String, Object?>{});
      expect(m.video, isNull);
      expect(m.videoQueue, isEmpty);
      for (final String n in <String>['a.mp4', 'b.mp4', 'c.mp4']) {
        m.videos.delete(n);
      }
      expect(_error(() => m.apply('video/play_all', <String, Object?>{})).status, 409);
    });
  });

  group('los rótulos (ADR 0031)', () {
    Map<String, Object?> rotulo(String nombre, String titulo, [String sub = '']) =>
        <String, Object?>{'name': nombre, 'title': titulo, 'subtitle': sub};

    test('se guardan, se sacan 10 s o fijos, y se quitan', () {
      m.apply('graphics/caption_save', rotulo('Ángeles', 'Presentación artística', 'Cantado por Jonathan Quiwi'));
      expect(m.toJson()['captions'], <Object?>[
        <String, Object?>{'name': 'Ángeles', 'title': 'Presentación artística', 'subtitle': 'Cantado por Jonathan Quiwi'},
      ]);
      m.apply('graphics/caption', <String, Object?>{'name': 'ÁNGELES'});
      Map<String, Object?> dto = m.toJson();
      expect(dto['caption'], 'Ángeles');
      expect(dto['caption_remaining_ms'], captionShowDefaultS * 1000);
      reloj.ms = captionShowDefaultS * 1000;
      expect(m.captionOnAir, isNull);
      expect(m.tick(), isTrue);

      m.apply('graphics/caption', <String, Object?>{'name': 'Ángeles', 'hold': true});
      reloj.ms += 600000;
      dto = m.toJson();
      expect(dto['caption'], 'Ángeles');
      expect(dto['caption_remaining_ms'], captionHoldRemainingMs);
      m.apply('graphics/caption', <String, Object?>{'show_s': 0});
      expect(m.toJson()['caption'], isNull);
    });

    test('renombrar uno al aire lo deja al aire; borrarlo lo quita; los topes y los choques', () {
      m.apply('graphics/caption_save', rotulo('A', 'UNO'));
      m.apply('graphics/caption', <String, Object?>{'name': 'A', 'hold': true});
      m.apply('graphics/caption_save', <String, Object?>{...rotulo('B', 'UNO BIS'), 'previous_name': 'A'});
      expect(m.captionOnAir?.name, 'B');
      expect(m.captionOnAir?.title, 'UNO BIS');
      m.apply('graphics/caption_save', rotulo('C', 'DOS'));
      expect(_error(() => m.apply('graphics/caption_save', <String, Object?>{...rotulo('C', 'X'), 'previous_name': 'B'})).status, 409);
      m.apply('graphics/caption_delete', <String, Object?>{'name': 'b'});
      expect(m.captionOnAir, isNull);
      expect(_error(() => m.apply('graphics/caption_delete', <String, Object?>{'name': 'B'})).status, 404);
      expect(_error(() => m.apply('graphics/caption', <String, Object?>{'name': 'nadie'})).status, 404);
      expect(_error(() => m.apply('graphics/caption_save', rotulo('D', 'X' * 49))).status, 400);
      for (int i = m.graphics.captions.length; i < captionPresetsMax; i++) {
        m.apply('graphics/caption_save', rotulo('R$i', 'R'));
      }
      expect(_error(() => m.apply('graphics/caption_save', rotulo('Otro', 'R'))).status, 409);
    });

    test('pasar todos: uno tras otro y se ocultan; se guardan con el gráfico', () {
      m.apply('graphics/caption_save', rotulo('A', 'UNO'));
      m.apply('graphics/caption_save', rotulo('B', 'DOS'));
      m.apply('graphics/caption_all', <String, Object?>{'show_s': 5});
      expect(m.toJson()['caption_queue'], <String>['B']);
      reloj.ms = 5000;
      expect(m.captionOnAir?.name, 'B');
      reloj.ms = 10000;
      expect(m.captionOnAir, isNull);
      expect(GraphicsStore(dir).captions.map((CaptionPreset c) => c.name), <String>['A', 'B']);
    });
  });

  group('el partido de la jornada (ADR 0032)', () {
    setUp(() {
      m.apply('match/fixtures', jornada(<(String, String, String)>[
        ('Santa Cruz', 'San Cristóbal', '14:00'),
        ('Bellavista', 'Progreso', '16:00'),
      ]));
    });

    test('empezar uno pone sus nombres, el reloj a cero y lo marca en juego', () {
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms = 60000;
      m.apply('graphics/halftime', <String, Object?>{'on_air': true});
      m.apply('graphics/scoreboard', <String, Object?>{'on_air': false});
      m.apply('graphics/element', <String, Object?>{'element': 'live', 'on_air': false});
      final Map<String, Object?> dto = m.apply('match/fixture_start', <String, Object?>{'index': 0});
      expect((m.home, m.away), ('Santa Cruz', 'San Cristóbal'));
      expect((m.homeGoals, m.awayGoals), (0, 0));
      expect((m.clock.elapsedMs, m.clock.running), (0, false));
      expect(m.fullScreenCard, isNull);
      expect(m.goal, isNull);
      expect(m.scoreboardOnAir, isTrue);
      expect(m.hiddenElements, <String>{'live'}, reason: 'son del evento: empezar un partido no los enciende');
      expect(dto['current_fixture'], 0);
      expect(_error(() => m.apply('match/fixture_start', <String, Object?>{'index': 2})).status, 404);
      expect(_error(() => m.apply('match/fixture_start', <String, Object?>{'index': -1})).status, 400);
    });

    test('finalizar guarda el marcador en la jornada y para el reloj; reabrirlo lo trae', () {
      expect(_error(() => m.apply('match/finish', <String, Object?>{})).status, 409, reason: 'nada en juego');
      m.apply('match/fixture_start', <String, Object?>{'index': 1});
      m.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      final Map<String, Object?> dto = m.apply('match/finish', <String, Object?>{});
      expect(dto['current_fixture'], isNull);
      expect(m.clock.running, isFalse);
      final Map<String, Object?> fila = (dto['fixtures']! as List<Object?>)[1]! as Map<String, Object?>;
      expect((fila['home_goals'], fila['away_goals']), (0, 1));
      expect(GraphicsStore(dir).fixtures[1].played, isTrue, reason: 'se guarda');

      m.apply('match/fixture_start', <String, Object?>{'index': 0});
      m.apply('match/fixture_start', <String, Object?>{'index': 1});
      expect((m.homeGoals, m.awayGoals), (0, 1), reason: 'reabierto, con su marcador');
    });

    test('volver a guardar la jornada conserva los resultados y el que se juega', () {
      m.apply('match/fixture_start', <String, Object?>{'index': 0});
      m.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      m.apply('match/finish', <String, Object?>{});
      m.apply('match/fixture_start', <String, Object?>{'index': 1});
      m.apply('match/fixtures', jornada(<(String, String, String)>[
        ('Puerto Ayora', 'Galápagos', '11:00'),
        ('Bellavista', 'Progreso', '16:30'),
        ('SANTA  CRUZ', 'San Cristóbal', '14:00'),
      ]));
      expect(m.graphics.currentFixture, 1);
      expect(m.graphics.fixtures[2].homeGoals, 1, reason: 'los mismos equipos, por la clave de su nombre');
      expect(m.graphics.fixtures[0].played, isFalse);
      expect(GraphicsStore(dir).currentFixture, 1);
    });

    test('la tarjeta de resultados es otra de pantalla completa; sin jornada, 409', () {
      m.apply('graphics/results', <String, Object?>{'on_air': true});
      expect(m.toJson()['results_on_air'], isTrue);
      m.apply('graphics/fixtures', <String, Object?>{'on_air': true});
      expect(m.toJson()['results_on_air'], isFalse, reason: 'una tarjeta a la vez');
      final MatchEngine otro = abrir(nombre: 'otro.json');
      otro.graphics.setFixtures(const <Fixture>[]);
      expect(_error(() => otro.apply('graphics/results', <String, Object?>{'on_air': true})).status, 409);
    });

    test('las alineaciones van por equipo: la del que deja de jugar vuelve cuando juega', () {
      m.saveLineup(MatchTeam.home, 'Bellavista', '4-4-2', _milan);
      m.apply('match/fixture_start', <String, Object?>{'index': 0});
      expect(m.lineups.teams[MatchTeam.home], isNull, reason: 'Santa Cruz no tiene');
      expect((m.toJson()['home']! as Map<String, Object?>)['players'], 0);
      m.apply('match/fixture_start', <String, Object?>{'index': 1});
      expect(m.lineups.teams[MatchTeam.home]?.name, 'BELLAVISTA');
      expect(m.lineups.teams[MatchTeam.home]?.players, 11);
    });
  });
}

OrderError _error(void Function() f) {
  try {
    f();
  } on OrderError catch (e) {
    return e;
  }
  fail('se esperaba un OrderError');
}
