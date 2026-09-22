/// Elegir lado, servidor y modo. Es lo primero y lo único que no puede equivocarse.
///
/// Si los dos móviles dicen ser el izquierdo, el servidor recibe dos veces la misma
/// mitad del campo y el partido se pierde antes del saque inicial. Por eso los dos
/// bloques de lado son lo más grande de la pantalla y llevan escrito debajo qué implica
/// cada uno: el izquierdo es el maestro del reloj y puede arrancar solo, y el derecho
/// espera a tener reloj común (ADR 0012, decisión 2). Eso hasta hoy solo estaba en el
/// ADR, y quien monta el soporte no lee el ADR en la banda.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';
import 'package:football_ai_capture/src/zero_shell.dart';

/// De dónde salió lo que pone en «Servidor». Decide lo que dice la línea de debajo:
/// atribuir a Bonjour un nombre escrito a mano haría pasar una errata por un servidor
/// encontrado.
enum _ServerOrigin { none, saved, bonjour, typed, scanned }

class RolePage extends StatefulWidget {
  const RolePage({this.api, super.key});

  /// Inyectable para los tests.
  final CaptureHostApi? api;

  @override
  State<RolePage> createState() => _RolePageState();
}

class _RolePageState extends State<RolePage> {
  late final CaptureHostApi _api = widget.api ?? CaptureHostApi();
  final TextEditingController _server = TextEditingController();

  CameraRole _role = CameraRole.left;

  /// Apagado por defecto: encenderlo en un partido es grabar dos vídeos que no parean.
  bool _standalone = false;

  bool _searching = false;
  _ServerOrigin _origin = _ServerOrigin.none;

  @override
  void initState() {
    super.initState();
    unawaited(_loadServer());
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  /// Lo guardado manda; si no hay nada, se busca el servidor por Bonjour y se guarda lo
  /// encontrado, para no teclear una IP nunca.
  Future<void> _loadServer() async {
    try {
      _server.text = await _api.loadServerHost();
      if (_server.text.isNotEmpty) {
        _origin = _ServerOrigin.saved;
      }
    } on Exception {
      // Sin nativo (tests) no hay nada guardado. Se queda vacío: solo grabación.
    }
    if (_server.text.isEmpty) {
      await _discoverServer();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _discoverServer() async {
    if (mounted) {
      setState(() => _searching = true);
    }
    try {
      final String found = await _api.discoverServer();
      if (found.isNotEmpty) {
        _server.text = found;
        _origin = _ServerOrigin.bonjour;
        await _saveServer(found);
      }
    } on Exception {
      // Sin nativo no hay red que buscar.
    }
    if (mounted) {
      setState(() => _searching = false);
    }
  }

  /// El QR de la tarjeta «Cámaras» del panel trae la dirección tal cual va en el campo.
  Future<void> _scanServer() async {
    String found = '';
    try {
      found = await _api.scanServerQr();
    } on Exception {
      // Sin nativo (tests) no hay cámara.
    }
    if (found.trim().isEmpty || !mounted) {
      return;
    }
    setState(() {
      _server.text = found.trim();
      _origin = _ServerOrigin.scanned;
    });
    await _saveServer(found);
  }

  Future<void> _saveServer(String host) async {
    try {
      await _api.saveServerHost(host.trim());
    } on Exception {
      // Igual que arriba: sin nativo no se guarda, y no pasa nada.
    }
  }

  void _onTyped(String value) {
    unawaited(_saveServer(value));
    setState(() => _origin = value.trim().isEmpty ? _ServerOrigin.none : _ServerOrigin.typed);
  }

  /// El protocolo se deduce de lo escrito: sin esquema o `srt://` es SRT.
  String get _protocol => _server.text.trim().startsWith('rtmp') ? 'rtmp' : 'srt';

  /// Cambiar de protocolo reescribe el campo, para no teclear el esquema en el móvil.
  void _setProtocol(String protocol) {
    final String bare = _server.text.trim().replaceFirst(RegExp(r'^[a-z]+://'), '');
    final String next = (protocol == 'rtmp' && bare.isNotEmpty) ? 'rtmp://$bare' : bare;
    setState(() => _server.text = next);
    unawaited(_saveServer(next));
  }

  String get _serverNote {
    if (_searching) {
      return 'buscando el servidor en la red…';
    }
    return switch (_origin) {
      _ServerOrigin.bonjour => 'encontrado por Bonjour · vacío = solo graba en el móvil',
      _ServerOrigin.saved => 'guardado en el móvil · vacío = solo graba en el móvil',
      _ServerOrigin.scanned => 'leído del QR del panel · vacío = solo graba en el móvil',
      _ServerOrigin.typed || _ServerOrigin.none => 'vacío = solo graba en el móvil',
    };
  }

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ZeroShell(role: _role, standalone: _standalone, serverHost: _server.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Los 34 px de abajo del diseño son el indicador de inicio del iPhone, no un
      // margen aparte: `minimum` deja el mayor de los dos en vez de sumarlos, y en un
      // móvil sin indicador el botón sigue sin pegarse al borde.
      body: SafeArea(
        minimum: const EdgeInsets.only(bottom: 34),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: ZeroMetrics.gutter),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(0, 14, 0, 26),
                      child: Row(
                        children: <Widget>[ZeroLockup(diameter: 22), Spacer(), _Kicker('CAPTURA')],
                      ),
                    ),
                    Text(
                      '¿Qué mitad cubre este móvil?',
                      style: ZeroType.archivo(
                        size: 30,
                        weight: FontWeight.w600,
                        color: ZeroColors.ink,
                        letterSpacing: -1.05,
                        height: 1.08,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Si los dos dicen lo mismo, el servidor recibe dos veces media cancha.',
                      style: ZeroType.plex(
                        size: 14,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    // `IntrinsicHeight` para que los dos bloques midan lo mismo aunque
                    // «SIGUE AL RELOJ» ocupe dos líneas y «MAESTRO» una: dos bloques de
                    // distinto alto se leen como si uno valiera más que el otro.
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(
                            child: _SideBlock(
                              label: 'IZQUIERDA',
                              note: 'MAESTRO',
                              selected: _role == CameraRole.left,
                              onTap: () => setState(() => _role = CameraRole.left),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SideBlock(
                              label: 'DERECHA',
                              note: 'SIGUE AL RELOJ',
                              selected: _role == CameraRole.right,
                              onTap: () => setState(() => _role = CameraRole.right),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    _ServerCard(
                      controller: _server,
                      searching: _searching,
                      note: _serverNote,
                      protocol: _protocol,
                      onChanged: _onTyped,
                      onFind: () => unawaited(_discoverServer()),
                      onScan: () => unawaited(_scanServer()),
                      onProtocol: _setProtocol,
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    _StandaloneRow(
                      value: _standalone,
                      onChanged: () => setState(() => _standalone = !_standalone),
                    ),
                    const Spacer(),
                    const SizedBox(height: 20),
                    ZeroButton.primary(
                      label: 'Abrir cámara ${_role == CameraRole.left ? 'izquierda' : 'derecha'}',
                      height: ZeroMetrics.primaryHeight,
                      textStyle: ZeroType.plex(
                        size: 17,
                        weight: FontWeight.w600,
                        color: ZeroColors.onAccent,
                        height: 1.0,
                      ),
                      onPressed: _open,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La etiqueta pequeña de la esquina.
class _Kicker extends StatelessWidget {
  const _Kicker(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: ZeroType.data(
        size: 10,
        weight: FontWeight.w500,
        color: ZeroColors.inkTertiary,
        letterSpacing: 1.6,
        height: 1.0,
      ),
    );
  }
}

/// Uno de los dos bloques de lado. Alto mínimo 96 porque es el toque que no se puede
/// fallar, y el único de la pantalla que se da con el móvil ya en el soporte.
class _SideBlock extends StatelessWidget {
  const _SideBlock({
    required this.label,
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fill = selected ? ZeroColors.accent : Colors.transparent;
    final Color ink = selected ? ZeroColors.onAccent : ZeroColors.ink;
    // El diseño lo pide al 70 %, ya mezclado aquí contra el fondo del bloque para que se
    // pinte opaco. Va al 80 %: al 70 % la tinta oscura sobre el teal da 4.1:1, y un
    // subtítulo de 11 px necesita 4.5. Al 80 % da 5.0 sobre teal y 10 sobre el fondo.
    final Color noteInk = ZeroColors.blend(
      ink,
      0.8,
      selected ? ZeroColors.accent : ZeroColors.background,
    );

    return Semantics(
      button: true,
      selected: selected,
      child: ZeroTappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: selected ? ZeroColors.accent : ZeroColors.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                textAlign: TextAlign.center,
                style: ZeroType.plex(
                  size: 15,
                  weight: FontWeight.w700,
                  color: ink,
                  letterSpacing: 0.9,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                note,
                textAlign: TextAlign.center,
                style: ZeroType.data(
                  size: 11,
                  weight: FontWeight.w400,
                  color: noteInk,
                  letterSpacing: 1.1,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dónde se emite. Vacío es una respuesta válida: sin servidor el móvil sigue
/// grabando en local, que es lo que convierte un fallo de red en un partido en diferido.
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.controller,
    required this.searching,
    required this.note,
    required this.protocol,
    required this.onChanged,
    required this.onFind,
    required this.onScan,
    required this.onProtocol,
  });

  final TextEditingController controller;
  final bool searching;
  final String note;
  final String protocol;
  final ValueChanged<String> onChanged;
  final VoidCallback onFind;
  final VoidCallback onScan;
  final ValueChanged<String> onProtocol;

  @override
  Widget build(BuildContext context) {
    final bool hasHost = controller.text.trim().isNotEmpty;
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Servidor'),
          Container(
            padding: const EdgeInsets.only(left: 16),
            decoration: BoxDecoration(
              color: ZeroColors.well,
              border: Border.all(color: ZeroColors.outlineSoft),
              borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  // El `hint` desaparece al escribir: sin etiqueta, VoiceOver lee
                  // solo la URL, sin decir para qué es el campo.
                  child: Semantics(
                    label: 'Servidor',
                    child: TextField(
                      controller: controller,
                      onChanged: onChanged,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      style: ZeroType.data(
                        size: 15,
                        weight: FontWeight.w500,
                        color: ZeroColors.ink,
                        height: 1.2,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'mediamtx.local',
                        hintStyle: ZeroType.data(
                          size: 15,
                          weight: FontWeight.w500,
                          color: ZeroColors.inkTertiary,
                          height: 1.2,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                // El punto de estado es el botón de buscar en la red. Un icono de lupa a
                // su lado sería un segundo objetivo de 8 px en la misma esquina. La zona
                // de toque mide 48×44 y llega hasta el borde del campo; el punto queda a
                // 16 px de ese borde, como el texto por la izquierda.
                Semantics(
                  button: true,
                  enabled: !searching,
                  label: 'Buscar el servidor en la red',
                  child: ZeroTappable(
                    onTap: searching ? null : onFind,
                    borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
                    child: SizedBox(
                      width: 48,
                      height: 44,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.only(right: 16),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: hasHost && !searching
                                ? ZeroColors.accent
                                : ZeroColors.inkTertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            note,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          // SRT es el bueno para Starlink (recupera lo que se pierde en cada traspaso);
          // RTMP, el único que entra a un pod de RunPod. Elegir reescribe el campo.
          Row(
            children: <Widget>[
              ZeroPill(label: 'SRT', selected: protocol == 'srt', onTap: () => onProtocol('srt')),
              const SizedBox(width: 8),
              ZeroPill(
                label: 'RTMP',
                selected: protocol == 'rtmp',
                onTap: () => onProtocol('rtmp'),
              ),
              const SizedBox(width: 8),
              // La dirección del pod cambia con cada despliegue y no se teclea en la
              // cancha: el panel la enseña como QR (tarjeta «Cámaras») y aquí se lee.
              Expanded(
                child: ZeroButton.secondary(
                  label: 'Escanear QR',
                  onPressed: searching ? null : onScan,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un solo móvil, sin reloj.
///
/// La tarjeta entera se tiñe de rojo al encenderlo, y no solo el interruptor, porque
/// encenderlo sin querer en un partido de verdad es volver con dos vídeos que no parean
/// y no enterarse hasta que el servidor los rechace.
class _StandaloneRow extends StatelessWidget {
  const _StandaloneRow({required this.value, required this.onChanged});

  final bool value;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // `excludeSemantics` se lleva la acción del `InkWell`: el toque se declara aquí o
    // el interruptor se anuncia pero no se puede accionar con VoiceOver o TalkBack.
    return Semantics(
      toggled: value,
      label: 'Un solo móvil, sin reloj',
      onTap: onChanged,
      excludeSemantics: true,
      child: ZeroTappable(
        onTap: onChanged,
        borderRadius: BorderRadius.circular(ZeroMetrics.cardRadius),
        decoration: BoxDecoration(
          color: value ? ZeroColors.dangerRow : ZeroColors.surface,
          border: Border.all(color: value ? ZeroColors.dangerBorder : ZeroColors.border),
          borderRadius: BorderRadius.circular(ZeroMetrics.cardRadius),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Un solo móvil, sin reloj',
                      style: ZeroType.plex(
                        size: 15,
                        weight: FontWeight.w600,
                        color: ZeroColors.ink,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Lo grabado así no parea con el otro.',
                      style: ZeroType.plex(
                        size: 12,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _Switch(value: value),
            ],
          ),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 32,
      decoration: BoxDecoration(
        color: value ? ZeroColors.danger : ZeroColors.switchTrack,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 26,
          height: 26,
          decoration: const BoxDecoration(color: ZeroColors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
