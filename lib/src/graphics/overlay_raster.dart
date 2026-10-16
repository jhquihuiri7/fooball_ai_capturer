/// El gráfico del programa rasterizado a RGBA (IOS-45): PictureRecorder → ui.Image →
/// toByteData, y SOLO cuando cambia el contenido.
///
/// El compositor de Metal compone esta capa en cada fotograma, pero la capa solo
/// cambia cuando cambia lo que enseña: con el reloj en marcha, una vez por segundo.
/// Rasterizar a 30 Hz quemaría batería del maestro para pintar 29 veces lo mismo.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../generated/overlay_spec.g.dart';
import 'fixtures_card_painter.dart';
import 'halftime_card_painter.dart';
import 'lineup_card_painter.dart';
import 'scoreboard_painter.dart';
import 'slate_painter.dart';

/// Una capa rasterizada: RGBA de 8 bits por canal, fila a fila, alfa SIN
/// premultiplicar (`ui.ImageByteFormat.rawStraightRgba`): es el contrato de la
/// composición (compose_reference de REF-18, como `Image.alpha_composite`), y lo que
/// el kernel ComposeProgram de IOS-41 espera.
class OverlayFrame {
  const OverlayFrame({
    required this.rgba,
    required this.width,
    required this.height,
    required this.generation,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// Sube con cada raster nuevo: el lado nativo solo sube la textura si cambió.
  final int generation;
}

class OverlayRaster {
  OverlayRaster({
    this.width = OverlaySpec.programWidth,
    this.height = OverlaySpec.programHeight,
  });

  final int width;
  final int height;

  ScoreboardState? _lastState;
  bool? _lastSlots;
  OverlayFrame? _last;
  int _generation = 0;

  /// Cuántas veces se ha rasterizado de verdad. Para el banco y los tests.
  int get rasterCount => _generation;

  /// La capa para `state`. Si nada cambió desde la última, devuelve la misma sin
  /// volver a pintar.
  /// `championship` es el icono del campeonato ya decodificado; el estado lleva su
  /// versión (`iconRev`), que es lo que decide si hay que volver a pintar.
  /// `crests`, igual, los escudos de los equipos (ADR 0028), con su versión en el estado.
  Future<OverlayFrame> render(
    ScoreboardState state, {
    bool sponsorSlots = true,
    ui.Image? championship,
    Map<String, ui.Image> crests = const <String, ui.Image>{},
  }) async {
    final OverlayFrame? previa = _last;
    if (previa != null && state == _lastState && sponsorSlots == _lastSlots) {
      return previa;
    }
    final Uint8List rgba = await _rgbaOf(
      await paintScoreboard(
        state,
        width,
        height,
        sponsorSlots: sponsorSlots,
        championship: championship,
        crests: crests,
      ),
    );
    _generation += 1;
    _lastState = state;
    _lastSlots = sponsorSlots;
    return _last =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
  }
}

/// Los bytes RGBA sin premultiplicar de una imagen, que se libera al terminar.
Future<Uint8List> _rgbaOf(ui.Image imagen) async {
  try {
    final ByteData? bytes = await imagen.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (bytes == null) {
      throw StateError('el motor no devolvió los bytes del gráfico');
    }
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    imagen.dispose();
  }
}

/// Las tarjetas que tapan el programa: la alineación y SIN SEÑAL. Se rasterizan bajo
/// demanda, cuando cambia lo que está al aire, y se guarda la última de cada una:
/// volver a sacar la misma alineación es instantáneo.
class CardRaster {
  CardRaster({
    this.width = OverlaySpec.programWidth,
    this.height = OverlaySpec.programHeight,
  });

  final int width;
  final int height;

  final Map<bool, (LineupCardTeam, int?, OverlayFrame)> _lineups = <bool, (LineupCardTeam, int?, OverlayFrame)>{};
  /// La última tarjeta de pantalla completa pintada y lo que la decide: solo hay una al aire.
  (Object, OverlayFrame)? _fullScreen;
  OverlayFrame? _slate;
  int _generation = 0;

  int get rasterCount => _generation;

  /// La alineación del local (`home`) o del visitante, en el color de su barra. `crest` es
  /// el escudo del equipo y `crestRev` su versión, que decide si hay que volver a pintar
  /// (ADR 0028).
  Future<OverlayFrame> lineup(LineupCardTeam team, {required bool home, ui.Image? crest, int? crestRev}) async {
    final (LineupCardTeam, int?, OverlayFrame)? previa = _lineups[home];
    if (previa != null && previa.$1 == team && previa.$2 == crestRev) {
      return previa.$3;
    }
    final Uint8List rgba =
        await _rgbaOf(await paintLineupCard(team, lineupColour(home), width, height, crest: crest));
    _generation += 1;
    final OverlayFrame frame =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
    _lineups[home] = (team, crestRev, frame);
    return frame;
  }

  /// La tarjeta de entretiempo (ADR 0027): solo se pinta de nuevo si cambia lo que enseña
  /// (los nombres, los goles, la competición o el icono). El reloj no sale en ella.
  ///
  /// Con `title`, la de final del partido; con `next`, la de próximo partido (ADR 0029):
  /// las tres comparten la última pintada, porque solo hay una al aire.
  Future<OverlayFrame> halftime(
    ScoreboardState state, {
    ui.Image? icon,
    Map<String, ui.Image> crests = const <String, ui.Image>{},
    String? title,
    NextMatchCard? next,
    InterviewCard? interview,
  }) async {
    final ScoreboardState clave = ScoreboardState(
      competition: state.competition,
      home: state.home,
      away: state.away,
      homeGoals: state.homeGoals,
      awayGoals: state.awayGoals,
      clockS: 0,
      live: false,
      cameraMode: '',
      iconRev: state.iconRev,
      homeCrestRev: state.homeCrestRev,
      awayCrestRev: state.awayCrestRev,
    );
    final Object llave = (title, next, interview, clave);
    final (Object, OverlayFrame)? previa = _fullScreen;
    if (previa != null && previa.$1 == llave) {
      return previa.$2;
    }
    final Uint8List rgba = await _rgbaOf(
      await paintHalftimeCard(
        clave,
        width,
        height,
        icon: icon,
        crests: crests,
        title: title,
        next: next,
        interview: interview,
      ),
    );
    _generation += 1;
    final OverlayFrame frame =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
    _fullScreen = (llave, frame);
    return frame;
  }

  /// La jornada (ADR 0030): se pinta de nuevo si cambian los partidos, la competición o la
  /// versión de algún escudo (`crestRevs`, en el orden de los equipos).
  Future<OverlayFrame> fixtures(
    String competition,
    List<FixtureCard> partidos, {
    Map<String, ui.Image> crests = const <String, ui.Image>{},
    List<int?> crestRevs = const <int?>[],
  }) async {
    final Object llave = (competition, Object.hashAll(partidos), partidos.length, Object.hashAll(crestRevs));
    final (Object, OverlayFrame)? previa = _fullScreen;
    if (previa != null && previa.$1 == llave) {
      return previa.$2;
    }
    final Uint8List rgba = await _rgbaOf(await paintFixturesCard(competition, partidos, width, height, crests: crests));
    _generation += 1;
    final OverlayFrame frame =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
    _fullScreen = (llave, frame);
    return frame;
  }

  /// SIN SEÑAL: no depende de nada más que del tamaño, se pinta una vez.
  Future<OverlayFrame> slate() async {
    final OverlayFrame? previa = _slate;
    if (previa != null) return previa;
    final Uint8List rgba = await _rgbaOf(await paintSlate(width, height));
    _generation += 1;
    return _slate =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
  }
}
