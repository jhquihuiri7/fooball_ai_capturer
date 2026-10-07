/// El director de la franja (IOS-49): los flancos del partido de tools/ad_director.py y
/// lo que se manda al nativo.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/ads/ad_director.dart';
import 'package:football_ai_capture/src/ads/ad_pack_downloader.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/master_host.dart';

import 'ad_pack_fixture.dart';

class FakeAdSink implements AdSink {
  final List<String> playlists = <String>[];
  final List<(String, int)> overrides = <(String, int)>[];
  String answer = '';

  @override
  Future<String> setAdPlaylist(String json) async {
    playlists.add(json);
    return answer;
  }

  @override
  Future<void> setAdOverride(String name, int loops) async => overrides.add((name, loops));
}

MatchSignals _s({int goals = 0, bool running = true, bool live = true}) =>
    MatchSignals(goals: goals, clockRunning: running, live: live);

void main() {
  group('triggerBetween', () {
    test('un gol más es gol; uno menos, nada', () {
      expect(triggerBetween(_s(), _s(goals: 1)), AdTrigger.goal);
      expect(triggerBetween(_s(goals: 2), _s(goals: 1)), isNull);
    });

    test('el reloj que se para es el descanso; el que arranca, nada', () {
      expect(triggerBetween(_s(), _s(running: false)), AdTrigger.halfTime);
      expect(triggerBetween(_s(running: false), _s()), isNull);
    });

    test('ponerse al aire es el arranque; dejarlo, nada', () {
      expect(triggerBetween(_s(live: false), _s()), AdTrigger.onAir);
      expect(triggerBetween(_s(), _s(live: false)), isNull);
    });

    test('si coinciden, manda el gol', () {
      expect(triggerBetween(_s(live: false), _s(goals: 1, running: false)), AdTrigger.goal);
      expect(triggerBetween(_s(), _s()), isNull);
    });

    test('los nombres reservados son los de la referencia', () {
      expect(AdTrigger.values.map((AdTrigger t) => t.adName), <String>['gol', 'medio-tiempo', 'arranque']);
    });
  });

  test('playlistJson carga todos y rota los de rotación por orden alfabético', () {
    final AdPack pack = fixturePack();
    final Map<String, Object?> doc = jsonDecode(playlistJson(pack)) as Map<String, Object?>;
    final List<Object?> ads = doc['ads']! as List<Object?>;
    expect(ads.map((Object? a) => (a! as Map<String, Object?>)['name']), <String>['b-promo', 'gol', 'a-casa']);
    final Map<String, Object?> promo = ads.first! as Map<String, Object?>;
    final String f0 = 'blobs/${sha256Of(fixturePngs[0])}.png';
    final String f1 = 'blobs/${sha256Of(fixturePngs[1])}.png';
    expect(promo['frames'], <String>[f0, f0, f1]);
    expect(promo['fps'], 30);
    expect(doc['slots'], <Object?>[
      <String, Object?>{'name': 'a-casa', 'loops': 1},
      <String, Object?>{'name': 'b-promo', 'loops': 1},
    ]);
  });

  test('un gol pone el anuncio de gol EVENT_LOOPS vueltas y después vuelve la rotación', () {
    fakeAsync((FakeAsync async) {
      final FakeAdSink sink = FakeAdSink();
      final AdDirector d = AdDirector(sink);
      d.load(fixturePack());
      async.flushMicrotasks();
      expect(sink.playlists, hasLength(1));
      expect(d.rotation, <String>['a-casa', 'b-promo']);

      d.observe(_s());
      d.observe(_s(goals: 1));
      async.flushMicrotasks();
      expect(sink.overrides, <(String, int)>[('gol', adEventLoops)]);
      expect(d.eventOnAir, 'gol');

      // `gol` son 60 fotogramas a 30 fps: 2 s por vuelta.
      async.elapse(const Duration(seconds: 2 * adEventLoops) - const Duration(milliseconds: 1));
      expect(d.eventOnAir, 'gol');
      async.elapse(const Duration(milliseconds: 1));
      expect(d.eventOnAir, isNull, reason: 'vuelve la rotación');
      expect(sink.overrides, hasLength(1), reason: 'la vuelta la hace el nativo solo');
    });
  });

  test('el primer corte no dispara y un evento sin anuncio no toca la franja', () {
    fakeAsync((FakeAsync async) {
      final FakeAdSink sink = FakeAdSink();
      final AdDirector d = AdDirector(sink)..load(fixturePack());
      d.observe(_s(live: false));
      d.observe(_s());
      d.observe(_s(running: false));
      async.flushMicrotasks();
      expect(sink.overrides, isEmpty, reason: 'ni arranque ni medio-tiempo se vendieron');
      expect(d.eventOnAir, isNull);
    });
  });

  test('un gol durante otro vuelve a empezar sus vueltas; cargar un paquete lo quita', () {
    fakeAsync((FakeAsync async) {
      final FakeAdSink sink = FakeAdSink()..answer = 'gol: no cabe';
      final AdDirector d = AdDirector(sink, loops: 1)..load(fixturePack());
      d.observe(_s());
      d.observe(_s(goals: 1));
      async.elapse(const Duration(milliseconds: 1500));
      d.observe(_s(goals: 2));
      async.elapse(const Duration(milliseconds: 1500));
      expect(d.eventOnAir, 'gol');
      expect(sink.overrides, <(String, int)>[('gol', 1), ('gol', 1)]);
      d.load(fixturePack());
      async.flushMicrotasks();
      expect(d.eventOnAir, isNull);
      expect(d.error, 'gol: no cabe');
    });
  });

  group('en el maestro', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ios49d'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('al dirigir pone el paquete vigente y un gol desde el mando cuela el de gol', () async {
      // El paquete ya bajado de otra vez, sin red.
      final Directory ads = Directory('${dir.path}/ads');
      final AdPack pack = fixturePack();
      for (int i = 0; i < fixturePngs.length; i++) {
        File('${ads.path}/${pack.files[i].path}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(fixturePngs[i]);
      }
      File('${ads.path}/manifests/${pack.sha256}.json')
        ..createSync(recursive: true)
        ..writeAsBytesSync(fixtureManifest());
      File('${ads.path}/current').writeAsStringSync(pack.sha256);

      final FakeAdSink sink = FakeAdSink();
      final MasterHost host = MasterHost(
        directory: Directory('${dir.path}/partido'),
        controlSecret: (_) async => '',
        announceMatch: (_) async {},
        peerAddress: () async => '',
        operatorPin: () async => '123456',
        addresses: () async => <String>['192.168.7.20'],
        port: 0,
        adSink: sink,
        adPacks: AdPackDownloader(root: ads),
      );
      await host.becomeMaster('m_ads');
      expect(sink.playlists, <String>[playlistJson(pack)]);
      host.engine!.apply('match/goal', <String, Object?>{'team': 'home', 'delta': 1, 'expect': 0});
      await pumpEventQueue();
      expect(sink.overrides, <(String, int)>[('gol', adEventLoops)]);
      expect(host.ads!.eventOnAir, 'gol');
      await host.stepDown();
      expect(host.ads, isNull);
    });
  });
}
