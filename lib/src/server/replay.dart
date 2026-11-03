/// La repetición al aire en el maestro (IOS-119, ADR 0034): las marcas del operador, la
/// repetición que prepara el nativo y la que está al aire, con su línea de tiempo.
///
/// Todo va en el reloj del soporte (`MatchTimeSource`), el mismo con el que el nativo sella los
/// instantes del programa: una marca es «ahora» al llegar la orden, y la repetición entra en el
/// instante que fija el nativo al tenerla preparada (`cut`). Alrededor de cada corte va una
/// cortinilla: la de entrada termina antes de que empiece la de vuelta, porque la repetición más
/// corta dura lo que dos cortinillas.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable;
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
import 'package:football_ai_capture/src/graphics/replay_painter.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

int _r(String clave) => OverlaySpec.replay[clave]!;

const String replayWithoutProgram = 'sin programa no hay repetición: el maestro tiene que estar emitiendo';
const String replayBusy = 'ya hay una repetición en marcha: vuelve al directo antes';
const String replayNoneOnAir = 'no hay ninguna repetición al aire';
const String videoBlocksReplay = 'suena un vídeo: páralo antes de repetir';
const String replayBlocksVideo = 'hay una repetición al aire: vuelve al directo antes de pasar un vídeo';

/// Ms desde que el nativo tiene la repetición preparada hasta el corte de entrada: el adelanto
/// y la cortinilla hasta su centro.
int get replayLeadToCutMs => _r('lead_ms') + replayCutMs;

/// Una marca: su número, el instante del soporte y el cronómetro del partido entonces.
@immutable
class ReplayMark {
  const ReplayMark({required this.id, required this.rigMs, required this.clockMs});

  final int id;
  final int rigMs;
  final int clockMs;
}

/// Lo que el maestro le pide al nativo para `replay/play`: `[fromRigMs, toRigMs)`.
typedef ReplayRequest = ({int id, int fromRigMs, int toRigMs});

/// Lo que contesta el nativo: lo que se repite de verdad y el instante en que entra.
typedef ReplayArmed = ({int id, int fromRigMs, int toRigMs, int cutRigMs});

/// Lo que guarda el anillo del programa, en el reloj del soporte.
typedef ReplayBuffer = ({int oldestRigMs, int newestRigMs});

/// La respuesta de `prepareReplay` del nativo. Si dice por qué no, OrderError 409 con ello.
ReplayArmed parseReplayArmed(int id, String json) {
  final Object? j = jsonDecode(json);
  if (j is Map<String, Object?>) {
    final Object? desde = j['from_rig_ms'], hasta = j['to_rig_ms'], corte = j['cut_rig_ms'];
    if (desde is int && hasta is int && corte is int) {
      return (id: id, fromRigMs: desde, toRigMs: hasta, cutRigMs: corte);
    }
    final Object? error = j['error'];
    if (error is String && error.isNotEmpty) {
      throw OrderError(HttpStatus.conflict, error);
    }
  }
  throw OrderError(HttpStatus.conflict, 'el maestro no supo preparar la repetición');
}

/// La respuesta de `replayBuffer` del nativo: null sin programa.
ReplayBuffer? parseReplayBuffer(String json) {
  final Object? j = jsonDecode(json);
  if (j is Map<String, Object?>) {
    final Object? viejo = j['oldest_rig_ms'], nuevo = j['newest_rig_ms'];
    if (viejo is int && nuevo is int) {
      return (oldestRigMs: viejo, newestRigMs: nuevo);
    }
  }
  return null;
}

/// La repetición al aire: lo que se repite y cuándo entra y vuelve el directo.
class ReplayOnAir {
  ReplayOnAir({
    required this.id,
    required this.mark,
    required this.seconds,
    required this.fromRigMs,
    required this.toRigMs,
    required this.cutInMs,
    required this.cutOutMs,
  });

  final int id;

  /// La marca que se repite, o null si fue «lo último».
  final int? mark;
  final int seconds;
  final int fromRigMs;
  final int toRigMs;

  /// El instante del programa en que entra la repetición: el corte de la primera cortinilla.
  final int cutInMs;

  /// El instante en que vuelve el directo: el corte de la segunda. Lo adelanta `replay/stop`.
  int cutOutMs;

  /// Cuando empieza la cortinilla de entrada.
  int get startMs => cutInMs - replayCutMs;

  /// Cuando empieza la de vuelta.
  int get returnMs => cutOutMs - replayCutMs;

  /// Cuando acaba la de vuelta: entonces ya no queda nada de la repetición.
  int get endMs => returnMs + replayTransitionMs;

  /// `in` mientras entra la cortinilla, `replay` mientras se ve la repetición y `out` mientras
  /// vuelve el directo.
  String phaseAt(int now) => now < cutInMs ? 'in' : (now < cutOutMs ? 'replay' : 'out');

  Map<String, Object?> toJson(int now) => <String, Object?>{
    'id': id,
    'mark': mark,
    'seconds': seconds,
    'phase': phaseAt(now),
    'remaining_ms': max(0, cutOutMs - now),
  };
}

class ReplayDesk {
  ReplayDesk(this._time);

  final MatchTimeSource _time;
  List<ReplayMark> _marks = const <ReplayMark>[];
  int _markIds = 0;
  int _replayIds = 0;

  /// La que se prepara en el nativo, con lo que pidió el mando.
  ({int id, int? mark, int seconds})? _preparing;
  ReplayOnAir? _onAir;
  ReplayBuffer? _buffer;

  /// Las marcas, de la más nueva a la más vieja.
  List<ReplayMark> get marks => List<ReplayMark>.unmodifiable(_marks);

  /// La repetición al aire, o null: pasada su cortinilla de vuelta ya no lo está.
  ReplayOnAir? get onAir {
    final ReplayOnAir? a = _onAir;
    return a == null || _time.nowMs() >= a.endMs ? null : a;
  }

  /// Hay una preparándose o al aire: no cabe otra, ni un vídeo.
  bool get busy => _preparing != null || onAir != null;

  /// Apunta una marca ahora. La más vieja se olvida pasadas `marks_max`.
  ReplayMark mark(int clockMs) {
    _markIds += 1;
    final ReplayMark m = ReplayMark(id: _markIds, rigMs: _time.nowMs(), clockMs: clockMs);
    _marks = <ReplayMark>[m, ..._marks.take(_r('marks_max') - 1)];
    return m;
  }

  /// Lo que dice el nativo del anillo. Devuelve si cambió de tener programa a no tenerlo, o al
  /// revés: lo demás no sube `rev`, que se pregunta cada segundo.
  bool setBuffer(ReplayBuffer? buffer) {
    final bool antes = _buffer != null;
    _buffer = buffer;
    return antes != (buffer != null);
  }

  /// `replay/play`, con `mark` (el número de una marca, o null para «lo último») y `seconds`
  /// (de 3 a 30): comprueba la orden y aparta su número. Lanza OrderError sin tocar nada.
  ReplayRequest request(Map<String, Object?> body, {required bool videoPlaying}) {
    if (busy) {
      throw OrderError(HttpStatus.conflict, replayBusy);
    }
    if (videoPlaying) {
      throw OrderError(HttpStatus.conflict, videoBlocksReplay);
    }
    final Object? segundos = body.containsKey('seconds') ? body['seconds'] : _r('default_s');
    if (segundos is! int || segundos < _r('min_s') || segundos > _r('max_s')) {
      throw OrderError(HttpStatus.badRequest, 'seconds tiene que ser un entero entre ${_r('min_s')} y ${_r('max_s')}');
    }
    final Object? numero = body['mark'];
    if (numero != null && numero is! int) {
      throw OrderError(HttpStatus.badRequest, 'mark tiene que ser el número de una marca, o null');
    }
    ReplayMark? marca;
    if (numero is int) {
      marca = _marks.where((ReplayMark m) => m.id == numero).firstOrNull;
      if (marca == null) {
        throw OrderError(HttpStatus.notFound, 'no hay ninguna marca $numero');
      }
    }
    if (_buffer == null) {
      throw OrderError(HttpStatus.conflict, replayWithoutProgram);
    }
    final int hasta = marca?.rigMs ?? _time.nowMs();
    _replayIds += 1;
    _preparing = (id: _replayIds, mark: marca?.id, seconds: segundos);
    return (id: _replayIds, fromRigMs: hasta - segundos * Duration.millisecondsPerSecond, toRigMs: hasta);
  }

  /// El nativo la preparó: sale con la cortinilla.
  void armed(ReplayArmed a) {
    final ({int id, int? mark, int seconds})? p = _preparing;
    if (p == null || p.id != a.id) {
      return;
    }
    _preparing = null;
    _onAir = ReplayOnAir(
      id: a.id,
      mark: p.mark,
      seconds: p.seconds,
      fromRigMs: a.fromRigMs,
      toRigMs: a.toRigMs,
      cutInMs: a.cutRigMs,
      cutOutMs: a.cutRigMs + (a.toRigMs - a.fromRigMs),
    );
  }

  /// El nativo no la preparó: no sale.
  void failed(int id) {
    if (_preparing?.id == id) {
      _preparing = null;
    }
  }

  /// `replay/stop`: el directo vuelve en cuanto pueda pasar la cortinilla, pero la repetición
  /// dura al menos lo que dos cortinillas. Devuelve el instante del programa en que vuelve.
  ({int id, int cutRigMs}) stop() {
    final ReplayOnAir? a = onAir;
    if (a == null) {
      throw OrderError(HttpStatus.conflict, replayNoneOnAir);
    }
    final int pedido = _time.nowMs() + replayLeadToCutMs;
    a.cutOutMs = min(a.cutOutMs, max(pedido, a.cutInMs + replayTransitionMs));
    return (id: a.id, cutRigMs: a.cutOutMs);
  }

  /// Lo que cambia solo con el tiempo: suelta la repetición acabada y olvida las marcas que ya
  /// no caben en el anillo.
  void tick() {
    final int ahora = _time.nowMs();
    final ReplayOnAir? a = _onAir;
    if (a != null && ahora >= a.endMs) {
      _onAir = null;
    }
    final int limite = ahora - _r('ring_s') * Duration.millisecondsPerSecond;
    if (_marks.any((ReplayMark m) => m.rigMs < limite)) {
      _marks = <ReplayMark>[for (final ReplayMark m in _marks) if (m.rigMs >= limite) m];
    }
  }

  /// Lo que [MatchEngine.tick] compara para saber si subir `rev`.
  Object timedState(int now) => (onAir?.id, onAir?.phaseAt(now), _marks.length);

  /// Lo que va ahora en la capa de la repetición, o null si nada.
  ReplayGraphic? graphic({int? iconRev}) {
    final ReplayOnAir? a = onAir;
    if (a == null) {
      return null;
    }
    final int ahora = _time.nowMs();
    final Stinger? entrada = stingerAt(ahora - a.startMs);
    final Stinger? vuelta = stingerAt(ahora - a.returnMs);
    final ReplayGraphic g = ReplayGraphic(
      stinger: vuelta ?? entrada,
      title: vuelta == null && entrada != null,
      bug: ahora >= a.cutInMs && ahora < a.cutOutMs,
      iconRev: iconRev,
    );
    return g.isEmpty ? null : g;
  }

  /// Si la cortinilla se mueve ahora: entonces el gráfico se pinta a `anim_fps`.
  bool get moving {
    final ReplayOnAir? a = onAir;
    if (a == null) {
      return false;
    }
    final int ahora = _time.nowMs();
    return stingerMoving(ahora - a.startMs) || stingerMoving(ahora - a.returnMs);
  }

  /// `replay` del estado: las marcas, hasta dónde llega la memoria y la repetición al aire.
  Map<String, Object?> toJson() {
    final int ahora = _time.nowMs();
    final ReplayBuffer? b = _buffer;
    return <String, Object?>{
      'marks': <Map<String, Object?>>[
        for (final ReplayMark m in _marks)
          <String, Object?>{'id': m.id, 'age_ms': max(0, ahora - m.rigMs), 'clock_ms': m.clockMs},
      ],
      'buffer_ms': b == null ? 0 : max(0, ahora - b.oldestRigMs),
      'on_air': onAir?.toJson(ahora),
    };
  }
}
