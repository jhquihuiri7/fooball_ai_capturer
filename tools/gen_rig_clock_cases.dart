// Genera los casos compartidos del reloj del soporte (IOS-13).
//
// La referencia es lib/src/rig_clock.dart, que es donde la cuenta está probada: este
// script define las entradas y deja que el Dart calcule las respuestas. El JSON queda
// congelado en ios/ZeroKit/Tests/RigCoreTests/Fixtures/rig_clock_cases.json (fuera de
// la carpeta Golden/, que la controla el manifiesto de los dorados) y lo leen
// test/rig_clock_test.dart (regresión del Dart) y RigClockTests.swift (paridad del
// puerto: ±1 ns de offset, ±1e-6 ppm de deriva).
//
// Va envuelto en un test porque el pigeon arrastra dart:ui y `dart run` pelado no lo
// tiene; `flutter test` sí. Se lanza a mano, no corre con la suite:
//   flutter test tools/gen_rig_clock_cases.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/rig_clock.dart';

const String destino = 'ios/ZeroKit/Tests/RigCoreTests/Fixtures/rig_clock_cases.json';

void main() {
  test('genera rig_clock_cases.json desde la referencia Dart', () {
    final Map<String, Object?> doc = <String, Object?>{
      'schema': 1,
      'solve_cases': _solveCases(),
      'clock_cases': _clockCases(),
    };
    File(destino)
      ..createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
    stdout.writeln('escrito $destino');
  });
}

List<Map<String, Object?>> _solveCases() {
  final List<(String, int, int, int, int)> entradas = <(String, int, int, int, int)>[
    ('ida y vuelta simetrica', 1000000, 6000000, 6500000, 11500000),
    ('desfase negativo impar trunca hacia cero', 1000, 0, 100, 2101),
    ('desfase positivo impar trunca hacia cero', 0, 8, 9, 3),
    ('ida y vuelta negativa se recorta a cero', 0, 100000, 105000, 4000),
  ];
  return entradas.map(((String, int, int, int, int) e) {
    final ClockSample s = solveClockSample(t1: e.$2, t2: e.$3, t3: e.$4, t4: e.$5);
    return <String, Object?>{
      'name': e.$1,
      't1': e.$2,
      't2': e.$3,
      't3': e.$4,
      't4': e.$5,
      'round_trip_ns': s.roundTripNs,
      'offset_ns': s.offsetNs,
      'local_monotonic_ns': s.localMonotonicNs,
    };
  }).toList();
}

List<Map<String, Object?>> _clockCases() {
  const int segundo = 1000000000;
  final List<Map<String, Object?>> casos = <Map<String, Object?>>[];

  void caso(String name, List<ClockSample> samples, List<int> consultas) {
    final RigClock clock = RigClock();
    samples.forEach(clock.add);
    final ClockSyncEstimate? estimate = clock.estimate;
    casos.add(<String, Object?>{
      'name': name,
      'samples': samples
          .map((ClockSample s) => <String, Object?>{
                'round_trip_ns': s.roundTripNs,
                'offset_ns': s.offsetNs,
                'local_monotonic_ns': s.localMonotonicNs,
              })
          .toList(),
      'estimate': estimate == null
          ? null
          : <String, Object?>{
              'offset_ns': estimate.offsetNs,
              'drift_ppm': estimate.driftPpm,
              'samples': estimate.samples,
              'best_round_trip_ns': estimate.bestRoundTripNs,
              'uncertainty_ns': estimate.uncertaintyNs,
            },
      'offset_at': consultas
          .map((int at) =>
              <String, Object?>{'at_ns': at, 'offset_ns': clock.offsetAtNs(at)})
          .toList(),
    });
  }

  ClockSample m(int rtt, int offset, int at) =>
      ClockSample(roundTripNs: rtt, offsetNs: offset, localMonotonicNs: at);

  caso('sin muestras no se afirma nada', <ClockSample>[], <int>[123 * segundo]);

  caso(
    'dos muestras no bastan y se responde la ultima',
    <ClockSample>[m(2000000, 5000000, 10 * segundo), m(2200000, 5100000, 15 * segundo)],
    <int>[20 * segundo],
  );

  caso(
    'ventana corta hace media sin deriva',
    <ClockSample>[
      m(2000000, 1000000, 10 * segundo),
      m(2500000, 1100000, 15 * segundo),
      m(2200000, 900000, 20 * segundo),
      m(2400000, 1050001, 25 * segundo),
      m(2100000, 950000, 30 * segundo),
    ],
    <int>[30 * segundo, 60 * segundo],
  );

  caso(
    'el filtro tira las muestras lentas',
    <ClockSample>[
      m(1000000, 1000000, 10 * segundo),
      m(5000000, 9999999, 12 * segundo),
      m(1200000, 1010000, 14 * segundo),
      m(6000000, -777777, 16 * segundo),
      m(1100000, 990000, 18 * segundo),
      m(1300000, 1005000, 20 * segundo),
    ],
    <int>[20 * segundo],
  );

  caso(
    'deriva limpia de 20 ppm',
    List<ClockSample>.generate(
      25,
      (int i) => m(2000000, 5000000 + 20000 * 5 * i, (100 + 5 * i) * segundo),
    ),
    <int>[220 * segundo, 280 * segundo],
  );

  final List<int> ruido = <int>[500, -300, 250, -450, 120, -80, 333];
  caso(
    'deriva de 20 ppm con ruido determinista',
    List<ClockSample>.generate(
      25,
      (int i) => m(
        2000000 + 100000 * (i % 3),
        5000000 + 20000 * 5 * i + ruido[i % ruido.length],
        (100 + 5 * i) * segundo,
      ),
    ),
    <int>[220 * segundo, 280 * segundo],
  );

  caso(
    'a tope de muestras las viejas se van',
    List<ClockSample>.generate(
      250,
      (int i) => m(2000000, 1000000 + 10000 * i, (50 + i) * segundo),
    ),
    <int>[300 * segundo, 350 * segundo],
  );

  return casos;
}
