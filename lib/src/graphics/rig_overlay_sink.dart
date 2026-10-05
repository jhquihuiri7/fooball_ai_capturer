/// El canal nativo del gráfico (IOS-47): RigHostApi como OverlaySink.
library;

import 'dart:typed_data';

import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';

class RigOverlaySink implements OverlaySink {
  RigOverlaySink([RigHostApi? api]) : _api = api ?? RigHostApi();

  final RigHostApi _api;

  @override
  Future<void> setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation) =>
      _api.setOverlay(rgba, width, height, x, y, layer, generation);

  @override
  Future<void> clearOverlay(int layer) => _api.clearOverlay(layer);
}
