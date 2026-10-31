/// El encuadre a mano de «Una cámara» en el maestro (ADR 0033, IOS-116).
///
/// La geometría vive en nativo (`FramingSpace` de RigCore, porte de libs/vision/framing.py):
/// aquí solo se lee el cuerpo de cada `camera/*`, se lleva a una orden nativa por el
/// [CameraBridge] y se guarda lo que vuelve, que es lo que el estado enseña. Los encuadres
/// guardados van con el evento, en `grafico.json`, como las franjas.
///
/// Y la vista en vivo del mando en la cancha: `GET /api/v1/rig/live/{overview|program}` en
/// MJPEG, con las miniaturas que el nativo hace más seguidas mientras alguien mira.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/match_engine.dart' show OrderError;

/// Lo que contesta `camera/*` en un móvil que no emite con «Una cámara».
const String cameraWithoutSingle = 'este móvil no emite con «Una cámara»: con dos móviles encuadra el director';

/// Cómo está el encuadre, como lo dice el nativo: el destino, si va de camino.
@immutable
class CameraState {
  const CameraState({
    required this.centerU,
    required this.centerV,
    required this.zoom,
    required this.outline,
    required this.moving,
    required this.soft,
  });

  /// Dónde cae el centro del destino en la vista general (0–1).
  final double centerU;
  final double centerV;

  /// En la escala de la app Cámara: 1 es la cámara principal; 0,5, la lente entera.
  final double zoom;

  /// Las cuatro esquinas del contorno en la vista general, u y v alternos.
  final List<double> outline;
  final bool moving;

  /// Pasado el 2×: el mando avisa «se verá borroso».
  final bool soft;

  Map<String, Object?> toJson() => <String, Object?>{
        'center': <double>[centerU, centerV],
        'zoom': zoom,
        'outline': <List<double>>[
          for (int i = 0; i + 1 < outline.length; i += 2) <double>[outline[i], outline[i + 1]],
        ],
        'moving': moving,
        'soft': soft,
      };

  @override
  bool operator ==(Object other) =>
      other is CameraState &&
      other.centerU == centerU &&
      other.centerV == centerV &&
      other.zoom == zoom &&
      listEquals(other.outline, outline) &&
      other.moving == moving &&
      other.soft == soft;

  @override
  int get hashCode => Object.hash(centerU, centerV, zoom, Object.hashAll(outline), moving, soft);
}

/// Lo que contesta el nativo a una orden: el encuadre como queda y, si no se aplicó, por qué.
@immutable
class CameraReply {
  const CameraReply(this.state, this.error);

  final CameraState state;
  final String error;
}

/// La orden nativa (`cameraOrder` de Pigeon). null si este móvil no emite con «Una cámara».
typedef CameraBridge = Future<CameraReply?> Function(String kind, List<double> values, bool cut);

/// Un encuadre guardado (ADR 0033): su nombre, su centro en la vista general y su zoom. Va
/// por el centro y el zoom, no por el contorno: así sigue a la lente aunque el soporte se
/// mueva entre partidos.
@immutable
class CameraPreset {
  const CameraPreset({required this.name, required this.centerU, required this.centerV, required this.zoom});

  /// Lee `{name, center: [u, v], zoom}`; [FormatException] si no vale.
  factory CameraPreset.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('se espera {name, center, zoom}');
    }
    final Object? nombre = json['name'], centro = json['center'], zoom = json['zoom'];
    if (nombre is! String ||
        centro is! List<Object?> ||
        centro.length != 2 ||
        centro.any((Object? c) => c is! num) ||
        zoom is! num) {
      throw const FormatException('se espera {name, center: [u, v], zoom}');
    }
    return CameraPreset(
      name: nombre,
      centerU: (centro[0]! as num).toDouble(),
      centerV: (centro[1]! as num).toDouble(),
      zoom: zoom.toDouble(),
    );
  }

  final String name;
  final double centerU;
  final double centerV;
  final double zoom;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'center': <double>[centerU, centerV],
        'zoom': zoom,
      };
}

/// El nombre de un encuadre guardado, recortado: 400 si falta o es largo.
String cameraPresetName(Map<String, Object?> body) {
  final Object? nombre = body['name'];
  final String limpio = nombre is String ? nombre.trim() : '';
  if (limpio.isEmpty || limpio.length > cameraPresetNameMaxChars) {
    throw OrderError(400, 'name tiene que llevar de 1 a $cameraPresetNameMaxChars caracteres');
  }
  return limpio;
}

/// Una orden nativa: su tipo, sus números y si salta de golpe.
typedef CameraNativeOrder = ({String kind, List<double> values, bool cut});

/// El cuerpo de `camera/frame`, `camera/zoom`, `camera/pan`, `camera/reset` o
/// `camera/preset`, llevado a la orden nativa. Aquí solo se miran los tipos: los topes (el
/// tamaño del recuadro, el factor, el paso) los pone `FramingSpace`, que contesta con su
/// error. `preset` busca un encuadre guardado por nombre.
CameraNativeOrder cameraNativeOrder(
  String name,
  Map<String, Object?> body,
  CameraPreset? Function(String name) preset,
) {
  final Object corte = body['cut'] ?? false;
  if (corte is! bool) {
    throw OrderError(400, 'cut tiene que ser true o false');
  }
  List<double> numeros(List<String> claves) {
    final List<double> valores = <double>[];
    for (final String k in claves) {
      final Object? v = body[k];
      if (v is! num || !v.isFinite) {
        throw OrderError(400, '$k tiene que ser un número');
      }
      valores.add(v.toDouble());
    }
    return valores;
  }
  switch (name) {
    case 'camera/frame':
      return (kind: 'frame', values: numeros(<String>['x0', 'y0', 'x1', 'y1']), cut: corte);
    case 'camera/zoom':
      return (kind: 'zoom', values: numeros(<String>['factor']), cut: corte);
    case 'camera/pan':
      return (kind: 'pan', values: numeros(<String>['dx', 'dy']), cut: corte);
    case 'camera/reset':
      final Object a = body['to'] ?? 'start';
      if (a != 'start' && a != 'full') {
        throw OrderError(400, 'to tiene que ser start o full');
      }
      return (kind: 'reset', values: <double>[a == 'start' ? 0 : 1], cut: corte);
    case 'camera/preset':
      final String nombre = cameraPresetName(body);
      final CameraPreset? p = preset(nombre);
      if (p == null) {
        throw OrderError(404, 'no hay ningún encuadre que se llame $nombre');
      }
      return (kind: 'goto', values: <double>[p.centerU, p.centerV, p.zoom], cut: corte);
    default:
      throw OrderError(404, 'orden desconocida: $name');
  }
}

/// La vista en vivo del mando en la cancha (ADR 0033): las miniaturas de una fuente en
/// MJPEG (`multipart/x-mixed-replace`), una cada [interval] si cambió.
///
/// Como mucho [maxViewers] por fuente: el tercero, 503. Si el mando lee más despacio de lo
/// que llegan, el socket se atasca, el flujo se pausa y las miniaturas de mientras se
/// descartan: nunca se encolan (CLAUDE.md §2).
class LiveViews {
  LiveViews({
    required this.thumbnail,
    this.interval = cameraLiveFrameInterval,
    this.maxViewers = cameraLiveMaxViewers,
  });

  /// La última miniatura JPEG de una fuente (vacía si no hay); el nativo la hace más seguida
  /// mientras se le pide.
  final Future<Uint8List> Function(String name) thumbnail;
  final Duration interval;
  final int maxViewers;

  /// Las fuentes que se pueden mirar en vivo.
  static const List<String> sources = <String>['overview', 'program'];

  final Map<String, int> _viewers = <String, int>{};

  /// Cuántos miran `source` ahora.
  int viewers(String source) => _viewers[source] ?? 0;

  /// Ocupa un sitio para mirar `source`; false si ya están todos.
  bool open(String source) {
    if (viewers(source) >= maxViewers) {
      return false;
    }
    _viewers[source] = viewers(source) + 1;
    return true;
  }

  void close(String source) {
    _viewers[source] = (viewers(source) - 1).clamp(0, maxViewers);
  }

  /// Las partes del multipart de `source`, hasta que quien lee se va o se cumple `until` (el
  /// `done` de la respuesta, que también avisa si el mando cortó la conexión).
  Stream<List<int>> frames(String source, {Future<void>? until}) {
    late final StreamController<List<int>> salida;
    Timer? reloj;
    bool pidiendo = false;
    Uint8List? ultima;
    Future<void> una() async {
      if (pidiendo || salida.isPaused || salida.isClosed) {
        return; // atascado o aún con la anterior: esta se descarta
      }
      pidiendo = true;
      try {
        final Uint8List jpeg = await thumbnail(source);
        if (jpeg.isNotEmpty && !_same(jpeg, ultima) && !salida.isClosed) {
          ultima = jpeg;
          salida.add(livePart(jpeg));
        }
      } on Exception {
        // Una miniatura que no llega no corta la vista: va la siguiente.
      } finally {
        pidiendo = false;
      }
    }

    salida = StreamController<List<int>>(
      onListen: () {
        unawaited(una());
        reloj = Timer.periodic(interval, (_) => unawaited(una()));
      },
      onCancel: () {
        reloj?.cancel();
      },
    );
    unawaited(until?.catchError((Object _) {}).whenComplete(() {
      reloj?.cancel();
      if (!salida.isClosed) {
        unawaited(salida.close());
      }
    }));
    return salida.stream;
  }

  static bool _same(Uint8List a, Uint8List? b) {
    if (b == null || a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// El tipo de la respuesta, con su frontera.
  static const String contentType = 'multipart/x-mixed-replace; boundary=$cameraLiveBoundary';

  /// Una parte del multipart: su cabecera, el JPEG y el salto.
  static List<int> livePart(Uint8List jpeg) => <int>[
        ...ascii.encode('--$cameraLiveBoundary\r\n'
            '${HttpHeaders.contentTypeHeader}: image/jpeg\r\n'
            '${HttpHeaders.contentLengthHeader}: ${jpeg.length}\r\n\r\n'),
        ...jpeg,
        ...ascii.encode('\r\n'),
      ];
}
