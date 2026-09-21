/// La paleta Zero. Fuera de aquí no se escribe ningún color.
///
/// Tres reglas que no se negocian, porque cada una arregla un fallo concreto en una
/// cancha con sol:
///
/// 1. **El acento solo aparece en lo que está activo o listo.** Si todo brilla, nada
///    destaca, y el operador deja de mirar la pantalla.
/// 2. **Las alarmas van en [alarm], nunca en un naranja de Material.** El naranja se
///    confunde con el color del equipo local, que también es cálido.
/// 3. **Ningún texto se atenúa con opacidad.** Un gris a opacidad completa se lee
///    igual bajo el sol; un blanco al 60 % desaparece. Cuando el diseño pide un 70 %,
///    aquí vive el color ya mezclado contra su fondo.
library;

import 'package:flutter/painting.dart';

/// Los colores de marca y los velos neutros que el diseño usa sobre ellos.
abstract final class ZeroColors {
  // ------------------------------------------------------------------------- //
  // Marca
  // ------------------------------------------------------------------------- //

  /// Fondo de pantalla. También el del splash nativo: si no coinciden se ve un
  /// destello entre el splash y el primer frame de Flutter.
  static const Color background = Color(0xFF12181A);

  /// Texto principal.
  static const Color ink = Color(0xFFFAFAF7);

  /// Texto secundario: párrafos, nombres de equipo en la tira del marcador.
  static const Color inkSecondary = Color(0xFFB7BFC3);

  /// Texto terciario y etiquetas de sección. Es el gris con el que se atenúa: a
  /// opacidad completa, no con `withValues`.
  static const Color inkTertiary = Color(0xFF8E979C);

  /// Acento. Solo en lo activo o lo listo.
  static const Color accent = Color(0xFF00B8A9);

  /// Texto sobre acento tenue. El acento puro sobre un velo del 18 % no llega a 4.5:1.
  static const Color accentLight = Color(0xFF2ECFC0);

  /// Peligro: grabando, al aire, el modo de un solo móvil.
  static const Color danger = Color(0xFFE5484D);

  /// Texto de alarma. Es el rojo que se lee; [danger] como texto sobre fondo oscuro
  /// no llega al contraste mínimo.
  static const Color alarm = Color(0xFFFF9A9C);

  /// Equipo local.
  static const Color home = Color(0xFFF26B38);

  /// Texto sobre local tenue.
  static const Color homeLight = Color(0xFFFFB08A);

  /// Tinta sobre acento sólido.
  static const Color onAccent = Color(0xFF151A1D);

  /// Blanco puro. Solo en tres sitios, los tres pedidos por el diseño: el texto sobre
  /// rojo sólido (PARAR, GRABANDO), el texto de los datos sobre la imagen y el pomo del
  /// interruptor. Para texto sobre el fondo de la app se usa [ink], que es más cálido.
  static const Color white = Color(0xFFFFFFFF);

  /// Negro puro: el fondo de la vista previa mientras la cámara no pinta nada.
  static const Color black = Color(0xFF000000);

  /// Destino inactivo de la barra inferior. Suficiente para leerse, insuficiente para
  /// competir con el destino activo.
  static const Color inactive = Color(0xFF6F787C);

  /// Texto de un chip apagado sobre la imagen (EN PAUSA). Más claro que
  /// [inkSecondary] porque va sobre césped al sol a través de un velo del 60 %, no
  /// sobre el fondo de la app.
  static const Color hudInk = Color(0xFFD3D8D3);

  // ------------------------------------------------------------------------- //
  // Velos neutros
  //
  // No son colores nuevos: son blanco o negro con alfa sobre [background]. Viven aquí
  // con nombre para que nadie vuelva a escribir un `Colors.white.withValues(...)`
  // suelto y el 10 % de una tarjeta acabe siendo el 12 % en la de al lado.
  // ------------------------------------------------------------------------- //

  /// Superficie de tarjeta: blanco al 5 %.
  static const Color surface = Color(0x0DFFFFFF);

  /// Borde de tarjeta: blanco al 10 %. También la línea que separa filas de datos.
  static const Color border = Color(0x1AFFFFFF);

  /// Borde de un control inactivo: blanco al 22 %.
  static const Color outline = Color(0x38FFFFFF);

  /// Borde del campo de servidor y de la tira del marcador: blanco al 14 %.
  static const Color outlineSoft = Color(0x24FFFFFF);

  /// Borde de la vista previa: blanco al 12 %.
  static const Color previewBorder = Color(0x1FFFFFFF);

  /// Borde de un chip sobre la imagen: blanco al 18 %.
  static const Color hudBorder = Color(0x2EFFFFFF);

  /// Separador de la cabecera y de la barra inferior: blanco al 9 %.
  static const Color chrome = Color(0x17FFFFFF);

  /// Realce de una celda dentro de la tira del marcador: blanco al 8 %.
  static const Color cellFill = Color(0x14FFFFFF);

  /// Pista de un interruptor apagado: blanco al 18 %.
  static const Color switchTrack = Color(0x2EFFFFFF);

  /// Fondo hundido: negro al 35 %. El campo de servidor y la tira del marcador.
  static const Color well = Color(0x59000000);

  /// Fondo de un chip sobre la imagen: negro al 60 %. Es lo que hace legible un dato
  /// sobre césped iluminado.
  static const Color hudFill = Color(0x99000000);

  /// Cabecera y barra inferior translúcidas: el fondo al 94 %.
  static const Color chromeFill = Color(0xF012181A);

  /// Velo de la vista previa, de arriba abajo: negro al 42 %, nada al 34 % del alto y
  /// negro al 58 % abajo. Oscurece la imagen justo donde va texto y en ningún otro
  /// sitio, para no falsear lo que se está encuadrando.
  static const Color scrimTop = Color(0x6B000000);
  static const Color scrimClear = Color(0x00000000);
  static const Color scrimBottom = Color(0x94000000);

  // ------------------------------------------------------------------------- //
  // Estados
  // ------------------------------------------------------------------------- //

  /// Fondo de un control activo: acento al 18 %.
  static const Color accentFill = Color(0x2E00B8A9);

  /// Fondo de un chip de acento: acento al 14 %.
  static const Color accentChip = Color(0x2400B8A9);

  /// Borde de un chip de acento: acento al 50 %.
  static const Color accentChipBorder = Color(0x8000B8A9);

  /// Borde de un control activo de acento cuando el fondo ya lleva el velo: 60 %.
  static const Color accentStrong = Color(0x9900B8A9);

  /// Fondo de la tarjeta de problema: rojo al 7 %.
  static const Color dangerCard = Color(0x12E5484D);

  /// Fondo del banner de grabación: rojo al 14 %.
  static const Color dangerFill = Color(0x24E5484D);

  /// Fondo del chip de fallo: rojo al 16 %.
  static const Color dangerChip = Color(0x29E5484D);

  /// Fondo del chip «al aire»: rojo al 18 %, un punto más encendido que un fallo.
  static const Color onAirChip = Color(0x2EE5484D);

  /// Fondo de la fila de un solo móvil encendida: rojo al 10 %.
  static const Color dangerRow = Color(0x1AE5484D);

  /// Borde rojo tenue: 35 %.
  static const Color dangerCardBorder = Color(0x59E5484D);

  /// Borde rojo medio: 45 %.
  static const Color dangerBorder = Color(0x73E5484D);

  /// Borde rojo fuerte: 60 %.
  static const Color dangerStrong = Color(0x99E5484D);

  /// Fondo del `+` local y del dorsal local: local al 18 %.
  static const Color homeFill = Color(0x2EF26B38);

  /// Borde del `+` local: local al 60 %.
  static const Color homeStrong = Color(0x99F26B38);

  /// Realce al pulsar: blanco al 12 %. Se ve sobre el teal sólido y sobre el fondo,
  /// que es donde un velo de acento desaparecería.
  static const Color press = Color(0x1FFFFFFF);

  /// Chip apagado: blanco al 8 % con borde al 20 %.
  static const Color mutedChip = Color(0x14FFFFFF);
  static const Color mutedChipBorder = Color(0x33FFFFFF);

  /// Mezcla [color] al [alpha] indicado **contra un fondo opaco** y devuelve un color
  /// opaco.
  ///
  /// Es la forma de obtener el «70 %» del diseño sin poner opacidad en un texto: el
  /// resultado se pinta a opacidad completa y se lee igual bajo el sol.
  static Color blend(Color color, double alpha, Color over) =>
      Color.alphaBlend(color.withValues(alpha: alpha), over);
}
