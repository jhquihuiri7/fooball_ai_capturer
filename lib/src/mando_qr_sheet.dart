/// El QR Mando en la pantalla del maestro (IOS-63) y el PIN del operador (IOS-62).
///
/// Aparece en el móvil que dirige y sirve el mando, o que debería y no pudo (Bug A,
/// 2026-10-21: el botón ya no desaparece sin decir por qué). El QR lleva este móvil, el
/// otro y el VPS (si hay), con un token del partido que caduca a las doce horas; «puede
/// emitir» añade el ámbito `stream`. El PIN abre los tres ámbitos y se guarda en el
/// Keychain. Sin QR, la hoja dice por qué, da la dirección del panel para entrar con el
/// PIN y deja reintentar el mando sin matar la app ni parar la emisión.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/server/master_host.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/qr_view.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

/// Lado del QR en la hoja, en puntos: se lee desde otro móvil a un brazo de distancia.
const double mandoQrSize = 260;

/// Cifras del PIN del operador, como mínimo: con menos se adivina en la banda.
const int operatorPinMinDigits = 6;

/// El botón «QR MANDO» de la pantalla de captura: si este móvil sirve el mando, o si
/// tenía que servirlo y no arrancó, con el motivo debajo.
class MandoQrButton extends StatelessWidget {
  const MandoQrButton({required this.host, required this.savePin, super.key});

  final MasterHost host;

  /// Guarda el PIN en el Keychain (vacío lo borra).
  final Future<void> Function(String pin) savePin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: host,
      builder: (BuildContext context, Widget? _) {
        final String? problema = host.serving ? null : host.problem;
        if (!host.serving && problema == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZeroButton.secondary(
                label: 'QR MANDO',
                onPressed: () => unawaited(showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: ZeroColors.background,
                  isScrollControlled: true,
                  builder: (BuildContext _) => MandoQrSheet(host: host, savePin: savePin),
                )),
              ),
              if (problema != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'Mando: $problema',
                  style: ZeroType.plex(size: 13, weight: FontWeight.w500, color: ZeroColors.alarm),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class MandoQrSheet extends StatefulWidget {
  const MandoQrSheet({required this.host, required this.savePin, super.key});

  final MasterHost host;
  final Future<void> Function(String pin) savePin;

  @override
  State<MandoQrSheet> createState() => _MandoQrSheetState();
}

class _MandoQrSheetState extends State<MandoQrSheet> {
  bool _stream = false;
  MandoPairing? _pairing;
  bool _loading = true;
  final TextEditingController _pin = TextEditingController();
  String? _pinNote;

  @override
  void initState() {
    super.initState();
    unawaited(_compose());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _compose() async {
    final MandoPairing p = await widget.host.pairing(stream: _stream);
    if (mounted) {
      setState(() {
        _pairing = p;
        _loading = false;
      });
    }
  }

  /// «REINTENTAR MANDO»: arranca el mando si no se sirve y vuelve a mirar la red.
  Future<void> _retry() async {
    setState(() => _loading = true);
    await widget.host.retry();
    await _compose();
  }

  Future<void> _savePin() async {
    final String pin = _pin.text.trim();
    if (pin.isNotEmpty && (pin.length < operatorPinMinDigits || int.tryParse(pin) == null)) {
      setState(() => _pinNote = 'El PIN son $operatorPinMinDigits cifras o más.');
      return;
    }
    await widget.savePin(pin);
    widget.host.updateOperatorPin(pin);
    _pin.clear();
    if (mounted) {
      setState(() => _pinNote = pin.isEmpty ? 'PIN borrado.' : 'PIN guardado.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final MandoPairing? pairing = _pairing;
    final String? texto = pairing?.text;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          ZeroMetrics.gutter,
          20,
          ZeroMetrics.gutter,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const ZeroSectionHeader('Mando'),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (texto == null) ...<Widget>[
              Text(
                'Sin QR: ${pairing?.reason ?? mandoReasonNotServing}.',
                style: ZeroType.plex(size: 14, weight: FontWeight.w500, color: ZeroColors.alarm),
              ),
              if (pairing != null && pairing.manual.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'A mano, con el PIN del operador:',
                  style: ZeroType.plex(size: 14, weight: FontWeight.w400, color: ZeroColors.inkSecondary),
                ),
                for (final Uri panel in pairing.manual)
                  SelectableText(
                    panel.toString(),
                    style: ZeroType.data(size: 16, weight: FontWeight.w600, color: ZeroColors.ink),
                  ),
              ],
              const SizedBox(height: 10),
              ZeroButton.secondary(label: 'REINTENTAR MANDO', onPressed: () => unawaited(_retry())),
            ] else
              Center(child: QrView(data: texto, size: mandoQrSize)),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _stream,
              title: Text('Puede emitir', style: ZeroType.plex(size: 15, weight: FontWeight.w500, color: ZeroColors.ink)),
              onChanged: (bool v) {
                setState(() {
                  _stream = v;
                  _loading = true;
                });
                unawaited(_compose());
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN del operador (vacío lo borra)'),
              onSubmitted: (_) => unawaited(_savePin()),
            ),
            const SizedBox(height: 8),
            ZeroButton.secondary(label: 'GUARDAR PIN', onPressed: () => unawaited(_savePin())),
            if (_pinNote != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(_pinNote!, style: ZeroType.data(size: 12, weight: FontWeight.w500, color: ZeroColors.inkSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}
