/// La pizarra replicada (IOS-82): serialización, la más fresca, el disco, el envío del
/// maestro y el reloj que no retrocede al abrir el partido desde la réplica.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/master_host.dart';
import 'package:football_ai_capture/src/server/match_record.dart';
import 'package:football_ai_capture/src/server/replica.dart';

class _Reloj implements MatchTimeSource {
  _Reloj(this.domain);
  int ms = 0;
  @override
  final String domain;
  @override
  int nowMs() => ms;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ios82'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('ida y vuelta, con la idempotencia reciente y sin secretos', () async {
    final _Reloj reloj = _Reloj('soporte1');
    final MatchEngine e = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(1));
    final MasterApi api = MasterApi(engine: e, monotonicMs: () => 1000, wallS: () => 0, operatorPin: '123456');
    await api.handle(ApiRequest(
      method: 'POST', path: '/api/v1/match/goal',
      headers: const <String, String>{'authorization': 'Bearer 123456', 'content-type': 'application/json',
        'idempotency-key': 'k-gol'},
      body: utf8.encode(jsonEncode(<String, Object?>{'team': 'home', 'delta': 1, 'expect': 0})),
    ));
    final StateReplica r = StateReplica.fromEngine(e, term: 2, seq: 7, rigMs: 5000, clockDomain: 'soporte1',
        idempotency: api.idempotency);
    final String json = r.encode();
    expect(json.contains('123456'), isFalse, reason: 'ni el PIN ni secretos en la pizarra');
    final StateReplica back = StateReplica.decode(json)!;
    expect((back.term, back.seq, back.match.homeGoals, back.rev), (2, 7, 1, e.rev));
    expect(back.idempotency.single['key'], 'match/goal k-gol');
    expect(back.idempotency.single['status'], 200);
  });

  test('manda la más fresca por (term, seq) y queda en disco', () {
    String r(int term, int seq) => StateReplica(
      matchId: 'm', term: term, seq: seq, rigMs: 0, clockDomain: 'd', boot: 'b', rev: seq,
      match: const MatchRecord(matchId: 'm', home: 'A', away: 'B', homeGoals: 0, awayGoals: 0,
          accumulatedMs: 0, running: false, startedRigMs: null, clockDomain: 'd'),
      lineups: const <String, Object?>{}, idempotency: const <Map<String, Object?>>[],
    ).encode();
    final File f = File('${dir.path}/replica.json');
    final ReplicaStore s = ReplicaStore(f);
    expect(s.accept(r(1, 5)), isTrue);
    expect(s.accept(r(1, 4)), isFalse, reason: 'vieja');
    expect(s.accept(r(1, 5)), isFalse, reason: 'la misma');
    expect(s.accept(r(2, 1)), isTrue, reason: 'term mayor, aunque el seq empiece de nuevo');
    expect(s.accept('{roto'), isFalse);
    expect(ReplicaStore(f).latest!.term, 2, reason: 'sobrevive a reiniciar');
  });

  test('un maestro que reinicia la app (mismo term, seq desde 1) sigue mandando', () {
    String r({required String boot, required int seq, required int rigMs, String domain = 'd'}) => StateReplica(
      matchId: 'm', term: 1, seq: seq, rigMs: rigMs, clockDomain: domain, boot: boot, rev: seq,
      match: MatchRecord(matchId: 'm', home: 'A', away: 'B', homeGoals: 0, awayGoals: 0,
          accumulatedMs: 0, running: false, startedRigMs: null, clockDomain: domain),
      lineups: const <String, Object?>{}, idempotency: const <Map<String, Object?>>[],
    ).encode();
    final ReplicaStore s = ReplicaStore(File('${dir.path}/replica.json'));
    expect(s.accept(r(boot: 'a', seq: 80, rigMs: 400000)), isTrue);
    expect(s.accept(r(boot: 'b', seq: 1, rigMs: 900000)), isTrue, reason: 'otro arranque, más tarde en el reloj');
    expect(s.accept(r(boot: 'a', seq: 81, rigMs: 400100)), isFalse, reason: 'el arranque viejo, antes en el reloj');
    expect(s.accept(r(boot: 'b', seq: 2, rigMs: 900033)), isTrue);
    expect(s.accept(r(boot: 'c', seq: 1, rigMs: 5, domain: 'otro')), isTrue, reason: 'otro dominio: gana la que llega');
  });

  test('el maestro la manda al cambiar el partido', () async {
    final List<String> enviadas = <String>[];
    final MasterHost h = MasterHost(
      directory: dir, controlSecret: (_) async => '', announceMatch: (_) async {},
      peerAddress: () async => '', operatorPin: () async => '', port: 0,
      replicaSink: (String j) async => enviadas.add(j), term: () => 3,
    );
    await h.becomeMaster('m_r');
    await Future<void>.delayed(Duration.zero);
    final int antes = enviadas.length;
    h.engine!.apply('match/goal', <String, Object?>{'team': 'away', 'delta': 1, 'expect': 0});
    await Future<void>.delayed(Duration.zero);
    expect(enviadas.length, greaterThan(antes));
    final StateReplica ultima = StateReplica.decode(enviadas.last)!;
    expect((ultima.term, ultima.match.awayGoals), (3, 1));
    expect(ultima.seq, greaterThan(StateReplica.decode(enviadas.first)!.seq));
    await h.stepDown();
  });

  test('en el mismo dominio, el partido de la réplica sigue en marcha y no retrocede', () {
    final _Reloj reloj = _Reloj('soporte1');
    final MatchEngine m = MatchEngine.open(file: File('${dir.path}/a.json'), time: reloj, random: Random(2));
    m.apply('match/clock', <String, Object?>{'action': 'start'});
    reloj.ms = 44 * 60 * 1000;
    final StateReplica r = StateReplica.fromEngine(m, term: 1, seq: 1, rigMs: reloj.ms, clockDomain: 'soporte1');
    final double alAire = m.clock.elapsedMs / 1000;
    // El esclavo, 3 s después y con el mismo reloj del soporte, abre el partido.
    reloj.ms += 3000;
    final File f = File('${dir.path}/b.json');
    saveRecord(f, r.match);
    final MatchEngine promovido = MatchEngine.open(file: f, time: reloj);
    expect(promovido.clock.running, isTrue);
    expect(promovido.clock.restored, isFalse, reason: 'la promoción no marca clock_restored');
    expect(promovido.clock.elapsedMs / 1000, greaterThanOrEqualTo(alAire));
    expect(promovido.clock.elapsedMs / 1000 - alAire, lessThanOrEqualTo(3.0 + 1.0));
    expect(promovido.homeGoals, m.homeGoals);
    expect(MatchTeam.values, hasLength(2));
  });
}
