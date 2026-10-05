/// El token de mando en el maestro (IOS-63), porte de `tools/control_token.py` del repo
/// football-ai: el mismo formato byte a byte, así que un token emitido en Python abre
/// aquí y al revés (lo comprueban los dorados `control_token.json`).
///
/// Un token es `base64url(json).base64url(hmac)`, sin relleno. El JSON lleva `m` (el
/// partido), `r` (el rig, solo en el token del soporte), `s` (los ámbitos, ordenados),
/// `e` (caducidad, segundos de pared desde 1970) y `g` (generación del token del
/// soporte); los ausentes no se escriben.
///
/// El secreto que lo firma no se guarda ni viaja: lo derivan los dos móviles del secreto
/// del soporte y del `match_id` (ADR 0023 §3, [deriveControlSecret]). Un partido nuevo, o
/// rotar el secreto del soporte, revoca todos los tokens.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:football_ai_capture/src/constants.dart';

/// Ámbito de las órdenes del soporte (`SCOPE_RIG`).
const String controlScopeRig = 'rig';

/// Ámbito del túnel del VPS, solo en el token del soporte (`SCOPE_TUNNEL`).
const String controlScopeTunnel = 'tunnel';

/// Los ámbitos que un token puede llevar (`ALL_SCOPES`). Uno fuera de aquí es de otra
/// versión y no abre.
const Set<String> controlAllScopes = <String>{
  panelScopeMatch,
  panelScopeStream,
  controlScopeRig,
  controlScopeTunnel,
};

/// El QR que hay que volver a escanear si falla un token de mando (`QR_CONTROL`).
const String controlQrName = 'QR Mando';

final RegExp _rigIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Un token que no abre: 401 si no vale o caducó, 410 si es de otro partido.
class TokenError implements Exception {
  TokenError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'TokenError($status): $message';
}

/// Lo que dice un token. El de mando es de un partido (`matchId`); el del soporte, de un
/// rig (`rigId`) con su `generation`.
class ControlClaims {
  const ControlClaims({
    required this.matchId,
    required this.scopes,
    required this.expiresS,
    this.rigId,
    this.generation,
  });

  final String? matchId;
  final Set<String> scopes;

  /// Hora de pared, en segundos desde 1970.
  final int expiresS;
  final String? rigId;
  final int? generation;
}

/// El secreto del mando de un partido: `HMAC-SHA256(S, "zero-control-v1 " ‖ match_id)`
/// en base64url sin relleno, 43 caracteres (ADR 0023 §3). Se usa como texto, igual que
/// `FOOTBALL_CONTROL_SECRET` en Python. Nunca se registra.
List<int> deriveControlSecret(List<int> rigSecret, String matchId) {
  final Digest d = Hmac(sha256, rigSecret).convert(utf8.encode('$controlSecretContext$matchId'));
  return ascii.encode(_b64(d.bytes));
}

String issueToken(List<int> secret, ControlClaims claims) {
  final Map<String, Object?> crudo = <String, Object?>{
    if (claims.matchId != null) 'm': claims.matchId,
    if (claims.rigId != null) 'r': claims.rigId,
    's': claims.scopes.toList()..sort(),
    'e': claims.expiresS,
    if (claims.generation != null) 'g': claims.generation,
  };
  final List<int> datos = ascii.encode(_asciiJson(crudo));
  return '${_b64(datos)}.${_b64(_sign(secret, datos))}';
}

/// Lo que dice `token` si lo firmó este secreto, no ha caducado y es de `matchId` y de
/// `generation` (cada comprobación, solo si se pide). Si no, [TokenError] con el mismo
/// estado y mensaje que la referencia de Python.
ControlClaims verifyToken(
  List<int> secret,
  String token, {
  required String? matchId,
  required int nowS,
  int? generation,
  String qr = controlQrName,
}) {
  final int punto = token.indexOf('.');
  final List<int> datos;
  final List<int> firma;
  try {
    if (punto < 0) {
      throw const FormatException();
    }
    datos = _unb64(token.substring(0, punto));
    firma = _unb64(token.substring(punto + 1));
  } on FormatException {
    throw TokenError(401, 'token mal formado: escanea el $qr');
  }
  if (!_sameBytes(firma, _sign(secret, datos))) {
    throw TokenError(401, 'token no valido: escanea el $qr');
  }
  final ControlClaims claims = _claims(datos, qr);
  if (matchId != null && claims.matchId != matchId) {
    throw TokenError(410, 'esta transmision termino: escanea el QR nuevo');
  }
  if (generation != null && claims.generation != generation) {
    throw TokenError(401, 'token de otra generacion: escanea el $qr');
  }
  if (claims.expiresS <= nowS) {
    throw TokenError(401, 'token caducado: escanea el $qr otra vez');
  }
  return claims;
}

/// Lo firmado, ya comprobada la firma. Aun así se valida: un token de otra versión,
/// firmado con el mismo secreto, no puede abrir con ámbitos que no existen.
ControlClaims _claims(List<int> datos, String qr) {
  Object? crudo;
  try {
    crudo = jsonDecode(utf8.decode(datos));
  } on FormatException {
    crudo = null;
  }
  final Map<String, Object?> m = crudo is Map<String, Object?> ? crudo : <String, Object?>{};
  final Object? partido = m['m'];
  final Object? rig = m['r'];
  final Object? ambitos = m['s'];
  final Object? caduca = m['e'];
  final Object? generacion = m['g'];
  final bool valido =
      (partido != null || rig != null) &&
      (partido == null || partido is String) &&
      (rig == null || (rig is String && _rigIdPattern.hasMatch(rig))) &&
      ambitos is List<Object?> &&
      ambitos.every((Object? a) => a is String && controlAllScopes.contains(a)) &&
      caduca is int &&
      (generacion == null || (generacion is int && generacion >= 0));
  if (!valido) {
    throw TokenError(401, 'token de otra version: escanea el $qr');
  }
  return ControlClaims(
    matchId: partido as String?,
    scopes: ambitos.cast<String>().toSet(),
    expiresS: caduca,
    rigId: rig as String?,
    generation: generacion as int?,
  );
}

List<int> _sign(List<int> secret, List<int> datos) => Hmac(sha256, secret).convert(datos).bytes;

/// En tiempo constante, como en Python (`hmac.compare_digest`): fallar antes o después
/// es medible por la red.
bool _sameBytes(List<int> a, List<int> b) {
  int diferencia = a.length ^ b.length;
  for (int i = 0; i < a.length && i < b.length; i++) {
    diferencia |= a[i] ^ b[i];
  }
  return diferencia == 0;
}

String _b64(List<int> datos) => base64Url.encode(datos).replaceAll('=', '');

/// Sin relleno en el token: va dentro de una URL y de una cabecera, y `=` estorba.
List<int> _unb64(String texto) => base64Url.decode(base64Url.normalize(texto));

/// `json.dumps(…, separators=(",", ":"))` de Python: lo que no es ASCII sale como
/// `\uXXXX`. Sin esto, un `match_id` con tildes firmaría otros bytes que en Python.
String _asciiJson(Object? valor) {
  final StringBuffer out = StringBuffer();
  for (final int u in jsonEncode(valor).codeUnits) {
    out.write(u < 0x80 ? String.fromCharCode(u) : '\\u${u.toRadixString(16).padLeft(4, '0')}');
  }
  return out.toString();
}
