/// El emparejamiento con el panel como mando (ADR 0017 del repo football-ai).
///
/// El panel enseña en su tarjeta «Mando» un QR con `https://<panel>/#mando=<token>`: la
/// dirección del panel y un token firmado para un partido. La app guarda ese texto entero
/// en el Keychain (`savePanelPairing`) y lo lee con esto cada vez que abre.
///
/// El token es opaco para la app. El partido y los permisos van dentro, y el panel los
/// repite en cada respuesta (`scopes`); si el partido ya no es el suyo, contesta 410.
///
/// El QR Mando del maestro (IOS-63, ADR 0023) lleva además `alt`: las otras direcciones
/// por las que se llega al mismo partido (la IP del otro móvil, que puede pasar a dirigir,
/// y la URL del VPS), separadas por espacios. Ante un corte o un 503 se prueba la siguiente.
library;

import 'package:football_ai_capture/src/constants.dart';

/// Letras de un token: base64url y el punto que separa los datos de la firma. Todo lo
/// demás se rechaza, porque el token va tal cual en una cabecera HTTP.
final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_.-]+$');

class PanelPairing {
  const PanelPairing({
    required this.panel,
    required this.token,
    this.alternates = const <Uri>[],
  });

  /// Esquema, host, puerto y ruta del panel, sin barra final ni fragmento.
  final Uri panel;

  final String token;

  /// Las otras direcciones del mismo partido, en el orden en que se prueban.
  final List<Uri> alternates;

  /// Todas las direcciones: [panel] primero.
  List<Uri> get panels => <Uri>[panel, ...alternates];

  /// Lee el texto del QR «Mando». `null` si no es uno: otro QR (el de «Cámaras», una web),
  /// un esquema que no es http(s) o un token que no se puede mandar en una cabecera.
  static PanelPairing? parse(String text) {
    final Uri? uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    final Map<String, String> fragmento = Uri.splitQueryString(uri.fragment);
    final String? token = fragmento[pairingFragmentKey];
    if (token == null || !_tokenPattern.hasMatch(token)) {
      return null;
    }
    // Una alternativa ilegible se ignora: el QR sigue sirviendo con las demás.
    final List<Uri> alternativas = <Uri>[
      for (final String texto in (fragmento[pairingAlternatesKey] ?? '').split(' '))
        if (_base(Uri.tryParse(texto)) case final Uri base) base,
    ];
    return PanelPairing(panel: _base(uri)!, token: token, alternates: alternativas);
  }

  /// El QR Mando del maestro: su dirección, las alternativas y el token.
  static String compose(List<Uri> panels, String token) {
    final String primero = panels.first.toString();
    final String resto = panels.skip(1).map((Uri u) => u.toString()).join(' ');
    return '$primero/#$pairingFragmentKey=$token'
        '${resto.isEmpty ? '' : '&$pairingAlternatesKey=${Uri.encodeQueryComponent(resto)}'}';
  }

  /// Esquema, host, puerto y ruta, sin barra final; `null` si no es http(s).
  static Uri? _base(Uri? uri) {
    if (uri == null || uri.host.isEmpty || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    String path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  /// Lo que se guarda en el Keychain: el mismo texto que el QR, así que leerlo otra vez
  /// con [parse] da lo mismo.
  String get qrText => compose(panels, token);

  /// Cómo se nombra el panel en pantalla: el host, sin el token.
  String get label =>
      panel.hasPort ? '${panel.host}:${panel.port}' : panel.host;

  /// La URL de una ruta de la API del mando: `match`, `match/goal`…
  Uri endpoint(String route, [Map<String, String>? query]) =>
      endpointAt(0, route, query);

  /// La misma ruta en la dirección `index` de [panels] (módulo su número).
  Uri endpointAt(int index, String route, [Map<String, String>? query]) {
    final Uri base = panels[index % panels.length];
    return base.replace(
      path: '${base.path}$panelApiPrefix$route',
      queryParameters: query,
    );
  }
}
