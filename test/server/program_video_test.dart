/// El conductor del vídeo del programa (IOS-103, ADR 0027): lleva al nativo lo que dice
/// el motor, una vez por reproducción, y lo que falla no se queda «sonando».
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/program_video.dart';

import 'mp4_fixture.dart';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

class _Nativo implements VideoSink {
  final List<String> calls = <String>[];
  String error = '';

  @override
  Future<String> play(int id, String path, int leadMs) async {
    calls.add('play $id ${path.split(Platform.pathSeparator).last.split('/').last} $leadMs');
    return error;
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine engine;
  late _Nativo nativo;
  late ProgramVideo video;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('program_video_');
    reloj = _Reloj();
    engine = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, matchId: 'm_v');
    engine.videos.directory.createSync(recursive: true);
    engine.videos.file('a.mp4').writeAsBytesSync(fakeMp4(durationMs: 8000));
    nativo = _Nativo();
    video = ProgramVideo(engine: engine, sink: nativo);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('pasa, no repite, vuelve a pasar y para', () async {
    await video.refresh();
    expect(nativo.calls, isEmpty, reason: 'sin vídeo no se llama a nadie');
    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    await video.refresh();
    expect(nativo.calls, <String>['play 1 a.mp4 $videoStartLeadMs']);
    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    expect(nativo.calls.last, 'play 2 a.mp4 $videoStartLeadMs');
    engine.apply('video/stop', <String, Object?>{});
    await video.refresh();
    expect(nativo.calls.last, 'stop');
  });

  test('el aviso del nativo y el margen sin aviso dejan el programa como estaba', () async {
    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    engine.videoFinished(engine.video!.id);
    await video.refresh();
    expect(nativo.calls.last, 'stop');

    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    reloj.ms += videoStartLeadMs + 8000 + videoEndGraceMs + 1;
    await video.refresh();
    expect(nativo.calls.last, 'stop', reason: 'el tic de cada segundo lo quita sin aviso');
  });

  test('lo que el nativo no puede pasar no se queda sonando', () async {
    nativo.error = 'códec no soportado';
    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    expect(engine.video, isNull);
    expect(video.lastError, 'códec no soportado');
  });

  test('al dejar de dirigir, se quita', () async {
    engine.apply('video/play', <String, Object?>{'name': 'a.mp4'});
    await video.refresh();
    await video.close();
    expect(nativo.calls.last, 'stop');
  });
}
