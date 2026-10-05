/// El QR Mando en la pantalla del maestro (IOS-63) y el PIN del operador (IOS-62).
///
/// Aparece solo en el móvil que dirige y sirve el mando. El QR lleva este móvil, el otro y
/// el VPS (si hay), con un token del partido que caduca a las doce horas; «puede emitir»
/// añade el ámbito `stream`. El PIN abre los tres ámbitos y se guarda en el Keychain.
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

/// El botón «QR MANDO» de la pantalla de captura: solo si este móvil sirve el mando.
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
        if (!host.serving) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: ZeroButton.secondary(
            label: 'QR MANDO',
            onPressed: () => unawaited(showModalBottomSheet<void>(
              context: context,
              backgroundColor: ZeroColors.background,
              isScrollControlled: true,
              builder: (BuildContext _) => MandoQrSheet(host: host, savePin: savePin),
            )),
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
  String? _text;
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
    final String? texto = await widget.host.pairingText(stream: _stream);
    if (mounted) {
      setState(() {
        _text = texto;
        _loading = false;
      });
    }
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
    final String? texto = _text;
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
            else if (texto == null)
              Text(
                'Sin secreto del soporte no se puede firmar el QR: entra con el PIN del operador.',
                style: ZeroType.plex(size: 14, weight: FontWeight.w400, color: ZeroColors.inkSecondary),
              )
            else
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
