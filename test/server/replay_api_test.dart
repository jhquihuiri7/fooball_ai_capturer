/// La repetición por la API del maestro (IOS-119, ADR 0034): `replay/play` espera al nativo y
/// contesta con lo que dijo; `replay/stop` le dice cuándo vuelve el directo. Igual por la LAN que
/// por el túnel: aquí, por el túnel con el panel remoto (principal operator).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/program_replay.dart';
import 'package:football_ai_capture/src/server/replay.dart';

class _Reloj implements MatchTimeSource {
  int ms = 500000;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

/// El nativo falso: contesta lo que se le diga, o se queda callado.
class _Nativo implements ReplaySink {
  _Nativo(this.reloj);

  final _Reloj reloj;
  final List<String> calls = <String>[];
  String? respuesta;
  bool mudo = false;
  String anillo = '{}';

  @override
  Future<String> prepare(int id, int fromRigMs, int toRigMs, int leadMs) async {
    calls.add('prepare $id $fromRigMs $toRigMs $leadMs');
    if (mudo) {
      return Completer<String>().future;
    }
    return respuesta ?? '{"from_rig_ms":$fromRigMs,"to_rig_ms":$toRigMs,"cut_rig_ms":${reloj.ms + leadMs}}';
  }

  @override
  Future<void> stop(int id, int cutRigMs) async => calls.add('stop $id $cutRigMs');

  @override
  Future<String> buffer() async => anillo;
}

void main() {
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine engine;
  late _Nativo nativo;
  late MasterApi api;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ios119api');
    reloj = _Reloj();
    engine = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(9));
    nativo = _Nativo(reloj);
    api = MasterApi(engine: engine, monotonicMs: () => reloj.ms, wallS: () => 1790000000, replay: nativo);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<CommandReply> orden(String ruta, Map<String, Object?> body) => api.command(ApiRequest.fromCommand(
    <String, Object?>{'method': 'POST', 'path': '/api/v1/$ruta', 'principal': 'operator', 'body': body},
  ));

  Map<String, Object?> cuerpo(CommandReply r) => r.responseData['body']! as Map<String, Object?>;

  Future<void> conPrograma() async {
    nativo.anillo = '{"oldest_rig_ms":${reloj.ms - 90000},"newest_rig_ms":${reloj.ms}}';
    await ReplayBufferWatch(engine: engine, sink: nativo).poll();
  }

  test('marcar y repetir: el nativo la prepara y la cortinilla sale con su número', () async {
    await conPrograma();
    expect((await orden('replay/mark', <String, Object?>{})).response.status, 200);
    reloj.ms += 4000;
    final CommandReply r = await orden('replay/play', <String, Object?>{'mark': 1, 'seconds': 10});
    expect(r.response.status, 200);
    expect(nativo.calls, <String>['prepare 1 490000 500000 $replayLeadToCutMs']);
    final Map<String, Object?> alAire = (cuerpo(r)['replay']! as Map<String, Object?>)['on_air']! as Map<String, Object?>;
    expect(alAire['mark'], 1);
    expect(alAire['phase'], 'in');
    expect(r.state, isNotNull, reason: 'sube rev: el túnel manda el state antes');
  });

  test('lo que no se puede, el nativo lo dice y la repetición no sale', () async {
    await conPrograma();
    nativo.respuesta = '{"error":"esa jugada ya no está en la memoria del maestro"}';
    final CommandReply r = await orden('replay/play', <String, Object?>{'seconds': 15});
    expect(r.response.status, 409);
    expect(cuerpo(r)['detail'], 'esa jugada ya no está en la memoria del maestro');
    expect(engine.replay.busy, isFalse, reason: 'se puede pedir otra');
  });

  test('sin programa, 409 sin preguntar al nativo', () async {
    final CommandReply r = await orden('replay/play', <String, Object?>{'seconds': 15});
    expect(r.response.status, 409);
    expect(nativo.calls, isEmpty);
  });

  test('si el nativo no contesta a tiempo, 504 y se le dice que no salga', () async {
    await conPrograma();
    nativo.mudo = true;
    final CommandReply r = await orden('replay/play', <String, Object?>{'seconds': 15});
    expect(r.response.status, 504);
    expect(nativo.calls.last, 'stop 1 0');
    expect(engine.replay.busy, isFalse);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('volver al directo le dice al nativo el instante; sin repetición, 409', () async {
    expect((await orden('replay/stop', <String, Object?>{})).response.status, 409);
    await conPrograma();
    await orden('replay/play', <String, Object?>{'seconds': 15});
    final ReplayOnAir a = engine.replay.onAir!;
    reloj.ms = a.cutInMs + 2000;
    final CommandReply r = await orden('replay/stop', <String, Object?>{});
    expect(r.response.status, 200);
    expect(nativo.calls.last, 'stop 1 ${reloj.ms + replayLeadToCutMs}');
  });

  test('sin nativo de repetición (otro móvil, un banco), 409', () async {
    final MasterApi sin = MasterApi(engine: engine, monotonicMs: () => reloj.ms, wallS: () => 1790000000);
    final CommandReply r = await sin.command(ApiRequest.fromCommand(<String, Object?>{
      'method': 'POST', 'path': '/api/v1/replay/play', 'principal': 'operator', 'body': <String, Object?>{},
    }));
    expect(r.response.status, 409);
    expect((r.responseData['body']! as Map<String, Object?>)['detail'], replayWithoutProgram);
  });
}
