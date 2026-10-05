/// La pestaña Partido en el móvil que dirige el soporte (IOS-87, ADR 0017 enmienda).
///
/// El partido con autoridad vive en este mismo proceso ([MatchEngine], el que sirve la
/// API del mando): cada botón es la misma orden que mandaría un mando por la LAN, con su
/// `expect`, pero sin red ni token. Así la pantalla del maestro, el panel local y los
/// mandos nunca enseñan dos partidos distintos. Lo que el motor rechaza queda en
/// [message], con sus palabras.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_board.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

class MasterBoard extends ChangeNotifier implements MatchBoard {
  MasterBoard(this.engine) {
    _sub = engine.changes.listen((_) => _changed());
    _changed();
  }

  final MatchEngine engine;
  late final StreamSubscription<void> _sub;
  MatchTeam _lineupTeam = MatchTeam.home;
  String? _message;
  Timer? _ticker;

  /// Lo que el motor contestó a la última orden si no la aceptó; `null` si fue bien.
  String? get message => _message;

  Team? get _visibleTeam => engine.lineups.teams[_lineupTeam];

  @override
  String get homeName => engine.home;

  @override
  String get awayName => engine.away;

  @override
  int get homeGoals => engine.homeGoals;

  @override
  int get awayGoals => engine.awayGoals;

  @override
  Duration get elapsed => Duration(milliseconds: engine.clock.elapsedMs);

  @override
  bool get running => engine.clock.running;

  @override
  bool get streaming => engine.streaming;

  @override
  MatchTeam get lineupTeam => _lineupTeam;

  @override
  String get visibleTeamName => _visibleTeam?.name ?? (_lineupTeam == MatchTeam.home ? homeName : awayName);

  @override
  String get visibleFormation => _visibleTeam?.formation ?? 'sin alineación';

  @override
  List<PlayerSlot> get visibleLineup {
    final Team? t = _visibleTeam;
    return t == null ? const <PlayerSlot>[] : lineupSlots(t);
  }

  @override
  List<String> get formationNames => matchFormations;

  @override
  bool? get visibleLineupOnAir => _visibleTeam == null ? null : engine.lineups.onAirSide == _lineupTeam;

  @override
  String? get lineupNote =>
      _visibleTeam == null ? 'sin alineación: se carga en el panel local (QR «Soporte»)' : null;

  @override
  bool get canStream => engine.canStream;

  @override
  String get onAirNote {
    if (!engine.canStream) {
      return 'sin túnel al relé: no se puede emitir';
    }
    return engine.streaming ? 'emitiendo desde este móvil' : 'preparado en este móvil';
  }

  /// Las órdenes se aplican en el acto: nunca hay una en camino.
  @override
  bool get busy => false;

  @override
  bool get confirmsDestructive => true;

  // ------------------------------------------------------------------------- //
  // Órdenes: las mismas que la API del mando, con su expect
  // ------------------------------------------------------------------------- //

  @override
  void startClock() => _order('match/clock', <String, Object?>{'action': 'start'});

  @override
  void stopClock() => _order('match/clock', <String, Object?>{'action': 'pause'});

  @override
  void resetClock() => _order('match/clock', <String, Object?>{'action': 'reset'});

  @override
  void nudgeClock(int minutes) => _order(
    'match/clock',
    <String, Object?>{'action': 'nudge', 'seconds': minutes * Duration.secondsPerMinute},
  );

  @override
  void addGoal(MatchTeam team, int delta) => _order('match/goal', <String, Object?>{
    'team': team.name,
    'delta': delta,
    'expect': team == MatchTeam.home ? homeGoals : awayGoals,
  });

  @override
  void resetScore() => _order('match/score', <String, Object?>{
    'home': 0,
    'away': 0,
    'expect': <String, Object?>{'home': homeGoals, 'away': awayGoals},
  });

  @override
  void toggleStreaming() => _order(engine.streaming ? 'stream/stop' : 'stream/start', const <String, Object?>{});

  /// Qué alineación se mira: es de esta pantalla, no del partido.
  @override
  void showLineup(MatchTeam team) {
    _lineupTeam = team;
    notifyListeners();
  }

  @override
  void setFormation(String name) =>
      _order('match/lineup', <String, Object?>{'team': _lineupTeam.name, 'formation': name});

  @override
  void toggleLineupOnAir() => _order('match/lineup', <String, Object?>{
    'team': _lineupTeam.name,
    'on_air': engine.lineups.onAirSide != _lineupTeam,
  });

  void _order(String name, Map<String, Object?> body) {
    try {
      engine.apply(name, body);
      _message = null;
    } on OrderError catch (error) {
      _message = error.message;
    }
    notifyListeners();
  }

  void _changed() {
    // El cronómetro se repinta cada segundo solo mientras corre (como el PanelBoard).
    if (engine.clock.running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    } else if (!engine.clock.running) {
      _ticker?.cancel();
      _ticker = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// El once de un equipo, en el orden de la lista (portero y líneas de atrás adelante),
/// con el puesto por línea: el maestro guarda números y nombres, no puestos finos.
List<PlayerSlot> lineupSlots(Team t) {
  final List<int> lineas = t.lines;
  final List<PlayerSlot> once = <PlayerSlot>[
    PlayerSlot(player: Player(number: t.starters.first.number, name: t.starters.first.name, role: PlayerRole.gk),
        position: 'POR'),
  ];
  int i = 1;
  for (int l = 0; l < lineas.length; l++) {
    final (String puesto, PlayerRole rol) = l == 0
        ? ('DEF', PlayerRole.cb)
        : l == lineas.length - 1
            ? ('DEL', PlayerRole.st)
            : ('MED', PlayerRole.cm);
    for (int k = 0; k < lineas[l] && i < t.starters.length; k++, i++) {
      final RosterPlayer p = t.starters[i];
      once.add(PlayerSlot(player: Player(number: p.number, name: p.name, role: rol), position: puesto));
    }
  }
  return once;
}
