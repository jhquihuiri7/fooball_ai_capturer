/// Lo que la pestaña Partido necesita de un partido, lo lleve quien lo lleve (ADR 0017 del
/// repo football-ai).
///
/// Dos implementaciones. [MatchState] es el marcador que vive en este móvil, como hasta
/// ahora. `PanelBoard` es el del panel, cuando el móvil hace de mando: lo que enseña es lo
/// que contestó el panel y cada botón es una orden. La pantalla es la misma a propósito:
/// los mismos botones en el mismo sitio, lleve quien lleve el marcador.
library;

import 'package:flutter/foundation.dart';

import 'package:football_ai_capture/src/match_state.dart';

abstract interface class MatchBoard implements Listenable {
  String get homeName;
  String get awayName;
  int get homeGoals;
  int get awayGoals;

  /// El cronómetro, ya resuelto para pintarlo ahora.
  Duration get elapsed;
  bool get running;
  bool get streaming;

  /// Qué equipo se está mirando en Posiciones. No cambia lo que sale al aire.
  MatchTeam get lineupTeam;
  String get visibleTeamName;
  String get visibleFormation;

  /// Los once del equipo que se mira. Vacía si la lista no está en este móvil.
  List<PlayerSlot> get visibleLineup;

  /// Las formaciones que se pueden elegir, en su orden.
  List<String> get formationNames;

  /// Si la alineación que se mira está al aire; `null` si este marcador no la saca al
  /// aire (el local no puede: no tiene camino hasta la emisión).
  bool? get visibleLineupOnAir;

  /// Lo que se dice en lugar de la lista cuando la lista no está aquí.
  String? get lineupNote;

  /// Si se puede pulsar Emitir.
  bool get canStream;

  /// Lo que dice la tarjeta Salida al aire; `null` para el texto de siempre.
  String? get onAirNote;

  /// Hay una orden en camino: hasta que el panel conteste, los botones esperan. Un
  /// segundo toque con la primera sin respuesta es el gol doble que se quiere evitar.
  bool get busy;

  /// Reiniciar el reloj, reiniciar el marcador y parar la emisión piden confirmación.
  bool get confirmsDestructive;

  void startClock();
  void stopClock();
  void resetClock();
  void nudgeClock(int minutes);
  void addGoal(MatchTeam team, int delta);
  void resetScore();
  void toggleStreaming();
  void showLineup(MatchTeam team);
  void setFormation(String name);
  void toggleLineupOnAir();
}
