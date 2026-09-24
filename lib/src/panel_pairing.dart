/// El emparejamiento con el panel como mando (ADR 0017 del repo football-ai).
///
/// El panel enseña en su tarjeta «Mando» un QR con `https://<panel>/#mando=<token>`: la
/// dirección del panel y un token firmado para un partido. La app guarda ese texto entero
/// en el Keychain (`savePanelPairing`) y lo lee con esto cada vez que abre.
///
/// El token es opaco para la app. El partido y los permisos van dentro, y el panel los
/// repite en cada respuesta (`scopes`); si el partido ya no es el suyo, contesta 410.
library;

import 'package:football_ai_capture/src/constants.dart';

/// Letras de un token: base64url y el punto que separa los datos de la firma. Todo lo
/// demás se rechaza, porque el token va tal cual en una cabecera HTTP.
final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

class PanelPairing {
  const PanelPairing({required this.panel, required this.token});

  /// Esquema, host, puerto y ruta del panel, sin barra final ni fragmento.
  final Uri panel;

  final String token;

  /// Lee el texto del QR «Mando». `null` si no es uno: otro QR (el de «Cámaras», una web),
  /// un esquema que no es http(s) o un token que no se puede mandar en una cabecera.
  static PanelPairing? parse(String text) {
    final Uri? uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    final String? token = Uri.splitQueryString(
      uri.fragment,
    )[pairingFragmentKey];
    if (token == null || !_tokenPattern.hasMatch(token)) {
      return null;
    }
    String path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return PanelPairing(
      panel: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: path,
      ),
      token: token,
    );
  }

  /// Lo que se guarda en el Keychain: el mismo texto que el QR, así que leerlo otra vez
  /// con [parse] da lo mismo.
  String get qrText => '$panel/#$pairingFragmentKey=$token';

  /// Cómo se nombra el panel en pantalla: el host, sin el token.
  String get label =>
      panel.hasPort ? '${panel.host}:${panel.port}' : panel.host;

  /// La URL de una ruta de la API del mando: `match`, `match/goal`…
  Uri endpoint(String route, [Map<String, String>? query]) => panel.replace(
    path: '${panel.path}$panelApiPrefix$route',
    queryParameters: query,
  );
}
