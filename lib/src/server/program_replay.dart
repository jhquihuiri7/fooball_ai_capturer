/// La repetición del programa (IOS-119, ADR 0034), del maestro al nativo: prepararla, cortarla
/// y preguntar hasta dónde llega el anillo del programa.
///
/// El motor es la verdad de lo que está al aire (`MatchEngine.replay`); el nativo tiene el
/// programa y decide qué instantes son de la repetición. `replay/play` y `replay/stop` los lleva
/// `MasterApi`, que espera al nativo; esto solo pregunta por el anillo cada segundo.
library;

import 'dart:async';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/replay.dart';

/// El lado nativo de la repetición: lo que devuelve `prepare` lo lee [parseReplayArmed] y lo
/// de `buffer`, [parseReplayBuffer].
abstract class ReplaySink {
  Future<String> prepare(int id, int fromRigMs, int toRigMs, int leadMs);
  Future<void> stop(int id, int cutRigMs);
  Future<String> buffer();
}

/// RigHostApi como [ReplaySink].
class RigReplaySink implements ReplaySink {
  RigReplaySink([RigHostApi? api]) : _api = api ?? RigHostApi();

  final RigHostApi _api;

  @override
  Future<String> prepare(int id, int fromRigMs, int toRigMs, int leadMs) =>
      _api.prepareReplay(id, fromRigMs, toRigMs, leadMs);

  @override
  Future<void> stop(int id, int cutRigMs) => _api.stopReplay(id, cutRigMs);

  @override
  Future<String> buffer() => _api.replayBuffer();
}

/// Pregunta al nativo por el anillo cada [replayBufferInterval], una pregunta a la vez, y se lo
/// dice al motor.
class ReplayBufferWatch {
  ReplayBufferWatch({required this.engine, required this.sink});

  final MatchEngine engine;
  final ReplaySink sink;
  Timer? _timer;
  bool _asking = false;

  void start() {
    _timer ??= Timer.periodic(replayBufferInterval, (_) => unawaited(poll()));
    unawaited(poll());
  }

  /// Una pregunta. Si el canal no contesta, el motor se queda con lo que sabía.
  Future<void> poll() async {
    if (_asking) {
      return;
    }
    _asking = true;
    try {
      engine.setReplayBuffer(parseReplayBuffer(await sink.buffer()));
    } on Exception {
      // Sin canal o con una respuesta que no se lee: se pregunta en el siguiente tic.
    } finally {
      _asking = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
