/// El móvil como mando del panel, sin cámara (ADR 0017 del repo football-ai).
///
/// Se llega desde la pantalla de lado, por «Solo mando», con el QR «Mando» del panel ya
/// escaneado. Es la pestaña Partido de siempre sobre el marcador del panel
/// ([PanelBoard]), con un aviso debajo de la cabecera cuando hay algo que decir: que el
/// panel no contesta, que la transmisión terminó o que la última orden no entró.
///
/// No monta [CapturePage]: un móvil que lleva el marcador no abre la cámara.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/match_page.dart';
import 'package:football_ai_capture/src/panel_board.dart';
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

/// Crea el mando para un emparejamiento. Inyectable para los tests: sin él harían falta
/// un panel y una red de verdad.
typedef PanelControlFactory = PanelControl Function(PanelPairing pairing);

PanelControl _realControl(PanelPairing pairing) =>
    PanelControl(pairing: pairing, deviceName: mandoDeviceName);

class MandoPage extends StatefulWidget {
  const MandoPage({
    required this.pairing,
    this.api,
    this.controlFactory,
    super.key,
  });

  final PanelPairing pairing;

  /// Para escanear otro QR y guardarlo. Inyectable para los tests.
  final CaptureHostApi? api;

  /// `null`: el mando de verdad, por la red.
  final PanelControlFactory? controlFactory;

  @override
  State<MandoPage> createState() => _MandoPageState();
}

class _MandoPageState extends State<MandoPage> {
  late final CaptureHostApi _api = widget.api ?? CaptureHostApi();
  late PanelPairing _pairing = widget.pairing;
  late PanelControl _control;
  PanelBoard? _board;
  Timer? _silence;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    final PanelControlFactory create = widget.controlFactory ?? _realControl;
    _control = create(_pairing)..addListener(_changed);
    _control.start();
    _changed();
  }

  void _disconnect() {
    _silence?.cancel();
    _silence = null;
    _board?.dispose();
    _board = null;
    _control
      ..removeListener(_changed)
      ..dispose();
  }

  void _changed() {
    // El tablero se crea con el primer partido: antes no hay nada que enseñar.
    if (_board == null && _control.match != null) {
      _board = PanelBoard(_control)..addListener(_repaint);
    }
    // Sin panel, el «hace N s» tiene que correr solo aunque nada cambie.
    if (_control.link == PanelLink.offline) {
      _silence ??= Timer.periodic(mandoSilenceRefresh, (_) => _repaint());
    } else {
      _silence?.cancel();
      _silence = null;
    }
    _repaint();
  }

  void _repaint() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Escanea otro QR «Mando» y se engancha a él. Lo que no sea un QR Mando no cambia
  /// nada: el emparejamiento bueno no se pierde por apuntar a otro QR.
  Future<void> _rescan() async {
    String text = '';
    try {
      text = await _api.scanServerQr();
    } on Exception {
      // Sin nativo (tests) no hay cámara.
    }
    final PanelPairing? next = PanelPairing.parse(text);
    if (next == null || !mounted) {
      return;
    }
    try {
      await _api.savePanelPairing(next.qrText);
    } on Exception {
      // Si no se guarda, vale para esta vez: al volver a abrir habrá que escanearlo.
    }
    // `_connect` repinta solo, con el mando nuevo y sin el tablero del anterior.
    _disconnect();
    _pairing = next;
    _connect();
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PanelBoard? board = _board;
    return Scaffold(
      body: board == null
          ? _Waiting(pairing: _pairing, banner: _banner(null))
          : MatchPage(match: board, banner: _banner(board)),
    );
  }

  /// Lo que hay que decir debajo de la cabecera, o nada. El enlace manda sobre la última
  /// orden: si la transmisión terminó, que la última orden fallara ya da igual.
  Widget? _banner(PanelBoard? board) {
    switch (_control.link) {
      case PanelLink.ended:
        return _Banner(
          text:
              'Esta transmisión terminó. Escanea el QR «Mando» del partido nuevo.',
          danger: true,
          action: 'Escanear QR',
          onAction: _rescan,
        );
      case PanelLink.unauthorized:
        return _Banner(
          text:
              'El panel ya no acepta este QR. Escanea el de la tarjeta «Mando».',
          danger: true,
          action: 'Escanear QR',
          onAction: _rescan,
        );
      case PanelLink.offline:
        final int seconds = _control.silence.inSeconds;
        return _Banner(
          text: board == null
              ? 'El panel no contesta ($seconds s). Se sigue intentando.'
              : 'Sin panel desde hace $seconds s: esto es lo último que dijo.',
          danger: true,
        );
      case PanelLink.connecting || PanelLink.online:
        final String? message = board?.message;
        return message == null ? null : _Banner(text: message);
    }
  }
}

/// Antes del primer partido: a qué panel se está llamando.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.pairing, required this.banner});

  final PanelPairing pairing;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ?banner,
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ZeroMetrics.gutter,
                ),
                child: Text(
                  'Conectando con el panel\n${pairing.label}',
                  textAlign: TextAlign.center,
                  style: ZeroType.plex(
                    size: 15,
                    weight: FontWeight.w500,
                    color: ZeroColors.inkSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    this.danger = false,
    this.action,
    this.onAction,
  });

  final String text;
  final bool danger;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String? label = action;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: ZeroMetrics.gutter,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: danger ? ZeroColors.dangerRow : ZeroColors.surface,
        border: Border(
          bottom: BorderSide(
            color: danger ? ZeroColors.dangerBorder : ZeroColors.border,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            text,
            style: ZeroType.plex(
              size: 13,
              weight: FontWeight.w500,
              color: danger ? ZeroColors.alarm : ZeroColors.ink,
              height: 1.4,
            ),
          ),
          if (label != null) ...<Widget>[
            const SizedBox(height: 10),
            ZeroButton.secondary(label: label, onPressed: onAction),
          ],
        ],
      ),
    );
  }
}
