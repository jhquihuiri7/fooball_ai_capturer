/// El pipeline falso para los tests (IOS-58): EMITIR en la arquitectura B sin nativo.
library;

import 'package:football_ai_capture/src/generated/rig_api.g.dart';

ProgramStatus fakeProgramStatus({
  bool running = true,
  bool master = true,
  double programFps = 30,
  String srtState = 'publishing',
  String srtTarget = '192.0.2.7:8890',
  String srtDetail = '',
  int srtBitrateBps = 6000000,
  double srtRttMs = 42,
  int srtReconnects = 0,
  double partMbps = 7.9,
  int partFallbacks = 3,
  int partsLost = 2,
  int detectorRuns = 120,
  String detectorNote = '',
  String problem = '',
  String rigSource = 'rig.json',
}) {
  return ProgramStatus(
    running: running,
    master: master,
    programFps: programFps,
    programFrames: 900,
    srtState: srtState,
    srtTarget: srtTarget,
    srtDetail: srtDetail,
    srtBitrateBps: srtBitrateBps,
    srtRttMs: srtRttMs,
    srtReconnects: srtReconnects,
    partMbps: partMbps,
    partFallbacks: partFallbacks,
    partsLost: partsLost,
    detectorRuns: detectorRuns,
    detectorNote: detectorNote,
    problem: problem,
    rigSource: rigSource,
  );
}

class FakeRigApi extends RigHostApi {
  FakeRigApi({this.startProblem = '', ProgramStatus? status})
    : programState = status ?? fakeProgramStatus();

  /// Lo que contesta `startProgram`: vacío si arranca.
  String startProblem;

  /// Lo que contesta `programStatus`.
  ProgramStatus programState;

  int startCalls = 0;
  int stopCalls = 0;
  int statusCalls = 0;

  /// La pasada que el nativo tendría en marcha.
  bool get running => startCalls > stopCalls && startProblem.isEmpty;

  @override
  Future<String> startProgram() async {
    startCalls++;
    return startProblem;
  }

  @override
  Future<void> stopProgram() async => stopCalls++;

  @override
  Future<ProgramStatus> programStatus() async {
    statusCalls++;
    return programState;
  }
}
