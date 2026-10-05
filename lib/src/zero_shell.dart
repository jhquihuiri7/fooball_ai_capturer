/// Los dos lugares de la app, con la barra inferior que los separa.
///
/// El móvil que está en el soporte **no debe ver el marcador**, y quien lleva el
/// marcador **no debe poder tocar la cámara**. Cuando las dos cosas comparten pantalla,
/// lo que acaba pasando es un toque de más en GRABAR a mitad de partido.
///
/// Las dos pantallas se montan en un [IndexedStack] y no se destruyen al cambiar de
/// pestaña: reconstruir la vista previa reabriría la sesión de captura, que es
/// exactamente el segundo y medio de vídeo que no se puede perder.
library;

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/capture_page.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/mando_page.dart' show MatchBanner;
import 'package:football_ai_capture/src/master_board.dart';
import 'package:football_ai_capture/src/match_page.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/master_host.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';

class ZeroShell extends StatefulWidget {
  const ZeroShell({
    required this.role,
    this.standalone = false,
    this.serverHost = '',
    this.linkOnly = false,
    this.autoRecordSeconds = 0,
    this.prefersMaster,
    this.session,
    this.match,
    super.key,
  });

  final CameraRole role;

  /// Un solo móvil, sin reloj (ver `CaptureSession.standalone`).
  final bool standalone;

  /// Host o URL del servidor que recibe la emisión. Vacío: solo se graba.
  final String serverHost;

  /// Solo el enlace entre móviles, sin cámara (ver `CaptureSession.linkOnly`).
  final bool linkOnly;

  /// Grabación de prueba automática, en segundos (ver `CapturePage.autoRecordSeconds`).
  final int autoRecordSeconds;

  /// «Este móvil dirige» (IOS-80); null = el izquierdo.
  final bool? prefersMaster;

  /// Inyectables para los tests: sin esto habría que hablar con la cámara de verdad y
  /// con el almacenamiento del móvil.
  final CaptureSession? session;
  final MatchState? match;

  @override
  State<ZeroShell> createState() => _ZeroShellState();
}

class _ZeroShellState extends State<ZeroShell> {
  Widget _matchPage() {
    final MasterBoard? board = _board;
    final int destinos = widget.serverHost.trim().isEmpty ? 0 : 1;
    if (board == null) {
      return MatchPage(match: _match, destinations: destinos);
    }
    return ListenableBuilder(
      listenable: board,
      builder: (BuildContext context, Widget? _) {
        final String? aviso = board.message;
        return MatchPage(
          match: board,
          destinations: destinos,
          banner: aviso == null ? null : MatchBanner(text: aviso, danger: true),
        );
      },
    );
  }

  late final MatchState _match = widget.match ?? MatchState();
  bool _ownsMatch = false;
  int _index = 0;

  /// IOS-87: mientras este móvil dirige, la pestaña Partido es la del partido del
  /// maestro (el mismo que ven el panel local y los mandos). Si deja de dirigir, vuelve
  /// el marcador local, que queda para el móvil sin soporte.
  MasterHost? _host;
  MasterBoard? _board;

  void _onMasterHost(MasterHost host) {
    _host?.removeListener(_hostChanged);
    _host = host..addListener(_hostChanged);
    _hostChanged();
  }

  void _hostChanged() {
    final MatchEngine? engine = _host?.engine;
    if (engine == _board?.engine) {
      return;
    }
    _board?.dispose();
    _board = engine == null ? null : MasterBoard(engine);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _ownsMatch = widget.match == null;
    if (_ownsMatch) {
      // Sin `await`: el marcador aparece con los valores de arranque y se corrige solo
      // cuando llega lo guardado. Bloquear la pantalla por leer un `SharedPreferences`
      // sería una espera en blanco justo al abrir.
      _match.load();
    }
  }

  @override
  void dispose() {
    _host?.removeListener(_hostChanged);
    _board?.dispose();
    if (_ownsMatch) {
      _match.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          CapturePage(
            role: widget.role,
            session: widget.session,
            standalone: widget.standalone,
            serverHost: widget.serverHost,
            linkOnly: widget.linkOnly,
            autoRecordSeconds: widget.autoRecordSeconds,
            prefersMaster: widget.prefersMaster,
            onMasterHost: _onMasterHost,
          ),
          _matchPage(),
        ],
      ),
      // La misma línea al 9 % que cierra la cabecera por abajo: sin ella, la barra se
      // funde con la tarjeta que pasa por debajo y se lee como parte de la lista.
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: ZeroColors.chrome)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (int next) => setState(() => _index = next),
          destinations: const <Widget>[
            NavigationDestination(
              icon: _CaptureIcon(selected: false),
              selectedIcon: _CaptureIcon(selected: true),
              label: 'Captura',
            ),
            NavigationDestination(
              icon: _MatchIcon(selected: false),
              selectedIcon: _MatchIcon(selected: true),
              label: 'Partido',
            ),
          ],
        ),
      ),
    );
  }
}

/// Captura son los dos anillos de la marca a 12 px. Es la app mirando por la lente.
class _CaptureIcon extends StatelessWidget {
  const _CaptureIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? ZeroColors.accent : ZeroColors.inactive;
    return ZeroMark(diameter: 12, left: color, right: color);
  }
}

/// Partido es el rótulo del marcador: un rectángulo tumbado, como se ve en la emisión.
class _MatchIcon extends StatelessWidget {
  const _MatchIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 12,
      decoration: BoxDecoration(
        border: Border.all(color: selected ? ZeroColors.accent : ZeroColors.inactive, width: 2),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}
