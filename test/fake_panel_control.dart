/// Un mando del panel de mentira, para las pantallas: sin red, con el partido que se le
/// dé y apuntando qué órdenes se pulsaron.
library;

import 'dart:async';

import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';

/// Un partido como los que manda el panel, con lo que se quiera cambiar.
PanelMatch panelMatch({
  int rev = 1,
  int home = 1,
  int away = 0,
  int clockMs = 2700000,
  bool clockRunning = false,
  String? homeFormation = '4-3-3',
  int homePlayers = 14,
  String? lineupOnAir,
  bool streaming = false,
  bool canStream = true,
  List<String> scopes = const <String>['match'],
}) {
  return PanelMatch.fromJson(<String, Object?>{
    'match_id': 'm_prueba',
    'boot': 'b1',
    'rev': rev,
    'home': <String, Object?>{
      'name': 'BELLAVISTA',
      'goals': home,
      'formation': homeFormation,
      'players': homePlayers,
    },
    'away': <String, Object?>{
      'name': 'PROGRESO',
      'goals': away,
      'formation': null,
      'players': 0,
    },
    'clock_ms': clockMs,
    'clock_running': clockRunning,
    'clock_restored': false,
    'lineup_on_air': lineupOnAir,
    'streaming': streaming,
    'can_stream': canStream,
    'formations': <String>['4-4-2', '4-3-3', '3-5-2'],
    'save_error': null,
    'scopes': scopes,
  });
}

class FakePanelControl extends PanelControl {
  FakePanelControl([PanelMatch? match])
    : _shown = match,
      super(
        pairing: PanelPairing.parse('http://panel.test/#mando=a.b')!,
        deviceName: 'prueba',
      );

  PanelMatch? _shown;
  PanelLink _shownLink = PanelLink.online;

  /// Las órdenes pulsadas, en texto: `goal home 1`, `score 0 0`…
  final List<String> calls = <String>[];

  /// Si está puesta, las órdenes esperan a que se complete: una orden en camino.
  Completer<CommandResult>? hold;

  /// Lo que contestan las órdenes que no esperan.
  CommandResult answer = const CommandResult(CommandOutcome.applied);

  bool started = false;

  @override
  PanelMatch? get match => _shown;

  @override
  PanelLink get link => _shownLink;

  @override
  int? get clockMsNow => _shown?.clockMs;

  @override
  void start() => started = true;

  /// El panel contesta con este partido.
  void publish(PanelMatch match) {
    _shown = match;
    notifyListeners();
  }

  void cut(PanelLink link) {
    _shownLink = link;
    notifyListeners();
  }

  Future<CommandResult> _record(String call) {
    calls.add(call);
    return hold?.future ?? Future<CommandResult>.value(answer);
  }

  @override
  Future<CommandResult> goal(MatchTeam team, int delta) =>
      _record('goal ${team.name} $delta');

  @override
  Future<CommandResult> setScore(int home, int away) =>
      _record('score $home $away');

  @override
  Future<CommandResult> startClock() => _record('clock start');

  @override
  Future<CommandResult> pauseClock() => _record('clock pause');

  @override
  Future<CommandResult> resetClock() => _record('clock reset');

  @override
  Future<CommandResult> nudgeClock(Duration by) =>
      _record('clock nudge ${by.inSeconds}');

  @override
  Future<CommandResult> setFormation(MatchTeam team, String formation) =>
      _record('formation ${team.name} $formation');

  @override
  Future<CommandResult> showLineup(MatchTeam team, {required bool onAir}) =>
      _record('lineup ${team.name} $onAir');

  @override
  Future<CommandResult> markClip() => _record('clip');

  @override
  Future<CommandResult> setStreaming({required bool on}) =>
      _record('stream $on');
}
