/// La API `/api/v1` del mando servida por el maestro (IOS-62), porte de la parte de
/// `tools/live_panel.py` que la atiende (ADR 0017, con las enmiendas de los ADR 0022 y
/// 0023).
///
/// [MasterApi] no sabe de sockets: recibe un [ApiRequest] y devuelve un [ApiResponse].
/// Así la misma lógica atiende la LAN ([MasterApiServer], un HttpServer de dart:io) y,
/// con IOS-65, los `command` que llegan por el túnel del VPS.
///
/// - `GET /api/v1/match?since=<boot>:<rev>`: el partido al momento o, si el mando ya lo
///   tiene al día, en cuanto cambie (≤25 s); como mucho 8 esperas, la novena es un 503.
/// - `POST /api/v1/<orden>`: las órdenes de MatchEngine, con `Idempotency-Key`.
/// - `stream/*` es del VPS, que tiene el relé: se manda como `relay_command` y se espera
///   la respuesta [apiCommandTimeout] (504 si vence); sin túnel, 503.
/// - Errores en RFC 7807. `Authorization: Bearer` con el token de mando (ámbitos `match`
///   y, si se marcó, `stream`, nunca `rig`) o con el PIN del operador (los tres).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/idempotency.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

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

/// Una petición ya leída, venga de la LAN o del túnel. Las cabeceras, en minúsculas.
class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.path,
    this.query = const <String, String>{},
    this.headers = const <String, String>{},
    this.body,
  });

  final String method;

  /// Absoluto, con `/api/v1/` delante.
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;

  /// Los bytes del cuerpo, sin leer como JSON todavía.
  final List<int>? body;
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
      if (ruta != _matchRoute) {
        return ApiResponse.problem(HttpStatus.notFound, 'no existe ${request.path}');
      }
      return _match(request, acceso.$1!);
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

  // ------------------------------------------------------------------------- //
  // La puerta
  // ------------------------------------------------------------------------- //

  /// Los ámbitos de quien pregunta, o el error que hay que contestar.
  (Set<String>?, ApiResponse?) _access(ApiRequest request, String? scope) {
    final String cabecera = request.headers['authorization'] ?? '';
    if (!cabecera.startsWith(_bearerPrefix)) {
      return (null, ApiResponse.problem(HttpStatus.unauthorized, 'falta el token: escanea el $controlQrName'));
    }
    final String credencial = cabecera.substring(_bearerPrefix.length);
    final Set<String> ambitos;
    final String? pin = operatorPin;
    if (pin != null && pin.isNotEmpty && _sameText(credencial, pin)) {
      ambitos = _operatorScopes;
    } else {
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
        ambitos = claims.scopes.intersection(_tokenScopes);
      } on TokenError catch (error) {
        return (null, ApiResponse.problem(error.status, error.message));
      }
    }
    if (scope != null && !ambitos.contains(scope)) {
      return (null, ApiResponse.problem(HttpStatus.forbidden, 'este mando no tiene permiso de $scope'));
    }
    _noteDevice(request.headers[panelDeviceHeader.toLowerCase()], stream: ambitos.contains(panelScopeStream));
    return (ambitos, null);
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
    'clips/mark',
    'stream/start',
    'stream/stop',
  };

  /// Emitir o parar es `stream`; lo demás, `match` (`order_scope`).
  static String _scopeOf(String name) => name.startsWith('stream/') ? panelScopeStream : panelScopeMatch;

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
      final List<int>? cuerpo = await _readBody(request);
      if (cuerpo == null) {
        respuesta = ApiResponse.problem(
          HttpStatus.requestEntityTooLarge,
          'el cuerpo pasa de $apiMaxBodyBytes bytes',
        );
      } else {
        final Map<String, String> cabeceras = <String, String>{};
        request.headers.forEach((String nombre, List<String> valores) {
          cabeceras[nombre.toLowerCase()] = valores.join(',');
        });
        respuesta = await api.handle(ApiRequest(
          method: request.method,
          path: request.uri.path,
          query: request.uri.queryParameters,
          headers: cabeceras,
          body: cuerpo,
        ));
      }
    } on Exception {
      respuesta = ApiResponse.problem(HttpStatus.badRequest, 'peticion ilegible');
    }
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
