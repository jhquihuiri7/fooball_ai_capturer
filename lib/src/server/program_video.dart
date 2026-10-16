/// El vídeo del programa (IOS-103, ADR 0027 decisión 4): lo que el motor dice que suena,
/// llevado al nativo, que lo pasa a pantalla completa con su sonido.
///
/// El motor es la verdad: `video/play` y `video/stop` lo cambian, y el aviso del nativo
/// al acabar (`onVideoEnded`) vuelve a él por `MatchEngine.videoFinished`. Este conductor
/// solo compara lo que el motor quiere con lo último que mandó.
library;

import 'dart:async';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

/// El lado nativo del vídeo: pasar uno (devuelve "" o el error) y quitarlo.
abstract class VideoSink {
  Future<String> play(int id, String path, int leadMs);
  Future<void> stop();
}

/// RigHostApi como [VideoSink].
class RigVideoSink implements VideoSink {
  RigVideoSink([RigHostApi? api]) : _api = api ?? RigHostApi();

  final RigHostApi _api;

  @override
  Future<String> play(int id, String path, int leadMs) => _api.playVideo(id, path, leadMs);

  @override
  Future<void> stop() => _api.stopVideo();
}

class ProgramVideo {
  ProgramVideo({required this.engine, required this.sink});

  final MatchEngine engine;
  final VideoSink sink;

  /// La reproducción que se mandó al nativo, o null si no suena ninguna.
  int? _sent;
  Future<void> _turno = Future<void>.value();

  /// Lo último que dijo el nativo al pedirle un vídeo, si falló.
  String? lastError;

  /// Lleva al nativo lo que diga el motor; las llamadas se encadenan, nunca se cruzan.
  Future<void> refresh() => _turno = _turno.then((_) => _sync());

  Future<void> _sync() async {
    final VideoPlay? v = engine.video;
    if (v?.id == _sent) {
      return;
    }
    if (v == null) {
      _sent = null;
      await sink.stop();
      return;
    }
    _sent = v.id;
    final String error = await sink.play(v.id, engine.videos.file(v.name).path, videoStartLeadMs);
    lastError = error.isEmpty ? null : error;
    if (error.isNotEmpty) {
      // Lo que no se puede pasar no se queda «sonando» en el mando.
      engine.videoFinished(v.id);
    }
  }

  /// Al dejar de dirigir: que no siga sonando en el programa.
  Future<void> close() async {
    await _turno;
    if (_sent != null) {
      _sent = null;
      await sink.stop();
    }
  }
}
