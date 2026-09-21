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
      home: _autoRole.isEmpty
          ? RolePage(api: api)
          : ZeroShell(
              role: _autoRole == 'right' ? CameraRole.right : CameraRole.left,
              linkOnly: _linkOnly,
            ),
    );
  }
}
