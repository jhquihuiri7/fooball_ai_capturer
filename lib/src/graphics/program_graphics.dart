/// El gráfico del programa del maestro (IOS-47): del partido (MatchEngine) al marcador y
/// a la tarjeta de alineación, rasterizados en Dart y publicados a Metal.
///
/// Se llama con cada cambio del partido y una vez por segundo (el reloj). OverlayRaster
/// solo vuelve a pintar si cambió lo que se enseña, y el puente solo cruza Pigeon con
/// una generación nueva: con el reloj en marcha, un raster y una subida por segundo. Mientras
/// el gol entra o sale ([ProgramGraphics.animating], ADR 0032), el maestro lo llama a
/// `anim_fps`.
///
/// Lo que se pinta depende del tipo de evento (ADR 0031): el fútbol con todo; el espectáculo
/// sin marcador ni tarjetas, con EN VIVO, el rótulo y la franja; el vóley, nada por ahora.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/fixtures_card_painter.dart';
import 'package:football_ai_capture/src/graphics/goal_banner_painter.dart';
import 'package:football_ai_capture/src/graphics/halftime_card_painter.dart';
import 'package:football_ai_capture/src/graphics/lineup_card_painter.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';
import 'package:football_ai_capture/src/graphics/scoreboard_painter.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/graphics_store.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

/// Lo que dice el marcador mientras la IA dirige (el operador aún no puede cambiarlo
/// desde el maestro: llega con la cámara del mando, IOS-73).
const String programCameraModeAuto = 'AUTO';

class ProgramGraphics {
  ProgramGraphics({
    required this.engine,
    required this.bridge,
    this.competition = '',
    OverlayRaster? scoreboard,
    CardRaster? cards,
  }) : _scoreboard = scoreboard ?? OverlayRaster(),
       _cards = cards ?? CardRaster();

  final MatchEngine engine;
  final OverlayBridge bridge;
  String competition;
  final OverlayRaster _scoreboard;
  final CardRaster _cards;
  bool _busy = false;
  bool _again = false;
  bool _slateSent = false;

  /// El icono del campeonato decodificado y la versión de la que salió (ADR 0027).
  ui.Image? _icon;
  int _iconRev = 0;

  /// Los escudos decodificados (ADR 0028), por su versión: cada versión es un fichero, así
  /// que no se decodifica dos veces. Lo que deja de usarse se suelta al acabar la pasada.
  final Map<int, ui.Image> _crests = <int, ui.Image>{};
  final Set<int> _crestsUsed = <int>{};

  /// El escudo del equipo `name` decodificado, o null si va el genérico (o no se lee).
  Future<ui.Image?> _crest(String? name) async {
    final TeamCrest? escudo = name == null ? null : engine.graphics.crestFor(name);
    if (escudo == null) {
      return null;
    }
    _crestsUsed.add(escudo.rev);
    final ui.Image? previo = _crests[escudo.rev];
    if (previo != null) {
      return previo;
    }
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(await escudo.file.readAsBytes());
      final ui.Image imagen = (await codec.getNextFrame()).image;
      codec.dispose();
      return _crests[escudo.rev] = imagen;
    } on Exception {
      return null; // un fichero que no se decodifica: el genérico, como sin escudo
    }
  }

  /// Los escudos de dos equipos por lado (`home`, `away`), los que los tienen.
  Future<Map<String, ui.Image>> _crestsOf(String? home, String? away) async => <String, ui.Image>{
    if (await _crest(home) case final ui.Image i) 'home': i,
    if (await _crest(away) case final ui.Image i) 'away': i,
  };

  /// Suelta los escudos que esta pasada no usó.
  void _dropUnusedCrests() {
    for (final int rev in _crests.keys.where((int r) => !_crestsUsed.contains(r)).toList()) {
      _crests.remove(rev)?.dispose();
    }
    _crestsUsed.clear();
  }

  /// La imagen de la franja puesta decodificada y su versión (enmienda del ADR 0027 del
  /// 2026-10-16).
  ui.Image? _stripImage;
  int? _stripImageRev;

  /// Decodifica la imagen de la franja puesta (la de la tanda, si hay una) si cambió; sin
  /// imagen, null.
  Future<ui.Image?> _stripImageNow() async {
    final StripImage? img = engine.stripImage;
    if (img?.rev == _stripImageRev) {
      return _stripImage;
    }
    _stripImageRev = img?.rev;
    _stripImage?.dispose();
    _stripImage = null;
    if (img == null) {
      return null;
    }
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(await img.file.readAsBytes());
      _stripImage = (await codec.getNextFrame()).image;
      codec.dispose();
    } on Exception {
      _stripImage = null; // una imagen que no se decodifica: la franja sale sin ella
    }
    return _stripImage;
  }

  /// Decodifica el icono si cambió desde el último; sin icono, null.
  Future<ui.Image?> _championship() async {
    final int rev = engine.graphics.iconRev;
    if (rev == _iconRev) {
      return _icon;
    }
    _iconRev = rev;
    _icon?.dispose();
    _icon = null;
    if (!engine.graphics.hasIcon) {
      return null;
    }
    try {
      final Uint8List bytes = await File(engine.graphics.iconFile.path).readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      _icon = (await codec.getNextFrame()).image;
      codec.dispose();
    } on Exception {
      _icon = null; // un fichero que no se decodifica: el marcador sigue, sin icono
    }
    return _icon;
  }

  ScoreboardState scoreboardState() {
    final bool futbol = engine.eventKind.isFootball;
    final CaptionPreset? rotulo = engine.captionOnAir;
    final StripTexts franja = engine.stripTexts;
    return ScoreboardState(
      competition: competition,
      home: engine.home,
      away: engine.away,
      homeGoals: engine.homeGoals,
      awayGoals: engine.awayGoals,
      clockS: engine.clock.elapsedMs ~/ Duration.millisecondsPerSecond,
      live: engine.streaming,
      cameraMode: programCameraModeAuto,
      stripVisible: engine.stripVisible,
      stripTitle: franja.title,
      stripSubtitle: franja.subtitle,
      stripImageRev: engine.stripImage?.rev,
      iconRev: engine.graphics.hasIcon ? engine.graphics.iconRev : null,
      homeCrestRev: engine.graphics.crestFor(engine.home)?.rev,
      awayCrestRev: engine.graphics.crestFor(engine.away)?.rev,
      // El marcador solo en el fútbol, y si el operador no lo quitó (ADR 0031 y 0032).
      scoreboard: futbol && engine.scoreboardOnAir,
      lowerThirdTitle: rotulo?.title,
      lowerThirdSubtitle: rotulo?.subtitle ?? '',
      goal: futbol ? _goalBanner() : null,
    );
  }

  /// El gol que se celebra en el punto de su animación, o null (ADR 0032).
  GoalBanner? _goalBanner() {
    final ({MatchTeam team, int elapsedMs})? g = engine.goal;
    final (double, double, double)? punto = g == null ? null : goalFrame(g.elapsedMs);
    if (g == null || punto == null) {
      return null;
    }
    final bool local = g.team == MatchTeam.home;
    final String nombre = local ? engine.home : engine.away;
    return GoalBanner(
      home: local,
      name: nombre,
      homeGoals: engine.homeGoals,
      awayGoals: engine.awayGoals,
      crestRev: engine.graphics.crestFor(nombre)?.rev,
      reveal: punto.$1,
      textScale: punto.$2,
      fade: punto.$3,
    );
  }

  /// Si el último raster llevaba el gol: al irse, hace falta uno más que lo quite.
  bool _goalShown = false;

  /// Si el gol está entrando o saliendo, o acaba de irse: entonces el maestro pinta a
  /// `OverlaySpec.goal['anim_fps']`; quieto, basta el segundo del reloj.
  bool get animating {
    final ({MatchTeam team, int elapsedMs})? g = engine.goal;
    return g == null ? _goalShown : goalMoving(g.elapsedMs);
  }

  /// Pone el gráfico al día. Si se llama mientras pinta, repite una vez al acabar: nunca
  /// hay dos rasters a la vez ni se pierde el último cambio.
  Future<void> refresh() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      if (!_slateSent) {
        // SIN SEÑAL se sube una vez y queda oculta en nativo: la enseña el programa
        // cuando no queda ninguna cámara (IOS-84), sin esperar a Dart.
        await bridge.publish(OverlayLayerId.slate, await _cards.slate());
        _slateSent = true;
      }
      do {
        _again = false;
        if (engine.eventKind == EventKind.volleyball) {
          // El vóley, por ahora, sin gráfico: sale la cámara tal cual (ADR 0031).
          _goalShown = false;
          await bridge.setBackdropBlur(false);
          await bridge.clear(OverlayLayerId.lineup);
          await bridge.clear(OverlayLayerId.scoreboard);
          continue;
        }
        final bool futbol = engine.eventKind.isFootball;
        final ui.Image? icono = await _championship();
        final Map<String, ui.Image> escudos = await _crestsOf(engine.home, engine.away);
        final ScoreboardState estado = scoreboardState();
        // La capa de tarjetas: una de pantalla completa o una alineación, nunca dos (ADR 0027
        // y 0029). Solo en el fútbol.
        final (MatchTeam, Team)? alAire = futbol ? engine.lineups.onAir : null;
        final OverlayFrame? pantalla = futbol ? await _fullScreenCard(estado, icono, escudos) : null;
        final GoalBanner? gol = pantalla == null ? estado.goal : null;
        final ui.Image? escudoGol = gol == null ? null : await _crest(gol.name);
        _dropUnusedCrests();
        if (pantalla != null) {
          // Tapa la pantalla entera con un velo translúcido sobre la cancha desenfocada: el
          // marcador se vería a través del velo, así que sale.
          _goalShown = false;
          await bridge.publish(OverlayLayerId.lineup, pantalla);
          await bridge.setBackdropBlur(true);
          await bridge.clear(OverlayLayerId.scoreboard);
          continue;
        }
        _goalShown = gol != null;
        await bridge.setBackdropBlur(false);
        await bridge.publish(
          OverlayLayerId.scoreboard,
          await _scoreboard.render(
            estado,
            championship: icono,
            crests: escudos,
            stripImage: await _stripImageNow(),
            goalCrest: escudoGol,
          ),
        );
        if (alAire == null) {
          await bridge.clear(OverlayLayerId.lineup);
        } else {
          // El nombre es el del marcador: si el operador lo cambió desde el mando, también aquí.
          final String nombre = alAire.$1 == MatchTeam.home ? engine.home : engine.away;
          final bool local = alAire.$1 == MatchTeam.home;
          final OverlayFrame tarjeta = await _cards.lineup(
            cardTeam(alAire.$2, name: nombre),
            home: local,
            crest: escudos[alAire.$1.name],
            crestRev: local ? estado.homeCrestRev : estado.awayCrestRev,
          );
          await bridge.publish(OverlayLayerId.lineup, tarjeta);
        }
      } while (_again);
    } finally {
      _busy = false;
    }
  }
}

extension on ProgramGraphics {
  /// La tarjeta de pantalla completa al aire (entretiempo, final o próximo partido), o null.
  Future<OverlayFrame?> _fullScreenCard(ScoreboardState estado, ui.Image? icono, Map<String, ui.Image> escudos) async {
    switch (engine.fullScreenCard) {
      case MatchEngine.cardHalftime:
        return _cards.halftime(estado, icon: icono, crests: escudos);
      case MatchEngine.cardFulltime:
        return _cards.halftime(estado, icon: icono, crests: escudos, title: OverlaySpec.fulltimeTitle);
      case MatchEngine.cardNextMatch:
        final NextMatch? n = engine.graphics.nextMatch;
        if (n == null) {
          return null;
        }
        final ScoreboardState conSusEscudos = ScoreboardState(
          competition: estado.competition,
          home: n.home,
          away: n.away,
          homeGoals: 0,
          awayGoals: 0,
          clockS: 0,
          live: false,
          cameraMode: '',
          iconRev: estado.iconRev,
          homeCrestRev: engine.graphics.crestFor(n.home)?.rev,
          awayCrestRev: engine.graphics.crestFor(n.away)?.rev,
        );
        return _cards.halftime(
          conSusEscudos,
          icon: icono,
          crests: await _crestsOf(n.home, n.away),
          next: NextMatchCard(home: n.home, away: n.away, when: n.when, venue: n.venue),
        );
      case MatchEngine.cardInterview:
        final Interview e = engine.graphics.interview;
        return _cards.halftime(estado, icon: icono, interview: InterviewCard(name: e.name, role: e.role));
      case MatchEngine.cardFixtures || MatchEngine.cardResults:
        final bool resultados = engine.fullScreenCard == MatchEngine.cardResults;
        final List<Fixture> jornada = engine.graphics.fixtures;
        final int? enJuego = engine.graphics.currentFixture;
        final Map<String, ui.Image> escudos = <String, ui.Image>{};
        final List<int?> versiones = <int?>[];
        for (final Fixture f in jornada) {
          for (final String equipo in <String>[f.home, f.away]) {
            versiones.add(engine.graphics.crestFor(equipo)?.rev);
            if (await _crest(equipo) case final ui.Image i) {
              escudos[fixtureCrestKey(equipo)] = i;
            }
          }
        }
        return _cards.fixtures(
          estado.competition,
          <FixtureCard>[
            for (int i = 0; i < jornada.length; i++)
              FixtureCard(
                home: jornada[i].home,
                away: jornada[i].away,
                time: jornada[i].time,
                subtitle: jornada[i].subtitle,
                // El que se juega lleva el marcador de ahora (ADR 0032).
                homeGoals: i == enJuego ? engine.homeGoals : jornada[i].homeGoals,
                awayGoals: i == enJuego ? engine.awayGoals : jornada[i].awayGoals,
              ),
          ],
          crests: escudos,
          crestRevs: versiones,
          results: resultados,
        );
      default:
        return null;
    }
  }
}

/// La alineación del partido, como la pinta la tarjeta; `name` sustituye al de la plantilla.
LineupCardTeam cardTeam(Team t, {String? name}) => LineupCardTeam(
  name: name ?? t.name,
  lines: t.lines,
  starters: <LineupEntry>[for (final RosterPlayer p in t.starters) LineupEntry(p.number, p.name)],
  substitutes: <LineupEntry>[for (final RosterPlayer p in t.substitutes) LineupEntry(p.number, p.name)],
  coach: t.coach,
);
