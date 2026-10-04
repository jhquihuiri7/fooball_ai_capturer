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
import 'scoreboard_painter.dart';

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
    final ui.Image imagen = await paintScoreboard(state, width, height, sponsorSlots: sponsorSlots);
    try {
      final ByteData? bytes = await imagen.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) {
        throw StateError('el motor no devolvió los bytes del gráfico');
      }
      _generation += 1;
      _lastState = state;
      _lastSlots = sponsorSlots;
      return _last = OverlayFrame(
        rgba: bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        width: width,
        height: height,
        generation: _generation,
      );
    } finally {
      imagen.dispose();
    }
  }
}
