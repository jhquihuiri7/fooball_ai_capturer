/// Las medidas de Zero. Están aquí y no repartidas por las pantallas porque una
/// tarjeta con radio 22 al lado de otra con radio 20 se nota aunque nadie sepa decir
/// por qué.
///
/// Los altos mínimos no son estéticos: la app se usa de pie, con sol, con la mano
/// sudada y sin mirar. Nada por debajo de 44 px se acierta en esas condiciones, y lo
/// que para el partido —GRABAR— es lo más alto de la pantalla.
library;

import 'package:flutter/widgets.dart';

abstract final class ZeroMetrics {
  /// Radio de tarjeta.
  static const double cardRadius = 22;

  /// Relleno de tarjeta.
  static const EdgeInsets cardPadding = EdgeInsets.all(20);

  /// Relleno de una tarjeta de filas de datos: algo más plano, porque la primera línea
  /// ya trae su propia separación.
  static const EdgeInsets dataCardPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 18);

  /// Separación entre tarjetas.
  static const double cardGap = 12;

  /// Separación dentro de una tarjeta.
  static const double innerGap = 14;

  /// Margen lateral de pantalla.
  static const double gutter = 20;

  /// Alto mínimo de un botón píldora.
  static const double pillHeight = 50;

  /// Alto mínimo de un segmento o de un botón secundario.
  static const double segmentHeight = 44;

  /// Alto de los `+`/`−` del marcador y de los botones de minuto.
  static const double stepperSize = 46;

  /// Radio de los `+`/`−` del marcador.
  static const double stepperRadius = 13;

  /// Alto del botón primario de la pantalla de lado.
  static const double primaryHeight = 58;

  /// Alto del botón GRABAR. Es el control que decide el partido: se acierta sin mirar.
  static const double recordHeight = 72;

  /// Radio de la vista previa.
  static const double previewRadius = 18;

  /// Radio del campo de servidor y de la tira del marcador.
  static const double fieldRadius = 14;
}
