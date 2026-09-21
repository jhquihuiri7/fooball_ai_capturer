/// El tema de la app.
///
/// Explícito y no `colorSchemeSeed`: la semilla verde de Material genera su propio teal
/// —y su propio gris, y su propio rojo— que no es el de la marca, y luego cada pantalla
/// acaba peleándose con el tema a base de `styleFrom`. Aquí se fija una vez.
library;

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';

ThemeData zeroTheme() {
  const ColorScheme scheme = ColorScheme.dark(
    primary: ZeroColors.accent,
    onPrimary: ZeroColors.onAccent,
    secondary: ZeroColors.accentLight,
    onSecondary: ZeroColors.onAccent,
    error: ZeroColors.danger,
    onError: ZeroColors.white,
    surface: ZeroColors.background,
    onSurface: ZeroColors.ink,
    outline: ZeroColors.inkTertiary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    // El mismo `#12181A` del splash nativo. Si no coinciden se ve un destello blanco
    // entre el splash y el primer frame de Flutter.
    scaffoldBackgroundColor: ZeroColors.background,
    canvasColor: ZeroColors.background,
    fontFamily: ZeroType.sans,
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: ZeroColors.accent,
      selectionColor: ZeroColors.accentFill,
      selectionHandleColor: ZeroColors.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ZeroColors.accent,
        foregroundColor: ZeroColors.onAccent,
        disabledBackgroundColor: ZeroColors.surface,
        disabledForegroundColor: ZeroColors.inkTertiary,
        // 50 px: se usa de pie, con sol y con la mano sudada.
        minimumSize: const Size.fromHeight(50),
        shape: const StadiumBorder(),
        textStyle: ZeroType.plex(
          size: 15,
          weight: FontWeight.w600,
          color: ZeroColors.onAccent,
          height: 1.0,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ZeroColors.ink,
        disabledForegroundColor: ZeroColors.inkTertiary,
        minimumSize: const Size.fromHeight(44),
        side: const BorderSide(color: ZeroColors.outline),
        shape: const StadiumBorder(),
        textStyle: ZeroType.plex(
          size: 14,
          weight: FontWeight.w600,
          color: ZeroColors.ink,
          height: 1.0,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ZeroColors.chromeFill,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
        final bool selected = states.contains(WidgetState.selected);
        // El icono inactivo va en `inactive` (#6F787C), como en el diseño; la
        // etiqueta no puede: ese gris da 3.97:1 sobre la barra y el texto pide 4.5.
        return ZeroType.plex(
          size: 11,
          weight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? ZeroColors.accentLight : ZeroColors.inkTertiary,
          height: 1.0,
        );
      }),
    ),
    textTheme: TextTheme(
      bodyMedium: ZeroType.plex(size: 14, weight: FontWeight.w400, color: ZeroColors.ink),
      bodySmall: ZeroType.plex(size: 12, weight: FontWeight.w400, color: ZeroColors.inkTertiary),
    ),
  );
}
