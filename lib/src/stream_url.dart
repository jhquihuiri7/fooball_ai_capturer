/// A dónde emite este móvil (ADR 0012; TASK A5).
///
/// Dos transportes, elegidos por lo que deja pasar la red del servidor:
///
/// - **SRT** (UDP): el bueno para Starlink, porque recupera los paquetes que se pierden
///   en cada traspaso de satélite. Es el que usa el banco de pruebas y el que usaría un
///   relé propio.
/// - **RTMP** (TCP): el único que entra directo a un pod de RunPod, que no admite UDP.
///   Sobre TCP cada pérdida es un parón, así que es el plan B, no el preferido.
///
/// En los dos casos el canal es el mismo en MediaMTX: `rig/izquierda` o `rig/derecha`.
/// Dos niveles porque el cliente RTMP parte la URL en aplicación y nombre de stream, y
/// con uno solo se rompe.
library;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// El canal de MediaMTX de cada cámara. Es lo que el servidor abre por RTSP.
String streamPath(CameraRole role) =>
    '$streamPathPrefix/${role == CameraRole.left ? 'izquierda' : 'derecha'}';

/// Lo que el operador escribió en «Servidor», convertido en la URL de emisión.
///
/// Acepta un host pelado (`10.0.0.5`, `pod.ejemplo.com:9000`), que se toma como SRT, o
/// una URL con esquema `srt://`, `rtmp://` o `rtmps://`. Las credenciales van como
/// `usuario:clave@host` y se traducen a lo que espera MediaMTX en cada protocolo.
/// Devuelve vacío si no hay servidor o no se entiende: entonces solo se graba.
String buildStreamUrl(String server, CameraRole role) {
  final String text = server.trim();
  if (text.isEmpty) {
    return '';
  }
  final Uri? uri = Uri.tryParse(text.contains('://') ? text : 'srt://$text');
  if (uri == null || uri.host.isEmpty) {
    return '';
  }

  final List<String> credentials = uri.userInfo.isEmpty
      ? const <String>[]
      : uri.userInfo.split(':').map(Uri.decodeComponent).toList();
  final String path = streamPath(role);

  switch (uri.scheme) {
    case 'srt':
      final int port = uri.hasPort ? uri.port : streamPort;
      final String streamId = <String>['publish', path, ...credentials].join(':');
      return 'srt://${uri.host}:$port?streamid=$streamId&latency=$streamLatencyMs';
    case 'rtmp':
    case 'rtmps':
      final int port = uri.hasPort ? uri.port : (uri.scheme == 'rtmps' ? rtmpsPort : rtmpPort);
      final String query = credentials.length == 2
          ? '?user=${Uri.encodeQueryComponent(credentials[0])}'
              '&pass=${Uri.encodeQueryComponent(credentials[1])}'
          : '';
      return '${uri.scheme}://${uri.host}:$port/$path$query';
    default:
      return '';
  }
}

/// Protocolo y host, para enseñarlos en pantalla sin la clave.
String describeStreamTarget(String server) {
  final String text = server.trim();
  final Uri? uri = Uri.tryParse(text.contains('://') ? text : 'srt://$text');
  if (uri == null || uri.host.isEmpty) {
    return text;
  }
  return '${uri.scheme.toUpperCase()} a ${uri.host}';
}
