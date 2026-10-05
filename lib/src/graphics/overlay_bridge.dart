/// El gráfico del programa, de Dart a Metal (IOS-47).
///
/// Cada capa se rasteriza a tamaño de programa (OverlayRaster, CardRaster), pero entre
/// dos rasters cambia muy poco: con el reloj en marcha, sus cifras. Por Pigeon cruza
/// solo el rectángulo que cambió respecto a lo último que se mandó de esa capa (un
/// parche, transparentes incluidos: así también se borra). El nativo lo pega en su copia
/// de la capa. La generación viaja con el parche: el nativo ignora uno que llegue tarde,
/// y aquí no se manda dos veces la misma.
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

/// La caja de los píxeles que difieren entre `previous` y `frame` (del mismo tamaño),
/// con los de `frame` dentro; null si no cambió nada. Sin `previous`, la del contenido.
CroppedOverlay? changedRegion(Uint8List? previous, OverlayFrame frame) {
  if (previous == null) {
    return cropToContent(frame);
  }
  final Uint8List p = frame.rgba;
  final int w = frame.width;
  int x0 = w, y0 = frame.height, x1 = -1, y1 = -1;
  for (int y = 0; y < frame.height; y++) {
    final int fila = y * w * 4;
    for (int x = 0; x < w; x++) {
      final int i = fila + x * 4;
      if (p[i] != previous[i] || p[i + 1] != previous[i + 1] || p[i + 2] != previous[i + 2] || p[i + 3] != previous[i + 3]) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        y1 = y;
      }
    }
  }
  return x1 < 0 ? null : _crop(frame, x0, y0, x1, y1);
}

CroppedOverlay _crop(OverlayFrame frame, int x0, int y0, int x1, int y1) {
  final int w = frame.width;
  final int cw = x1 - x0 + 1;
  final int ch = y1 - y0 + 1;
  final Uint8List out = Uint8List(cw * ch * 4);
  for (int y = 0; y < ch; y++) {
    final int desde = ((y0 + y) * w + x0) * 4;
    out.setRange(y * cw * 4, (y + 1) * cw * 4, frame.rgba, desde);
  }
  return CroppedOverlay(rgba: out, x: x0, y: y0, width: cw, height: ch);
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
  return x1 < 0 ? null : _crop(frame, x0, y0, x1, y1);
}

/// Lo que el puente necesita del canal nativo (RigHostApi lo cumple).
abstract class OverlaySink {
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation);
  Future<void> clearOverlay(int layer);
}

class OverlayBridge {
  OverlayBridge(this.sink);

  final OverlaySink sink;
  final Map<OverlayLayerId, OverlayFrame> _sent = <OverlayLayerId, OverlayFrame>{};

  /// Parches mandados de verdad, y sus bytes, para el banco y los tests.
  int published = 0;
  int publishedBytes = 0;

  /// Manda lo que cambió de la capa si su generación es nueva. Una capa vacía es quitarla.
  Future<void> publish(OverlayLayerId layer, OverlayFrame frame) async {
    final OverlayFrame? previa = _sent[layer];
    if (previa?.generation == frame.generation) {
      return;
    }
    if (cropToContent(frame) == null) {
      if (_sent.remove(layer) != null) {
        await sink.clearOverlay(layer.index);
      }
      return;
    }
    final bool mismoTamano = previa != null && previa.width == frame.width && previa.height == frame.height;
    _sent[layer] = frame;
    final CroppedOverlay? c = changedRegion(mismoTamano ? previa.rgba : null, frame);
    if (c == null) {
      return;
    }
    published += 1;
    publishedBytes += c.rgba.length;
    await sink.setOverlay(c.rgba, c.width, c.height, c.x, c.y, layer.index, frame.generation);
  }

  Future<void> clear(OverlayLayerId layer) async {
    if (_sent.remove(layer) != null) {
      await sink.clearOverlay(layer.index);
    }
  }
}
