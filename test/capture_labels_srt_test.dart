/// La fila SRT de la tarjeta Programa (IOS-58): el destino, la latencia SRT en uso (sube
/// sola cuando la red lo pide, 2026-10-15) y, reconectando, el porqué.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/capture_labels.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';

import 'fake_capture_api.dart';
import 'fake_rig_api.dart';

void main() {
  String srtLabel(ProgramStatus program) {
    final CaptureSession session = CaptureSession(
      role: CameraRole.left,
      api: FakeCaptureApi(),
    )
      ..status = fakeStatus()
      ..phase = SessionPhase.grabando
      ..program = program;
    return CaptureReadout(session)
        .programReadings
        .firstWhere((CaptureReading r) => r.label == 'SRT')
        .value;
  }

  test('publicando dice la latencia SRT en uso y las reconexiones', () {
    expect(
      srtLabel(fakeProgramStatus(srtDetail: 'latencia 1,5 s')),
      'publicando a 192.0.2.7:8890 · latencia 1,5 s',
    );
    expect(
      srtLabel(fakeProgramStatus(srtDetail: 'latencia 2,5 s', srtReconnects: 2)),
      'publicando a 192.0.2.7:8890 · latencia 2,5 s · 2 reconexiones',
    );
    // Un Runner anterior, sin detalle: como siempre.
    expect(srtLabel(fakeProgramStatus()), 'publicando a 192.0.2.7:8890');
  });

  test('conectando lleva la latencia con la que va; reconectando, el porqué', () {
    expect(
      srtLabel(fakeProgramStatus(srtState: 'connecting', srtDetail: 'latencia 4 s')),
      'conectando a 192.0.2.7:8890 · latencia 4 s…',
    );
    expect(
      srtLabel(fakeProgramStatus(
        srtState: 'waiting',
        srtDetail: 'SRT vivo pero 5 s sin sacar vídeo (búfer de envío 1520 ms)',
        srtReconnects: 1,
      )),
      'RECONECTANDO a 192.0.2.7:8890 · SRT vivo pero 5 s sin sacar vídeo (búfer de envío 1520 ms)',
    );
  });
}
