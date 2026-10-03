import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/rig_clock.dart';

ClockSample _sample({required int atSeconds, required int offsetNs, int rttNs = 2000000}) {
  return ClockSample(
    roundTripNs: rttNs,
    offsetNs: offsetNs,
    localMonotonicNs: atSeconds * nsPerSecond,
  );
}

void main() {
  group('solveClockSample', () {
    test('despeja un desfase conocido con red simétrica', () {
      // El maestro va 1 s por delante; la red tarda 10 ms en cada sentido.
      const int offset = nsPerSecond;
      const int oneWay = 10 * nsPerMillisecond;
      final ClockSample sample = solveClockSample(
        t1: 0,
        t2: oneWay + offset,
        t3: oneWay + offset,
        t4: 2 * oneWay,
      );

      expect(sample.offsetNs, offset);
      expect(sample.roundTripNs, 2 * oneWay);
    });

    test('una red asimétrica sesga el desfase la mitad de lo que se desvía', () {
      // Ida de 30 ms, vuelta de 10: el error es (30-10)/2 = 10 ms.
      final ClockSample sample = solveClockSample(
        t1: 0,
        t2: 30 * nsPerMillisecond,
        t3: 30 * nsPerMillisecond,
        t4: 40 * nsPerMillisecond,
      );

      expect(sample.offsetNs, 10 * nsPerMillisecond);
    });

    test('el RTT nunca sale negativo', () {
      final ClockSample sample = solveClockSample(t1: 0, t2: 0, t3: 50, t4: 10);

      expect(sample.roundTripNs, 0);
    });
  });

  group('RigClock', () {
    test('sin muestras suficientes no hay estimación', () {
      final RigClock clock = RigClock()..add(_sample(atSeconds: 0, offsetNs: 100));

      expect(clock.estimate, isNull);
    });

    test('con relojes estables devuelve el desfase medio y deriva cero', () {
      final RigClock clock = RigClock();
      for (int i = 0; i < 5; i++) {
        clock.add(_sample(atSeconds: i * 10, offsetNs: 1000000));
      }

      final ClockSyncEstimate estimate = clock.estimate!;
      expect(estimate.offsetNs, 1000000);
      expect(estimate.driftPpm, 0.0);
      expect(estimate.samples, 5);
    });

    test('descarta las muestras con RTT muy por encima del mejor', () {
      final RigClock clock = RigClock()
        ..add(_sample(atSeconds: 0, offsetNs: 0, rttNs: 2 * nsPerMillisecond))
        ..add(_sample(atSeconds: 10, offsetNs: 0, rttNs: 2 * nsPerMillisecond))
        ..add(_sample(atSeconds: 20, offsetNs: 0, rttNs: 2 * nsPerMillisecond))
        // Esta se encoló en la WiFi: su desfase es basura y no debe promediar.
        ..add(_sample(atSeconds: 30, offsetNs: 90 * nsPerMillisecond, rttNs: 180 * nsPerMillisecond));

      final ClockSyncEstimate estimate = clock.estimate!;
      expect(estimate.samples, 3);
      expect(estimate.offsetNs, 0);
      expect(estimate.bestRoundTripNs, 2 * nsPerMillisecond);
    });

    test('estima la deriva cuando las muestras abarcan tiempo suficiente', () {
      // 20 ppm: 20 µs por segundo, o sea 20 000 ns de desfase por cada segundo que
      // pasa. En 90 min son 108 ms, más de tres frames.
      const double ppm = 20.0;
      final RigClock clock = RigClock();
      for (int i = 0; i <= 10; i++) {
        final int t = i * 30;
        clock.add(_sample(atSeconds: t, offsetNs: (t * ppm * 1000).round()));
      }

      final ClockSyncEstimate estimate = clock.estimate!;
      expect(estimate.driftPpm, closeTo(ppm, 0.01));
    });

    test('extrapola la deriva a un instante futuro', () {
      const double ppm = 20.0;
      final RigClock clock = RigClock();
      for (int i = 0; i <= 10; i++) {
        final int t = i * 30;
        clock.add(_sample(atSeconds: t, offsetNs: (t * ppm * 1000).round()));
      }

      // A los 90 minutos: 5400 s × 20 µs/s = 108 ms.
      final int offset = clock.offsetAtNs(5400 * nsPerSecond);
      expect(offset, closeTo(108 * nsPerMillisecond, nsPerMillisecond.toDouble()));
    });

    test('toRigTimeNs suma el desfase al instante local', () {
      final RigClock clock = RigClock();
      for (int i = 0; i < 4; i++) {
        clock.add(_sample(atSeconds: i * 10, offsetNs: 5 * nsPerMillisecond));
      }

      expect(clock.toRigTimeNs(nsPerSecond), nsPerSecond + 5 * nsPerMillisecond);
    });

    test('la incertidumbre es la mitad del mejor RTT', () {
      final RigClock clock = RigClock();
      for (int i = 0; i < 3; i++) {
        clock.add(_sample(atSeconds: i, offsetNs: 0, rttNs: 4 * nsPerMillisecond));
      }

      expect(clock.estimate!.uncertaintyNs, 2 * nsPerMillisecond);
    });

    test('no crece sin límite', () {
      final RigClock clock = RigClock(maxSamples: 10);
      for (int i = 0; i < 50; i++) {
        clock.add(_sample(atSeconds: i, offsetNs: i));
      }

      expect(clock.samples.length, 10);
      expect(clock.samples.first.offsetNs, 40);
    });

    test('sin ninguna muestra el desfase es cero', () {
      expect(RigClock().offsetAtNs(123456), 0);
    });
  });

  // Los casos compartidos con el puerto Swift (IOS-13). El fichero lo congela
  // tools/gen_rig_clock_cases.dart desde esta misma implementación: aquí es un candado
  // de regresión; la paridad del puerto la vigila RigClockTests.swift.
  group('casos compartidos Dart/Swift', () {
    final Map<String, Object?> doc = jsonDecode(
      File('ios/ZeroKit/Tests/RigCoreTests/Fixtures/rig_clock_cases.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;

    test('solveClockSample reproduce los casos congelados', () {
      final List<Object?> casos = doc['solve_cases']! as List<Object?>;
      expect(casos, isNotEmpty);
      for (final Object? raw in casos) {
        final Map<String, Object?> caso = raw! as Map<String, Object?>;
        final ClockSample sample = solveClockSample(
          t1: caso['t1']! as int,
          t2: caso['t2']! as int,
          t3: caso['t3']! as int,
          t4: caso['t4']! as int,
        );
        expect(sample.roundTripNs, caso['round_trip_ns'], reason: '${caso['name']}');
        expect(sample.offsetNs, caso['offset_ns'], reason: '${caso['name']}');
        expect(sample.localMonotonicNs, caso['local_monotonic_ns'],
            reason: '${caso['name']}');
      }
    });

    test('RigClock reproduce los casos congelados', () {
      final List<Object?> casos = doc['clock_cases']! as List<Object?>;
      expect(casos, isNotEmpty);
      for (final Object? raw in casos) {
        final Map<String, Object?> caso = raw! as Map<String, Object?>;
        final String nombre = caso['name']! as String;
        final RigClock clock = RigClock();
        for (final Object? m in caso['samples']! as List<Object?>) {
          final Map<String, Object?> muestra = m! as Map<String, Object?>;
          clock.add(ClockSample(
            roundTripNs: muestra['round_trip_ns']! as int,
            offsetNs: muestra['offset_ns']! as int,
            localMonotonicNs: muestra['local_monotonic_ns']! as int,
          ));
        }

        final Object? esperado = caso['estimate'];
        if (esperado == null) {
          expect(clock.estimate, isNull, reason: nombre);
        } else {
          final Map<String, Object?> e = esperado as Map<String, Object?>;
          final ClockSyncEstimate estimate = clock.estimate!;
          expect(estimate.offsetNs, e['offset_ns'], reason: nombre);
          expect(estimate.driftPpm, closeTo(e['drift_ppm']! as num, 1e-9),
              reason: nombre);
          expect(estimate.samples, e['samples'], reason: nombre);
          expect(estimate.bestRoundTripNs, e['best_round_trip_ns'], reason: nombre);
          expect(estimate.uncertaintyNs, e['uncertainty_ns'], reason: nombre);
        }

        for (final Object? q in caso['offset_at']! as List<Object?>) {
          final Map<String, Object?> consulta = q! as Map<String, Object?>;
          expect(
            clock.offsetAtNs(consulta['at_ns']! as int),
            consulta['offset_ns'],
            reason: '$nombre en ${consulta['at_ns']}',
          );
        }
      }
    });
  });
}
