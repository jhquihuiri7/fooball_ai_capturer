/// La pestaña Partido cuando el móvil hace de mando del panel (ADR 0017 del repo
/// football-ai).
///
/// Lo que se enseña es lo que contestó el panel ([PanelControl.match]); cada botón es una
/// orden. Mientras una orden está en camino, [busy] deja la pantalla quieta: un segundo
/// toque antes de la respuesta es justo el gol doble que el ADR quiere evitar. Lo que salió
/// mal con la última orden queda en [message], para que la pantalla lo diga con palabras.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:football_ai_capture/src/match_board.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_match.dart';

class PanelBoard extends ChangeNotifier implements MatchBoard {
  /// Solo tiene sentido con el partido ya visto: `MandoPage` no lo crea antes.
  PanelBoard(this.control) {
    control.addListener(_changed);
    _changed();
  }

  final PanelControl control;

  MatchTeam _lineupTeam = MatchTeam.home;
  bool _busy = false;
  String? _message;
  Timer? _ticker;
  bool _disposed = false;

  PanelMatch get _match => control.match!;

  PanelTeam get _visibleTeam => _match.team(_lineupTeam);

  /// Lo que salió mal con la última orden, en palabras; `null` si fue bien.
  String? get message => _message;

  @override
  String get homeName => _match.home.name;

  @override
  String get awayName => _match.away.name;

  @override
  int get homeGoals => _match.home.goals;

  @override
  int get awayGoals => _match.away.goals;

  @override
  Duration get elapsed =>
      Duration(milliseconds: control.clockMsNow ?? _match.clockMs);

  @override
  bool get running => _match.clockRunning;

  @override
  bool get streaming => _match.streaming;

  @override
  MatchTeam get lineupTeam => _lineupTeam;

  @override
  String get visibleTeamName => _visibleTeam.name;

  /// Sin alineación guardada en el panel no hay formación que marcar.
  @override
  String get visibleFormation => _visibleTeam.formation ?? 'sin alineación';

  /// La lista vive en el panel, que es donde se escribe: aquí solo llega cuántos son.
  @override
  List<PlayerSlot> get visibleLineup => const <PlayerSlot>[];

  @override
  List<String> get formationNames => _match.formations;

  @override
  bool? get visibleLineupOnAir =>
      _visibleTeam.formation == null ? null : _match.lineupOnAir == _lineupTeam;

  @override
  String get lineupNote {
    final int players = _visibleTeam.players;
    return players == 0
        ? 'sin alineación en el panel: se carga desde su página'
        : '$players jugadores · la lista se edita en el panel';
  }

  @override
  bool get canStream => _match.mayStream && _match.canStream;

  @override
  String get onAirNote {
    if (!_match.mayStream) {
      return 'este mando no emite: para eso, escanea el QR «marcador y emisión»';
    }
    if (!_match.canStream) {
      return 'el panel no tiene a dónde emitir';
    }
    return _match.streaming
        ? 'emitiendo desde el panel'
        : 'preparado en el panel';
  }

  @override
  bool get busy => _busy;

  @override
  bool get confirmsDestructive => true;

  // ------------------------------------------------------------------------- //
  // Órdenes
  // ------------------------------------------------------------------------- //

  @override
  void startClock() => _order(control.startClock);

  @override
  void stopClock() => _order(control.pauseClock);

  @override
  void resetClock() => _order(control.resetClock);

  @override
  void nudgeClock(int minutes) =>
      _order(() => control.nudgeClock(Duration(minutes: minutes)));

  @override
  void addGoal(MatchTeam team, int delta) =>
      _order(() => control.goal(team, delta));

  @override
  void resetScore() => _order(() => control.setScore(0, 0));

  @override
  void toggleStreaming() =>
      _order(() => control.setStreaming(on: !_match.streaming));

  /// Qué alineación se mira: es de esta pantalla, no del panel.
  @override
  void showLineup(MatchTeam team) {
    _lineupTeam = team;
    notifyListeners();
  }

  @override
  void setFormation(String name) =>
      _order(() => control.setFormation(_lineupTeam, name));

  @override
  void toggleLineupOnAir() => _order(
    () => control.showLineup(
      _lineupTeam,
      onAir: _match.lineupOnAir != _lineupTeam,
    ),
  );

  void _order(Future<CommandResult> Function() send) {
    if (_busy) {
      return;
    }
    _busy = true;
    notifyListeners();
    unawaited(
      send().then((CommandResult result) {
        _busy = false;
        _message = describe(result);
        if (!_disposed) {
          notifyListeners();
        }
      }),
    );
  }

  /// Lo que se le dice a quien pulsó. Nada si salió bien: el marcador ya lo dice.
  @visibleForTesting
  static String? describe(CommandResult result) => switch (result.outcome) {
    CommandOutcome.applied => null,
    CommandOutcome.conflict =>
      'otro mando se adelantó: esto es lo que hay en el panel',
    CommandOutcome.forbidden => 'este mando no tiene permiso para eso',
    CommandOutcome.rejected => result.detail ?? 'el panel no lo aceptó',
    CommandOutcome.unpaired =>
      result.detail ?? 'el panel ya no acepta este mando',
    CommandOutcome.unreachable =>
      'no llegó al panel: mira el marcador antes de repetir',
  };

  void _changed() {
    // El cronómetro se pinta cada segundo solo mientras corre: parado, no hay nada que
    // mover y el temporizador gastaría batería para nada.
    final bool corre = control.match?.clockRunning ?? false;
    if (corre && _ticker == null) {
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => notifyListeners(),
      );
    } else if (!corre) {
      _ticker?.cancel();
      _ticker = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    control.removeListener(_changed);
    super.dispose();
  }
}
