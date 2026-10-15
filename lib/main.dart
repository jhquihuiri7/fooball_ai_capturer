/// App de captura del soporte de dos iPhone (ADR 0012 del repo `football-ai`).
///
/// La app tiene dos lugares y no uno. **Captura** es el móvil que está en el soporte:
/// elegir el lado, comprobar que la cámara arrancó bien y darle a grabar. **Partido**
/// es quien lleva el marcador y las posiciones. Están separados a propósito: cuando las
/// dos cosas comparten pantalla, lo que acaba pasando es un toque de más en GRABAR a
/// mitad de partido.
///
/// Lo demás lo decide el código. Los ajustes de la cámara no son preferencias
/// (`defaultSettings`), y grabar sin reloj común no se puede aunque se quiera
/// (`CaptureSession.canRecord`).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/auto_emitir.dart';
import 'package:football_ai_capture/src/bench_page.dart';
import 'package:football_ai_capture/src/role_page.dart';
import 'package:football_ai_capture/src/theme/zero_theme.dart';
import 'package:football_ai_capture/src/zero_shell.dart';

// Se reexportan para que las pantallas se importen desde un solo sitio, aquí o en un
// test, sin tener que saber en qué fichero de `src/` vive cada una.
export 'package:football_ai_capture/src/capture_page.dart' show CapturePage;
export 'package:football_ai_capture/src/match_page.dart' show MatchPage;
export 'package:football_ai_capture/src/match_state.dart';
export 'package:football_ai_capture/src/role_page.dart' show RolePage;
export 'package:football_ai_capture/src/zero_shell.dart' show ZeroShell;

/// Banco de pruebas del enlace entre móviles sin tocar la pantalla, por ejemplo en dos
/// simuladores: `flutter run --dart-define=AUTO_ROLE=right --dart-define=LINK_ONLY=true`
/// entra directo como ese lado y abre solo el enlace, sin cámara. Vacío en producción.
const String _autoRole = String.fromEnvironment('AUTO_ROLE');
const bool _linkOnly = bool.fromEnvironment('LINK_ONLY');

/// «Este móvil dirige» con AUTO_ROLE (IOS-80): `true` o `false`; vacío, el de siempre (el
/// izquierdo). Para el banco del rol desacoplado del lado.
const String _prefersMaster = String.fromEnvironment('PREFERS_MASTER');

/// Grabación de prueba sin tocar la pantalla (IOS-15): con AUTO_ROLE, un solo móvil
/// (STANDALONE) y AUTO_RECORD_S, empieza a grabar guardando el vídeo en cuanto la
/// cámara está lista y para sola a los AUTO_RECORD_S segundos. 0 = no graba.
const bool _standalone = bool.fromEnvironment('STANDALONE');
const int _autoRecordS = int.fromEnvironment('AUTO_RECORD_S');

/// EMITIR sin tocar la pantalla (2026-10-15, `tools/emitir_auto.sh`): con AUTO_ROLE y
/// AUTO_EMITIR=true, el camino de producción de los toques —el lado, «Este móvil dirige» en
/// el izquierdo, el enlace AUTO_LINK (aware, wifi o single: «Una cámara (sin pareja)») de
/// «Enlace y emisión», «Abrir cámara» y, en el maestro con LISTA, el mismo EMITIR del
/// botón—, y no el banco split. AUTO_EMITIR_4K
/// enciende «Guardar vídeo»; AUTO_EMITIR_S > 0 llama a PARAR a esos segundos de EMITIR.
/// Los interruptores valen `1` o `true`.
const String _autoEmitirDefine = String.fromEnvironment('AUTO_EMITIR');
const bool _autoEmitir = _autoEmitirDefine == '1' || _autoEmitirDefine == 'true';
const String _autoLink = String.fromEnvironment('AUTO_LINK', defaultValue: 'aware');
const String _autoEmitir4kDefine = String.fromEnvironment('AUTO_EMITIR_4K');
const bool _autoEmitir4k = _autoEmitir4kDefine == '1' || _autoEmitir4kDefine == 'true';
const int _autoEmitirS = int.fromEnvironment('AUTO_EMITIR_S');

/// IOS-08: `flutter run --dart-define=BENCH=<nombre>` abre el modo banco, que corre
/// solo y deja su informe en Documents/bench/. Vacío en producción.
/// BENCH_PARAMS lleva los parámetros del banco como JSON, tal cual al informe:
/// `--dart-define=BENCH_PARAMS={"duration_s":30}`.
const String _bench = String.fromEnvironment('BENCH');
const String _benchParams = String.fromEnvironment('BENCH_PARAMS', defaultValue: '{}');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // El splash nativo va a pantalla completa y deja la barra de estado oculta. Aquí se
  // devuelve: la hora y la batería del móvil son información de campo, y el diseño
  // cuenta con ella. Iconos claros, porque el fondo es oscuro siempre.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const CaptureApp());
}

class CaptureApp extends StatelessWidget {
  const CaptureApp({this.api, super.key});

  /// Inyectable para los tests.
  final CaptureHostApi? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zero',
      theme: zeroTheme(),
      // Un solo tema: la app es oscura siempre. En una cancha de noche, un tema claro
      // deslumbra a quien mira el móvil y ciega a quien mira el campo después.
      themeMode: ThemeMode.dark,
      home: _bench.isNotEmpty
          ? BenchPage(name: _bench, paramsJson: _benchParams)
          : _autoRole.isEmpty
          ? RolePage(api: api)
          : _autoEmitir
          ? autoEmitirShell(
              role: _autoRole,
              link: _autoLink,
              save4k: _autoEmitir4k,
              stopAfterS: _autoEmitirS,
              prefersMaster: _prefersMaster,
            )
          : ZeroShell(
              role: _autoRole == 'right' ? CameraRole.right : CameraRole.left,
              linkOnly: _linkOnly,
              standalone: _standalone,
              autoRecordSeconds: _autoRecordS,
              prefersMaster: _prefersMaster.isEmpty ? null : _prefersMaster == 'true',
            ),
    );
  }
}

/// La pantalla de captura del modo sin toques, como la abre «Abrir cámara» desde la de lado
/// (`RolePage._open`): sin servidor del pod (el programa va al QR Soporte del Keychain, o
/// SIN DESTINO), «Este móvil dirige» en el izquierdo salvo PREFERS_MASTER, y el enlace pedido
/// (aware por defecto; wifi, ethernet o single; nunca Multipeer, que no tiene programa). Con
/// single dirige del lado que sea, como desde la pantalla.
ZeroShell autoEmitirShell({
  required String role,
  required String link,
  required bool save4k,
  required int stopAfterS,
  String prefersMaster = '',
}) {
  final CameraRole lado = role == 'right' ? CameraRole.right : CameraRole.left;
  final LinkMode modo =
      LinkMode.values.where((LinkMode m) => m.name == link && m != LinkMode.multipeer).firstOrNull ??
      LinkMode.aware;
  return ZeroShell(
    role: lado,
    prefersMaster: modo == LinkMode.single ||
        (prefersMaster.isEmpty ? lado == CameraRole.left : prefersMaster == 'true'),
    linkMode: modo,
    autoEmitir: AutoEmitirConfig(
      save4k: save4k,
      stopAfter: stopAfterS > 0 ? Duration(seconds: stopAfterS) : null,
    ),
  );
}
