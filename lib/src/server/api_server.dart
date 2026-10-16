/// La API `/api/v1` del mando servida por el maestro (IOS-62), porte de la parte de
/// `tools/live_panel.py` que la atiende (ADR 0017, con las enmiendas de los ADR 0022 y
/// 0023).
///
/// [MasterApi] no sabe de sockets: recibe un [ApiRequest] y devuelve un [ApiResponse].
/// Así la misma lógica atiende la LAN ([MasterApiServer], un HttpServer de dart:io) y,
/// con IOS-65, los `command` que llegan por el túnel del VPS ([MasterApi.command], que
/// dice también qué `state` sale antes de la `response`).
///
/// - `GET /api/v1/match?since=<boot>:<rev>`: el partido al momento o, si el mando ya lo
///   tiene al día, en cuanto cambie (≤25 s); como mucho 8 esperas, la novena es un 503.
/// - `POST /api/v1/<orden>`: las órdenes de MatchEngine, con `Idempotency-Key`.
/// - `stream/*` es del VPS, que tiene el relé: se manda como `relay_command` y se espera
///   la respuesta [apiCommandTimeout] (504 si vence); sin túnel, 503.
/// - Errores en RFC 7807. `Authorization: Bearer` con el token de mando (ámbitos `match`
///   y, si se marcó, `stream`, nunca `rig`) o con el PIN del operador (los tres). Por el
///   túnel, `principal: operator` (el panel remoto) también tiene los tres.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart' show MatchTeam;
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/idempotency.dart';
import 'package:football_ai_capture/src/server/graphics_store.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/video_store.dart';

/// Tipo de los errores de la API (`PROBLEM_CONTENT_TYPE`, RFC 7807).
const String problemContentType = 'application/problem+json';

const String _jsonContentType = 'application/json';
const String _bearerPrefix = 'Bearer ';
const String _matchRoute = 'match';

/// Lo que un token de mando puede abrir en el maestro: `rig` no, aunque lo traiga
/// (ADR 0017, enmienda §3).
const Set<String> _tokenScopes = <String>{panelScopeMatch, panelScopeStream};

/// Lo que abre el PIN del operador.
const Set<String> _operatorScopes = <String>{panelScopeMatch, panelScopeStream, controlScopeRig};

/// Quién manda la petición. Por la LAN siempre es [bearer]: la credencial va en
/// `Authorization`. Por el túnel, el VPS dice [operator] cuando la orden es del panel
/// remoto, que ya entró con su contraseña y no trae `Authorization` (ADR 0022 §7).
enum ApiPrincipal { bearer, operator }

/// Una petición ya leída, venga de la LAN o del túnel. Las cabeceras, en minúsculas.
class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.path,
    this.query = const <String, String>{},
    this.headers = const <String, String>{},
    this.body,
    this.principal = ApiPrincipal.bearer,
  });

  /// El `data` de un `command` del túnel (ADR 0022 §6), ya validado por el lector del
  /// protocolo. Un `command` nunca espera, así que su `since` no se atiende (el hub ya lo
  /// quita). El cuerpo llega como objeto JSON: no hace falta que traiga `content-type`.
  factory ApiRequest.fromCommand(Map<String, Object?> data) {
    final Object? query = data['query'];
    final Object? headers = data['headers'];
    final Object? body = data['body'];
    final Map<String, String> cabeceras = <String, String>{
      if (headers is Map<String, Object?>)
        for (final MapEntry<String, Object?> e in headers.entries)
          if (e.value is String) e.key.toLowerCase(): e.value! as String,
    };
    if (body != null) {
      cabeceras.putIfAbsent('content-type', () => _jsonContentType);
    }
    return ApiRequest(
      method: data['method'] is String ? data['method']! as String : '',
      path: data['path'] is String ? data['path']! as String : '',
      query: <String, String>{
        if (query is String && query.isNotEmpty) ...Uri.splitQueryString(query),
      }..remove('since'),
      headers: cabeceras,
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      principal: data['principal'] == 'operator' ? ApiPrincipal.operator : ApiPrincipal.bearer,
    );
  }

  final String method;

  /// Absoluto, con `/api/v1/` delante.
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;

  /// Los bytes del cuerpo, sin leer como JSON todavía.
  final List<int>? body;
  final ApiPrincipal principal;
}

class ApiResponse {
  const ApiResponse(this.status, this.contentType, this.body);

  factory ApiResponse.json(Object? value, [int status = HttpStatus.ok]) =>
      ApiResponse(status, _jsonContentType, utf8.encode(jsonEncode(value)));

  /// Un error en RFC 7807 (`problem_body`). `current` es el partido de verdad, en los 409.
  factory ApiResponse.problem(int status, String detail, [Map<String, Object?>? current]) =>
      ApiResponse(
        status,
        problemContentType,
        utf8.encode(jsonEncode(<String, Object?>{
          'type': 'about:blank',
          'title': _phrase(status),
          'status': status,
          'detail': detail,
          'state': ?current,
        })),
      );

  final int status;
  final String contentType;
  final List<int> body;
}

/// Lo que contesta el maestro a un `command` del túnel (IOS-65).
class CommandReply {
  const CommandReply(this.state, this.response);

  /// El DTO sin `scopes` si la orden subió `rev`; null si no. El túnel lo manda como
  /// `state` **antes** que la `response`: el hub lee la conexión en orden, y así, cuando
  /// el mando recibe su respuesta, la caché del VPS ya tiene el `rev` nuevo y la espera
  /// larga que lanza después no le devuelve el partido de antes (ADR 0022, anotado al
  /// implementar NUBE-07). Un `state` con ese `rev` ya en la cola por delante vale igual.
  final Map<String, Object?>? state;
  final ApiResponse response;

  /// El `data` de la `response` del túnel: `{status, headers: {content-type}, body}`.
  Map<String, Object?> get responseData => <String, Object?>{
    'status': response.status,
    'headers': <String, String>{'content-type': response.contentType},
    'body': jsonDecode(utf8.decode(response.body)),
  };
}

/// Lo que pide `stream/*` al VPS por el túnel. Devuelve sin más si el relé aplicó la
/// orden, o lanza [OrderError] con el problema que contestó el VPS.
typedef RelayCommand = Future<void> Function(String action);

/// Un mando visto hace poco: su nombre y si puede emitir.
class ControlDevice {
  const ControlDevice(this.name, {required this.stream, required this.lastMs});

  final String name;
  final bool stream;
  final int lastMs;
}

class MasterApi {
  MasterApi({
    required this.engine,
    required this.monotonicMs,
    required this.wallS,
    this.controlSecret,
    this.operatorPin,
    this.relay,
    this.longPollTimeout = apiLongPollTimeout,
    this.commandTimeout = apiCommandTimeout,
    this.panelHtml,
    this.thumbnail,
    this.rigStatus,
  }) : _idempotency = IdempotencyCache(nowMs: monotonicMs);

  final MatchEngine engine;

  /// Reloj monótono en ms: la caché de claves y la lista de mandos.
  final int Function() monotonicMs;

  /// Hora de pared en segundos: solo para la caducidad de los tokens, que es de pared
  /// por definición (la comprueban el otro móvil y el VPS).
  final int Function() wallS;

  /// El secreto del mando de este partido (`deriveControlSecret`); sin él, solo el PIN.
  List<int>? controlSecret;

  /// El PIN del operador que guarda el maestro en el Keychain; sin él, solo tokens.
  String? operatorPin;

  /// El túnel al VPS; null sin túnel (entonces `stream/*` es un 503).
  RelayCommand? relay;

  final Duration longPollTimeout;
  final Duration commandTimeout;
  final IdempotencyCache _idempotency;

  /// La caché de idempotencia, para la réplica (IOS-82).
  IdempotencyCache get idempotency => _idempotency;

  /// El panel local (IOS-64), servido en `/` sin puerta: la página no lleva datos y
  /// toma el token del fragmento `#mando=` de la URL del QR.
  final String? panelHtml;

  /// La última miniatura JPEG de `left`, `right` o `program` (vacía si no hay).
  final Future<Uint8List> Function(String name)? thumbnail;

  /// El estado del soporte para el panel: enlace, térmica, escalera, fps…
  final Map<String, Object?> Function()? rigStatus;

  int _longPolls = 0;

  /// Esperas largas abiertas ahora mismo.
  int get longPolls => _longPolls;

  final Map<String, ControlDevice> _devices = <String, ControlDevice>{};

  /// Los mandos del último minuto, el más reciente primero.
  List<ControlDevice> devices() {
    final int ahora = monotonicMs();
    return _devices.values
        .where((ControlDevice d) => ahora - d.lastMs < apiControlDeviceRecent.inMilliseconds)
        .toList()
      ..sort((ControlDevice a, ControlDevice b) => b.lastMs.compareTo(a.lastMs));
  }

  static const List<String> _thumbNames = <String>['left', 'right', 'program'];

  Future<ApiResponse> handle(ApiRequest request) async {
    final String? html = panelHtml;
    if (request.method == 'GET' && (request.path == '/' || request.path == '/index.html') && html != null) {
      return ApiResponse(HttpStatus.ok, 'text/html; charset=utf-8', utf8.encode(html));
    }
    if (!request.path.startsWith(panelApiPrefix)) {
      return ApiResponse.problem(HttpStatus.notFound, 'no existe ${request.path}');
    }
    final String ruta = request.path.substring(panelApiPrefix.length);
    if (request.method == 'GET') {
      final (Set<String>?, ApiResponse?) acceso = _access(request, null);
      if (acceso.$2 != null) {
        return acceso.$2!;
      }
      if (ruta.startsWith('rig/thumb/') && thumbnail != null) {
        final String nombre = ruta.substring('rig/thumb/'.length);
        if (!_thumbNames.contains(nombre)) {
          return ApiResponse.problem(HttpStatus.notFound, 'no hay miniatura de $nombre');
        }
        final Uint8List jpeg = await thumbnail!(nombre);
        return jpeg.isEmpty
            ? ApiResponse.problem(HttpStatus.notFound, 'todavía no hay miniatura de $nombre')
            : ApiResponse(HttpStatus.ok, 'image/jpeg', jpeg);
      }
      if (ruta == 'rig/status' && rigStatus != null) {
        return ApiResponse.json(rigStatus!());
      }
      if (ruta == championshipAssetRoute) {
        // El icono del campeonato (ADR 0027), para que el mando lo enseñe.
        final String? tipo = engine.graphics.iconMime;
        return tipo == null
            ? ApiResponse.problem(HttpStatus.notFound, 'no hay icono del campeonato')
            : ApiResponse(HttpStatus.ok, tipo, await engine.graphics.iconFile.readAsBytes());
      }
      final String? franja = stripNamed(request.path);
      if (franja != null) {
        // La imagen de una franja guardada (enmienda del ADR 0027 del 2026-10-16).
        final StripImage? img = engine.graphics.stripImageFor(franja);
        return img == null
            ? ApiResponse.problem(HttpStatus.notFound, 'la franja $franja no tiene imagen')
            : ApiResponse(HttpStatus.ok, img.mime, await img.file.readAsBytes());
      }
      final String? ranura = crestSlot(request.path), nombrado = crestNamed(request.path);
      if (ranura != null || nombrado != null) {
        // El escudo del equipo de esa ranura (ADR 0028 y 0029), o el del nombre (ADR 0030).
        final String? equipo = nombrado ?? engine.crestTeam(ranura!);
        final TeamCrest? escudo = equipo == null ? null : engine.graphics.crestFor(equipo);
        return escudo == null
            ? ApiResponse.problem(HttpStatus.notFound, '${equipo ?? 'el próximo partido'} no tiene escudo')
            : ApiResponse(HttpStatus.ok, escudo.mime, await escudo.file.readAsBytes());
      }
      if (ruta == videosRoute) {
        return ApiResponse.json(<String, Object?>{
          'videos': <Map<String, Object?>>[for (final VideoInfo v in engine.videos.list()) v.toJson()],
        });
      }
      if (ruta != _matchRoute) {
        return ApiResponse.problem(HttpStatus.notFound, 'no existe ${request.path}');
      }
      return _match(request, acceso.$1!);
    }
    if (request.method == 'DELETE' && ruta == championshipAssetRoute) {
      final (Set<String>?, ApiResponse?) acceso = _access(request, panelScopeMatch);
      if (acceso.$2 != null) {
        return acceso.$2!;
      }
      engine.deleteChampionshipIcon();
      return ApiResponse.json(engine.toJson(scopes: acceso.$1!));
    }
    final String? escudo = crestSlot(request.path), escudoNombrado = crestNamed(request.path);
    if (request.method == 'DELETE' && (escudo != null || escudoNombrado != null)) {
      final (Set<String>?, ApiResponse?) acceso = _access(request, panelScopeMatch);
      if (acceso.$2 != null) {
        return acceso.$2!;
      }
      final String? equipo = escudoNombrado ?? engine.crestTeam(escudo!);
      if (equipo == null) {
        return ApiResponse.problem(HttpStatus.conflict, 'no hay próximo partido');
      }
      engine.deleteCrestFor(equipo);
      return ApiResponse.json(engine.toJson(scopes: acceso.$1!));
    }
    final String? franja = stripNamed(request.path);
    if (request.method == 'DELETE' && franja != null) {
      final (Set<String>?, ApiResponse?) acceso = _access(request, panelScopeMatch);
      if (acceso.$2 != null) {
        return acceso.$2!;
      }
      engine.deleteStripImage(franja);
      return ApiResponse.json(engine.toJson(scopes: acceso.$1!));
    }
    final String? video = videoName(request.path);
    if (request.method == 'DELETE' && video != null) {
      final (Set<String>?, ApiResponse?) acceso = _access(request, panelScopeMatch);
      if (acceso.$2 != null) {
        return acceso.$2!;
      }
      if (engine.video?.name == video) {
        return ApiResponse.problem(HttpStatus.conflict, '$video está sonando: páralo antes de borrarlo');
      }
      return engine.videos.delete(video)
          ? ApiResponse.json(<String, Object?>{'deleted': video})
          : ApiResponse.problem(HttpStatus.notFound, 'no hay ningún vídeo que se llame $video');
    }
    if (request.method != 'POST') {
      return ApiResponse.problem(HttpStatus.methodNotAllowed, 'solo GET y POST');
    }
    final bool conocida = _orders.contains(ruta);
    final (Set<String>?, ApiResponse?) acceso = _access(request, conocida ? _scopeOf(ruta) : null);
    if (acceso.$2 != null) {
      return acceso.$2!;
    }
    if (!conocida) {
      return ApiResponse.problem(HttpStatus.notFound, 'orden desconocida: $ruta');
    }
    return _order(ruta, request, acceso.$1!);
  }

  /// Un `command` del túnel (IOS-65), con los mismos manejadores que la LAN. Por el túnel
  /// solo llega lo que el hub reenvía: el partido y las órdenes. `stream/*` lo atiende el
  /// propio VPS, que tiene el relé, y las miniaturas y el estado del soporte los sirve el
  /// hub (ADR 0022 §7 y §12): 404.
  Future<CommandReply> command(ApiRequest request) async {
    final String ruta = request.path.startsWith(panelApiPrefix)
        ? request.path.substring(panelApiPrefix.length)
        : request.path;
    if ((request.method == 'GET' && ruta != _matchRoute) || ruta.startsWith('stream/')) {
      return CommandReply(null, ApiResponse.problem(HttpStatus.notFound, 'por el tunel no se sirve ${request.path}'));
    }
    final int antes = engine.rev;
    final ApiResponse respuesta = await handle(request);
    return CommandReply(engine.rev == antes ? null : stateDto(), respuesta);
  }

  /// La puerta de una subida por la LAN (ADR 0027): los ámbitos de quien sube, o el error
  /// que hay que contestar antes de leer un solo byte del cuerpo.
  (Set<String>?, ApiResponse?) uploadAccess(Map<String, String> headers) =>
      _access(ApiRequest(method: 'PUT', path: '', headers: headers), panelScopeMatch);

  /// La ranura de una ruta `/api/v1/assets/crest/<ranura>`: `home` y `away` (ADR 0028),
  /// `next_home` y `next_away` (ADR 0029); null si la ruta no es de un escudo.
  static String? crestSlot(String path) {
    for (final String ranura in const <String>['home', 'away', 'next_home', 'next_away']) {
      if (path == '$panelApiPrefix$teamCrestAssetRoute/$ranura') {
        return ranura;
      }
    }
    return null;
  }

  /// La franja guardada de una ruta `/api/v1/assets/strip/<nombre>`, ya sin el %-escapado;
  /// null si la ruta no es de la imagen de una franja.
  static String? stripNamed(String path) {
    const String prefijo = '$panelApiPrefix$stripImageRoute/';
    if (!path.startsWith(prefijo)) {
      return null;
    }
    try {
      final String nombre = Uri.decodeComponent(path.substring(prefijo.length)).trim();
      return nombre.isEmpty || nombre.length > stripPresetNameMaxChars || nombre.contains('/') ? null : nombre;
    } on ArgumentError {
      return null;
    }
  }

  /// El equipo de una ruta `/api/v1/assets/crests/<nombre>` (ADR 0030), ya sin el
  /// %-escapado; null si la ruta no es de un escudo por nombre.
  static String? crestNamed(String path) {
    const String prefijo = '$panelApiPrefix$teamCrestsByNameRoute/';
    if (!path.startsWith(prefijo)) {
      return null;
    }
    try {
      final String nombre = Uri.decodeComponent(path.substring(prefijo.length)).trim();
      return nombre.isEmpty || nombre.length > matchTeamNameMaxChars || nombre.contains('/') ? null : nombre;
    } on ArgumentError {
      return null;
    }
  }

  /// El nombre del vídeo de una ruta `/api/v1/videos/<nombre>` (ya sin el %-escapado), o
  /// null si la ruta no es de un vídeo.
  static String? videoName(String path) {
    const String prefijo = '$panelApiPrefix$videosRoute/';
    if (!path.startsWith(prefijo)) {
      return null;
    }
    try {
      final String nombre = Uri.decodeComponent(path.substring(prefijo.length));
      return nombre.isEmpty || nombre.contains('/') ? null : nombre;
    } on ArgumentError {
      return null;
    }
  }

  /// El DTO del `state` del túnel: sin `scopes`, que son de cada petición (ADR 0022 §5).
  Map<String, Object?> stateDto() => engine.toJson()..remove('scopes');

  // ------------------------------------------------------------------------- //
  // La puerta
  // ------------------------------------------------------------------------- //

  /// Los ámbitos de quien pregunta, o el error que hay que contestar.
  (Set<String>?, ApiResponse?) _access(ApiRequest request, String? scope) {
    final bool operador = request.principal == ApiPrincipal.operator;
    final (Set<String>?, ApiResponse?) quien = operador ? (_operatorScopes, null) : _bearer(request);
    final Set<String>? ambitos = quien.$1;
    if (ambitos == null) {
      return quien;
    }
    if (scope != null && !ambitos.contains(scope)) {
      return (null, ApiResponse.problem(HttpStatus.forbidden, 'este mando no tiene permiso de $scope'));
    }
    final String? dispositivo = request.headers[panelDeviceHeader.toLowerCase()];
    // El panel remoto sin nombre no es un mando: el hub ya lleva su propia lista.
    if (!operador || dispositivo != null) {
      _noteDevice(dispositivo, stream: ambitos.contains(panelScopeStream));
    }
    return (ambitos, null);
  }

  /// Los ámbitos del `Authorization: Bearer`: el PIN del operador o un token de mando.
  (Set<String>?, ApiResponse?) _bearer(ApiRequest request) {
    final String cabecera = request.headers['authorization'] ?? '';
    if (!cabecera.startsWith(_bearerPrefix)) {
      return (null, ApiResponse.problem(HttpStatus.unauthorized, 'falta el token: escanea el $controlQrName'));
    }
    final String credencial = cabecera.substring(_bearerPrefix.length);
    final String? pin = operatorPin;
    if (pin != null && pin.isNotEmpty && _sameText(credencial, pin)) {
      return (_operatorScopes, null);
    }
    final List<int>? secreto = controlSecret;
    if (secreto == null) {
      return (null, ApiResponse.problem(HttpStatus.unauthorized, 'token no valido: escanea el $controlQrName'));
    }
    try {
      final ControlClaims claims = verifyToken(
        secreto,
        credencial,
        matchId: engine.matchId,
        nowS: wallS(),
      );
      return (claims.scopes.intersection(_tokenScopes), null);
    } on TokenError catch (error) {
      return (null, ApiResponse.problem(error.status, error.message));
    }
  }

  void _noteDevice(String? header, {required bool stream}) {
    final String nombre = deviceName(header);
    _devices.remove(nombre);
    _devices[nombre] = ControlDevice(nombre, stream: stream, lastMs: monotonicMs());
    while (_devices.length > apiMaxControlDevices) {
      _devices.remove(_devices.keys.first);
    }
  }

  // ------------------------------------------------------------------------- //
  // GET /api/v1/match
  // ------------------------------------------------------------------------- //

  Future<ApiResponse> _match(ApiRequest request, Set<String> scopes) async {
    final String pedido = request.query['since'] ?? '';
    (String, int)? visto;
    if (pedido.isNotEmpty) {
      visto = parseSince(pedido);
      if (visto == null) {
        return ApiResponse.problem(HttpStatus.badRequest, 'since tiene que ser <boot>:<rev>');
      }
    }
    if (visto == (engine.boot, engine.rev)) {
      if (_longPolls >= apiMaxLongPolls) {
        return ApiResponse.problem(
          HttpStatus.serviceUnavailable,
          'demasiados mandos esperando: pide otra vez sin since',
        );
      }
      _longPolls++;
      try {
        await engine.changes.first.timeout(longPollTimeout);
      } on TimeoutException {
        // Nada nuevo en todo el plazo: se contesta lo mismo y el mando vuelve a preguntar.
      } finally {
        _longPolls--;
      }
    }
    return ApiResponse.json(engine.toJson(scopes: scopes));
  }

  // ------------------------------------------------------------------------- //
  // POST /api/v1/<orden>
  // ------------------------------------------------------------------------- //

  static const Set<String> _orders = <String>{
    'match/goal',
    'match/score',
    'match/clock',
    'match/lineup',
    'match/roster',
    'match/teams',
    'graphics/halftime',
    'graphics/fulltime',
    'graphics/next_match',
    'match/next',
    'graphics/fixtures',
    'match/fixtures',
    'graphics/interview',
    'match/interview',
    'graphics/strip',
    'graphics/strip_texts',
    'graphics/strip_save',
    'graphics/strip_delete',
    'video/play',
    'video/stop',
    'clips/mark',
    'stream/start',
    'stream/stop',
  };

  /// Emitir o parar es `stream`; las plantillas, `rig` (ADR 0017 enmienda §2: el QR
  /// Mando no las edita); lo demás, `match` (`order_scope`).
  static String _scopeOf(String name) => switch (name) {
    'match/roster' => controlScopeRig,
    _ when name.startsWith('stream/') => panelScopeStream,
    _ => panelScopeMatch,
  };

  Future<ApiResponse> _order(String name, ApiRequest request, Set<String> scopes) async {
    final String? clave = request.headers['idempotency-key'];
    if (clave != null && !validIdempotencyKey(clave)) {
      return ApiResponse.problem(HttpStatus.badRequest, 'Idempotency-Key: hasta 128 letras, cifras o ._:-');
    }
    final String tipo = (request.headers['content-type'] ?? '').split(';').first.trim();
    if (tipo != _jsonContentType) {
      return ApiResponse.problem(HttpStatus.unsupportedMediaType, 'se espera $_jsonContentType');
    }
    final Object? cuerpo;
    try {
      cuerpo = jsonDecode(utf8.decode(request.body ?? const <int>[]));
    } on FormatException {
      return ApiResponse.problem(HttpStatus.badRequest, 'cuerpo JSON invalido');
    }
    if (cuerpo is! Map<String, Object?>) {
      return ApiResponse.problem(HttpStatus.badRequest, 'se espera un objeto JSON');
    }
    final Map<String, Object?> orden = cuerpo;
    Future<StoredResponse> responder() async {
      final ApiResponse r = await _apply(name, orden, scopes);
      return StoredResponse(r.status, r.contentType, r.body);
    }

    // La clave va junto al nombre: la misma clave en otra orden es otra orden.
    final StoredResponse r =
        clave == null ? await responder() : await _idempotency.run('$name $clave', responder);
    return ApiResponse(r.status, r.contentType, r.body);
  }

  Future<ApiResponse> _apply(String name, Map<String, Object?> body, Set<String> scopes) async {
    final List<String> ambitos = scopes.toList()..sort();
    if (name.startsWith('stream/')) {
      return _stream(name, ambitos);
    }
    if (name == 'match/roster') {
      return _roster(body, ambitos);
    }
    try {
      final Map<String, Object?> partido = engine.apply(name, body);
      return ApiResponse.json(<String, Object?>{...partido, 'scopes': ambitos});
    } on OrderError catch (error) {
      final Map<String, Object?>? actual = error.current;
      return ApiResponse.problem(
        error.status,
        error.message,
        actual == null ? null : <String, Object?>{...actual, 'scopes': ambitos},
      );
    }
  }

  /// `match/roster` {team, name, coach, formation, roster}: la plantilla tecleada, pegada
  /// o en CSV, leída con las reglas de tools/lineup.py (IOS-87). El nombre pasa al
  /// marcador.
  ApiResponse _roster(Map<String, Object?> body, List<String> ambitos) {
    final Object? equipo = body['team'];
    final MatchTeam? lado = equipo == 'home' ? MatchTeam.home : (equipo == 'away' ? MatchTeam.away : null);
    if (lado == null) {
      return ApiResponse.problem(HttpStatus.badRequest, 'team tiene que ser home o away');
    }
    String texto(String k) => body[k] is String ? body[k]! as String : '';
    try {
      engine.saveLineup(lado, texto('name'), texto('formation'), texto('roster'), coach: texto('coach'));
    } on LineupError catch (error) {
      return ApiResponse.problem(HttpStatus.badRequest, error.message);
    }
    return ApiResponse.json(<String, Object?>{...engine.toJson(), 'scopes': ambitos});
  }

  /// `stream/*` desde la LAN: el relé está en el VPS (ADR 0022). El maestro no cambia
  /// `streaming` aquí; lo cambia el `relay_state` que manda el VPS al aplicarlo.
  Future<ApiResponse> _stream(String name, List<String> ambitos) async {
    final RelayCommand? tunel = relay;
    if (tunel == null) {
      return ApiResponse.problem(HttpStatus.serviceUnavailable, 'sin tunel al rele: no se puede emitir');
    }
    try {
      await tunel(name.substring('stream/'.length)).timeout(commandTimeout);
    } on TimeoutException {
      return ApiResponse.problem(HttpStatus.gatewayTimeout, 'el rele no contesto a tiempo');
    } on OrderError catch (error) {
      return ApiResponse.problem(error.status, error.message);
    }
    return ApiResponse.json(<String, Object?>{...engine.toJson(), 'scopes': ambitos});
  }
}

/// El `<boot>:<rev>` de `?since=`, o null si no lo es (`parse_since`).
(String, int)? parseSince(String text) {
  final int dos = text.indexOf(':');
  if (dos <= 0) {
    return null;
  }
  final String rev = text.substring(dos + 1);
  if (rev.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(rev)) {
    return null;
  }
  return (text.substring(0, dos), int.parse(rev));
}

/// El nombre del móvil de `X-Zero-Device`, en algo que se pueda pintar sin riesgo
/// (`device_name`): sin caracteres de control y acotado.
String deviceName(String? header) {
  String texto;
  try {
    texto = Uri.decodeComponent(header ?? '');
  } on ArgumentError {
    texto = header ?? '';
  }
  final String limpio = String.fromCharCodes(
    texto.runes.where((int c) => c >= 0x20 && c != 0x7f && !(c >= 0x80 && c < 0xa0)),
  ).trim();
  final String corto = String.fromCharCodes(limpio.runes.take(apiMaxDeviceNameChars));
  return corto.isEmpty ? 'sin nombre' : corto;
}

/// En tiempo constante, como `hmac.compare_digest`.
bool _sameText(String a, String b) {
  final List<int> x = utf8.encode(a);
  final List<int> y = utf8.encode(b);
  int diferencia = x.length ^ y.length;
  for (int i = 0; i < x.length && i < y.length; i++) {
    diferencia |= x[i] ^ y[i];
  }
  return diferencia == 0;
}

String _phrase(int status) => switch (status) {
  HttpStatus.badRequest => 'Bad Request',
  HttpStatus.unauthorized => 'Unauthorized',
  HttpStatus.forbidden => 'Forbidden',
  HttpStatus.notFound => 'Not Found',
  HttpStatus.methodNotAllowed => 'Method Not Allowed',
  HttpStatus.conflict => 'Conflict',
  HttpStatus.gone => 'Gone',
  HttpStatus.requestEntityTooLarge => 'Request Entity Too Large',
  HttpStatus.unsupportedMediaType => 'Unsupported Media Type',
  HttpStatus.insufficientStorage => 'Insufficient Storage',
  HttpStatus.serviceUnavailable => 'Service Unavailable',
  HttpStatus.gatewayTimeout => 'Gateway Timeout',
  _ => 'Error',
};

/// [MasterApi] en la LAN: un HttpServer de dart:io en [masterApiPort].
class MasterApiServer {
  MasterApiServer._(this._server, this.api);

  final HttpServer _server;
  final MasterApi api;

  int get port => _server.port;

  static Future<MasterApiServer> start(
    MasterApi api, {
    Object? address,
    int port = masterApiPort,
  }) async {
    final HttpServer server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    final MasterApiServer s = MasterApiServer._(server, api);
    server.listen((HttpRequest r) => unawaited(s._serve(r)));
    return s;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    ApiResponse respuesta;
    try {
      if (request.method == 'PUT' && request.uri.path == '$panelApiPrefix$championshipAssetRoute') {
        final MatchEngine motor = api.engine;
        respuesta = await _putImage(
          request,
          que: 'el icono',
          maxBytes: championshipIconMaxBytes,
          destino: motor.graphics.uploadFile,
          adoptar: motor.adoptChampionshipIcon,
        );
        await _reply(request, respuesta);
        return;
      }
      final String? franja = MasterApi.stripNamed(request.uri.path);
      if (request.method == 'PUT' && franja != null) {
        final MatchEngine motor = api.engine;
        if (!motor.graphics.stripPresets.any((StripPreset p) => p.name.toUpperCase() == franja.toUpperCase())) {
          await request.drain<void>();
          respuesta = ApiResponse.problem(HttpStatus.notFound, 'no hay ninguna franja que se llame $franja');
        } else {
          respuesta = await _putImage(
            request,
            que: 'la imagen de la franja',
            maxBytes: stripImageMaxBytes,
            destino: motor.graphics.stripImageUploadFile,
            adoptar: (String tipo) => motor.adoptStripImage(franja, tipo),
          );
        }
        await _reply(request, respuesta);
        return;
      }
      final String? escudo = MasterApi.crestSlot(request.uri.path);
      final String? escudoNombrado = MasterApi.crestNamed(request.uri.path);
      if (request.method == 'PUT' && (escudo != null || escudoNombrado != null)) {
        final MatchEngine motor = api.engine;
        final String? equipo = escudoNombrado ?? motor.crestTeam(escudo!);
        if (equipo == null) {
          await request.drain<void>();
          respuesta = ApiResponse.problem(HttpStatus.conflict, 'no hay próximo partido: guárdalo antes');
        } else {
          respuesta = await _putImage(
            request,
            que: 'el escudo',
            maxBytes: teamCrestMaxBytes,
            destino: motor.graphics.crestUploadFile,
            adoptar: (String tipo) => motor.adoptCrestFor(equipo, tipo),
          );
        }
        await _reply(request, respuesta);
        return;
      }
      final String? video = MasterApi.videoName(request.uri.path);
      if (request.method == 'PUT' && video != null) {
        respuesta = await _putVideo(request, video);
        await _reply(request, respuesta);
        return;
      }
      final List<int>? cuerpo = await _readBody(request);
      if (cuerpo == null) {
        respuesta = ApiResponse.problem(
          HttpStatus.requestEntityTooLarge,
          'el cuerpo pasa de $apiMaxBodyBytes bytes',
        );
      } else {
        respuesta = await api.handle(ApiRequest(
          method: request.method,
          path: request.uri.path,
          query: request.uri.queryParameters,
          headers: _headers(request),
          body: cuerpo,
        ));
      }
    } on Exception {
      respuesta = ApiResponse.problem(HttpStatus.badRequest, 'peticion ilegible');
    }
    await _reply(request, respuesta);
  }

  static Map<String, String> _headers(HttpRequest request) {
    final Map<String, String> cabeceras = <String, String>{};
    request.headers.forEach((String nombre, List<String> valores) {
      cabeceras[nombre.toLowerCase()] = valores.join(',');
    });
    return cabeceras;
  }

  /// Una imagen del gráfico: el icono del campeonato (ADR 0027) o el escudo de un equipo
  /// (ADR 0028). La puerta antes del cuerpo, y el cuerpo a disco en `destino`, con su tope,
  /// sin pasar entero por la memoria. Solo se adopta si es PNG o JPEG de verdad y llegó
  /// entero; `que` es cómo la llama el mensaje de error.
  Future<ApiResponse> _putImage(
    HttpRequest request, {
    required String que,
    required int maxBytes,
    required File destino,
    required void Function(String mime) adoptar,
  }) async {
    final (Set<String>?, ApiResponse?) acceso = api.uploadAccess(_headers(request));
    if (acceso.$2 != null) {
      await request.drain<void>();
      return acceso.$2!;
    }
    if (request.contentLength > maxBytes) {
      await request.drain<void>();
      return ApiResponse.problem(HttpStatus.requestEntityTooLarge, '$que pasa de ${maxBytes ~/ (1024 * 1024)} MB');
    }
    destino.parent.createSync(recursive: true);
    final IOSink salida = destino.openWrite();
    final List<int> cabeza = <int>[];
    int total = 0;
    bool grande = false;
    try {
      await for (final List<int> trozo in request) {
        total += trozo.length;
        // Pasado el tope se sigue leyendo sin escribir: si se deja de leer, dart:io corta
        // la conexión y el mando no recibe el 413 que explica por qué.
        grande = grande || total > maxBytes;
        if (grande) {
          continue;
        }
        if (cabeza.length < 16) {
          cabeza.addAll(trozo.take(16 - cabeza.length));
        }
        salida.add(trozo);
      }
    } finally {
      await salida.close();
    }
    final String? tipo = GraphicsStore.sniff(cabeza);
    if (grande || tipo == null) {
      destino.deleteSync();
      return grande
          ? ApiResponse.problem(HttpStatus.requestEntityTooLarge, '$que pasa de ${maxBytes ~/ (1024 * 1024)} MB')
          : ApiResponse.problem(HttpStatus.unsupportedMediaType, '$que tiene que ser PNG o JPEG');
    }
    adoptar(tipo);
    return ApiResponse.json(api.engine.toJson(scopes: acceso.$1!));
  }

  /// Un vídeo (ADR 0027): la puerta, el nombre, el tope y la reserva de grabación antes
  /// del cuerpo; el cuerpo a disco por trozos, y solo se adopta si es un MP4 que se lee.
  Future<ApiResponse> _putVideo(HttpRequest request, String nombre) async {
    final (Set<String>?, ApiResponse?) acceso = api.uploadAccess(_headers(request));
    if (acceso.$2 != null) {
      await request.drain<void>();
      return acceso.$2!;
    }
    final VideoStore store = api.engine.videos;
    try {
      store.checkUpload(nombre, request.contentLength);
    } on VideoError catch (error) {
      await request.drain<void>();
      return ApiResponse.problem(error.status, error.message);
    }
    if (api.engine.video?.name == nombre) {
      await request.drain<void>();
      return ApiResponse.problem(HttpStatus.conflict, '$nombre está sonando: páralo antes de cambiarlo');
    }
    store.directory.createSync(recursive: true);
    final File destino = store.uploadFile(nombre);
    final IOSink salida = destino.openWrite();
    int total = 0;
    bool grande = false;
    try {
      await for (final List<int> trozo in request) {
        total += trozo.length;
        // Como el icono: pasado el tope se sigue leyendo sin escribir, para que llegue el 413.
        grande = grande || total > videoMaxBytes;
        if (!grande) {
          salida.add(trozo);
        }
      }
    } finally {
      await salida.close();
    }
    if (grande) {
      destino.deleteSync();
      return ApiResponse.problem(HttpStatus.requestEntityTooLarge, 'el vídeo pasa de ${videoMaxBytes ~/ (1 << 30)} GB');
    }
    try {
      return ApiResponse.json(store.adopt(nombre).toJson());
    } on VideoError catch (error) {
      return ApiResponse.problem(error.status, error.message);
    }
  }

  static Future<void> _reply(HttpRequest request, ApiResponse respuesta) async {
    try {
      request.response
        ..statusCode = respuesta.status
        ..headers.set(HttpHeaders.contentTypeHeader, respuesta.contentType)
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = respuesta.body.length
        ..add(respuesta.body);
      await request.response.close();
    } on Exception {
      // El mando se fue antes de la respuesta: reintentará con la misma clave.
    }
  }

  /// El cuerpo entero, o null si pasa de [apiMaxBodyBytes].
  static Future<List<int>?> _readBody(HttpRequest request) async {
    if (request.contentLength > apiMaxBodyBytes) {
      return null;
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> trozo in request) {
      bytes.add(trozo);
      if (bytes.length > apiMaxBodyBytes) {
        return null;
      }
    }
    return bytes.takeBytes();
  }
}
