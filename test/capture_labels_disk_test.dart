/// El disco en la pantalla de captura (2026-10-24): la copia local del programa llenó el
/// disco del 17 y se llevó la emisión, y la pantalla solo hablaba de la 4K. Ahora dice para
/// cuánta copia queda y, con poco sitio, avisa en palabras de cualquiera.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_labels.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

import 'fake_capture_api.dart';

void main() {
  const int gb = 1000 * 1000 * 1000;

  CaptureReadout readout(int freeBytes, {bool saveVideo = false}) {
    final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi())
      ..status = fakeStatus(freeDiskBytes: freeBytes)
      ..saveVideo = saveVideo;
    return CaptureReadout(session);
  }

  CaptureReading disco(CaptureReadout r) => r.deviceReadings.firstWhere((CaptureReading x) => x.label == 'Disco libre');

  test('sin 4K, la fila dice para cuántas horas de copia queda', () {
    expect(disco(readout(29 * gb)).value, '29.0 GB · copia del partido para ~13 h');
    expect(disco(readout(29 * gb)).tone, ZeroTone.neutral);
    expect(readout(29 * gb).lowDiskWarning, isNull);
    expect(readout(29 * gb).troubleReadings, isEmpty);
  });

  test('con poco sitio avisa: se borran copias viejas y la emisión sigue', () {
    final CaptureReadout r = readout(8 * gb);
    expect(disco(r).value, '8.0 GB · copia del partido para ~2 h');
    expect(disco(r).tone, ZeroTone.bad);
    expect(r.lowDiskWarning, contains('borra solo las copias viejas'));
    expect(r.troubleReadings.single.label, 'Espacio');
  });

  test('por debajo del suelo, la copia está parada y la emisión sigue (el 24-oct: 0,5 GB)', () {
    final CaptureReadout r = readout(gb ~/ 2);
    expect(disco(r).value, '0.5 GB · copia local parada, la emisión sigue');
    expect(disco(r).tone, ZeroTone.bad);
    expect(r.lowDiskWarning, contains('ya no guarda la copia'));
    expect(r.lowDiskWarning, contains('la emisión sigue'));
  });

  test('con la 4K encendida, la fila sigue mirando si la 4K llega al final', () {
    expect(disco(readout(20 * gb, saveVideo: true)).value, '20.0 GB · la 4K no llega al final del partido');
    expect(disco(readout(60 * gb, saveVideo: true)).value, '60.0 GB');
  });

  test('los umbrales son los del nativo (RecordingPolicy)', () {
    expect(programCopyFloorBytes, 3 * gb);
    expect(programCopyTargetFreeBytes, 12 * gb);
  });
}
