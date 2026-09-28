/// Subir la grabación de este móvil al panel para calibrar el soporte (ADR 0012).
///
/// Calibrar con lo que llega por la emisión no sirve por Starlink: a 1 Mbit/s un 4K no
/// tiene esquinas, y un móvil que llega segundos tarde deja al panel sin parejas. La
/// grabación del propio móvil —4K a 45 Mbit/s, con el código de tiempo pintado— sí sirve.
/// Esto la sube al panel; cuando tiene las dos, el panel calibra solo (`rig_recordings.py`
/// y `calibrate_from_recordings.py` en el repo `football-ai`).
///
/// **Por trozos, y reanudable.** Diez segundos son ~56 MB y el enlace saca 1–2 Mbit/s por
/// conexión: minutos, en los que Starlink corta. Cada trozo lleva su desplazamiento; si uno
/// falla, se pregunta al panel dónde se quedó y se sigue desde ahí.
///
/// En Dart y no en nativo a propósito: es HTTP normal, y así se prueba sin un iPhone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// Ruta del panel que recibe las grabaciones (`RIG_RECORDING_PATH`).
const String recordingUploadPath = '/api/rig/recording';

/// Dónde está el panel, sacado del campo «Servidor».
///
/// En un pod, el QR lo trae en `?panel=`: el panel va por el proxy de RunPod y el móvil no
/// lo puede deducir de la IP del RTMP. Sin eso, es el servidor de la cancha (el Mac), con
/// el panel en su puerto de siempre. `null` si no hay servidor.
Uri? panelUriFrom(String server) {
  final String text = server.trim();
  if (text.isEmpty) {
    return null;
  }
  final Uri? uri = Uri.tryParse(text.contains('://') ? text : 'srt://$text');
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  final String? panel = uri.queryParameters['panel'];
  if (panel != null && panel.isNotEmpty) {
    final Uri? parsed = Uri.tryParse(panel);
    final bool web =
        parsed != null && (parsed.scheme == 'https' || parsed.scheme == 'http');
    return web && parsed.host.isNotEmpty ? parsed : null;
  }
  return Uri(scheme: 'http', host: uri.host, port: localPanelPort);
}

/// Usuario y contraseña de las cámaras, del mismo campo, o `null` si no lleva. Son los
/// que el panel acepta para subir, y solo para esto.
({String user, String password})? cameraCredentialsFrom(String server) {
  final String text = server.trim();
  final Uri? uri = Uri.tryParse(text.contains('://') ? text : 'srt://$text');
  if (uri == null || uri.userInfo.isEmpty || !uri.userInfo.contains(':')) {
    return null;
  }
  final List<String> parts = uri.userInfo
      .split(':')
      .map(Uri.decodeComponent)
      .toList();
  return (user: parts.first, password: parts.skip(1).join(':'));
}

/// Un fallo que la pantalla puede enseñar tal cual.
class CalibrationUploadException implements Exception {
  CalibrationUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Behind implements Exception {
  _Behind(this.bytes);

  /// Dónde se quedó la subida según el panel.
  final int bytes;
}

/// Sube una grabación al panel, trozo a trozo.
/// Cómo acabó una calibración en el panel, tal como se la cuenta al móvil.
class CalibrationResult {
  const CalibrationResult({
    required this.attempt,
    required this.ok,
    required this.message,
    required this.hint,
  });

  /// Cuántas veces se ha calibrado en este panel. Sirve para saber si el resultado que
  /// llega es el de esta vez o el de antes.
  final int attempt;
  final bool ok;

  /// Qué pasó, con los números del servidor.
  final String message;

  /// Qué tocar si falló. Vacío si salió bien.
  final String hint;
}

class CalibrationUploader {
  CalibrationUploader({
    required this.panel,
    required this.role,
    this.credentials,
    HttpClient? client,
    this.chunkBytes = calibrationChunkBytes,
    this.maxRetries = calibrationMaxRetries,
    this.retryDelay = calibrationRetryDelay,
    this.requestTimeout = calibrationRequestTimeout,
  }) : _client = client ?? HttpClient();

  final Uri panel;
  final CameraRole role;
  final ({String user, String password})? credentials;
  final int chunkBytes;
  final int maxRetries;
  final Duration retryDelay;
  final Duration requestTimeout;
  final HttpClient _client;

  String get _side => role == CameraRole.left ? 'left' : 'right';

  /// Sube `file` entero. Devuelve `true` si con esta ya están las dos y el panel se pone a
  /// calibrar. Lanza [CalibrationUploadException] con el motivo si no se pudo.
  Future<bool> upload(
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final int total = await file.length();
    if (total == 0) {
      throw CalibrationUploadException('la grabación está vacía');
    }
    final RandomAccessFile reader = await file.open();
    try {
      int offset = 0;
      int failures = 0;
      while (offset < total) {
        final int length = math.min(chunkBytes, total - offset);
        await reader.setPosition(offset);
        final List<int> chunk = await reader.read(length);
        try {
          final Map<String, Object?> reply = await _send(
            'POST',
            <String, String>{'offset': '$offset'},
            chunk,
          );
          offset = (reply['bytes'] as num?)?.toInt() ?? offset + length;
          failures = 0;
          onProgress?.call(offset, total);
        } on _Behind catch (behind) {
          offset = behind.bytes;
        } on CalibrationUploadException {
          rethrow;
        } on Exception {
          // La red: se espera, se pregunta dónde se quedó y se sigue desde ahí.
          failures++;
          if (failures > maxRetries) {
            throw CalibrationUploadException(
              'la red no deja subir la grabación: se cortó $failures veces',
            );
          }
          await Future<void>.delayed(retryDelay);
          offset = await _serverBytes(fallback: offset);
        }
      }
      final Map<String, Object?> done = await _send('POST', <String, String>{
        'finish': '$total',
      }, const <int>[]);
      return done['calibrating'] == true;
    } finally {
      await reader.close();
    }
  }

  /// Cómo fue la calibración, esperando a que el panel la termine.
  ///
  /// El panel calibra en su hilo en cuanto tiene las dos grabaciones, así que no hay una
  /// respuesta que esperar: se pregunta cada `pollDelay` hasta que conteste con un
  /// intento nuevo. `null` si se acaba el tiempo, que es distinto de «falló»: no se sabe.
  Future<CalibrationResult?> waitForResult({
    required int previousAttempt,
    Duration timeout = calibrationResultTimeout,
    Duration pollDelay = calibrationPollDelay,
  }) async {
    final DateTime limit = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(limit)) {
      try {
        final Map<String, Object?> status = await _send('GET', const <String, String>{}, null);
        final Object? raw = status['calibration'];
        if (raw is Map<String, Object?>) {
          final int attempt = (raw['attempt'] as num?)?.toInt() ?? 0;
          if (attempt > previousAttempt) {
            return CalibrationResult(
              attempt: attempt,
              ok: raw['ok'] == true,
              message: (raw['message'] as String?) ?? '',
              hint: (raw['hint'] as String?) ?? '',
            );
          }
        }
      } on Exception {
        // El panel puede tardar o cortar mientras calibra: se vuelve a preguntar.
      }
      await Future<void>.delayed(pollDelay);
    }
    return null;
  }

  /// El número del último intento que el panel dice tener, para saber cuál es nuevo.
  Future<int> lastAttempt() async {
    try {
      final Map<String, Object?> status = await _send('GET', const <String, String>{}, null);
      final Object? raw = status['calibration'];
      return raw is Map<String, Object?> ? (raw['attempt'] as num?)?.toInt() ?? 0 : 0;
    } on Exception {
      return 0;
    }
  }

  /// Dónde se quedó la subida según el panel; si no contesta, lo que ya se sabía.
  Future<int> _serverBytes({required int fallback}) async {
    try {
      final Map<String, Object?> status = await _send(
        'GET',
        const <String, String>{},
        null,
      );
      return (status['bytes'] as num?)?.toInt() ?? fallback;
    } on Exception {
      return fallback;
    }
  }

  Future<Map<String, Object?>> _send(
    String method,
    Map<String, String> query,
    List<int>? body,
  ) async {
    final Uri uri = panel.replace(
      path: recordingUploadPath,
      queryParameters: <String, String>{'side': _side, ...query},
    );
    final HttpClientRequest request = await _client
        .openUrl(method, uri)
        .timeout(requestTimeout);
    final ({String user, String password})? auth = credentials;
    if (auth != null) {
      final String token = base64Encode(
        utf8.encode('${auth.user}:${auth.password}'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
    }
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final HttpClientResponse response = await request.close().timeout(
      requestTimeout,
    );
    final String text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(requestTimeout);
    Map<String, Object?> json = <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        json = decoded;
      }
    } on FormatException {
      // Los errores del panel que no son de la subida vienen en HTML: basta el código.
    }
    switch (response.statusCode) {
      case HttpStatus.ok:
        return json;
      case HttpStatus.conflict:
        throw _Behind((json['bytes'] as num?)?.toInt() ?? 0);
      case HttpStatus.unauthorized:
        throw CalibrationUploadException(
          'el panel no acepta las credenciales: vuelve a escanear el QR de la tarjeta Cámaras',
        );
      case HttpStatus.notFound:
        throw CalibrationUploadException(
          'este servidor no recibe grabaciones para calibrar',
        );
      default:
        final Object? error = json['error'];
        throw CalibrationUploadException(
          'el panel rechazó la subida (${response.statusCode})${error == null ? '' : ': $error'}',
        );
    }
  }
}
