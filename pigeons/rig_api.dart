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
@HostApi()
abstract class RigHostApi {
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
  /// dentro de `Documents/ads/`. Arranca en este instante. Devuelve "" o el error.
  String setAdPlaylist(String json);

  /// Un anuncio ya cargado que se cuela desde ahora `loops` vueltas; nombre vacío lo quita.
  void setAdOverride(String name, int loops);
}

@FlutterApi()
abstract class RigFlutterApi {
  /// Progreso del banco en marcha, para la página: fracción 0-1 y una línea de detalle.
  void onBenchProgress(String name, double fraction, String detail);
}
