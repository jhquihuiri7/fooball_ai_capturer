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
import 'lineup_card_painter.dart';
import 'scoreboard_painter.dart';
import 'slate_painter.dart';

/// Una capa rasterizada: RGBA de 8 bits por canal, fila a fila, alfa PREMULTIPLICADO
/// (`ui.ImageByteFormat.rawRgba`), que es lo que el blend de Metal espera.
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
  Future<OverlayFrame> render(ScoreboardState state, {bool sponsorSlots = true}) async {
    final OverlayFrame? previa = _last;
    if (previa != null && state == _lastState && sponsorSlots == _lastSlots) {
      return previa;
    }
    final Uint8List rgba =
        await _rgbaOf(await paintScoreboard(state, width, height, sponsorSlots: sponsorSlots));
    _generation += 1;
    _lastState = state;
    _lastSlots = sponsorSlots;
    return _last =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
  }
}

/// Los bytes RGBA premultiplicados de una imagen, que se libera al terminar.
Future<Uint8List> _rgbaOf(ui.Image imagen) async {
  try {
    final ByteData? bytes = await imagen.toByteData(format: ui.ImageByteFormat.rawRgba);
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

  final Map<bool, (LineupCardTeam, OverlayFrame)> _lineups = <bool, (LineupCardTeam, OverlayFrame)>{};
  OverlayFrame? _slate;
  int _generation = 0;

  int get rasterCount => _generation;

  /// La alineación del local (`home`) o del visitante, en el color de su barra.
  Future<OverlayFrame> lineup(LineupCardTeam team, {required bool home}) async {
    final (LineupCardTeam, OverlayFrame)? previa = _lineups[home];
    if (previa != null && previa.$1 == team) {
      return previa.$2;
    }
    final Uint8List rgba =
        await _rgbaOf(await paintLineupCard(team, lineupColour(home), width, height));
    _generation += 1;
    final OverlayFrame frame =
        OverlayFrame(rgba: rgba, width: width, height: height, generation: _generation);
    _lineups[home] = (team, frame);
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
