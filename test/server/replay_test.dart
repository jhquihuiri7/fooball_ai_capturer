/// La repetición al aire en el maestro (IOS-119, ADR 0034): las marcas, la orden de repetir y
/// sus errores, la línea de tiempo (cortinilla, repetición, vuelta) y lo que dice el estado.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/replay_painter.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';
import 'package:football_ai_capture/src/server/replay.dart';

class _Reloj implements MatchTimeSource {
  int ms = 1000000;
  @override
  int nowMs() => ms;
  @override
  String get domain => 'soporte1';
}

OrderError _error(void Function() f) {
  try {
    f();
  } on OrderError catch (e) {
    return e;
  }
  fail('se esperaba OrderError');
}

int _r(String clave) => OverlaySpec.replay[clave]!;

void main() {
  late Directory dir;
  late _Reloj reloj;
  late MatchEngine m;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ios119');
    reloj = _Reloj();
    m = MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(7));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, Object?> estado() => m.toJson()['replay']! as Map<String, Object?>;

  /// Repite «lo último» 15 s con el anillo lleno; el nativo la deja para dentro de 800 ms.
  ReplayOnAir repite({int segundos = 15, int? marca}) {
    m.setReplayBuffer((oldestRigMs: reloj.ms - 90000, newestRigMs: reloj.ms));
    final ReplayRequest r = m.replayRequest(<String, Object?>{'mark': marca, 'seconds': segundos});
    m.replayArmed((id: r.id, fromRigMs: r.fromRigMs, toRigMs: r.toRigMs, cutRigMs: reloj.ms + replayLeadToCutMs));
    return m.replay.onAir!;
  }

  group('marcas', () {
    test('replay/mark apunta el instante y el cronómetro, sube rev y corta el clip del VPS', () {
      int clips = 0;
      m.onClipMark = () => clips++;
      m.apply('match/clock', <String, Object?>{'action': 'start'});
      reloj.ms += 12000;
      final int rev = m.rev;
      m.apply('replay/mark', <String, Object?>{});
      reloj.ms += 3000;
      m.apply('replay/mark', <String, Object?>{});
      expect(m.rev, rev + 2);
      expect(clips, 2, reason: 'la misma marca corta el clip del VPS si hay gancho');
      final List<Object?> marcas = estado()['marks']! as List<Object?>;
      expect(marcas, <Map<String, Object?>>[
        <String, Object?>{'id': 2, 'age_ms': 0, 'clock_ms': 15000},
        <String, Object?>{'id': 1, 'age_ms': 3000, 'clock_ms': 12000},
      ]);
    });

    test('se guardan las últimas marks_max y se olvidan las que ya no caben en el anillo', () {
      for (int i = 0; i < _r('marks_max') + 2; i++) {
        m.apply('replay/mark', <String, Object?>{});
        reloj.ms += 1000;
      }
      expect(m.replay.marks.length, _r('marks_max'));
      expect(m.replay.marks.first.id, _r('marks_max') + 2);
      final int rev = m.rev;
      reloj.ms += _r('ring_s') * 1000 - 5500;
      expect(m.tick(), isTrue, reason: 'las que pasan del anillo se olvidan y sube rev');
      expect(m.rev, rev + 1);
      expect(m.replay.marks.length, 5);
    });
  });

  group('repetir', () {
    test('sin programa (el anillo vacío) es 409 con el partido', () {
      final OrderError e = _error(() => m.replayRequest(<String, Object?>{'seconds': 15}));
      expect(e.status, 409);
      expect(e.message, replayWithoutProgram);
      expect(e.current, isNotNull);
    });

    test('seconds fuera de 3-30 o que no es entero es 400; una marca que no hay, 404', () {
      m.setReplayBuffer((oldestRigMs: 0, newestRigMs: reloj.ms));
      for (final Object? malo in <Object?>[2, 31, 15.0, '15', null]) {
        expect(_error(() => m.replayRequest(<String, Object?>{'seconds': malo})).status, 400, reason: '$malo');
      }
      expect(_error(() => m.replayRequest(<String, Object?>{'mark': 'a'})).status, 400);
      expect(_error(() => m.replayRequest(<String, Object?>{'mark': 9})).status, 404);
    });

    test('sin seconds, los de por defecto; con marca, hacia atrás desde ella', () {
      m.setReplayBuffer((oldestRigMs: 0, newestRigMs: reloj.ms));
      m.apply('replay/mark', <String, Object?>{});
      final int marca = reloj.ms;
      reloj.ms += 7000;
      final ReplayRequest r = m.replayRequest(<String, Object?>{'mark': 1});
      expect(r.toRigMs, marca);
      expect(r.fromRigMs, marca - _r('default_s') * 1000);
      expect(_error(() => m.replayRequest(<String, Object?>{})).status, 409, reason: 'una a la vez');
      m.replayFailed(r.id);
      final ReplayRequest ultimo = m.replayRequest(<String, Object?>{'seconds': 10});
      expect(ultimo.toRigMs, reloj.ms, reason: 'sin marca, lo último hasta ahora');
      expect(ultimo.fromRigMs, reloj.ms - 10000);
      expect(ultimo.id, greaterThan(r.id));
    });

    test('preparada, el estado la lleva y pasa por sus fases hasta volver al directo', () {
      final ReplayOnAir a = repite();
      expect(a.cutOutMs - a.cutInMs, 15000);
      Map<String, Object?> alAire() => estado()['on_air']! as Map<String, Object?>;
      expect(alAire(), <String, Object?>{'id': 1, 'mark': null, 'seconds': 15, 'phase': 'in', 'remaining_ms': 15800});
      reloj.ms = a.cutInMs;
      expect(alAire()['phase'], 'replay');
      expect(m.tick(), isTrue, reason: 'el cambio de fase sube rev');
      reloj.ms = a.cutOutMs;
      expect(alAire()['phase'], 'out');
      reloj.ms = a.endMs;
      expect(estado()['on_air'], isNull);
      expect(m.tick(), isTrue);
      expect(m.replay.busy, isFalse);
    });

    test('con una repetición al aire no suena un vídeo, ni con uno sonando se repite', () {
      repite();
      expect(_error(() => m.apply('video/play', <String, Object?>{'name': 'x'})).message, replayBlocksVideo);
      expect(_error(() => m.apply('video/play_all', <String, Object?>{})).status, 409);
    });
  });

  group('volver al directo', () {
    test('antes de que entre: la repetición dura al menos dos cortinillas', () {
      final ReplayOnAir a = repite();
      final ({int id, int cutRigMs}) corte = m.replayStop();
      expect(corte.cutRigMs, a.cutInMs + replayTransitionMs);
      expect(a.startMs + replayTransitionMs, a.returnMs, reason: 'la de vuelta empieza al acabar la de entrada');
    });

    test('en mitad: en cuanto pasa la cortinilla; nunca la alarga', () {
      final ReplayOnAir a = repite();
      reloj.ms = a.cutInMs + 5000;
      expect(m.replayStop().cutRigMs, reloj.ms + replayLeadToCutMs);
      reloj.ms = a.cutOutMs - 100;
      final int antes = a.cutOutMs;
      expect(m.replayStop().cutRigMs, antes, reason: 'ya volvía: no se retrasa');
    });

    test('sin repetición es 409', () {
      expect(_error(m.replayStop).status, 409);
    });
  });

  group('lo que se pinta', () {
    test('la cortinilla con título al entrar, el rótulo durante, la cortinilla sin título al volver', () {
      final ReplayOnAir a = repite();
      reloj.ms = a.startMs - 1;
      expect(m.replayGraphic, isNull, reason: 'hasta que empieza la cortinilla, nada');
      reloj.ms = a.startMs + 100;
      final ReplayGraphic entra = m.replayGraphic!;
      expect(entra.title, isTrue);
      expect(entra.bug, isFalse);
      expect(entra.stinger!.covering, isTrue);
      expect(m.replay.moving, isTrue);
      reloj.ms = a.cutInMs;
      expect(m.replayGraphic!.stinger, stingerCovered, reason: 'tapada en el corte');
      expect(m.replayGraphic!.bug, isTrue);
      expect(m.replay.moving, isFalse, reason: 'tapada no se mueve: no se rasteriza');
      reloj.ms = a.cutInMs + 3000;
      expect(m.replayGraphic, const ReplayGraphic(bug: true), reason: 'en la repetición, solo el rótulo');
      reloj.ms = a.returnMs + 50;
      final ReplayGraphic vuelve = m.replayGraphic!;
      expect(vuelve.title, isFalse);
      expect(vuelve.bug, isTrue);
      reloj.ms = a.cutOutMs + 1;
      expect(m.replayGraphic!.bug, isFalse);
      reloj.ms = a.endMs;
      expect(m.replayGraphic, isNull);
    });
  });

  group('lo que contesta el nativo', () {
    test('la repetición preparada, o su error como 409', () {
      expect(
        parseReplayArmed(3, '{"from_rig_ms":1,"to_rig_ms":2,"cut_rig_ms":3}'),
        (id: 3, fromRigMs: 1, toRigMs: 2, cutRigMs: 3),
      );
      final OrderError e = _error(() => parseReplayArmed(3, '{"error":"esa jugada ya no está"}'));
      expect((e.status, e.message), (409, 'esa jugada ya no está'));
      expect(_error(() => parseReplayArmed(3, '{}')).status, 409);
    });

    test('el anillo, o null sin programa', () {
      expect(parseReplayBuffer('{"oldest_rig_ms":5,"newest_rig_ms":9}'), (oldestRigMs: 5, newestRigMs: 9));
      expect(parseReplayBuffer('{}'), isNull);
    });

    test('el anillo solo sube rev al empezar y acabar el programa; buffer_ms, hasta dónde llega', () {
      final int rev = m.rev;
      m.setReplayBuffer((oldestRigMs: reloj.ms - 40000, newestRigMs: reloj.ms));
      m.setReplayBuffer((oldestRigMs: reloj.ms - 41000, newestRigMs: reloj.ms));
      expect(m.rev, rev + 1);
      expect(estado()['buffer_ms'], 41000);
      m.setReplayBuffer(null);
      expect(m.rev, rev + 2);
      expect(estado()['buffer_ms'], 0);
    });
  });
}
