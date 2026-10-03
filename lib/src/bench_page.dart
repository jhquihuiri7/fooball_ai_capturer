/// La página del modo banco (IOS-08): arranca sola, corre y dice dónde dejó el JSON.
///
/// Se entra con `flutter run --dart-define=BENCH=<nombre>`. No hay botones que pulsar:
/// la prueba de una sola acción es lanzarla y leer el resumen con bench_summary.dart.
library;

import 'package:flutter/material.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';

class BenchPage extends StatefulWidget {
  const BenchPage({required this.name, this.paramsJson = '{}', this.api, super.key});

  final String name;

  /// Los parámetros del banco, en JSON tal cual van al informe (BENCH_PARAMS).
  final String paramsJson;

  /// Inyectable para los tests.
  final RigHostApi? api;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> implements RigFlutterApi {
  String _detail = 'arrancando…';
  double _fraction = 0;
  String? _reportPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    RigFlutterApi.setUp(this);
    _run();
  }

  @override
  void dispose() {
    RigFlutterApi.setUp(null);
    super.dispose();
  }

  Future<void> _run() async {
    final RigHostApi api = widget.api ?? RigHostApi();
    try {
      final String path = await api.runBench(widget.name, widget.paramsJson);
      if (mounted) {
        setState(() => _reportPath = path);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    }
  }

  @override
  void onBenchProgress(String name, double fraction, String detail) {
    if (mounted) {
      setState(() {
        _fraction = fraction;
        _detail = detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String estado = _error != null
        ? 'FALLÓ: $_error'
        : _reportPath != null
        ? 'HECHO · ${_reportPath!.split('/').last}\nBájalo con tools/bench_pull.sh'
        : '$_detail · ${(_fraction * 100).round()} %';
    return Scaffold(
      backgroundColor: ZeroColors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'BANCO · ${widget.name}',
                style: ZeroType.archivo(
                  size: 18,
                  weight: FontWeight.w600,
                  color: ZeroColors.ink,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                estado,
                key: const Key('bench-status'),
                style: ZeroType.plex(
                  size: 14,
                  weight: FontWeight.w400,
                  color: _error != null ? ZeroColors.danger : ZeroColors.inkSecondary,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
