/// El maestro como servidor del mando (IOS-62, IOS-63): cuando el enlace dice que este
/// móvil dirige, abre el partido y sirve `/api/v1` en la LAN; cuando deja de dirigir,
/// cierra. También compone el QR Mando.
///
/// Lo que sale del nativo llega por funciones (el secreto ya derivado, la IP del otro
/// móvil, el PIN del Keychain), así que esto se prueba sin Pigeon y sin iPhone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/program_graphics.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/match_migration.dart';
import 'package:football_ai_capture/src/server/replica.dart';
import 'package:football_ai_capture/src/server/rig_time.dart';

/// La carpeta Documents de la app en iOS: el temporal es `<contenedor>/tmp`, así que su
/// padre es el contenedor. Sin depender de HOME ni de path_provider.
String appDocumentsPath() => '${Directory.systemTemp.parent.path}/Documents';

/// Nombre del fichero del partido en la carpeta del maestro.
const String matchFileName = 'match.json';

/// Las IPv4 de la LAN de este móvil, la Wi-Fi o el hub primero.
Future<List<String>> lanAddresses() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  // en0 es la Wi-Fi en iOS; el adaptador Ethernet del hub sale como en1, en2…
  interfaces.sort((NetworkInterface a, NetworkInterface b) => a.name.compareTo(b.name));
  return <String>[
    for (final NetworkInterface i in interfaces)
      if (i.name.startsWith('en'))
        for (final InternetAddress a in i.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a.address,
  ];
}

class MasterHost extends ChangeNotifier {
  MasterHost({
    required this.directory,
    required this.controlSecret,
    required this.announceMatch,
    required this.peerAddress,
    required this.operatorPin,
    this.addresses = lanAddresses,
    int Function()? wallS,
    MatchTimeSource? time,
    this.port = masterApiPort,
    this.vpsUrl,
    this.overlaySink,
    this.panelHtml,
    this.thumbnail,
    this.rigStatus,
    this.legacyMatch,
    this.replicaSink,
    this.term,
  }) : wallS = wallS ?? _wallClockS,
       _time = time ?? StopwatchTimeSource(),
       _monotonic = Stopwatch()..start();

  /// La carpeta del partido (Documents en el iPhone).
  final Directory directory;

  /// El secreto del mando de un partido, ya derivado en nativo; vacío sin secreto.
  final Future<String> Function(String matchId) controlSecret;

  /// Le dice al enlace el partido que dirige este móvil.
  final Future<void> Function(String matchId) announceMatch;

  /// La IP del otro móvil, o vacío.
  final Future<String> Function() peerAddress;

  /// El PIN del operador del Keychain, o vacío.
  final Future<String> Function() operatorPin;

  final Future<List<String>> Function() addresses;

  /// Hora de pared en segundos: solo la caducidad de los tokens.
  final int Function() wallS;
  final MatchTimeSource _time;
  final Stopwatch _monotonic;
  final int port;

  /// La API del mando en el VPS, si el soporte tiene túnel (ADR 0022): tercera dirección
  /// del QR Mando.
  Uri? vpsUrl;

  /// El canal del gráfico a Metal (IOS-47); sin él, el maestro no pinta marcador.
  final OverlaySink? overlaySink;

  /// El panel local (IOS-64): la página, las miniaturas y el estado del soporte.
  final Future<String> Function()? panelHtml;
  final Future<Uint8List> Function(String name)? thumbnail;
  final Map<String, Object?> Function()? rigStatus;

  /// «zero.match» del MatchState local, si lo hay (IOS-87): se migra una vez, al abrir
  /// el maestro sin partido guardado.
  final Future<String?> Function()? legacyMatch;

  /// Si al abrir se migró el partido local.
  bool migrated = false;

  /// Por dónde sale la pizarra hacia el esclavo (IOS-82); null sin enlace.
  final Future<void> Function(String json)? replicaSink;

  /// El term vigente del soporte (el de la negociación, IOS-80).
  final int Function()? term;
  StreamSubscription<void>? _replicaChanges;
  Timer? _replicaTick;
  int _replicaSeq = 0;
  MasterApi? _api;

  /// Réplicas mandadas.
  int replicasSent = 0;
  ProgramGraphics? _graphics;

  /// El gráfico del programa mientras se sirve (para fijar la competición, p. ej.).
  ProgramGraphics? get graphics => _graphics;
  StreamSubscription<void>? _changes;
  Timer? _clockTick;

  MatchEngine? _engine;
  MasterApiServer? _server;
  List<int>? _secret;

  /// Por qué no se sirve el mando, si no se sirve.
  String? problem;

  MatchEngine? get engine => _engine;

  bool get serving => _server != null;

  /// Hay con qué firmar el QR Mando (sin secreto del soporte, solo abre el PIN).
  bool get canPair => _secret != null;

  int? get boundPort => _server?.port;

  /// Pasa a servir el partido `matchId` (el del enlace) o, si es null, el guardado o uno
  /// nuevo, que se anuncia al enlace. Dos veces con el mismo partido no hace nada.
  Future<void> becomeMaster(String? matchId) async {
    final MatchEngine? actual = _engine;
    if (actual != null && serving && (matchId == null || actual.matchId == matchId)) {
      return;
    }
    await stepDown();
    try {
      final MatchTimeSource reloj = _time;
      if (reloj is RigTimeSource) {
        // El reloj del soporte al día antes de abrir: el cronómetro sigue en marcha si el
        // dominio es el del partido guardado (un reinicio de la app, un relevo).
        await reloj.refresh();
      }
      await _migrateIfNeeded(matchId);
      final MatchEngine engine = MatchEngine.open(
        file: File('${directory.path}/$matchFileName'),
        time: _time,
        matchId: matchId,
      );
      if (matchId == null) {
        await announceMatch(engine.matchId);
      }
      final String secreto = await controlSecret(engine.matchId);
      final String pin = await operatorPin();
      _secret = secreto.isEmpty ? null : secreto.codeUnits;
      final MasterApi api = MasterApi(
        engine: engine,
        monotonicMs: () => _monotonic.elapsedMilliseconds,
        wallS: wallS,
        controlSecret: _secret,
        operatorPin: pin.isEmpty ? null : pin,
        panelHtml: panelHtml == null ? null : await panelHtml!(),
        thumbnail: thumbnail,
        rigStatus: rigStatus,
      );
      _server = await MasterApiServer.start(api, port: port);
      _engine = engine;
      _api = api;
      _startGraphics(engine);
      _startReplica(engine);
      problem = engine.lineupsError;
    } on Exception catch (error) {
      problem = 'no se pudo servir el mando: $error';
    }
    notifyListeners();
  }

  Future<void> _migrateIfNeeded(String? matchId) async {
    final Future<String?> Function()? leer = legacyMatch;
    if (leer == null || File('${directory.path}/$matchFileName').existsSync()) {
      return;
    }
    final String? crudo = await leer();
    if (crudo == null) {
      return;
    }
    final MigrationResult? m = migrateLocalMatch(
      crudo,
      matchId: matchId ?? 'm_migrado_${wallS()}',
      nowWallMs: wallS() * Duration.millisecondsPerSecond,
    );
    if (m != null) {
      migrated = applyMigration(directory, m, matchFileName: matchFileName);
    }
  }

  /// El marcador y la alineación del programa: con cada cambio y cada segundo.
  void _startGraphics(MatchEngine engine) {
    final OverlaySink? sink = overlaySink;
    if (sink == null) {
      return;
    }
    final ProgramGraphics g = ProgramGraphics(engine: engine, bridge: OverlayBridge(sink));
    _graphics = g;
    _changes = engine.changes.listen((_) => unawaited(g.refresh()));
    _clockTick = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(g.refresh()));
    unawaited(g.refresh());
  }

  /// La pizarra al esclavo: con cada cambio del partido y cada REPLICA_INTERVAL_S.
  void _startReplica(MatchEngine engine) {
    if (replicaSink == null) {
      return;
    }
    _replicaChanges = engine.changes.listen((_) => unawaited(sendReplica()));
    _replicaTick = Timer.periodic(replicaInterval, (_) => unawaited(sendReplica()));
    unawaited(sendReplica());
  }

  /// Manda la pizarra ahora (si se sirve un partido).
  Future<void> sendReplica() async {
    final MatchEngine? engine = _engine;
    final Future<void> Function(String json)? sink = replicaSink;
    if (engine == null || sink == null) {
      return;
    }
    _replicaSeq += 1;
    final StateReplica r = StateReplica.fromEngine(
      engine,
      // El term es ≥1 (ADR 0023 §7): el maestro que arranca solo aún no ha negociado.
      term: max(1, term?.call() ?? 1),
      seq: _replicaSeq,
      // En el reloj del soporte: ordena las réplicas entre arranques del maestro.
      rigMs: _time.nowMs(),
      clockDomain: engine.record().clockDomain,
      idempotency: _api?.idempotency,
    );
    final String json = r.encode();
    if (utf8.encode(json).length <= replicaMaxBytes) {
      replicasSent += 1;
      await sink(json);
    }
  }

  void _stopReplica() {
    unawaited(_replicaChanges?.cancel());
    _replicaChanges = null;
    _replicaTick?.cancel();
    _replicaTick = null;
  }

  void _stopGraphics() {
    unawaited(_changes?.cancel());
    _changes = null;
    _clockTick?.cancel();
    _clockTick = null;
    _graphics = null;
  }

  /// Deja de servir: otro móvil dirige, o se cerró la sesión.
  Future<void> stepDown() async {
    _stopGraphics();
    _stopReplica();
    final MasterApiServer? server = _server;
    _server = null;
    _engine = null;
    _secret = null;
    if (server != null) {
      await server.close();
      notifyListeners();
    }
  }

  /// Cambia el PIN del operador en el servidor que corre (ya guardado en el Keychain).
  void updateOperatorPin(String pin) {
    _server?.api.operatorPin = pin.isEmpty ? null : pin;
  }

  /// El texto del QR Mando: este móvil, el otro y el VPS, con un token del partido.
  /// null si no se sirve o no hay secreto con el que firmarlo.
  Future<String?> pairingText({bool stream = false}) async {
    final MatchEngine? engine = _engine;
    final List<int>? secreto = _secret;
    final int? puerto = boundPort;
    if (engine == null || secreto == null || puerto == null) {
      return null;
    }
    final List<String> mias = await addresses();
    final String otro = await peerAddress();
    final List<Uri> panels = <Uri>[
      for (final String ip in mias) Uri(scheme: 'http', host: ip, port: puerto),
      if (otro.isNotEmpty) Uri(scheme: 'http', host: otro, port: masterApiPort),
      ?vpsUrl,
    ];
    if (panels.isEmpty) {
      return null;
    }
    return PanelPairing.compose(
      panels,
      issueToken(
        secreto,
        ControlClaims(
          matchId: engine.matchId,
          scopes: <String>{panelScopeMatch, if (stream) panelScopeStream},
          expiresS: wallS() + controlTokenTtl.inSeconds,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopGraphics();
    _stopReplica();
    final MasterApiServer? server = _server;
    _server = null;
    if (server != null) {
      server.close();
    }
    super.dispose();
  }
}

/// La caducidad de un token es hora de pared por definición: la comprueban otro móvil y
/// el VPS, que no comparten el reloj monótono de este.
int _wallClockS() => DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
