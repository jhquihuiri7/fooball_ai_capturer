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
import 'package:football_ai_capture/src/ads/ad_director.dart';
import 'package:football_ai_capture/src/ads/ad_pack_downloader.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/overlay_bridge.dart';
import 'package:football_ai_capture/src/graphics/program_graphics.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/match_migration.dart';
import 'package:football_ai_capture/src/server/program_video.dart';
import 'package:football_ai_capture/src/server/replica.dart';
import 'package:football_ai_capture/src/server/rig_time.dart';

/// La carpeta Documents de la app en iOS: el temporal es `<contenedor>/tmp`, así que su
/// padre es el contenedor. Sin depender de HOME ni de path_provider.
String appDocumentsPath() => '${Directory.systemTemp.parent.path}/Documents';

/// Nombre del fichero del partido en la carpeta del maestro.
const String matchFileName = 'match.json';

/// Las interfaces por las que un mando de la LAN llega a este móvil, por orden de
/// preferencia. `en`: en0 es la Wi-Fi en iOS y el adaptador Ethernet del hub sale como
/// en1, en2…; `bridge`: la red que sirve este móvil cuando comparte sus datos (Bug A,
/// 2026-10-21: con el punto de acceso personal, en0 se queda sin IPv4 y la red va por
/// bridge100, 172.20.10.1); `ap`, la interfaz del punto de acceso, por si alguna versión
/// le da a ella la IPv4. Fuera quedan los datos móviles (`pdp_ip`), Wi-Fi Aware y AWDL.
const List<String> lanInterfacePrefixes = <String>['en', 'bridge', 'ap'];

/// Las IPv4 de la LAN entre `interfaces`: las de [lanInterfacePrefixes], por ese orden y
/// por nombre dentro de cada familia; sin loopback ni link-local.
List<String> lanAddressesOf(List<NetworkInterface> interfaces) {
  int familia(String nombre) => lanInterfacePrefixes.indexWhere(nombre.startsWith);
  final List<NetworkInterface> lan = <NetworkInterface>[
    for (final NetworkInterface i in interfaces)
      if (familia(i.name) >= 0) i,
  ]..sort((NetworkInterface a, NetworkInterface b) {
      final int orden = familia(a.name).compareTo(familia(b.name));
      return orden != 0 ? orden : a.name.compareTo(b.name);
    });
  return <String>[
    for (final NetworkInterface i in lan)
      for (final InternetAddress a in i.addresses)
        if (a.type == InternetAddressType.IPv4 && !a.isLoopback && !a.isLinkLocal) a.address,
  ];
}

/// Las IPv4 de la LAN de este móvil, la Wi-Fi o el hub primero y el punto de acceso detrás.
Future<List<String>> lanAddresses() async =>
    lanAddressesOf(await NetworkInterface.list(type: InternetAddressType.IPv4));

/// Por qué no hay QR Mando, tal cual lo lee el operador en la hoja (Bug A, 2026-10-21).
const String mandoReasonNotServing = 'el mando no está en marcha: este móvil no dirige';
const String mandoReasonNoLan =
    'sin red local: conecta este móvil a la Wi-Fi del mando (o comparte sus datos) y '
    'pulsa REINTENTAR MANDO';
const String mandoReasonNoSecret = 'sin secreto con el que firmar el QR: entra a mano con el PIN del operador';

/// Lo que dice `problem` cuando el mando no arranca.
const String mandoFailedPrefix = 'el mando no arrancó';

/// El QR Mando, o por qué no lo hay; y por dónde se entra a mano con el PIN.
@immutable
class MandoPairing {
  const MandoPairing({this.text, this.reason, this.manual = const <Uri>[]});

  /// El texto del QR; null si no hay QR.
  final String? text;

  /// Por qué no hay QR; null si lo hay.
  final String? reason;

  /// El panel de este móvil en la LAN (http://IP:puerto), para entrar con el PIN.
  final List<Uri> manual;
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
    this.adSink,
    this.adPacks,
    this.videoSink,
    this.freeDiskBytes,
    this.localRecording,
    this.reportState,
    this.eventKind = EventKind.football,
  }) : wallS = wallS ?? _wallClockS,
       _time = time ?? StopwatchTimeSource(),
       _monotonic = Stopwatch()..start();

  /// La carpeta del partido (Documents en el iPhone).
  final Directory directory;

  /// Lo que se transmite (ADR 0031): lo eligió quien abrió la cámara.
  final EventKind eventKind;

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

  /// La franja nativa (IOS-48); sin ella, el maestro no pone anuncios.
  final AdSink? adSink;

  /// Los paquetes de anuncios del VPS (IOS-49): el último bajado al dirigir y cada uno
  /// nuevo mientras se dirige.
  final AdPackDownloader? adPacks;
  AdDirector? _ads;
  StreamSubscription<void>? _adChanges;
  StreamSubscription<AdPack>? _adPackSub;

  /// La franja mientras se sirve.
  AdDirector? get ads => _ads;

  /// El vídeo nativo del programa (IOS-103); sin él, `video/play` no suena.
  final VideoSink? videoSink;

  /// Lo libre del disco del móvil, para la reserva de grabación al subir vídeos.
  final int? Function()? freeDiskBytes;

  /// Si el operador quiere la 4K local («Guardar vídeo»): solo entonces los vídeos dejan
  /// su reserva entera.
  final bool Function()? localRecording;
  ProgramVideo? _video;
  StreamSubscription<void>? _videoChanges;
  Timer? _videoTick;

  /// El estado del mando hacia el latido y el informe de la emisión (Bug A, 2026-10-21):
  /// un JSON con `serving`, `port`, `match_id`, `addresses`, `can_pair` y `problem`.
  final Future<void> Function(String json)? reportState;

  /// El vídeo del programa mientras se sirve.
  ProgramVideo? get video => _video;
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

  /// Los fotogramas del gol mientras entra y sale (ADR 0032).
  Timer? _animTick;

  /// Lo que cambia solo con el tiempo en el partido (las tandas, el gol, un vídeo que acabó
  /// sin aviso): [MatchEngine.tick] una vez por segundo.
  Timer? _engineTick;

  MatchEngine? _engine;
  MasterApiServer? _server;
  List<int>? _secret;

  /// Por qué no se sirve el mando, si no se sirve.
  String? problem;

  MatchEngine? get engine => _engine;

  bool get serving => _server != null;

  /// Hay con qué firmar el QR Mando (el secreto del soporte o, sin él, el propio del
  /// móvil; sin ninguno, solo abre el PIN).
  bool get canPair => _secret != null;

  int? get boundPort => _server?.port;

  /// La cola de [becomeMaster], [stepDown] y [retry] (Bug A, 2026-10-21): `onRigRole`
  /// las lanza sin esperar, y una que empieza mientras otra espera al nativo abría un
  /// segundo servidor en el mismo puerto o dejaba sirviendo a un esclavo. Cada una empieza
  /// cuando acaba la anterior, así que manda la última.
  Future<void> _turn = Future<void>.value();

  /// Lo último que pidió el enlace: dirigir y con qué partido (el anunciado, si lo
  /// empezó este móvil), para [retry].
  bool _wantsMaster = false;
  String? _wantedMatchId;

  /// Cerrado con la pantalla: lo que quede en la cola ya no arranca nada.
  bool _disposed = false;

  Future<void> _inTurn(Future<void> Function() action) {
    final Future<void> esta = _turn.then((_) => _disposed ? Future<void>.value() : action());
    _turn = esta.catchError((Object _) {});
    return esta;
  }

  /// Pasa a servir el partido `matchId` (el del enlace) o, si es null, el guardado o uno
  /// nuevo, que se anuncia al enlace. Dos veces con el mismo partido no hace nada.
  Future<void> becomeMaster(String? matchId) => _inTurn(() {
    _wantsMaster = true;
    _wantedMatchId = matchId;
    return _becomeMaster(matchId);
  });

  /// «REINTENTAR MANDO»: si el enlace dijo que este móvil dirige y el mando no se sirve,
  /// lo arranca otra vez con el mismo partido. No toca la emisión, que es nativa. Si ya
  /// se sirve, no hace nada: lo que falte (la red) lo vuelve a mirar la hoja.
  Future<void> retry() => _inTurn(() async {
    if (_wantsMaster && !serving) {
      await _becomeMaster(_wantedMatchId);
    }
  });

  Future<void> _becomeMaster(String? matchId) async {
    final MatchEngine? actual = _engine;
    if (actual != null && serving && (matchId == null || actual.matchId == matchId)) {
      return;
    }
    await _stepDown();
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
        freeBytes: freeDiskBytes,
        localRecording: localRecording,
        eventKind: eventKind,
      );
      if (matchId == null) {
        await announceMatch(engine.matchId);
      }
      // Reintentar sigue con este partido, ya anunciado, y no empieza otro.
      _wantedMatchId = engine.matchId;
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
      final MasterApiServer servidor = await MasterApiServer.start(api, port: port);
      if (_disposed) {
        // La pantalla se cerró mientras arrancaba: que no quede un servidor sin dueño.
        await servidor.close();
        return;
      }
      _server = servidor;
      _engine = engine;
      _api = api;
      _engineTick = Timer.periodic(const Duration(seconds: 1), (_) => engine.tick());
      _startGraphics(engine);
      _startVideo(engine);
      _startReplica(engine);
      await _startAds(engine);
      problem = engine.lineupsError;
    } on Exception catch (error) {
      _secret = null;
      problem = '$mandoFailedPrefix: $error';
    }
    notifyListeners();
    unawaited(_reportState());
  }

  /// El estado del mando al latido (Bug A): lo que se ve en la pantalla, también en el
  /// informe de la emisión. Que no llegue no cambia nada del mando.
  Future<void> _reportState() async {
    final Future<void> Function(String json)? sink = reportState;
    if (sink == null) {
      return;
    }
    try {
      await sink(jsonEncode(<String, Object?>{
        'serving': serving,
        'port': boundPort,
        'match_id': _engine?.matchId,
        'addresses': serving ? await addresses() : const <String>[],
        'can_pair': canPair,
        'problem': problem,
      }));
    } on Exception {
      // Sin canal o sin interfaces: el latido se queda con el estado anterior.
    }
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
    // Mientras el gol entra o sale, a `anim_fps`; el resto del tiempo el temporizador solo
    // mira un booleano.
    _animTick = Timer.periodic(
      Duration(milliseconds: Duration.millisecondsPerSecond ~/ OverlaySpec.goal['anim_fps']!),
      (_) {
        if (g.animating) {
          unawaited(g.refresh());
        }
      },
    );
    unawaited(g.refresh());
  }

  /// El vídeo del programa: con cada cambio y cada segundo, que es lo que tarda en verse
  /// un vídeo que se da por acabado sin aviso del nativo.
  void _startVideo(MatchEngine engine) {
    final VideoSink? sink = videoSink;
    if (sink == null) {
      return;
    }
    final ProgramVideo v = ProgramVideo(engine: engine, sink: sink);
    _video = v;
    _videoChanges = engine.changes.listen((_) => unawaited(v.refresh()));
    _videoTick = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(v.refresh()));
  }

  Future<void> _stopVideo() async {
    unawaited(_videoChanges?.cancel());
    _videoChanges = null;
    _videoTick?.cancel();
    _videoTick = null;
    final ProgramVideo? v = _video;
    _video = null;
    await v?.close();
  }

  /// La franja: el paquete vigente, cada uno nuevo y los eventos del partido. En el vóley,
  /// por ahora, nada (ADR 0031).
  Future<void> _startAds(MatchEngine engine) async {
    final AdSink? sink = adSink;
    if (sink == null || eventKind == EventKind.volleyball) {
      return;
    }
    final AdDirector director = AdDirector(sink);
    _ads = director;
    unawaited(director.observe(MatchSignals.of(engine)));
    _adChanges = engine.changes.listen((_) => unawaited(director.observe(MatchSignals.of(engine))));
    final AdPackDownloader? paquetes = adPacks;
    if (paquetes == null) {
      return;
    }
    _adPackSub = paquetes.packs.listen((AdPack p) => unawaited(director.load(p)));
    final AdPack? vigente = paquetes.current ?? paquetes.loadCurrent();
    if (vigente != null) {
      await director.load(vigente);
    }
  }

  void _stopAds() {
    unawaited(_adChanges?.cancel());
    _adChanges = null;
    unawaited(_adPackSub?.cancel());
    _adPackSub = null;
    _ads?.dispose();
    _ads = null;
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
    _animTick?.cancel();
    _animTick = null;
    _engineTick?.cancel();
    _engineTick = null;
    _graphics = null;
  }

  /// Deja de servir: otro móvil dirige, o se cerró la sesión.
  Future<void> stepDown() => _inTurn(() {
    _wantsMaster = false;
    return _stepDown();
  });

  Future<void> _stepDown() async {
    _stopGraphics();
    await _stopVideo();
    _stopReplica();
    _stopAds();
    final MasterApiServer? server = _server;
    _server = null;
    _engine = null;
    _secret = null;
    // Un fallo de arranque ya no es de este rol.
    final bool habiaProblema = problem != null;
    problem = null;
    if (server != null) {
      await server.close();
    }
    if (server != null || habiaProblema) {
      notifyListeners();
      unawaited(_reportState());
    }
  }

  /// Cambia el PIN del operador en el servidor que corre (ya guardado en el Keychain).
  void updateOperatorPin(String pin) {
    _server?.api.operatorPin = pin.isEmpty ? null : pin;
  }

  /// El texto del QR Mando, o null; [pairing] dice además por qué no.
  Future<String?> pairingText({bool stream = false}) async => (await pairing(stream: stream)).text;

  /// El QR Mando: este móvil, el otro y el VPS, con un token del partido. Sin QR, el
  /// motivo (Bug A: la hoja decía «sin secreto» por cualquier cosa) y, si se sirve, la
  /// dirección del panel para entrar a mano con el PIN.
  Future<MandoPairing> pairing({bool stream = false}) async {
    final MatchEngine? engine = _engine;
    final int? puerto = boundPort;
    if (engine == null || puerto == null) {
      return MandoPairing(reason: problem ?? mandoReasonNotServing);
    }
    final List<Uri> mias = <Uri>[
      for (final String ip in await _orNothing(addresses, const <String>[]))
        Uri(scheme: 'http', host: ip, port: puerto),
    ];
    final String otro = await _orNothing(peerAddress, '');
    // Sin dirección propia ni VPS no hay QR: el otro móvil solo sirve tras un relevo.
    if (mias.isEmpty && vpsUrl == null) {
      return const MandoPairing(reason: mandoReasonNoLan);
    }
    final List<int>? secreto = _secret;
    if (secreto == null) {
      return MandoPairing(reason: mandoReasonNoSecret, manual: mias);
    }
    final List<Uri> panels = <Uri>[
      ...mias,
      if (otro.isNotEmpty) Uri(scheme: 'http', host: otro, port: masterApiPort),
      ?vpsUrl,
    ];
    final String texto = PanelPairing.compose(
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
    return MandoPairing(text: texto, manual: mias);
  }

  /// Lo que devuelve `read`, o `nothing` si el canal o el sistema fallan: un fallo al
  /// mirar la red es «sin red», no una hoja colgada.
  static Future<T> _orNothing<T>(Future<T> Function() read, T nothing) async {
    try {
      return await read();
    } on Exception {
      return nothing;
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopGraphics();
    _stopReplica();
    _stopAds();
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
