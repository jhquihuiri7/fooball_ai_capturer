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
        final ScoreboardState estado = scoreboardState();
        // La capa de tarjetas: el entretiempo o una alineación, nunca las dos (ADR 0027).
        final (MatchTeam, Team)? alAire = engine.lineups.onAir;
        if (engine.halftimeOnAir) {
          // El entretiempo tapa la pantalla entera con un velo translúcido sobre la cancha
          // desenfocada: el marcador se quitaría a través del velo, así que sale.
          await bridge.publish(OverlayLayerId.lineup, await _cards.halftime(estado, icon: icono));
          await bridge.setBackdropBlur(true);
          await bridge.clear(OverlayLayerId.scoreboard);
          continue;
        }
        await bridge.setBackdropBlur(false);
        await bridge.publish(OverlayLayerId.scoreboard, await _scoreboard.render(estado, championship: icono));
        if (alAire == null) {
          await bridge.clear(OverlayLayerId.lineup);
        } else {
          // El nombre es el del marcador: si el operador lo cambió desde el mando, también aquí.
          final String nombre = alAire.$1 == MatchTeam.home ? engine.home : engine.away;
          final OverlayFrame tarjeta =
              await _cards.lineup(cardTeam(alAire.$2, name: nombre), home: alAire.$1 == MatchTeam.home);
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
