// El contrato del pipeline del soporte (IOS-08): lo que no es la cámara.
//
// Separado de capture_api.dart a propósito: ese es el contrato de la cámara de hoy y
// este el del pipeline nuevo (bancos, y detrás el detector, el render y el programa).
// Regenerar:
//   dart run pigeon --input pigeons/rig_api.dart

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/generated/rig_api.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/RigApi.g.swift',
    // El PigeonError compartido ya lo declara CaptureApi.g.swift en este mismo target.
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartPackageName: 'football_ai_capture',
  ),
)
/// Cómo va EMITIR en la arquitectura B (IOS-58), para la pantalla de cada móvil. Lo que no
/// toca a su papel va a cero o vacío: el esclavo no publica, el maestro no manda partes.
class ProgramStatus {
  ProgramStatus({
    required this.running,
    required this.master,
    required this.programFps,
    required this.programFrames,
    required this.srtState,
    required this.srtTarget,
    required this.srtDetail,
    required this.srtBitrateBps,
    required this.srtRttMs,
    required this.srtReconnects,
    required this.partMbps,
    required this.partFallbacks,
    required this.partsLost,
    required this.detectorRuns,
    required this.detectorNote,
    required this.problem,
  });

  /// Hay una pasada en marcha en este móvil.
  final bool running;

  /// Este móvil compone y publica ahora (el rol puede cambiar con un relevo).
  final bool master;

  /// Fotogramas del programa por segundo desde la lectura anterior, y en total.
  final double programFps;
  final int programFrames;

  /// El publicador SRT: `stopped`, `connecting`, `publishing`, `waiting` o `failed`;
  /// `none` sin destino (sin QR Soporte); vacío si este móvil no publica.
  final String srtState;

  /// `host:puerto` del destino. Nunca usuario, clave ni passphrase.
  final String srtTarget;

  /// Por qué espera o falló, en palabras; vacío si va bien.
  final String srtDetail;
  final int srtBitrateBps;
  final double srtRttMs;
  final int srtReconnects;

  /// La parte del esclavo, en Mbit/s: la que llega (maestro) o la que sale (esclavo).
  final double partMbps;

  /// Retrocesos: en el maestro, instantes que pedían las dos lentes y salieron de una
  /// porque la parte no llegó a tiempo; en el esclavo, fotogramas pintados con la vista
  /// extrapolada porque no había orden del maestro.
  final int partFallbacks;

  /// Partes que no llegaron al maestro.
  final int partsLost;

  /// Pasadas del detector de jugadores, y su nota (`sin modelo`, o el error al cargarlo).
  final int detectorRuns;
  final String detectorNote;

  /// Lo que impidió montar el programa, si algo lo impidió.
  final String problem;
}

@HostApi()
abstract class RigHostApi {
  /// EMITIR en la arquitectura B (IOS-58): pone en marcha el programa de este móvil con el
  /// enlace de Network abierto por `startLink`. En el maestro, la composición, el director,
  /// el detector, la copia .mov y el SRT al destino del QR Soporte; en el esclavo, su
  /// parte y su detector. La 4K va aparte, por `CaptureHostApi.start`. Devuelve "" o por
  /// qué no arrancó.
  String startProgram();

  /// PARAR: cierra la copia, el SRT y la parte, y deja el informe en Documents/bench.
  void stopProgram();

  /// Cómo va. Con `running` a false si no hay pasada.
  ProgramStatus programStatus();

  /// Lanza un banco por nombre (IOS-08) y devuelve la ruta del informe JSON que dejó
  /// en Documents/bench/. `paramsJson` son los parámetros del banco, tal cual se
  /// guardan en el informe; `{}` si no hay.
  ///
  /// Es la prueba de una sola acción: `flutter run --dart-define=BENCH=<nombre>`
  /// arranca, corre y escribe, sin tocar la pantalla.
  @async
  String runBench(String name, String paramsJson);

  /// Una capa del gráfico del programa (IOS-47): RGBA sin premultiplicar de
  /// `width × height`, ya recortada a su caja con contenido, en (`x`, `y`) del programa.
  /// `layer`: 0 marcador, 1 alineación, 2 SIN SEÑAL. Una `generation` que no sube se
  /// ignora en nativo.
  void setOverlay(Uint8List rgba, int width, int height, int x, int y, int layer, int generation);

  /// Quita una capa del gráfico.
  void clearOverlay(int layer);

  /// La rotación de la franja (IOS-48), en JSON: `{"ads": [{"name", "dir", "fps"}],
  /// "slots": [{"name", "loops"}]}`. `dir` es un directorio de PNG RGBA de 1920×108
  /// dentro de `Documents/ads/`; en lugar de `dir`, `frames` es la lista de PNG de cada
  /// fotograma, repetidos, relativos a `Documents/ads/` (el paquete del VPS, IOS-49).
  /// Los anuncios que no están en `slots` se cargan para `setAdOverride`. Arranca en
  /// este instante. Devuelve "" o el error.
  String setAdPlaylist(String json);

  /// La última miniatura JPEG de 640×360 (IOS-64): `left`, `right` o `program`. Vacía si
  /// todavía no hay.
  Uint8List thumbnail(String name);

  /// Un anuncio ya cargado que se cuela desde ahora `loops` vueltas; nombre vacío lo quita.
  void setAdOverride(String name, int loops);
}

@FlutterApi()
abstract class RigFlutterApi {
  /// Progreso del banco en marcha, para la página: fracción 0-1 y una línea de detalle.
  void onBenchProgress(String name, double fraction, String detail);
}
