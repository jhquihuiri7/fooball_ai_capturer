import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/exposure_phase.dart';

const int frame30 = 33333333; // ns, un frame a 30 fps

void main() {
  group('signedPhaseNs', () {
    test('un desfase de frames enteros es fase cero', () {
      // Un móvil empezó tres frames antes: 100 ms de diferencia, fase 0.
      expect(signedPhaseNs(3 * frame30, frame30), 0);
    });

    test('devuelve el resto con signo, no la diferencia bruta', () {
      expect(signedPhaseNs(3 * frame30 + 5 * nsPerMillisecond, frame30), 5 * nsPerMillisecond);
    });

    test('media vuelta se expresa como el desfase corto negativo', () {
      // 25 ms adelantado es lo mismo que 8,3 ms atrasado, y esto último es la verdad
      // física: lo que importa es el instante más cercano, no el número más grande.
      final int phase = signedPhaseNs(25 * nsPerMillisecond, frame30);

      expect(phase, lessThan(0));
      expect(phase.abs(), lessThan(frame30 ~/ 2 + 1));
    });

    test('es simétrico para desfases negativos', () {
      expect(signedPhaseNs(-5 * nsPerMillisecond, frame30), -5 * nsPerMillisecond);
    });

    test('el peor caso es medio frame', () {
      for (int delta = -100000000; delta < 100000000; delta += 997) {
        expect(signedPhaseNs(delta, frame30).abs(), lessThanOrEqualTo(frame30 ~/ 2 + 1));
      }
    });

    test('un intervalo no positivo es un error', () {
      expect(() => signedPhaseNs(0, 0), throwsArgumentError);
    });
  });

  group('measurePhaseNs', () {
    test('usa la mediana, así que un frame con el sello tocado no manda', () {
      final List<int> master = <int>[0, frame30, 2 * frame30, 3 * frame30, 4 * frame30];
      final List<int> local = <int>[
        4 * nsPerMillisecond,
        frame30 + 4 * nsPerMillisecond,
        2 * frame30 + 15 * nsPerMillisecond, // interrupción: sello movido
        3 * frame30 + 4 * nsPerMillisecond,
        4 * frame30 + 4 * nsPerMillisecond,
      ];

      expect(
        measurePhaseNs(localPtsNs: local, masterPtsNs: master, frameIntervalNs: frame30),
        4 * nsPerMillisecond,
      );
    });

    test('sin PTS no hay medida', () {
      expect(
        () => measurePhaseNs(localPtsNs: <int>[], masterPtsNs: <int>[0], frameIntervalNs: frame30),
        throwsArgumentError,
      );
    });
  });

  group('PhaseSortPolicy', () {
    const PhaseSortPolicy policy = PhaseSortPolicy();

    test('una fase dentro de la tolerancia se acepta al primer intento', () {
      expect(
        policy.decide(phaseNs: 4 * nsPerMillisecond, attempt: 1),
        PhaseDecision.accept,
      );
    });

    test('una fase mala se reintenta', () {
      expect(
        policy.decide(phaseNs: 14 * nsPerMillisecond, attempt: 1),
        PhaseDecision.retry,
      );
    });

    test('agotados los intentos se graba igual', () {
      // Es mejor grabar con fase mala que no grabar: el desfase se conoce y el
      // servidor lo registra en cada pareja (ADR 0012).
      expect(
        policy.decide(phaseNs: 14 * nsPerMillisecond, attempt: exposurePhaseMaxAttempts),
        PhaseDecision.acceptReluctantly,
      );
    });

    test('el signo de la fase no cambia la decisión', () {
      expect(
        policy.decide(phaseNs: -14 * nsPerMillisecond, attempt: 1),
        PhaseDecision.retry,
      );
    });

    test('los intentos empiezan en 1', () {
      expect(() => policy.decide(phaseNs: 0, attempt: 0), throwsArgumentError);
    });

    test('el desdoblamiento traduce la fase a lo que se ve en la costura', () {
      // Los dos números del ADR 0012: medio frame a 30 fps contra la tolerancia.
      expect(
        policy.smearMeters(phaseNs: frame30 ~/ 2, speedMetersPerSecond: 30.0),
        closeTo(0.50, 0.01),
      );
      expect(
        policy.smearMeters(phaseNs: exposurePhaseToleranceNs, speedMetersPerSecond: 30.0),
        closeTo(0.15, 0.01),
      );
    });
  });
}
