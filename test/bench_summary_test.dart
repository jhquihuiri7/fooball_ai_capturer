/// El resumen de los informes de banco (IOS-08).
library;

import 'package:flutter_test/flutter_test.dart';

import '../tools/bench_summary.dart';

void main() {
  test('resume el informe de noop con dispositivo, térmica y contadores', () {
    final Map<String, Object?> report = <String, Object?>{
      'name': 'noop',
      'device': 'iPhone18,1',
      'system_version': 'Version 26.1 (Build 23B74)',
      'started_epoch_s': 1791039000,
      'duration_s': 0.012,
      'params': <String, Object?>{'hz': '7.5'},
      'thermal': <Object?>['nominal', 'fair'],
      'stages_ms': <String, Object?>{
        'infer': <String, Object?>{'p50_ms': 11.5, 'p90_ms': 14.0, 'p99_ms': 21.0},
      },
      'counters': <String, Object?>{'noop': 1},
    };

    final String resumen = summarize(report);

    expect(resumen, contains('noop · iPhone18,1'));
    expect(resumen, contains('térmica nominal → fair'));
    expect(resumen, contains('infer'));
    expect(resumen, contains('11.5'));
    expect(resumen, contains('noop = 1'));
    expect(resumen, contains('hz=7.5'));
  });
}
