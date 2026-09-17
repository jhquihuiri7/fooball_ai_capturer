/// La fase de exposición entre los dos sensores (ADR 0012; TASK A4).
///
/// Sincronizar los relojes no hace que los dos sensores expongan a la vez. Sin genlock
/// cada uno arranca su cadencia donde quiere, y lo que queda es un desfase constante
/// dentro del intervalo de frame: hasta 16,7 ms a 30 fps. Saberlo no lo arregla, porque
/// no hay forma de mover la fase de un `AVCaptureSession` en marcha.
///
/// Lo que sí se puede hacer es **volver a tirar los dados**. La fase se sortea en cada
/// arranque, así que se mide con los PTS reales y, si salió mala, se reinicia la
/// captura. Cuesta segundos antes del saque inicial, y lo que se gana está en la
/// costura: a 16 ms un balón a 30 m/s se desdobla 50 cm, y a 5 ms, 15.
///
/// Nadie parece hacer esto, y es la parte más barata de todo el montaje.
library;

import 'package:football_ai_capture/src/constants.dart';

/// Qué hacer tras medir la fase de un arranque.
enum PhaseDecision {
  /// La fase es lo bastante pequeña: se puede grabar.
  accept,

  /// Merece la pena reiniciar y volver a sortear.
  retry,

  /// Se agotaron los intentos. Se graba con lo que hay, que sigue siendo mejor que no
  /// grabar: el desfase se conoce, y el servidor lo registra en cada pareja.
  acceptReluctantly,
}

/// Fase con signo entre dos cadencias que corren libres.
///
/// Devuelve el desfase equivalente dentro de `(-T/2, +T/2]`. La diferencia bruta de dos
/// PTS no sirve: si un móvil empezó tres frames antes, la diferencia son 100 ms y la
/// fase real es 0. Lo que importa es el resto, no los frames enteros.
int signedPhaseNs(int deltaNs, int frameIntervalNs) {
  if (frameIntervalNs <= 0) {
    throw ArgumentError.value(
      frameIntervalNs,
      'frameIntervalNs',
      'el intervalo de frame debe ser positivo',
    );
  }
  int phase = deltaNs % frameIntervalNs;
  if (phase < 0) {
    phase += frameIntervalNs;
  }
  if (phase * 2 > frameIntervalNs) {
    phase -= frameIntervalNs;
  }
  return phase;
}

/// Mide la fase a partir de los PTS de los dos móviles, ya en tiempo del soporte.
///
/// Se usa la mediana de las diferencias y no una sola: un frame suelto puede llegar con
/// el sello tocado por una interrupción, y una medida única lo tomaría por fase.
int measurePhaseNs({
  required List<int> localPtsNs,
  required List<int> masterPtsNs,
  required int frameIntervalNs,
}) {
  if (localPtsNs.isEmpty || masterPtsNs.isEmpty) {
    throw ArgumentError('hacen falta PTS de las dos cámaras para medir la fase');
  }
  final List<int> phases = <int>[];
  final int count = localPtsNs.length < masterPtsNs.length
      ? localPtsNs.length
      : masterPtsNs.length;
  for (int i = 0; i < count; i++) {
    phases.add(signedPhaseNs(localPtsNs[i] - masterPtsNs[i], frameIntervalNs));
  }
  phases.sort();
  return phases[phases.length ~/ 2];
}

/// Decide si reiniciar la captura para sortear una fase mejor.
class PhaseSortPolicy {
  const PhaseSortPolicy({
    this.toleranceNs = exposurePhaseToleranceNs,
    this.maxAttempts = exposurePhaseMaxAttempts,
  });

  final int toleranceNs;
  final int maxAttempts;

  /// `attempt` empieza en 1.
  PhaseDecision decide({required int phaseNs, required int attempt}) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt', 'los intentos empiezan en 1');
    }
    if (phaseNs.abs() <= toleranceNs) {
      return PhaseDecision.accept;
    }
    return attempt >= maxAttempts ? PhaseDecision.acceptReluctantly : PhaseDecision.retry;
  }

  /// Desdoblamiento en la costura, en metros, para un objeto a esa velocidad.
  ///
  /// Es la unidad en la que se decide de verdad si una fase es aceptable: 5 ms no
  /// significan nada, y 15 cm de balón sí.
  double smearMeters({required int phaseNs, required double speedMetersPerSecond}) =>
      phaseNs.abs() / nsPerSecond * speedMetersPerSecond;
}
