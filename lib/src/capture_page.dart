/// El móvil que está en el soporte.
///
/// El orden de la pantalla es el orden en que se mira, y no al revés:
///
/// 1. **la imagen**, con lo urgente encima —grabando o no, cuánto lleva, resolución,
///    obturación y fase—, porque un encuadre torcido se ve en la imagen y en ningún
///    otro sitio;
/// 2. **GRABAR**, a 72 px de alto: el control que decide el partido se acierta sin
///    mirar y con la mano sudada;
/// 3. **el banner** debajo del botón, no encima, porque confirma lo que acabas de
///    pulsar;
/// 4. **un problema, si lo hay**, antes que cualquier dato. Si hay algo que impide
///    grabar es lo primero que hay que leer, no la fila catorce;
/// 5. **los datos**, en cuatro tarjetas con nombre. Veinte filas planas son una lista
///    donde una alarma no se distingue de la batería.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/capture_labels.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

/// La vista nativa con la imagen de la cámara: una capa de previsualización sobre la
/// misma sesión que graba, así que enseña el encuadre real y no cuesta CPU.
const String capturePreviewViewType = 'capture-preview';

class CapturePage extends StatefulWidget {
  const CapturePage({
    required this.role,
    this.session,
    this.standalone = false,
    this.serverHost = '',
    this.linkOnly = false,
    super.key,
  });

  final CameraRole role;

  /// Inyectable para los tests: sin esto habría que hablar con la cámara de verdad.
  final CaptureSession? session;

  /// Probar con un solo móvil, sin esperar reloj (ver `CaptureSession.standalone`).
  final bool standalone;

  /// Host o IP del servidor. Vacío: solo grabación.
  final String serverHost;

  /// Solo el enlace entre móviles, sin cámara (ver `CaptureSession.linkOnly`).
  final bool linkOnly;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureSession _session =
      widget.session ??
      CaptureSession(
        role: widget.role,
        standalone: widget.standalone,
        serverHost: widget.serverHost,
        linkOnly: widget.linkOnly,
      );

  /// Refresco del estado nativo. Además de traer batería, calor y frames perdidos,
  /// repinta una vez por segundo, que es lo que hace avanzar el reloj del HUD.
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onChanged);
    // Los avisos del nativo van a la sesión que está en pantalla.
    CaptureFlutterApi.setUp(_session);
    // La cámara se abre sola al entrar: en la cancha nadie tiene que saber que hay un
    // paso previo. En un microtask y no aquí mismo, porque `prepare` notifica nada más
    // empezar y eso sería un `setState` en mitad del primer build.
    unawaited(Future<void>.microtask(_session.prepare));
    _refresh = Timer.periodic(statusRefreshInterval, (_) => unawaited(_session.refreshStatus()));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    CaptureFlutterApi.setUp(null);
    _session.removeListener(_onChanged);
    // La sesión la libera quien la crea. Si viene de fuera —un test—, liberarla aquí
    // dejaría al dueño con una sesión muerta.
    if (widget.session == null) {
      _session.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final CaptureReadout r = CaptureReadout(_session);
    final List<CaptureReading> trouble = r.troubleReadings;
    // Mientras graba no se sale. El gesto de volver de iOS se dispara con un roce en el
    // borde, y el móvil está en un soporte que alguien toca para ajustarlo: salir con
    // la grabación en marcha dejaría el fichero escribiéndose sin pantalla que lo pare.
    return PopScope(
      canPop: !_session.recording,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Para la grabación antes de salir.')));
        }
      },
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _Header(
              title: r.cameraTitle,
              chip: r.statusChipIsGood
                  ? ZeroChip.accent(r.statusChipLabel)
                  : ZeroChip.danger(r.statusChipLabel),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(ZeroMetrics.gutter, 14, ZeroMetrics.gutter, 28),
                children: <Widget>[
                  _Preview(readout: r),
                  const SizedBox(height: 16),
                  _RecordButton(session: _session),
                  const SizedBox(height: 10),
                  _RecordingBanner(readout: r),
                  if (trouble.isNotEmpty) ...<Widget>[
                    const SizedBox(height: ZeroMetrics.cardGap),
                    _TroubleCard(readings: trouble),
                  ],
                  const SizedBox(height: ZeroMetrics.innerGap),
                  _ReadingCard(title: 'Soporte', readings: r.rigReadings),
                  const SizedBox(height: ZeroMetrics.cardGap),
                  _ReadingCard(
                    title: 'Emisión',
                    readings: r.streamReadings,
                    trailing: r.streamIsUp
                        ? ZeroChip.accent(r.streamChipLabel)
                        : r.streamInTrouble
                        ? ZeroChip.danger(r.streamChipLabel)
                        : ZeroChip.mutedOnCard(r.streamChipLabel),
                  ),
                  if (r.cameraReadings.isNotEmpty) ...<Widget>[
                    const SizedBox(height: ZeroMetrics.cardGap),
                    _ReadingCard(title: 'Cámara', readings: r.cameraReadings),
                  ],
                  if (r.deviceReadings.isNotEmpty) ...<Widget>[
                    const SizedBox(height: ZeroMetrics.cardGap),
                    _ReadingCard(title: 'Dispositivo', readings: r.deviceReadings),
                  ],
                  const SizedBox(height: ZeroMetrics.innerGap),
                  Text(
                    'Las grabaciones quedan en Documentos: se ven en Finder al conectar el '
                    'móvil o en la app Archivos.',
                    style: ZeroType.plex(
                      size: 12,
                      weight: FontWeight.w400,
                      color: ZeroColors.inkTertiary,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La cabecera fija, igual en Captura y en Partido.
class _Header extends StatelessWidget {
  const _Header({required this.title, required this.chip});

  final String title;
  final Widget chip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ZeroMetrics.gutter, vertical: 12),
      decoration: const BoxDecoration(
        color: ZeroColors.chromeFill,
        border: Border(bottom: BorderSide(color: ZeroColors.chrome)),
      ),
      child: Row(
        children: <Widget>[
          const ZeroMark(diameter: 18),
          const SizedBox(width: 10),
          // `Expanded` y no `Flexible` + `Spacer`: con los dos a flex 1 el hueco libre se
          // reparte a medias y el título se corta al lado de un espacio vacío en cuanto
          // el chip dice ESPERANDO RELOJ.
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZeroType.archivo(
                size: 15,
                weight: FontWeight.w600,
                color: ZeroColors.ink,
                letterSpacing: -0.3,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 10),
          chip,
        ],
      ),
    );
  }
}

/// La vista previa con el HUD encima.
class _Preview extends StatelessWidget {
  const _Preview({required this.readout});

  final CaptureReadout readout;

  @override
  Widget build(BuildContext context) {
    final String? format = readout.formatChipLabel;
    final String? exposure = readout.exposureChipLabel;
    final String? phase = readout.phaseChipLabel;

    return ClipRRect(
      borderRadius: BorderRadius.circular(ZeroMetrics.previewRadius),
      child: Container(
        decoration: BoxDecoration(
          color: ZeroColors.black,
          border: Border.all(color: ZeroColors.previewBorder),
          borderRadius: BorderRadius.circular(ZeroMetrics.previewRadius),
        ),
        child: AspectRatio(
          // Vertical, la imagen gira y cabe más alta; apaisado, entera a 16:9. El diseño
          // la dibuja a 4:3 con una foto de archivo, pero lo que manda es la capa nativa.
          aspectRatio: MediaQuery.orientationOf(context) == Orientation.portrait ? 3 / 4 : 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const _NativePreview(),
              // Sin este velo, un chip blanco sobre un plano de césped al sol
              // desaparece. Oscurece la imagen justo donde va texto y en ningún otro
              // sitio, para no falsear lo que se está encuadrando.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      ZeroColors.scrimTop,
                      ZeroColors.scrimClear,
                      ZeroColors.scrimBottom,
                    ],
                    stops: <double>[0.0, 0.34, 1.0],
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Row(
                  children: <Widget>[
                    _RecBadge(recording: readout.session.recording),
                    const Spacer(),
                    // Siempre visible, como en el diseño: en pausa marca 00:00 y deja
                    // claro que el reloj existe y está parado.
                    _HudChip(
                      text: formatClock(
                        readout.session.recording
                            ? readout.session.recordingElapsed
                            : Duration.zero,
                      ),
                      size: 11,
                      letterSpacing: 0,
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    // Nada de guiones de relleno: lo que no se sabe todavía, no se
                    // dibuja. Un `—` a tres metros se lee como un cero.
                    if (format != null) _HudChip(text: format),
                    if (exposure != null) _HudChip(text: exposure),
                    if (phase != null) _HudChip(text: phase, dot: ZeroColors.accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La vista nativa de la cámara.
///
/// Fuera de un iPhone —y en los tests, que corren en el escritorio— no hay vista nativa:
/// se dice, en vez de dejar un hueco negro o reventar con una plataforma no soportada.
class _NativePreview extends StatelessWidget {
  const _NativePreview();

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return const UiKitView(viewType: capturePreviewViewType);
    }
    return ColoredBox(
      color: ZeroColors.black,
      child: Center(
        child: Text(
          'vista previa solo en iPhone',
          style: ZeroType.data(
            size: 11,
            weight: FontWeight.w400,
            color: ZeroColors.inkTertiary,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }
}

/// GRABANDO con un punto que late, o EN PAUSA.
class _RecBadge extends StatefulWidget {
  const _RecBadge({required this.recording});

  final bool recording;

  @override
  State<_RecBadge> createState() => _RecBadgeState();
}

class _RecBadgeState extends State<_RecBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.recording) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_RecBadge old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool on = widget.recording;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: on ? ZeroColors.danger : ZeroColors.hudFill,
        border: Border.all(color: on ? ZeroColors.danger : ZeroColors.hudBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // El punto late solo mientras graba. Es lo que se mira de reojo desde la
          // banda para saber si el móvil sigue vivo sin acercarse al soporte.
          FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.25).animate(_pulse),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: on ? ZeroColors.white : ZeroColors.inkTertiary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            on ? 'GRABANDO' : 'EN PAUSA',
            style: ZeroType.data(
              size: 10,
              weight: FontWeight.w600,
              color: on ? ZeroColors.white : ZeroColors.hudInk,
              letterSpacing: 1.8,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// Un dato sobre la imagen.
///
/// Los tres chips llevan el mismo fondo negro al 60 % con borde blanco al 18 % y texto
/// blanco. En el de fase el teal va en un punto de 5 px delante del texto y no en el
/// fondo: un plato teñido al 20 % sobre césped iluminado no se lee.
class _HudChip extends StatelessWidget {
  const _HudChip({required this.text, this.dot, this.size = 10, this.letterSpacing = 1.0});

  final String text;
  final Color? dot;
  final double size;

  /// Los datos de abajo van espaciados; el reloj de arriba no, para que sus cifras se
  /// lean igual de juntas que en el banner de debajo del botón.
  final double letterSpacing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: ZeroColors.hudFill,
        border: Border.all(color: ZeroColors.hudBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (dot != null) ...<Widget>[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: ZeroType.data(
              size: size,
              weight: FontWeight.w500,
              color: ZeroColors.white,
              letterSpacing: letterSpacing,
              height: 1.0,
              tabularFigures: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.session});

  final CaptureSession session;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = ZeroType.archivo(
      size: 22,
      weight: FontWeight.w700,
      color: ZeroColors.onAccent,
      letterSpacing: -0.22,
      height: 1.0,
    );
    // `canRecord` es de la sesión, no de la pantalla: grabar antes de tener reloj
    // común es la forma más fácil de volver a casa con dos vídeos que no parean.
    final VoidCallback? onPressed = session.canRecord
        ? () => unawaited(session.toggleRecording())
        : null;

    return session.recording
        ? ZeroButton.destructive(
            label: 'PARAR',
            onPressed: onPressed,
            height: ZeroMetrics.recordHeight,
            textStyle: style,
          )
        : ZeroButton.primary(
            label: 'GRABAR',
            onPressed: onPressed,
            height: ZeroMetrics.recordHeight,
            textStyle: style,
          );
  }
}

/// Una sola línea debajo del botón: minutos, segmento y dónde queda el fichero.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.readout});

  final CaptureReadout readout;

  @override
  Widget build(BuildContext context) {
    final bool on = readout.session.recording;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: on ? ZeroColors.dangerFill : ZeroColors.surface,
        border: Border.all(color: on ? ZeroColors.dangerBorder : ZeroColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        readout.recordingBannerLabel,
        textAlign: TextAlign.center,
        style: ZeroType.data(
          size: 12,
          weight: FontWeight.w500,
          color: on ? ZeroColors.alarm : ZeroColors.inkTertiary,
          height: 1.4,
          tabularFigures: true,
        ),
      ),
    );
  }
}

/// Una tarjeta de datos con su nombre y, si hace falta, un chip de estado.
class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.title, required this.readings, this.trailing});

  final String title;
  final List<CaptureReading> readings;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ZeroCard(
      padding: ZeroMetrics.dataCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ZeroSectionHeader(title, trailing: trailing, bottomGap: 8),
          for (final CaptureReading r in readings) ZeroDataRow(r.label, r.value, tone: r.tone),
        ],
      ),
    );
  }
}

/// Lo que impide grabar, o lo que se interrumpió. Va arriba y con el fondo rojo porque
/// es lo primero que hay que leer, y casi siempre no está.
class _TroubleCard extends StatelessWidget {
  const _TroubleCard({required this.readings});

  final List<CaptureReading> readings;

  @override
  Widget build(BuildContext context) {
    return ZeroCard(
      padding: ZeroMetrics.dataCardPadding,
      background: ZeroColors.dangerCard,
      border: ZeroColors.dangerCardBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Atención', bottomGap: 8),
          for (final CaptureReading r in readings) ZeroDataRow(r.label, r.value, tone: r.tone),
        ],
      ),
    );
  }
}
