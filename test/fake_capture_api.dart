/// Cámara falsa para los tests: el nativo no existe en Dart, y tampoco hace falta.
library;

import 'dart:async';

import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// Un frame a 30 fps, en nanosegundos.
const int frame30 = 33333333;

CaptureStatus fakeStatus({
  bool stabilizationDisabled = true,
  bool exposureLocked = true,
  StreamState streamState = StreamState.off,
  String streamDetail = '',
}) {
  return CaptureStatus(
    running: true,
    width: 3840,
    height: 2160,
    actualFps: 30.0,
    stabilizationDisabled: stabilizationDisabled,
    exposureLocked: exposureLocked,
    exposureSeconds: 0.01,
    iso: 320,
    whiteBalanceLocked: true,
    whiteBalanceKelvin: 5400,
    focusLocked: true,
    intrinsicsAvailable: true,
    thermalState: ThermalState.nominal,
    batteryLevel: 0.9,
    freeDiskBytes: 64000000000,
    droppedFrames: 0,
    timecodeFailures: 0,
    streamState: streamState,
    streamDetail: streamDetail,
    streamDroppedFrames: 0,
  );
}

class FakeCaptureApi extends CaptureHostApi {
  FakeCaptureApi({
    this.cameraAccess = true,
    this.localNetwork = true,
    this.ultraWide = true,
    CaptureStatus? status,
    this.phases = const <int>[0],
    this.failStart = false,
  }) : applied = status ?? fakeStatus();

  /// Simula que el nativo no puede abrir el archivo.
  final bool failStart;

  final bool cameraAccess;
  final bool localNetwork;
  final bool ultraWide;

  /// No se puede llamar `status`: chocaría con el método `status()` del contrato.
  final CaptureStatus applied;
  final List<int> phases;

  /// Lo que el nativo tiene guardado como servidor.
  String serverHost = '';

  /// Lo que Bonjour encontraría en la red.
  String discoverable = '';

  /// Si se pone, `configure` espera a que se complete: simula la medición de la luz.
  Completer<void>? configureGate;

  /// La URL de emisión que llegó en el último `start`.
  String? lastSrtUrl;

  int accessRequests = 0;
  int configureCalls = 0;
  int statusCalls = 0;
  int restarts = 0;
  int startCalls = 0;
  int stopCalls = 0;
  final List<int> offsets = <int>[];
  int _phaseIndex = 0;

  @override
  Future<bool> requestCameraAccess() async {
    accessRequests++;
    return cameraAccess;
  }

  @override
  Future<bool> requestLocalNetworkAccess() async => localNetwork;

  @override
  Future<bool> hasUltraWideCamera() async => ultraWide;

  @override
  Future<CaptureStatus> configure(CaptureSettings settings) async {
    configureCalls++;
    await configureGate?.future;
    return applied;
  }

  @override
  Future<CaptureStatus> status() async {
    statusCalls++;
    return applied;
  }

  /// Cada intento entrega un PTS local desplazado la fase que toque; el maestro
  /// siempre está en 0, así que la resta da exactamente esa fase.
  @override
  Future<List<int>> recentFramePtsNs() async {
    final int value = phases[_phaseIndex.clamp(0, phases.length - 1)];
    _phaseIndex++;
    return <int>[value, frame30 + value, 2 * frame30 + value];
  }

  @override
  Future<void> restartForPhase() async => restarts++;

  @override
  Future<String> start(String srtUrl, String recordingDirectory) async {
    startCalls++;
    lastSrtUrl = srtUrl;
    if (failStart) {
      throw Exception('disco lleno');
    }
    return '${recordingDirectory.isEmpty ? 'Documents' : recordingDirectory}/left-1.mov';
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> setClockOffsetNs(int offsetNs) async => offsets.add(offsetNs);

  @override
  Future<String> loadServerHost() async => serverHost;

  @override
  Future<void> saveServerHost(String host) async => serverHost = host;

  @override
  Future<String> discoverServer() async => discoverable;
}
