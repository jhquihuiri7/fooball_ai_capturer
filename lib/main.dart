/// App de captura del soporte de dos iPhone (ADR 0012 del repo `football-ai`).
///
/// La UI es deliberadamente pobre: quien la usa está en una cancha, con sol, y solo
/// tiene que hacer tres cosas —elegir el lado, comprobar que la cámara arrancó bien y
/// darle a grabar—. Todo lo demás lo decide el código.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

void main() {
  runApp(const CaptureApp());
}

class CaptureApp extends StatelessWidget {
  const CaptureApp({this.api, super.key});

  /// Inyectable para los tests.
  final CaptureHostApi? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'football-ai · captura',
      theme: ThemeData(colorSchemeSeed: Colors.green, brightness: Brightness.dark),
      home: RolePage(api: api),
    );
  }
}

/// Elegir lado. Es lo primero y lo único que no puede equivocarse: si los dos móviles
/// dicen ser el izquierdo, el servidor recibe dos veces la misma mitad del campo.
class RolePage extends StatefulWidget {
  const RolePage({this.api, super.key});

  final CaptureHostApi? api;

  @override
  State<RolePage> createState() => _RolePageState();
}

class _RolePageState extends State<RolePage> {
  late final CaptureHostApi _api = widget.api ?? CaptureHostApi();
  final TextEditingController _server = TextEditingController();

  /// Apagado por defecto: encenderlo en un partido es grabar dos vídeos que no parean.
  bool _standalone = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadServer());
  }

  /// Lo guardado manda; si no hay nada, se busca el banco de pruebas por Bonjour y se
  /// guarda lo encontrado, para no teclear una IP nunca.
  bool _searching = false;

  Future<void> _loadServer() async {
    try {
      _server.text = await _api.loadServerHost();
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
        await _saveServer(found);
      }
    } on Exception {
      // Sin nativo no hay red que buscar.
    }
    if (mounted) {
      setState(() => _searching = false);
    }
  }

  Future<void> _saveServer(String host) async {
    try {
      await _api.saveServerHost(host.trim());
    } on Exception {
      // Igual que arriba: sin nativo no se guarda, y no pasa nada.
    }
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('¿Qué mitad cubre este móvil?')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  _RoleButton(
                    role: CameraRole.left,
                    label: 'IZQUIERDA',
                    standalone: _standalone,
                    serverHost: _server.text.trim(),
                  ),
                  _RoleButton(
                    role: CameraRole.right,
                    label: 'DERECHA',
                    standalone: _standalone,
                    serverHost: _server.text.trim(),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Servidor (host o IP del MediaMTX)',
                helperText: _searching
                    ? 'Buscando el servidor en la red…'
                    : 'Vacío: solo se graba en el móvil, no se emite.',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Buscar en la red',
                  onPressed: _searching ? null : () => unawaited(_discoverServer()),
                ),
              ),
              onChanged: (String value) {
                unawaited(_saveServer(value));
                setState(() {});
              },
            ),
          ),
          SwitchListTile(
            title: const Text('Un solo móvil, sin reloj'),
            subtitle: const Text(
              'Solo para probar la cámara. Lo grabado así no parea con el otro móvil.',
            ),
            value: _standalone,
            onChanged: (bool value) => setState(() => _standalone = value),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({
    required this.role,
    required this.label,
    required this.standalone,
    required this.serverHost,
  });

  final CameraRole role;
  final String label;
  final bool standalone;
  final String serverHost;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CapturePage(role: role, standalone: standalone, serverHost: serverHost),
        ),
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      ),
      child: Text(label, style: const TextStyle(fontSize: 22)),
    );
  }
}

/// Estado de la captura y los dos botones.
class CapturePage extends StatefulWidget {
  const CapturePage({
    required this.role,
    this.session,
    this.standalone = false,
    this.serverHost = '',
    super.key,
  });

  final CameraRole role;

  /// Inyectable para los tests: sin esto habría que hablar con la cámara de verdad.
  final CaptureSession? session;

  /// Probar con un solo móvil, sin esperar reloj (ver `CaptureSession.standalone`).
  final bool standalone;

  /// Host o IP del servidor. Vacío: solo grabación.
  final String serverHost;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureSession _session = widget.session ??
      CaptureSession(role: widget.role, standalone: widget.standalone, serverHost: widget.serverHost);
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
    _refresh = Timer.periodic(
      statusRefreshInterval,
      (_) => unawaited(_session.refreshStatus()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    CaptureFlutterApi.setUp(null);
    _session.removeListener(_onChanged);
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
    final CaptureStatus? status = _session.status;
    final String side = widget.role == CameraRole.left ? 'Cámara izquierda' : 'Cámara derecha';
    return Scaffold(
      appBar: AppBar(title: Text(_session.standalone ? '$side · SIN RELOJ' : side)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const _Preview(),
          _RecordingBanner(session: _session),
          // El botón va antes que toda la información: es lo único que se pulsa.
          FilledButton(
            onPressed: _session.canRecord ? () => _session.toggleRecording() : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 28),
              backgroundColor: _session.recording ? Colors.red : null,
            ),
            child: Text(
              _session.recording ? 'PARAR' : 'GRABAR',
              style: const TextStyle(fontSize: 24),
            ),
          ),
          const SizedBox(height: 12),
          _Row('Red local', _session.localNetworkLabel, alarm: _session.localNetworkAllowed == false),
          _Row('Emisión', _session.streamLabel, alarm: _session.streamInTrouble),
          if (status != null && status.streamState != StreamState.off)
            _Row('Frames perdidos (emisión)', '${status.streamDroppedFrames}'),
          if (!_session.recording && _session.recordingFileName != null)
            _Row('Último archivo', _session.recordingFileName!),
          _Row('Modo', _session.modeLabel, alarm: _session.standalone),
          _Row('Estado', _session.phase.name),
          if (_session.problem != null) _Row('Problema', _session.problem!, alarm: true),
          if (_session.interruption != null)
            _Row('Interrupción', _session.interruption!, alarm: true),
          if (status != null) ...<Widget>[
            _Row('Cámara en marcha', status.running ? 'sí' : 'todavía no', alarm: !status.running),
            _Row('Resolución', '${status.width}×${status.height}'),
            _Row('Cadencia real', status.actualFps.toStringAsFixed(2)),
            _Row(
              'Estabilización',
              status.stabilizationDisabled ? 'desactivada' : 'ACTIVA',
              alarm: !status.stabilizationDisabled,
            ),
            _Row('Exposición', _session.exposureLabel, alarm: !status.exposureLocked),
            _Row(
              'Balance de blancos',
              _session.whiteBalanceLabel,
              alarm: !status.whiteBalanceLocked,
            ),
            _Row('Foco', status.focusLocked ? 'bloqueado' : 'AUTOMÁTICO'),
            _Row('Intrínsecas', status.intrinsicsAvailable ? 'sí' : 'no'),
            _Row(
              'Temperatura',
              status.thermalState.name,
              alarm: status.thermalState.index >= ThermalState.serious.index,
            ),
            _Row('Batería', '${(status.batteryLevel * 100).round()} %'),
            _Row('Disco libre', '${(status.freeDiskBytes / 1e9).toStringAsFixed(1)} GB'),
            _Row('Frames perdidos', '${status.droppedFrames}'),
            _Row(
              'Código de tiempo',
              _session.timecodeLabel,
              alarm: status.timecodeFailures > 0,
            ),
          ],
          _Row('Reloj del soporte', _session.clockLabel),
          _Row('Fase de exposición', _session.phaseLabel),
          const SizedBox(height: 16),
          const Text(
            'Las grabaciones quedan en Documentos: se ven en Finder al conectar el móvil '
            'o en la app Archivos.',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// La imagen de la cámara. Es una vista nativa sobre la misma sesión que graba, así
/// que enseña el encuadre real y no cuesta CPU. Solo existe en iPhone.
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    final bool portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    return AspectRatio(
      // Apaisado: la imagen entera a 16:9. Vertical: la imagen gira y cabe más alta.
      aspectRatio: portrait ? 3 / 4 : 16 / 9,
      child: Theme.of(context).platform == TargetPlatform.iOS
          ? const UiKitView(viewType: 'capture-preview')
          : const ColoredBox(
              color: Colors.black26,
              child: Center(child: Text('vista previa solo en iPhone')),
            ),
    );
  }
}

/// Grabando o no, en grande y en rojo: es lo primero que se mira desde lejos.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.session});

  final CaptureSession session;

  @override
  Widget build(BuildContext context) {
    final bool recording = session.recording;
    final String text;
    if (recording) {
      text = 'GRABANDO  ${session.recordingLabel}';
    } else if (session.canRecord) {
      text = 'No está grabando';
    } else {
      text = 'Cámara no lista';
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: recording ? Colors.red : Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            recording ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
            color: recording ? Colors.white : Colors.white54,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: recording ? Colors.white : Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.alarm = false});

  final String label;
  final String value;
  final bool alarm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: const TextStyle(color: Colors.white70)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: alarm ? Colors.orangeAccent : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
