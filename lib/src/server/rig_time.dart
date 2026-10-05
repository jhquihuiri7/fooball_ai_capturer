/// El reloj del soporte en Dart (ADR 0023 §4): lo que lee el cronómetro del partido.
///
/// El cronómetro necesita una lectura síncrona y Pigeon solo da asíncronas. Así que se
/// toma una instantánea del nativo (`rig_ns` y el `clock_domain`) y desde ahí se avanza
/// con un Stopwatch, que es monótono; cada [rigTimeRefresh] se vuelve a tomar para no
/// acumular la deriva del Stopwatch frente al reloj de host. El error es la latencia de
/// una llamada Pigeon (~1 ms), muy por debajo del segundo del cronómetro.
library;

import 'dart:convert';

import 'package:football_ai_capture/src/server/match_engine.dart';

/// Cada cuánto se rehace la instantánea del reloj del soporte.
const Duration rigTimeRefresh = Duration(seconds: 30);

class RigTimeSource implements MatchTimeSource {
  RigTimeSource(this._snapshot);

  /// El JSON `{"rig_ns", "domain"}` del nativo (CaptureHostApi.rigClockSnapshot).
  final Future<String> Function() _snapshot;
  final Stopwatch _watch = Stopwatch();
  int _baseMs = 0;
  String _domain = '';

  bool get ready => _domain.isNotEmpty;

  @override
  String get domain => _domain;

  @override
  int nowMs() => _baseMs + _watch.elapsedMilliseconds;

  /// Toma la instantánea. Nunca deja que el reloj retroceda: si la nueva lectura cae por
  /// detrás de lo extrapolado (latencia), se queda lo extrapolado.
  Future<void> refresh() async {
    final Map<String, Object?> j = jsonDecode(await _snapshot()) as Map<String, Object?>;
    final int rigMs = (j['rig_ns']! as int) ~/ 1000000;
    final String dominio = j['domain']! as String;
    final bool mismo = dominio == _domain;
    final int ahora = nowMs();
    _baseMs = mismo && rigMs < ahora ? ahora : rigMs;
    _domain = dominio;
    _watch
      ..reset()
      ..start();
  }
}
