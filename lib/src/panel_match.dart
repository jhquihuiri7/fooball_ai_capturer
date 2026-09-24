/// El partido tal y como lo cuenta el panel: el `MatchStateDTO` del ADR 0017 del repo
/// football-ai (`PanelState.match_json` en `tools/live_panel.py`).
///
/// Es lo que la pestaña Partido enseña cuando el móvil hace de mando: lo aplicado por el
/// panel, no lo que el móvil pidió. Se lee entero o no se lee: un campo que falta o no es
/// de su tipo es un panel de otra versión, y pintar la mitad de un marcador sería peor que
/// decir que no se entiende.
library;

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';

/// Un equipo, como lo ve el panel.
class PanelTeam {
  const PanelTeam({
    required this.name,
    required this.goals,
    required this.formation,
    required this.players,
  });

  final String name;
  final int goals;

  /// La formación de la alineación guardada en el panel; `null` si no tiene.
  final String? formation;

  /// Jugadores de la alineación guardada, suplentes incluidos. Cero sin alineación.
  final int players;

  static PanelTeam _fromJson(Object? raw, String key) {
    final Map<String, Object?> json = _map(raw, key);
    return PanelTeam(
      name: _string(json, 'name', key),
      goals: _int(json, 'goals', key),
      formation: _optionalString(json, 'formation', key),
      players: _int(json, 'players', key),
    );
  }
}

class PanelMatch {
  const PanelMatch({
    required this.matchId,
    required this.boot,
    required this.rev,
    required this.home,
    required this.away,
    required this.clockMs,
    required this.clockRunning,
    required this.clockRestored,
    required this.lineupOnAir,
    required this.streaming,
    required this.canStream,
    required this.formations,
    required this.saveError,
    required this.scopes,
  });

  final String matchId;

  /// Identificador del proceso del panel: cambia en cada arranque.
  final String boot;

  /// Sube con cada cambio. Con [boot], es el `since` de la espera larga.
  final int rev;

  final PanelTeam home;
  final PanelTeam away;

  /// El cronómetro al contestar, en ms. Entre dos respuestas lo hace avanzar la pantalla.
  final int clockMs;
  final bool clockRunning;

  /// Volvió parado de un reinicio del panel y nadie lo ha tocado: hay que revisarlo.
  final bool clockRestored;

  /// Qué alineación está al aire, si alguna.
  final MatchTeam? lineupOnAir;

  final bool streaming;

  /// Si el panel tiene destinos a los que emitir.
  final bool canStream;

  /// Las formaciones que ofrece el panel, en su orden.
  final List<String> formations;

  /// Por qué el panel ha dejado de guardar el partido, si ha dejado.
  final String? saveError;

  /// Lo que puede este mando: `match` siempre, `stream` si su QR lo concedía.
  final Set<String> scopes;

  /// Lo que se manda como `?since=` para esperar el siguiente cambio.
  String get since => '$boot:$rev';

  /// Si este mando puede emitir y parar la emisión.
  bool get mayStream => scopes.contains(panelScopeStream);

  PanelTeam team(MatchTeam side) => side == MatchTeam.home ? home : away;

  /// Lanza [FormatException] con el campo que no vale.
  factory PanelMatch.fromJson(Object? raw) {
    final Map<String, Object?> json = _map(raw, 'partido');
    final String? onAir = _optionalString(json, 'lineup_on_air', 'partido');
    return PanelMatch(
      matchId: _string(json, 'match_id', 'partido'),
      boot: _string(json, 'boot', 'partido'),
      rev: _int(json, 'rev', 'partido'),
      home: PanelTeam._fromJson(json['home'], 'home'),
      away: PanelTeam._fromJson(json['away'], 'away'),
      clockMs: _int(json, 'clock_ms', 'partido'),
      clockRunning: _bool(json, 'clock_running', 'partido'),
      clockRestored: _bool(json, 'clock_restored', 'partido'),
      lineupOnAir: onAir == null ? null : _side(onAir),
      streaming: _bool(json, 'streaming', 'partido'),
      canStream: _bool(json, 'can_stream', 'partido'),
      formations: _strings(json, 'formations'),
      saveError: _optionalString(json, 'save_error', 'partido'),
      scopes: _strings(json, 'scopes').toSet(),
    );
  }
}

Map<String, Object?> _map(Object? raw, String what) {
  if (raw is! Map<String, Object?>) {
    throw FormatException('$what: se esperaba un objeto');
  }
  return raw;
}

String _string(Map<String, Object?> json, String key, String what) {
  final Object? value = json[key];
  if (value is! String) {
    throw FormatException('$what.$key: se esperaba un texto');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key, String what) {
  final Object? value = json[key];
  if (value != null && value is! String) {
    throw FormatException('$what.$key: se esperaba un texto o nada');
  }
  return value as String?;
}

int _int(Map<String, Object?> json, String key, String what) {
  final Object? value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('$what.$key: se esperaba un entero no negativo');
  }
  return value;
}

bool _bool(Map<String, Object?> json, String key, String what) {
  final Object? value = json[key];
  if (value is! bool) {
    throw FormatException('$what.$key: se esperaba true o false');
  }
  return value;
}

List<String> _strings(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! List || value.any((Object? v) => v is! String)) {
    throw FormatException('partido.$key: se esperaba una lista de textos');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

MatchTeam _side(String value) {
  for (final MatchTeam side in MatchTeam.values) {
    if (side.name == value) {
      return side;
    }
  }
  throw FormatException('partido.lineup_on_air: equipo desconocido «$value»');
}
