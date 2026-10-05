/// El reloj del soporte en Dart (ADR 0023 §4): instantánea y Stopwatch, sin retroceder.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/server/rig_time.dart';

void main() {
  test('avanza desde la instantánea y no retrocede al rehacerla', () async {
    int rigNs = 5000 * 1000000;
    final RigTimeSource t = RigTimeSource(() async => '{"rig_ns":$rigNs,"domain":"rprueba12345"}');
    expect(t.ready, isFalse);
    await t.refresh();
    expect(t.domain, 'rprueba12345');
    expect(t.nowMs(), greaterThanOrEqualTo(5000));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final int antes = t.nowMs();
    expect(antes, greaterThanOrEqualTo(5025));
    rigNs = 5010 * 1000000;  // una lectura que llega «tarde»: por detrás de lo extrapolado
    await t.refresh();
    expect(t.nowMs(), greaterThanOrEqualTo(antes), reason: 'no retrocede');
    rigNs = 9000 * 1000000;
    await t.refresh();
    expect(t.nowMs(), greaterThanOrEqualTo(9000));
  });
}
