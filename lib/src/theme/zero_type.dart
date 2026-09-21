/// La tipografía Zero: tres familias con un reparto que no se cruza.
///
/// - **Archivo** — cifras grandes y titulares: cronómetro, goles, GRABAR, títulos.
/// - **IBM Plex Sans** — botones, nombres de jugador, texto corrido.
/// - **IBM Plex Mono** — todo dato técnico: ms, ppm, Mbit/s, resoluciones, marcas de
///   tiempo, nombres de fichero, y las etiquetas de sección.
///
/// Que los datos vayan en monoespaciada no es un gusto: son cifras que se leen de un
/// vistazo desde metro y medio, y en proporcional un `1` y un `7` ocupan distinto, así
/// que la columna baila a cada actualización. Por lo mismo, el cronómetro y el marcador
/// piden [FontFeature.tabularFigures].
///
/// Los interletrajes salen del HTML de referencia, que manda sobre cualquier regla
/// general: ahí están en `em` y aquí en píxeles ya multiplicados por el tamaño.
library;

import 'package:flutter/painting.dart';

abstract final class ZeroType {
  static const String display = 'Archivo';
  static const String sans = 'IBM Plex Sans';
  static const String mono = 'IBM Plex Mono';

  /// Cifras que no bailan al actualizarse.
  static const List<FontFeature> tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// Titular o cifra grande.
  static TextStyle archivo({
    required double size,
    required FontWeight weight,
    required Color color,
    double? letterSpacing,
    double? height,
    bool tabularFigures = false,
  }) {
    return TextStyle(
      fontFamily: display,
      fontSize: size,
      fontWeight: weight,
      color: color,
      // A partir de cierto cuerpo, el interletrado por omisión abre demasiado: el
      // titular se deshace en letras sueltas en vez de leerse como una palabra.
      letterSpacing: letterSpacing ?? -0.03 * size,
      height: height,
      fontFeatures: tabularFigures ? tabular : null,
    );
  }

  /// Texto de interfaz.
  static TextStyle plex({
    required double size,
    required FontWeight weight,
    required Color color,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: sans,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// Dato técnico.
  static TextStyle data({
    required double size,
    required FontWeight weight,
    required Color color,
    double? letterSpacing,
    double? height,
    bool tabularFigures = false,
  }) {
    return TextStyle(
      fontFamily: mono,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: tabularFigures ? tabular : null,
    );
  }

  /// La etiqueta de una sección: mono 10, interletrado 2, mayúsculas, gris terciario.
  /// Siempre igual, en las tres pantallas.
  static TextStyle sectionLabel(Color color) =>
      data(size: 10, weight: FontWeight.w500, color: color, letterSpacing: 2.0, height: 1.0);
}
