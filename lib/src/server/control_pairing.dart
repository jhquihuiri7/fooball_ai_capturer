/// El QR Mando que enseña el maestro (IOS-63, ADR 0017 y 0023).
///
/// El secreto se deriva del secreto del soporte y del partido, así que no se guarda en
/// ningún sitio: cualquiera de los dos móviles emite un token que el otro acepta. El QR
/// lleva la dirección del maestro, la del otro móvil y la del VPS (si la hay), para que
/// el mando siga tras un relevo.
library;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/control_token.dart';

/// La dirección de la API del mando en un móvil de la LAN.
Uri masterApiUri(String lanIp) => Uri(scheme: 'http', host: lanIp, port: masterApiPort);

/// El texto del QR Mando: token del partido `matchId` con `scopes`, válido
/// [controlTokenTtl] desde `nowS` (hora de pared en segundos: la caducidad es de pared
/// por definición, la comprueba el otro móvil o el VPS).
String controlPairingText({
  required List<int> rigSecret,
  required String matchId,
  required List<Uri> panels,
  required int nowS,
  Set<String> scopes = const <String>{panelScopeMatch},
}) {
  if (panels.isEmpty) {
    throw ArgumentError.value(panels, 'panels', 'hace falta al menos una dirección');
  }
  final String token = issueToken(
    deriveControlSecret(rigSecret, matchId),
    ControlClaims(matchId: matchId, scopes: scopes, expiresS: nowS + controlTokenTtl.inSeconds),
  );
  return PanelPairing.compose(panels, token);
}
