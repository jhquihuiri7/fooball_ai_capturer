import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/bench_page.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';

/// BENCH_PARAMS llega tal cual al nativo: es lo que permite repetir SPK-03 sin la
/// HEVC 4K ({"hevc":"0"}) sin tocar código.
class _FakeRigApi extends RigHostApi {
  String? name;
  String? paramsJson;

  @override
  Future<String> runBench(String name, String paramsJson) async {
    this.name = name;
    this.paramsJson = paramsJson;
    return '/tmp/informe.json';
  }
}

void main() {
  testWidgets('la página pasa el nombre y los parámetros al banco', (tester) async {
    final _FakeRigApi api = _FakeRigApi();
    await tester.pumpWidget(MaterialApp(
      home: BenchPage(
        name: 'vt-concurrency',
        paramsJson: '{"hevc":"0","duration_s":30}',
        api: api,
      ),
    ));
    await tester.pump();

    expect(api.name, 'vt-concurrency');
    expect(api.paramsJson, '{"hevc":"0","duration_s":30}');
    expect(find.textContaining('informe.json'), findsOneWidget);
  });
}
