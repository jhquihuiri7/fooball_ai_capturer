/// El puente del gráfico a Metal (IOS-47): el recorte a la caja con contenido y que
/// solo cruce Pigeon lo que cambió.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/overlay_raster.dart';

class _Sink implements OverlaySink {
  final List<String> calls = <String>[];
  Uint8List? last;

  @override
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation) async {
    last = rgba;
    calls.add('set $layer $x,$y ${width}x$height g$generation');
  }

  @override
  Future<void> clearOverlay(int layer) async => calls.add('clear $layer');
}

OverlayFrame _frame(int w, int h, int generation, List<(int, int)> opacos) {
  final Uint8List p = Uint8List(w * h * 4);
  for (final (int x, int y) in opacos) {
    final int i = (y * w + x) * 4;
    p.setRange(i, i + 4, <int>[x, y, 7, 255]);
  }
  return OverlayFrame(rgba: p, width: w, height: h, generation: generation);
}

void main() {
  test('recorta a la caja con contenido y copia las filas', () {
    final CroppedOverlay c = cropToContent(_frame(20, 10, 1, <(int, int)>[(3, 2), (6, 4)]))!;
    expect((c.x, c.y, c.width, c.height), (3, 2, 4, 3));
    expect(c.rgba.sublist(0, 4), <int>[3, 2, 7, 255]);
    expect(c.rgba.sublist((2 * 4 + 3) * 4, (2 * 4 + 3) * 4 + 4), <int>[6, 4, 7, 255]);
    expect(cropToContent(_frame(20, 10, 1, <(int, int)>[])), isNull);
  });

  test('una generación ya mandada no vuelve a cruzar; vacía es quitar', () async {
    final _Sink sink = _Sink();
    final OverlayBridge b = OverlayBridge(sink);
    await b.publish(OverlayLayerId.scoreboard, _frame(20, 10, 1, <(int, int)>[(1, 1)]));
    await b.publish(OverlayLayerId.scoreboard, _frame(20, 10, 1, <(int, int)>[(1, 1)]));
    await b.publish(OverlayLayerId.scoreboard, _frame(20, 10, 2, <(int, int)>[(2, 1)]));
    await b.publish(OverlayLayerId.lineup, _frame(20, 10, 1, <(int, int)>[]));
    await b.clear(OverlayLayerId.scoreboard);
    await b.clear(OverlayLayerId.scoreboard);
    expect(sink.calls, <String>['set 0 1,1 1x1 g1', 'set 0 2,1 1x1 g2', 'clear 1', 'clear 0']);
    expect(b.published, 2);
  });
}
