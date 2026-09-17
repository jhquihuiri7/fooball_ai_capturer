/// El reloj común del soporte (ADR 0012, decisión 2).
///
/// Los dos iPhone se sincronizan **entre ellos**, no contra el servidor. El motivo es
/// dónde está el enlace bueno: entre los dos móviles hay unos centímetros de WiFi local
/// con RTT de pocos milisegundos, mientras que hasta el pod hay Starlink, con jitter de
/// decenas de milisegundos y una pérdida cada 15 segundos. Y lo que hace falta para
/// coser es el desfase **relativo**, que es justo el que se puede medir barato.
///
/// Dos cosas que este módulo hace y que una media de muestras no haría:
///
/// 1. **Filtra por RTT mínimo.** El desfase se despeja suponiendo que la ida tarda lo
///    mismo que la vuelta. Esa suposición solo vale si nadie encoló el paquete, así que
///    las muestras lentas no se promedian: se tiran.
/// 2. **Ajusta una recta, no un punto.** Dos cristales derivan decenas de ppm, que en
///    90 minutos son más de 100 ms: tres frames. Un offset fijo medido al empezar llega
///    al descanso equivocado.
library;

import 'dart:math' as math;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// El estado del reloj del soporte en un instante dado.
class ClockSyncEstimate {
  const ClockSyncEstimate({
    required this.offsetNs,
    required this.driftPpm,
    required this.samples,
    required this.bestRoundTripNs,
  });

  /// Desfase a sumar al reloj local para obtener el del maestro, en el instante de la
  /// última muestra.
  final int offsetNs;

  /// Deriva relativa entre los dos relojes, en partes por millón. Positiva si el reloj
  /// local va lento respecto al maestro. Vale 0 mientras las muestras no abarquen
  /// `clockMinDriftSpanSeconds`.
  final double driftPpm;

  /// Muestras que sobrevivieron al filtro de RTT.
  final int samples;

  /// El mejor RTT visto. La incertidumbre del desfase es del orden de su mitad: es lo
  /// que hay que comparar con `exposurePhaseToleranceNs` antes de creerse una medida.
  final int bestRoundTripNs;

  /// Incertidumbre del desfase, en nanosegundos.
  int get uncertaintyNs => bestRoundTripNs ~/ 2;
}

/// Acumula medidas de desfase y entrega el reloj del soporte.
class RigClock {
  RigClock({
    this.maxSamples = clockMaxSamples,
    this.rttRejectFactor = clockRttRejectFactor,
    this.minSamples = clockMinSamples,
    this.minDriftSpanSeconds = clockMinDriftSpanSeconds,
  });

  final int maxSamples;
  final double rttRejectFactor;
  final int minSamples;
  final int minDriftSpanSeconds;

  final List<ClockSample> _samples = <ClockSample>[];

  /// Muestras conservadas, de la más antigua a la más reciente.
  List<ClockSample> get samples => List<ClockSample>.unmodifiable(_samples);

  /// Incorpora una medida. Las muestras viejas se van por el extremo antiguo.
  void add(ClockSample sample) {
    _samples.add(sample);
    while (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }

  /// Estimación actual, o `null` si todavía no hay muestras suficientes.
  ///
  /// Devolver `null` y no un cero es deliberado: un desfase de cero es una afirmación
  /// —«los relojes coinciden»— y al arrancar no se sabe nada. Quien emite tiene que
  /// esperar a tener reloj antes de mandar el primer PTS, o los dos streams entran al
  /// servidor en dominios distintos y no parea ni uno.
  ClockSyncEstimate? get estimate {
    final List<ClockSample> kept = _keep();
    if (kept.length < minSamples) {
      return null;
    }

    final int bestRtt = kept
        .map((ClockSample s) => s.roundTripNs)
        .reduce((int a, int b) => a < b ? a : b);
    final int spanNs = kept.last.localMonotonicNs - kept.first.localMonotonicNs;

    if (spanNs < minDriftSpanSeconds * nsPerSecond) {
      final int mean =
          kept.map((ClockSample s) => s.offsetNs).reduce((int a, int b) => a + b) ~/ kept.length;
      return ClockSyncEstimate(
        offsetNs: mean,
        driftPpm: 0.0,
        samples: kept.length,
        bestRoundTripNs: bestRtt,
      );
    }

    final _Line line = _fit(kept);
    return ClockSyncEstimate(
      offsetNs: line.at(kept.last.localMonotonicNs).round(),
      driftPpm: line.slope * 1e6,
      samples: kept.length,
      bestRoundTripNs: bestRtt,
    );
  }

  /// Desfase a aplicar a un instante local concreto, extrapolando la deriva.
  ///
  /// Sin muestras devuelve 0, que es la única respuesta honesta: no se sabe nada, y
  /// quien llama tiene que haber comprobado `estimate` antes de emitir.
  int offsetAtNs(int localMonotonicNs) {
    final List<ClockSample> kept = _keep();
    if (kept.length < minSamples) {
      return kept.isEmpty ? 0 : kept.last.offsetNs;
    }
    final int spanNs = kept.last.localMonotonicNs - kept.first.localMonotonicNs;
    if (spanNs < minDriftSpanSeconds * nsPerSecond) {
      return kept.map((ClockSample s) => s.offsetNs).reduce((int a, int b) => a + b) ~/
          kept.length;
    }
    return _fit(kept).at(localMonotonicNs).round();
  }

  /// Traduce un instante local al dominio de tiempo del soporte. Es lo que se escribe
  /// como PTS del stream, y lo que el servidor compara entre las dos cámaras.
  int toRigTimeNs(int localMonotonicNs) => localMonotonicNs + offsetAtNs(localMonotonicNs);

  /// Muestras que sobreviven al filtro de RTT.
  List<ClockSample> _keep() {
    if (_samples.isEmpty) {
      return const <ClockSample>[];
    }
    final int best = _samples
        .map((ClockSample s) => s.roundTripNs)
        .reduce((int a, int b) => a < b ? a : b);
    final double limit = best * rttRejectFactor;
    return _samples.where((ClockSample s) => s.roundTripNs <= limit).toList();
  }

  /// Mínimos cuadrados de `offset` contra `localMonotonicNs`.
  ///
  /// El tiempo se centra en la primera muestra antes de ajustar. Sin centrar, la `x`
  /// son nanosegundos desde el arranque del teléfono —del orden de 1e14— y sus
  /// cuadrados desbordan la precisión de un `double` justo donde se calcula la
  /// pendiente, que es la magnitud que aquí importa.
  _Line _fit(List<ClockSample> kept) {
    final int origin = kept.first.localMonotonicNs;
    double sx = 0.0;
    double sy = 0.0;
    double sxx = 0.0;
    double sxy = 0.0;
    for (final ClockSample sample in kept) {
      final double x = (sample.localMonotonicNs - origin).toDouble();
      final double y = sample.offsetNs.toDouble();
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final int n = kept.length;
    final double denominator = n * sxx - sx * sx;
    if (denominator.abs() < 1e-9) {
      return _Line(origin: origin, intercept: sy / n, slope: 0.0);
    }
    final double slope = (n * sxy - sx * sy) / denominator;
    return _Line(origin: origin, intercept: (sy - slope * sx) / n, slope: slope);
  }
}

class _Line {
  const _Line({required this.origin, required this.intercept, required this.slope});

  final int origin;
  final double intercept;
  final double slope;

  double at(int localMonotonicNs) =>
      intercept + slope * (localMonotonicNs - origin).toDouble();
}

/// Despeja el desfase de una ida y vuelta, al estilo NTP.
///
/// `t1` es cuándo se envió la pregunta, `t2` y `t3` cuándo la recibió y contestó el
/// maestro (en su reloj) y `t4` cuándo llegó la respuesta. Todo en nanosegundos.
ClockSample solveClockSample({
  required int t1,
  required int t2,
  required int t3,
  required int t4,
}) {
  final int roundTrip = (t4 - t1) - (t3 - t2);
  final int offset = ((t2 - t1) + (t3 - t4)) ~/ 2;
  return ClockSample(
    roundTripNs: math.max(roundTrip, 0),
    offsetNs: offset,
    localMonotonicNs: t4,
  );
}
