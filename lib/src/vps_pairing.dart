/// El emparejado del soporte con el VPS (IOS-68; ADR 0022 §3 del repo football-ai).
///
/// El panel del VPS (`/pair`, NUBE-16) enseña el QR «Soporte», un JSON compacto con lo que
/// el móvil necesita para publicar el programa y abrir el túnel:
///
///     {"v":1, "srt":{"host","port","path","user","pass","passphrase"},
///      "tunnel":{"url":"wss://<dominio>/tunnel/v1"}, "rig_id", "rig_key"}
///
/// Se valida aquí y se guarda tal cual en el Keychain (`saveVpsPairing`, que lo vuelve a
/// validar en nativo con `VpsPairing` de RigCore antes de escribir). Lo leen el túnel
/// (IOS-65, con [VpsPairing.load]) y el publicador del programa (IOS-56, en Swift con
/// `VpsPairingKeychain.load()`).
///
/// `rig_key` es el token del soporte (`tools/control_token.py`): caduca a las 12 h y el
/// VPS lo puede rotar. La app no tiene el secreto que lo firma: lee su rig y su caducidad
/// solo para decir a tiempo «escanea otra vez». Las credenciales del SRT no caducan con él.
///
/// Ningún secreto sale de aquí en un texto: ni `toString` ni los errores llevan valores.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/server/control_token.dart';

/// Los nombres del VPS: `FOOTBALL_VPS_DOMAIN` (`[A-Za-z0-9.-]+` en pairing.py).
final RegExp _hostPattern = RegExp(r'^[A-Za-z0-9.-]+$');

/// Usuario, clave y passphrase del programa (ADR 0022 §2): sin «:» ni «~».
final RegExp _credentialPattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// La ruta del streamid: ASCII imprimible sin «:» (`ProgramSrtStreamId.freeAlphabet`).
final RegExp _pathPattern = RegExp(r'^[\x21-\x39\x3B-\x7E]+$');

/// `RIG_ID_PATTERN`: el rig va en rutas del VPS.
final RegExp _rigIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Un token: base64url, un punto y base64url.
final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$');

/// La hora de pared en segundos. La caducidad del `rig_key` es hora de pared por diseño
/// (ADR 0022 §11); los temporizadores, no.
int wallClockS() => DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

/// Por qué no vale un QR Soporte.
enum VpsPairingProblem {
  /// No es un QR Soporte: el de Mando, el de Cámaras, una web.
  notSupport,

  /// Un QR Soporte de otra versión: hay que actualizar la app.
  version,

  /// Falta un campo o no vale: [VpsPairingException.field] dice cuál.
  field,

  /// El `rig_key` ya caducó: hay que pedir otro QR.
  expired,
}

class VpsPairingException implements Exception {
  const VpsPairingException(this.problem, [this.field]);

  final VpsPairingProblem problem;

  /// El campo que falla, como `srt.pass`: el nombre, nunca el valor.
  final String? field;

  /// Para la pantalla.
  String get message => switch (problem) {
    VpsPairingProblem.notSupport => 'Ese QR no es el Soporte: en el panel del VPS, /pair.',
    VpsPairingProblem.version => 'Ese QR Soporte es de otra versión: actualiza la app.',
    VpsPairingProblem.field => 'El QR Soporte no trae bien «$field»: pide otro en el VPS.',
    VpsPairingProblem.expired => 'Ese QR Soporte caducó: recarga /pair en el VPS.',
  };

  @override
  String toString() => 'VpsPairingException(${problem.name}${field == null ? '' : ', $field'})';
}

/// El bloque `srt` del QR: el destino del programa (`ProgramSrtTarget` en RigCore).
class VpsSrtTarget {
  const VpsSrtTarget({
    required this.host,
    required this.port,
    required this.path,
    required this.user,
    required this.pass,
    required this.passphrase,
  });

  final String host;
  final int port;
  final String path;
  final String user;
  final String pass;
  final String passphrase;

  /// Para los logs: sin clave ni passphrase.
  @override
  String toString() => 'srt://$host:$port publish:$path:$user:***';
}

class VpsPairing {
  const VpsPairing._({
    required this.srt,
    required this.tunnel,
    required this.rigId,
    required this.rigKey,
    required this.rigKeyExpiresS,
    required this.qrText,
  });

  final VpsSrtTarget srt;

  /// `wss://<dominio>/tunnel/v1`.
  final Uri tunnel;
  final String rigId;

  /// El Bearer del túnel y de las rutas HTTP de los móviles.
  final String rigKey;

  /// Cuándo caduca [rigKey], en segundos de hora de pared.
  final int rigKeyExpiresS;

  /// Lo que se guarda en el Keychain: el texto del QR sin espacios alrededor.
  final String qrText;

  /// Con quién está emparejado: el host del túnel.
  String get domain => tunnel.host;

  bool expiredAt(int nowS) => rigKeyExpiresS <= nowS;

  /// Lo que le queda a [rigKey]; cero si caducó.
  Duration validFor(int nowS) => Duration(seconds: math.max(0, rigKeyExpiresS - nowS));

  /// Si `text` parece un QR Soporte (un JSON) y no una dirección: nunca va al campo
  /// «Servidor», que se ve en pantalla.
  static bool looksLike(String text) => text.trimLeft().startsWith('{');

  /// Lee y valida el QR. Con [nowS], además rechaza un `rig_key` caducado (al escanear);
  /// sin él, no (al leer del Keychain: el SRT sigue valiendo). [VpsPairingException] si no
  /// vale. Se comprueba en el mismo orden que `VpsPairing.parse` de RigCore.
  static VpsPairing parse(String text, {int? nowS}) {
    final String qr = text.trim();
    Object? crudo;
    try {
      crudo = jsonDecode(qr);
    } on FormatException {
      crudo = null;
    }
    if (crudo is! Map<String, Object?> || !crudo.containsKey('v')) {
      throw const VpsPairingException(VpsPairingProblem.notSupport);
    }
    final Object? v = crudo['v'];
    if (v is! int || v != vpsPairingVersion) {
      throw const VpsPairingException(VpsPairingProblem.version);
    }
    final Map<String, Object?> s = _object(crudo, 'srt', 'srt');
    final String host = _matching(s, 'host', 'srt.host', _hostPattern);
    final Object? port = s['port'];
    if (port is! int || port < 1 || port > maxPort) {
      throw const VpsPairingException(VpsPairingProblem.field, 'srt.port');
    }
    final String path = _matching(s, 'path', 'srt.path', _pathPattern);
    final String user = _matching(s, 'user', 'srt.user', _credentialPattern);
    final String pass = _matching(s, 'pass', 'srt.pass', _credentialPattern);
    final String passphrase = _string(s, 'passphrase', 'srt.passphrase');
    if ('publish:$path:$user:$pass'.length > programStreamIdMaxChars) {
      throw const VpsPairingException(VpsPairingProblem.field, 'srt');
    }
    if (passphrase.length < programSrtPassphraseMinChars ||
        passphrase.length > programSrtPassphraseMaxChars ||
        !_credentialPattern.hasMatch(passphrase)) {
      throw const VpsPairingException(VpsPairingProblem.field, 'srt.passphrase');
    }
    final Map<String, Object?> t = _object(crudo, 'tunnel', 'tunnel');
    final Uri? tunnel = Uri.tryParse(_string(t, 'url', 'tunnel.url'));
    if (tunnel == null ||
        tunnel.scheme != vpsTunnelScheme ||
        tunnel.host.isEmpty ||
        tunnel.userInfo.isNotEmpty) {
      throw const VpsPairingException(VpsPairingProblem.field, 'tunnel.url');
    }
    final String rigId = _matching(crudo, 'rig_id', 'rig_id', _rigIdPattern);
    final String rigKey = _matching(crudo, 'rig_key', 'rig_key', _tokenPattern);
    final ControlClaims? claims = peekClaims(rigKey);
    if (claims == null || claims.rigId != rigId || !claims.scopes.contains(controlScopeTunnel)) {
      throw const VpsPairingException(VpsPairingProblem.field, 'rig_key');
    }
    if (nowS != null && claims.expiresS <= nowS) {
      throw const VpsPairingException(VpsPairingProblem.expired);
    }
    return VpsPairing._(
      srt: VpsSrtTarget(
        host: host,
        port: port,
        path: path,
        user: user,
        pass: pass,
        passphrase: passphrase,
      ),
      tunnel: tunnel,
      rigId: rigId,
      rigKey: rigKey,
      rigKeyExpiresS: claims.expiresS,
      qrText: qr,
    );
  }

  /// Lo guardado en el Keychain, sin mirar la caducidad, o `null` si no hay o no se lee.
  static Future<VpsPairing?> load(CaptureHostApi api) async {
    final String text = await api.loadVpsPairing();
    if (text.isEmpty) {
      return null;
    }
    try {
      return parse(text);
    } on VpsPairingException {
      return null;
    }
  }

  /// Para los logs: con quién y hasta cuándo, sin secretos.
  @override
  String toString() => 'VpsPairing($domain, rig $rigId, caduca $rigKeyExpiresS)';

  static Map<String, Object?> _object(Map<String, Object?> m, String key, String field) {
    final Object? valor = m[key];
    if (valor is! Map<String, Object?>) {
      throw VpsPairingException(VpsPairingProblem.field, field);
    }
    return valor;
  }

  static String _string(Map<String, Object?> m, String key, String field) {
    final Object? valor = m[key];
    if (valor is! String) {
      throw VpsPairingException(VpsPairingProblem.field, field);
    }
    return valor;
  }

  static String _matching(Map<String, Object?> m, String key, String field, RegExp pattern) {
    final String valor = _string(m, key, field);
    if (!pattern.hasMatch(valor)) {
      throw VpsPairingException(VpsPairingProblem.field, field);
    }
    return valor;
  }
}
