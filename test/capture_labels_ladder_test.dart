/// Las etiquetas de temperatura, presión y escalera (IOS-06).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_labels.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

import 'fake_capture_api.dart';

void main() {
  CaptureReadout readoutWith(CaptureStatus status) {
    final CaptureSession session = CaptureSession(
      role: CameraRole.left,
      api: FakeCaptureApi(),
    );
    session.status = status;
    return CaptureReadout(session);
  }

  CaptureReading reading(CaptureReadout readout, String label) =>
      readout.deviceReadings.firstWhere((CaptureReading r) => r.label == label);

  test('con todo nominal, presión y escalera salen en verde', () {
    final CaptureReadout readout = readoutWith(fakeStatus());

    expect(reading(readout, 'Presión').value, 'nominal');
    expect(reading(readout, 'Escalera').value, startsWith('L0'));
  });

  test('shutdown y L4 se dicen con todas las letras', () {
    final CaptureReadout readout = readoutWith(
      fakeStatus(pressure: SystemPressure.shutdown, ladderLevel: 4),
    );

    expect(reading(readout, 'Presión').value, contains('shutdown'));
    expect(reading(readout, 'Escalera').value, contains('L4'));
  });
}
