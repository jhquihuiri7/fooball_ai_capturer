/// La respuesta ya dada a un reintento (IOS-62), porte de `tools/idempotency.py`.
///
/// Por Starlink o por una Wi-Fi floja, una orden cuya respuesta se pierde se reintenta.
/// Con la misma `Idempotency-Key`, el maestro contesta lo mismo que la primera vez sin
/// volver a aplicar nada: el reintento de «+1 min» no son dos minutos.
library;

import 'dart:collection';

import 'package:football_ai_capture/src/constants.dart';

/// Una clave válida: un UUID o algo parecido, hasta 128 caracteres (`KEY_PATTERN`).
final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');

bool validIdempotencyKey(String key) => _keyPattern.hasMatch(key);

/// Una respuesta entera, tal y como se mandó.
class StoredResponse {
  const StoredResponse(this.status, this.contentType, this.body);

  final int status;
  final String contentType;
  final List<int> body;
}

/// Las últimas respuestas por clave, con caducidad y tamaño acotados.
class IdempotencyCache {
  IdempotencyCache({
    required this.nowMs,
    this.size = apiIdempotencyCacheSize,
    Duration ttl = apiIdempotencyTtl,
  }) : _ttlMs = ttl.inMilliseconds;

  /// Reloj monótono en ms.
  final int Function() nowMs;
  final int size;
  final int _ttlMs;

  /// Por orden de llegada: la más vieja es la primera en caducar y en salir.
  final LinkedHashMap<String, (int, Future<StoredResponse>)> _entries =
      LinkedHashMap<String, (int, Future<StoredResponse>)>();

  int get length => _entries.length;

  /// Las respuestas ya resueltas de los últimos `windowMs`, las más nuevas, `max` como
  /// mucho: lo que viaja en la réplica para que la idempotencia sobreviva al relevo
  /// (ADR 0023 §7). Solo las ya terminadas: una en vuelo no tiene aún status.
  Map<String, (int, StoredResponse)> recent({required int windowMs, required int max}) {
    final int desde = nowMs() - windowMs;
    final Map<String, (int, StoredResponse)> out = <String, (int, StoredResponse)>{};
    for (final MapEntry<String, (int, StoredResponse)> e in _done.entries.toList().reversed) {
      if (out.length >= max || e.value.$1 < desde) {
        break;
      }
      out[e.key] = e.value;
    }
    return out;
  }

  /// Las terminadas, por clave, en orden de llegada (para `recent`).
  final LinkedHashMap<String, (int, StoredResponse)> _done = LinkedHashMap<String, (int, StoredResponse)>();

  /// La respuesta guardada para `key`, o la de `respond()`, que queda guardada. Se guarda
  /// el Future, no el resultado: un reintento que llega mientras la primera aún se aplica
  /// espera a esa respuesta en vez de aplicarla otra vez (el lock de Python).
  Future<StoredResponse> run(String key, Future<StoredResponse> Function() respond) {
    final int ahora = nowMs();
    while (_entries.isNotEmpty && ahora - _entries.values.first.$1 >= _ttlMs) {
      _entries.remove(_entries.keys.first);
    }
    final (int, Future<StoredResponse>)? guardada = _entries[key];
    if (guardada != null) {
      return guardada.$2;
    }
    final Future<StoredResponse> respuesta = respond();
    _entries[key] = (ahora, respuesta);
    respuesta.then((StoredResponse r) {
      _done[key] = (ahora, r);
      while (_done.length > size) {
        _done.remove(_done.keys.first);
      }
    });
    if (_entries.length > size) {
      _entries.remove(_entries.keys.first);
    }
    return respuesta;
  }
}
