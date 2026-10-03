/// Resume informes de banco (IOS-08). Corre en el Mac y en Windows:
///
///   dart tools/bench_summary.dart bench/bench/noop-1791039000.json [más.json]
///
/// Lee el JSON que deja `BenchRunner.swift` y lo pone en una tabla legible. Las
/// claves son contrato: si cambian allí, cambian aquí en el mismo commit.
library;

import 'dart:convert';
import 'dart:io';

/// El resumen de un informe, listo para imprimir. Separado de `main` para poder
/// probarlo con `flutter test` sin tocar disco.
String summarize(Map<String, Object?> report) {
  final StringBuffer out = StringBuffer();
  final String name = report['name']! as String;
  final String device = report['device']! as String;
  final String system = report['system_version']! as String;
  final double duration = (report['duration_s']! as num).toDouble();
  final List<Object?> thermal = report['thermal']! as List<Object?>;

  out.writeln('$name · $device · $system');
  out.writeln(
    'duración ${duration.toStringAsFixed(2)} s · térmica ${thermal.join(" → ")}',
  );

  final Map<String, Object?> stages = (report['stages_ms'] as Map<String, Object?>?) ?? <String, Object?>{};
  if (stages.isNotEmpty) {
    out.writeln('etapa            p50      p90      p99 (ms)');
    for (final MapEntry<String, Object?> entry
        in stages.entries.toList()..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) => a.key.compareTo(b.key))) {
      final Map<String, Object?> s = entry.value! as Map<String, Object?>;
      String f(String key) => ((s[key]! as num).toDouble()).toStringAsFixed(1).padLeft(8);
      out.writeln('${entry.key.padRight(12)}${f('p50_ms')}${f('p90_ms')}${f('p99_ms')}');
    }
  }

  final Map<String, Object?> counters = (report['counters'] as Map<String, Object?>?) ?? <String, Object?>{};
  for (final MapEntry<String, Object?> entry
      in counters.entries.toList()..sort((MapEntry<String, Object?> a, MapEntry<String, Object?> b) => a.key.compareTo(b.key))) {
    out.writeln('${entry.key} = ${entry.value}');
  }
  final Map<String, Object?> params = (report['params'] as Map<String, Object?>?) ?? <String, Object?>{};
  if (params.isNotEmpty) {
    out.writeln('params: ${params.entries.map((MapEntry<String, Object?> e) => '${e.key}=${e.value}').join(', ')}');
  }
  return out.toString();
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('uso: dart tools/bench_summary.dart <informe.json> [...]');
    exitCode = 64;
    return;
  }
  for (final String path in args) {
    final Map<String, Object?> report =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    stdout.writeln(summarize(report));
  }
}
