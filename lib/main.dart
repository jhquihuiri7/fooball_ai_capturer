/// App de captura del soporte de dos iPhone (ADR 0012 del repo `football-ai`).
///
/// La UI es deliberadamente pobre: quien la usa está en una cancha, con sol, y solo
/// tiene que hacer tres cosas —elegir el lado, comprobar que la cámara arrancó bien y
/// darle a grabar—. Todo lo demás lo decide el código.
library;

import 'package:flutter/material.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

void main() {
  runApp(const CaptureApp());
}

class CaptureApp extends StatelessWidget {
  const CaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'football-ai · captura',
      theme: ThemeData(colorSchemeSeed: Colors.green, brightness: Brightness.dark),
      home: const RolePage(),
    );
  }
}

/// Elegir lado. Es lo primero y lo único que no puede equivocarse: si los dos móviles
/// dicen ser el izquierdo, el servidor recibe dos veces la misma mitad del campo.
class RolePage extends StatelessWidget {
  const RolePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('¿Qué mitad cubre este móvil?')),
      body: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: const <Widget>[
            _RoleButton(role: CameraRole.left, label: 'IZQUIERDA'),
            _RoleButton(role: CameraRole.right, label: 'DERECHA'),
          ],
        ),
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  const _RoleButton({required this.role, required this.label});

  final CameraRole role;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => CapturePage(role: role)),
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
  const CapturePage({required this.role, this.session, super.key});

  final CameraRole role;

  /// Inyectable para los tests: sin esto habría que hablar con la cámara de verdad.
  final CaptureSession? session;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final CaptureSession _session = widget.session ?? CaptureSession(role: widget.role);

  @override
  void initState() {
    super.initState();
    _session.addListener(_onChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_onChanged);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.role == CameraRole.left ? 'Cámara izquierda' : 'Cámara derecha'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _Row('Estado', _session.phase.name),
          if (_session.problem != null) _Row('Problema', _session.problem!, alarm: true),
          if (status != null) ...<Widget>[
            _Row('Resolución', '${status.width}×${status.height}'),
            _Row('Cadencia real', status.actualFps.toStringAsFixed(2)),
            _Row(
              'Estabilización',
              status.stabilizationDisabled ? 'desactivada' : 'ACTIVA',
              alarm: !status.stabilizationDisabled,
            ),
            _Row(
              'Exposición',
              status.exposureLocked ? 'bloqueada' : 'AUTOMÁTICA',
              alarm: !status.exposureLocked,
            ),
            _Row('Intrínsecas', status.intrinsicsAvailable ? 'sí' : 'no'),
            _Row(
              'Temperatura',
              status.thermalState.name,
              alarm: status.thermalState.index >= ThermalState.serious.index,
            ),
            _Row('Batería', '${(status.batteryLevel * 100).round()} %'),
            _Row('Frames perdidos', '${status.droppedFrames}'),
          ],
          _Row('Reloj del soporte', _session.clockLabel),
          _Row('Fase de exposición', _session.phaseLabel),
          const SizedBox(height: 24),
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
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: alarm ? Colors.orangeAccent : null,
            ),
          ),
        ],
      ),
    );
  }
}
