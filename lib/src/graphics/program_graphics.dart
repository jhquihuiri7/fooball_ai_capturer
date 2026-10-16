/// El gráfico del programa del maestro (IOS-47): del partido (MatchEngine) al marcador y
/// a la tarjeta de alineación, rasterizados en Dart y publicados a Metal.
///
/// Se llama con cada cambio del partido y una vez por segundo (el reloj). OverlayRaster
/// solo vuelve a pintar si cambió lo que se enseña, y el puente solo cruza Pigeon con
/// una generación nueva: con el reloj en marcha, un raster y una subida por segundo.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

  /// Los escudos de los equipos decodificados (ADR 0028), por lado, con la versión de la
  /// que salió cada uno.
  final Map<MatchTeam, (int, ui.Image)> _crests = <MatchTeam, (int, ui.Image)>{};

  /// Los escudos de los equipos que juegan ahora, por lado (`home`, `away`): se decodifica
  /// de nuevo solo el que cambió de versión (otro escudo, o el equipo cambió de nombre).
  Future<Map<String, ui.Image>> _teamCrests() async {
    final Map<String, ui.Image> escudos = <String, ui.Image>{};
    for (final MatchTeam lado in MatchTeam.values) {
      final TeamCrest? escudo = engine.graphics.crestFor(engine.teamName(lado));
      final (int, ui.Image)? previo = _crests[lado];
      if (previo != null && previo.$1 == escudo?.rev) {
        escudos[lado.name] = previo.$2;
        continue;
      }
      _crests.remove(lado)?.$2.dispose();
      if (escudo == null) {
        continue;
      }
      try {
        final ui.Codec codec = await ui.instantiateImageCodec(await escudo.file.readAsBytes());
        final ui.Image imagen = (await codec.getNextFrame()).image;
        codec.dispose();
        _crests[lado] = (escudo.rev, imagen);
        escudos[lado.name] = imagen;
      } on Exception {
        // un fichero que no se decodifica: el genérico, como sin escudo
      }
    }
    return escudos;
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

  ScoreboardState scoreboardState() => ScoreboardState(
    competition: competition,
    home: engine.home,
    away: engine.away,
    homeGoals: engine.homeGoals,
    awayGoals: engine.awayGoals,
    clockS: engine.clock.elapsedMs ~/ Duration.millisecondsPerSecond,
    live: engine.streaming,
    cameraMode: programCameraModeAuto,
    stripVisible: engine.stripVisible,
    stripClaim: engine.graphics.strip.claim,
    stripSlots: engine.graphics.strip.slots,
    iconRev: engine.graphics.hasIcon ? engine.graphics.iconRev : null,
    homeCrestRev: engine.graphics.crestFor(engine.home)?.rev,
    awayCrestRev: engine.graphics.crestFor(engine.away)?.rev,
  );

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
        final ui.Image? icono = await _championship();
        final Map<String, ui.Image> escudos = await _teamCrests();
        final ScoreboardState estado = scoreboardState();
        // La capa de tarjetas: el entretiempo o una alineación, nunca las dos (ADR 0027).
        final (MatchTeam, Team)? alAire = engine.lineups.onAir;
        if (engine.halftimeOnAir) {
          // El entretiempo tapa la pantalla entera con un velo translúcido sobre la cancha
          // desenfocada: el marcador se quitaría a través del velo, así que sale.
          await bridge.publish(OverlayLayerId.lineup, await _cards.halftime(estado, icon: icono, crests: escudos));
          await bridge.setBackdropBlur(true);
          await bridge.clear(OverlayLayerId.scoreboard);
          continue;
        }
        await bridge.setBackdropBlur(false);
        await bridge.publish(
          OverlayLayerId.scoreboard,
          await _scoreboard.render(estado, championship: icono, crests: escudos),
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

/// La alineación del partido, como la pinta la tarjeta; `name` sustituye al de la plantilla.
LineupCardTeam cardTeam(Team t, {String? name}) => LineupCardTeam(
  name: name ?? t.name,
  lines: t.lines,
  starters: <LineupEntry>[for (final RosterPlayer p in t.starters) LineupEntry(p.number, p.name)],
  substitutes: <LineupEntry>[for (final RosterPlayer p in t.substitutes) LineupEntry(p.number, p.name)],
  coach: t.coach,
);
