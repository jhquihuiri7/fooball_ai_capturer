/// El gráfico del programa del maestro (IOS-47): del partido (MatchEngine) al marcador y
/// a la tarjeta de alineación, rasterizados en Dart y publicados a Metal.
///
/// Se llama con cada cambio del partido y una vez por segundo (el reloj). OverlayRaster
/// solo vuelve a pintar si cambió lo que se enseña, y el puente solo cruza Pigeon con
/// una generación nueva: con el reloj en marcha, un raster y una subida por segundo.
library;

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

  ScoreboardState scoreboardState() => ScoreboardState(
    competition: competition,
    home: engine.home,
    away: engine.away,
    homeGoals: engine.homeGoals,
    awayGoals: engine.awayGoals,
    clockS: engine.clock.elapsedMs ~/ Duration.millisecondsPerSecond,
    live: engine.streaming,
    cameraMode: programCameraModeAuto,
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
        await bridge.publish(OverlayLayerId.scoreboard, await _scoreboard.render(scoreboardState()));
        final (MatchTeam, Team)? alAire = engine.lineups.onAir;
        if (alAire == null) {
          await bridge.clear(OverlayLayerId.lineup);
        } else {
          final OverlayFrame tarjeta =
              await _cards.lineup(cardTeam(alAire.$2), home: alAire.$1 == MatchTeam.home);
          await bridge.publish(OverlayLayerId.lineup, tarjeta);
        }
      } while (_again);
    } finally {
      _busy = false;
    }
  }
}

/// La alineación del partido, como la pinta la tarjeta.
LineupCardTeam cardTeam(Team t) => LineupCardTeam(
  name: t.name,
  lines: t.lines,
  starters: <LineupEntry>[for (final RosterPlayer p in t.starters) LineupEntry(p.number, p.name)],
  substitutes: <LineupEntry>[for (final RosterPlayer p in t.substitutes) LineupEntry(p.number, p.name)],
  coach: t.coach,
);
