/// El gráfico del programa, de Dart a Metal (IOS-47).
///
/// Cada capa se rasteriza a tamaño de programa (OverlayRaster, CardRaster) pero casi
/// toda es transparente: el marcador ocupa una esquina. Antes de cruzar Pigeon se
/// recorta a la caja con contenido, así por el canal pasa un marcador de unos cientos de
/// KB y no 8 MB por segundo. La generación viaja con la capa: el nativo ignora una que
/// llegue tarde, y aquí no se manda dos veces la misma.
library;

import 'dart:typed_data';

import 'package:football_ai_capture/src/graphics/overlay_raster.dart';

/// Las capas, en el orden en que se apilan (el mismo número que `OverlayLayer` en
/// RigMedia).
enum OverlayLayerId { scoreboard, lineup, slate }

/// Una capa recortada: sus bytes y dónde va en el programa.
class CroppedOverlay {
  const CroppedOverlay({
    required this.rgba,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final Uint8List rgba;
  final int x;
  final int y;
  final int width;
  final int height;
}

/// La caja de los píxeles con alfa > 0, o null si la capa está vacía.
CroppedOverlay? cropToContent(OverlayFrame frame) {
  final Uint8List p = frame.rgba;
  final int w = frame.width;
  int x0 = w, y0 = frame.height, x1 = -1, y1 = -1;
  for (int y = 0; y < frame.height; y++) {
    final int fila = y * w * 4;
    for (int x = 0; x < w; x++) {
      if (p[fila + x * 4 + 3] != 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        y1 = y;
      }
    }
  }
  if (x1 < 0) {
    return null;
  }
  final int cw = x1 - x0 + 1;
  final int ch = y1 - y0 + 1;
  final Uint8List out = Uint8List(cw * ch * 4);
  for (int y = 0; y < ch; y++) {
    final int desde = ((y0 + y) * w + x0) * 4;
    out.setRange(y * cw * 4, (y + 1) * cw * 4, p, desde);
  }
  return CroppedOverlay(rgba: out, x: x0, y: y0, width: cw, height: ch);
}

/// Lo que el puente necesita del canal nativo (RigHostApi lo cumple).
abstract class OverlaySink {
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation);
  Future<void> clearOverlay(int layer);
}

class OverlayBridge {
  OverlayBridge(this.sink);

  final OverlaySink sink;
  final Map<OverlayLayerId, int> _sent = <OverlayLayerId, int>{};

  /// Capas mandadas de verdad, para el banco y los tests.
  int published = 0;

  /// Manda la capa si su generación es nueva. Una capa vacía es quitarla.
  Future<void> publish(OverlayLayerId layer, OverlayFrame frame) async {
    if (_sent[layer] == frame.generation) {
      return;
    }
    _sent[layer] = frame.generation;
    final CroppedOverlay? c = cropToContent(frame);
    if (c == null) {
      await sink.clearOverlay(layer.index);
      return;
    }
    published += 1;
    await sink.setOverlay(c.rgba, c.width, c.height, c.x, c.y, layer.index, frame.generation);
  }

  Future<void> clear(OverlayLayerId layer) async {
    if (_sent.remove(layer) != null) {
      await sink.clearOverlay(layer.index);
    }
  }
}
