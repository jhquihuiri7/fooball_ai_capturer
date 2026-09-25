/// El vocabulario visual de Zero: tarjeta, etiqueta de sección, fila de datos, chip,
/// píldora y botón.
///
/// Existe para que las tres pantallas no vuelvan a inventar cada una su tarjeta. Todo
/// lo que aquí se decide una vez —radios, altos mínimos, cómo se pinta un estado
/// activo— deja de ser una decisión suelta en `capture_page.dart` y en `match_page.dart`.
library;

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';

/// Qué está diciendo un valor. Decide su color, y nada más.
enum ZeroTone {
  /// Un dato sin más: la resolución, la batería.
  neutral,

  /// Confirma algo que **tenía** que estar bien: estabilización desactivada, exposición
  /// bloqueada, 0 frames perdidos. Es el único sitio donde el acento aparece dentro de
  /// una lista de datos.
  ok,

  /// La alarma. Rojo, nunca naranja: el naranja es el color del equipo local.
  bad,
}

extension ZeroToneColor on ZeroTone {
  Color get color => switch (this) {
    ZeroTone.neutral => ZeroColors.ink,
    ZeroTone.ok => ZeroColors.accentLight,
    ZeroTone.bad => ZeroColors.alarm,
  };
}

/// La tarjeta: blanco al 5 % con borde al 10 %, radio 22.
class ZeroCard extends StatelessWidget {
  const ZeroCard({
    required this.child,
    this.padding = ZeroMetrics.cardPadding,
    this.background = ZeroColors.surface,
    this.border = ZeroColors.border,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(ZeroMetrics.cardRadius),
      ),
      child: child,
    );
  }
}

/// La cabecera de una tarjeta: la etiqueta a la izquierda y, si hace falta, un chip de
/// estado o un dato al otro extremo.
///
/// La etiqueta mide lo que mide —SOPORTE, POSICIONES: siempre corta— y el otro extremo
/// se queda con el resto, pegado a la derecha y recortándose si no cabe. Un nombre de
/// equipo largo —«DEPORTIVO INDEPENDIENTE · 4-3-3»— no cabe en 320 px junto a su
/// etiqueta, y lo que hace un `Row` rígido en ese caso no es recortar: es pintar la
/// franja amarilla y negra encima de la tarjeta. Dos `Flexible` tampoco sirven: el hueco
/// que no usa la etiqueta se pierde y el chip acaba en mitad de la fila.
class ZeroSectionHeader extends StatelessWidget {
  const ZeroSectionHeader(this.label, {this.trailing, this.bottomGap = 14, super.key});

  final String label;
  final Widget? trailing;
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomGap),
      child: Row(
        children: <Widget>[
          Text(
            label.toUpperCase(),
            maxLines: 1,
            style: ZeroType.sectionLabel(ZeroColors.inkTertiary),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ],
      ),
    );
  }
}

/// Una fila de datos: etiqueta a la izquierda, valor a la derecha en monoespaciada.
///
/// La separación es una línea al 10 % **arriba**, no una tarjeta anidada: anidar
/// tarjetas convierte una lista en un acordeón de cajas y deja de leerse de un barrido.
///
/// El valor envuelve en vez de recortarse. Una URL de SRT cortada con puntos
/// suspensivos no sirve para nada: justo el trozo que hay que comprobar es el final.
class ZeroDataRow extends StatelessWidget {
  const ZeroDataRow(this.label, this.value, {this.tone = ZeroTone.neutral, super.key});

  final String label;
  final String value;
  final ZeroTone tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: ZeroColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: ZeroType.plex(
              size: 12,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.4,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: ZeroType.data(
                size: 12,
                weight: FontWeight.w500,
                color: tone.color,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Un chip de estado: LISTA, EMITIENDO, AL AIRE.
class ZeroChip extends StatelessWidget {
  const ZeroChip(
    this.text, {
    required this.background,
    required this.border,
    required this.foreground,
    super.key,
  });

  /// Acento: algo está listo, o en marcha como debe.
  const ZeroChip.accent(String text, {Key? key})
    : this(
        text,
        background: ZeroColors.accentChip,
        border: ZeroColors.accentChipBorder,
        foreground: ZeroColors.accentLight,
        key: key,
      );

  /// Rojo: al aire, o algo que impide grabar.
  const ZeroChip.danger(String text, {Key? key})
    : this(
        text,
        background: ZeroColors.dangerChip,
        border: ZeroColors.dangerStrong,
        foreground: ZeroColors.alarm,
        key: key,
      );

  /// Apagado, dentro de una tarjeta. El gris terciario sobre el velo del chip más el de
  /// la tarjeta baja a 4.1:1, por debajo de lo legible a 9 px: aquí va el secundario.
  const ZeroChip.mutedOnCard(String text, {Key? key})
    : this(
        text,
        background: ZeroColors.mutedChip,
        border: ZeroColors.mutedChipBorder,
        foreground: ZeroColors.inkSecondary,
        key: key,
      );

  /// Apagado, sobre el fondo de la app (la cabecera).
  const ZeroChip.muted(String text, {Key? key})
    : this(
        text,
        background: ZeroColors.mutedChip,
        border: ZeroColors.mutedChipBorder,
        foreground: ZeroColors.inkTertiary,
        key: key,
      );

  final String text;
  final Color background;
  final Color border;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        softWrap: false,
        style: ZeroType.data(
          size: 9,
          weight: FontWeight.w500,
          color: foreground,
          letterSpacing: 1.26,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Una píldora seleccionable: SRT/RTMP, Local/Visita, 4-3-3.
///
/// Activa = acento al 18 % con borde acento y texto en acento claro. Inactiva =
/// transparente con borde al 22 % y texto principal. Nunca al revés: el acento marca lo
/// elegido, no lo elegible.
class ZeroPill extends StatelessWidget {
  const ZeroPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.mono = false,
    this.minHeight = ZeroMetrics.segmentHeight,
    this.expand = true,
    super.key,
  });

  final String label;
  final bool selected;

  /// `null` la deja quieta: con una orden al panel en camino, nada se pulsa dos veces.
  final VoidCallback? onTap;

  /// Una formación es un dato, no una palabra: va en monoespaciada.
  final bool mono;
  final double minHeight;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? ZeroColors.accentLight : ZeroColors.ink;
    final Widget pill = ZeroTappable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      decoration: BoxDecoration(
        color: selected ? ZeroColors.accentFill : Colors.transparent,
        border: Border.all(color: selected ? ZeroColors.accent : ZeroColors.outline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        alignment: Alignment.center,
        // Las formaciones van más anchas y un punto más bajas que los segmentos: son
        // tres píldoras que se envuelven, no dos que se reparten la fila.
        padding: mono
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 11)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(
          label,
          style: mono
              ? ZeroType.data(
                  size: 12,
                  weight: FontWeight.w500,
                  color: foreground,
                  letterSpacing: 0.72,
                  height: 1.0,
                )
              : ZeroType.plex(size: 13, weight: FontWeight.w600, color: foreground, height: 1.0),
        ),
      ),
    );
    // El estado elegido solo se ve por el color; sin esto, VoiceOver lee «SRT, RTMP»
    // sin decir cuál se va a usar.
    final Widget labelled = Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: pill,
    );
    // Sin `IntrinsicWidth`, el `Container` centrado se estira hasta el ancho que le
    // dejen: dentro de un `Wrap` cada formación ocuparía una fila entera.
    return expand ? Expanded(child: labelled) : IntrinsicWidth(child: labelled);
  }
}

/// El botón con el que se hace algo: GRABAR, Emitir, Abrir cámara.
class ZeroButton extends StatelessWidget {
  const ZeroButton({
    required this.label,
    required this.onPressed,
    required this.background,
    required this.foreground,
    required this.height,
    this.textStyle,
    this.border,
    this.expand = true,
    super.key,
  });

  /// Acento sólido con tinta oscura: la acción que la pantalla está esperando.
  const ZeroButton.primary({
    required String label,
    required VoidCallback? onPressed,
    double height = ZeroMetrics.pillHeight,
    TextStyle? textStyle,
    bool expand = true,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         background: ZeroColors.accent,
         foreground: ZeroColors.onAccent,
         height: height,
         textStyle: textStyle,
         expand: expand,
         key: key,
       );

  /// Rojo sólido: lo que para algo que está corriendo.
  const ZeroButton.destructive({
    required String label,
    required VoidCallback? onPressed,
    double height = ZeroMetrics.pillHeight,
    TextStyle? textStyle,
    bool expand = true,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         background: ZeroColors.danger,
         foreground: ZeroColors.white,
         height: height,
         textStyle: textStyle,
         expand: expand,
         key: key,
       );

  /// Transparente con borde: lo que se pulsa de vez en cuando.
  const ZeroButton.secondary({
    required String label,
    required VoidCallback? onPressed,
    Color foreground = ZeroColors.ink,
    double height = ZeroMetrics.segmentHeight,
    TextStyle? textStyle,
    bool expand = true,
    Key? key,
  }) : this(
         label: label,
         onPressed: onPressed,
         background: Colors.transparent,
         foreground: foreground,
         border: ZeroColors.outline,
         height: height,
         textStyle: textStyle,
         expand: expand,
         key: key,
       );

  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final double height;
  final TextStyle? textStyle;
  final Color? border;

  /// `false` para un botón que solo ocupa lo que mide su texto, como «Reiniciar» al
  /// lado del cronómetro.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    // Deshabilitado se dice con el gris terciario a opacidad completa, no bajando la
    // opacidad del botón entero: una pantalla al sol ya está bastante lavada.
    final bool enabled = onPressed != null;
    final Color fill = enabled ? background : ZeroColors.surface;
    final Color ink = enabled ? foreground : ZeroColors.inkTertiary;
    final Color edge = enabled ? (border ?? fill) : ZeroColors.border;

    final Widget button = ZeroTappable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: edge),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Container(
        width: expand ? double.infinity : null,
        constraints: BoxConstraints(minHeight: height),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style:
              (textStyle ??
                      ZeroType.plex(size: 15, weight: FontWeight.w600, color: ink, height: 1.0))
                  .copyWith(color: ink),
        ),
      ),
    );
    // GRABAR deshabilitado tiene que anunciarse como tal: un «GRABAR» a secas que no
    // hace nada al pulsarlo se lee como un botón roto.
    final Widget labelled = Semantics(button: true, enabled: enabled, child: button);
    // Igual que en `ZeroPill`: sin ancho intrínseco, el botón que no se expande se
    // estiraría igual en cuanto su padre le diera un ancho acotado.
    return expand ? labelled : IntrinsicWidth(child: labelled);
  }
}

/// Un `+` o un `−` del marcador: 46×46, radio 13.
class ZeroStepper extends StatelessWidget {
  const ZeroStepper({
    required this.sign,
    required this.onTap,
    required this.semanticLabel,
    this.background = Colors.transparent,
    this.border = ZeroColors.outline,
    this.foreground = ZeroColors.ink,
    super.key,
  });

  final String sign;

  /// `null` lo deja quieto, como en [ZeroPill].
  final VoidCallback? onTap;

  /// Un `+` suelto no dice nada en voz alta: aquí va «un gol más al local».
  final String semanticLabel;
  final Color background;
  final Color border;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    // `excludeSemantics` se lleva también la acción del `InkWell`, así que el toque se
    // declara aquí: sin `onTap`, VoiceOver y TalkBack anuncian el botón pero no pueden
    // pulsarlo.
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: ZeroTappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ZeroMetrics.stepperRadius),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(ZeroMetrics.stepperRadius),
        ),
        child: Container(
          width: ZeroMetrics.stepperSize,
          height: ZeroMetrics.stepperSize,
          alignment: Alignment.center,
          child: Text(
            sign,
            style: ZeroType.data(size: 19, weight: FontWeight.w500, color: foreground, height: 1.0),
          ),
        ),
      ),
    );
  }
}

/// Toque con realce, sin la tinta de Material por omisión: la app es oscura y plana, y
/// una onda morada de `InkWell` no pertenece a esta paleta.
///
/// El fondo se pasa como [decoration] y no dentro de [child] por una razón concreta:
/// Material pinta la onda **debajo** de sus hijos. Un `Container` con fondo opaco como
/// hijo taparía el realce, y justo los botones sólidos —GRABAR, Abrir cámara— se
/// quedarían sin respuesta al toque; al sol, quien no ve que el toque entró, vuelve a
/// pulsar. Con `Ink`, el fondo se pinta en el propio Material y la onda queda encima.
class ZeroTappable extends StatelessWidget {
  const ZeroTappable({
    required this.child,
    required this.onTap,
    required this.borderRadius,
    this.decoration,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final BoxDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Ink(
        decoration: decoration,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          splashColor: ZeroColors.press,
          highlightColor: ZeroColors.press,
          child: child,
        ),
      ),
    );
  }
}
