/// Cámara falsa para los tests: el nativo no existe en Dart, y tampoco hace falta.
library;

import 'dart:async';

import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// Un frame a 30 fps, en nanosegundos.
const int frame30 = 33333333;

CaptureStatus fakeStatus({
  bool stabilizationDisabled = true,
  bool exposureLocked = true,
  SystemPressure pressure = SystemPressure.nominal,
  int ladderLevel = 0,
  StreamState streamState = StreamState.off,
  String streamDetail = '',
  int streamBitrateBps = 0,
  String recordingFile = '',
  int freeDiskBytes = 64000000000,
  int recordingSegment = 0,
}) {
  return CaptureStatus(
    running: true,
    pressure: pressure,
    ladderLevel: ladderLevel,
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
    freeDiskBytes: freeDiskBytes,
    droppedFrames: 0,
    timecodeFailures: 0,
    recordingFile: recordingFile,
    recordingSegment: recordingSegment,
    streamState: streamState,
    streamDetail: streamDetail,
    streamDroppedFrames: 0,
    streamBitrateBps: streamBitrateBps,
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
    this.diskBelowReserve = false,
  }) : applied = status ?? fakeStatus();

  /// Simula que el nativo no puede abrir el archivo.
  final bool failStart;

  /// IOS-57: el nativo no abre la 4K sin la reserva de disco; la emisión sigue.
  final bool diskBelowReserve;

  /// IOS-07: cada llamada a setScreenDim, en orden. true = atenuada.
  final List<bool> screenDims = <bool>[];

  @override
  Future<void> setScreenDim(bool dimmed) async {
    screenDims.add(dimmed);
  }

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

  /// El enlace entre móviles: con qué lado se abrió y qué PTS contesta el maestro.
  int startLinkCalls = 0;
  int stopLinkCalls = 0;
  CameraRole? linkRole;
  List<int> masterPts = <int>[0, frame30, 2 * frame30];

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
  Future<String> start(String srtUrl, String recordingDirectory, bool saveVideo) async {
    startCalls++;
    lastSrtUrl = srtUrl;
    lastSaveVideo = saveVideo;
    if (failStart) {
      throw Exception('disco lleno');
    }
    // Sin guardar no hay fichero: el nativo devuelve vacío.
    if (!saveVideo || diskBelowReserve) {
      return '';
    }
    return '${recordingDirectory.isEmpty ? 'Documents' : recordingDirectory}/left-1.mov';
  }

  /// Si la última vez se pidió guardar el vídeo además de emitir.
  bool lastSaveVideo = false;

  /// Veces que se soltó la cámara. Parar de grabar no cuenta: eso dejaría la app sin
  /// poder volver a grabar.
  int releaseCalls = 0;

  @override
  Future<void> releaseCamera() async => releaseCalls++;

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

  /// Lo que «leería» la cámara al escanear el QR del panel. Vacío = cancelado.
  String scannable = '';

  @override
  Future<String> scanServerQr() async => scannable;

  /// Las órdenes que este móvil mandó al otro, en orden.
  final List<RigCommand> peerCommands = <RigCommand>[];

  @override
  Future<void> sendPeerCommand(RigCommand command) async => peerCommands.add(command);

  /// Lo que el nativo tiene en el Keychain como emparejamiento con el panel.
  String panelPairing = '';

  @override
  Future<String> loadPanelPairing() async => panelPairing;

  @override
  Future<void> savePanelPairing(String pairing) async => panelPairing = pairing;

  @override
  Future<void> clearPanelPairing() async => panelPairing = '';

  bool? lastPrefersMaster;

  @override
  Future<void> startLink(CameraRole role, bool prefersMaster) async {
    lastPrefersMaster = prefersMaster;
    startLinkCalls++;
    linkRole = role;
  }

  @override
  Future<void> stopLink() async => stopLinkCalls++;

  /// El secreto del mando que devolvería el nativo; vacío = sin secreto del soporte.
  String controlSecretValue = '';
  String? announcedMatchId;
  String peerAddress = '';
  String operatorPin = '';

  @override
  Future<String> controlSecret(String matchId) async => controlSecretValue;

  @override
  Future<void> setMatchId(String matchId) async => announcedMatchId = matchId;

  @override
  Future<String> linkPeerAddress() async => peerAddress;

  @override
  Future<String> loadOperatorPin() async => operatorPin;

  @override
  Future<String> captureCalibrationPairs() async => '{"count":5}';

  final List<String> replicas = <String>[];
  int rigNs = 1000000000;
  String clockDomain = 'rdominioprueba1';

  @override
  Future<String> rigClockSnapshot() async => '{"rig_ns":$rigNs,"domain":"$clockDomain"}';

  @override
  Future<void> adoptClockDomain(String domain) async => clockDomain = domain;

  @override
  Future<void> sendReplica(String json) async => replicas.add(json);

  @override
  Future<void> saveOperatorPin(String pin) async => operatorPin = pin;

  @override
  Future<List<int>> masterRecentPtsNs() async => masterPts;
}
