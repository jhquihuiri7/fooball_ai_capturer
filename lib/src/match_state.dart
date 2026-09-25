/// El partido: marcador, cronómetro y alineaciones.
///
/// Vive aparte de `CaptureSession` y no se mezcla con ella. Son dos trabajos distintos
/// hechos por dos personas distintas: el móvil del soporte no toca el marcador, y quien
/// lleva el marcador no toca la cámara. Compartir un `ChangeNotifier` entre los dos
/// acabaría con un `notifyListeners` del marcador repintando la vista previa a 60 Hz.
///
/// Se persiste entero en `shared_preferences` porque cerrar la app en el descanso —o
/// que iOS la mate por memoria mientras alguien contesta una llamada— no puede borrar
/// un 2-1 del minuto 44.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:football_ai_capture/src/match_board.dart';

/// Clave única: el estado del partido se guarda como un solo JSON y no campo a campo.
/// Guardar campo a campo deja estados a medias cuando la app muere entre dos escrituras.
const String matchStateKey = 'zero.match';

/// Los dos equipos.
enum MatchTeam { home, away }

/// El puesto que ocupa un jugador en el campo, con independencia de la formación.
///
/// Es lo que hace que cambiar de formación **reordene de verdad** la plantilla: un
/// lateral derecho es lateral en un 4-3-3 y carrilero en un 3-5-2, y quien ocupa la
/// banda es el mismo jugador. Sin este dato, cambiar de formación solo cambiaría una
/// etiqueta y la lista seguiría en el mismo orden, que es justo lo que no sirve.
enum PlayerRole { gk, rb, cb, lb, dm, cm, am, rw, st, lw }

/// Un jugador de la plantilla.
class Player {
  const Player({required this.number, required this.name, required this.role});

  final int number;
  final String name;
  final PlayerRole role;

  Map<String, Object?> toJson() => <String, Object?>{
    'number': number,
    'name': name,
    'role': role.name,
  };

  static Player fromJson(Map<String, Object?> json) {
    return Player(
      number: json['number']! as int,
      name: json['name']! as String,
      role: PlayerRole.values.byName(json['role']! as String),
    );
  }
}

/// Un hueco de una formación: cómo se llama el puesto y qué jugador lo ocupa mejor.
class _Slot {
  const _Slot(this.position, this.wants);

  /// La abreviatura que se enseña: POR, LTD, DFC, MCD, MCO, ED, DC…
  final String position;

  /// El puesto natural del jugador que va aquí.
  final PlayerRole wants;
}

/// Una forma de repartir once jugadores por el campo.
class Formation {
  const Formation(this.name, this._slots);

  final String name;
  final List<_Slot> _slots;

  /// Coloca la plantilla en esta formación.
  ///
  /// Cada hueco se lleva al primer jugador libre de su puesto natural; si no queda
  /// ninguno —porque la plantilla venga de fuera y no encaje— se lleva al siguiente
  /// libre, para que la lista siempre tenga once y nunca reviente en la banda.
  List<PlayerSlot> lineUp(List<Player> squad) {
    final List<Player> free = List<Player>.of(squad);
    final List<PlayerSlot> lineup = <PlayerSlot>[];
    for (final _Slot slot in _slots) {
      if (free.isEmpty) {
        break;
      }
      int index = free.indexWhere((Player p) => p.role == slot.wants);
      if (index < 0) {
        index = 0;
      }
      lineup.add(PlayerSlot(player: free.removeAt(index), position: slot.position));
    }
    return lineup;
  }
}

/// Un jugador ya colocado: quién es y qué puesto ocupa en esta formación.
class PlayerSlot {
  const PlayerSlot({required this.player, required this.position});

  final Player player;
  final String position;
}

/// Las tres formaciones del panel de emisión.
const List<Formation> formations = <Formation>[
  Formation('4-3-3', <_Slot>[
    _Slot('POR', PlayerRole.gk),
    _Slot('LTD', PlayerRole.rb),
    _Slot('DFC', PlayerRole.cb),
    _Slot('DFC', PlayerRole.cb),
    _Slot('LTI', PlayerRole.lb),
    // De atrás adelante, como en las otras dos formaciones: el pivote antes que el
    // interior. El diseño de referencia pone el 4-3-3 local al revés y el visitante
    // así; una sola regla no puede reproducir las dos, y esta es la que siguen las
    // otras cinco tablas.
    _Slot('MCD', PlayerRole.dm),
    _Slot('MC', PlayerRole.cm),
    _Slot('MCO', PlayerRole.am),
    _Slot('ED', PlayerRole.rw),
    _Slot('DC', PlayerRole.st),
    _Slot('EI', PlayerRole.lw),
  ]),
  Formation('4-4-2', <_Slot>[
    _Slot('POR', PlayerRole.gk),
    _Slot('LTD', PlayerRole.rb),
    _Slot('DFC', PlayerRole.cb),
    _Slot('DFC', PlayerRole.cb),
    _Slot('LTI', PlayerRole.lb),
    // El extremo derecho baja a la banda: en un 4-4-2 no hay tres arriba.
    _Slot('MD', PlayerRole.rw),
    _Slot('MC', PlayerRole.dm),
    _Slot('MC', PlayerRole.cm),
    _Slot('MI', PlayerRole.lw),
    _Slot('DC', PlayerRole.st),
    // Y el mediapunta sube a acompañar al delantero.
    _Slot('DC', PlayerRole.am),
  ]),
  Formation('3-5-2', <_Slot>[
    _Slot('POR', PlayerRole.gk),
    _Slot('DFC', PlayerRole.cb),
    _Slot('DFC', PlayerRole.cb),
    // El lateral izquierdo se mete dentro: con tres atrás no hay laterales.
    _Slot('DFC', PlayerRole.lb),
    _Slot('CAD', PlayerRole.rb),
    _Slot('MCD', PlayerRole.dm),
    _Slot('MC', PlayerRole.cm),
    _Slot('MCO', PlayerRole.am),
    _Slot('CAI', PlayerRole.lw),
    _Slot('DC', PlayerRole.st),
    _Slot('DC', PlayerRole.rw),
  ]),
];

Formation formationByName(String name) =>
    formations.firstWhere((Formation f) => f.name == name, orElse: () => formations.first);

/// Plantillas de arranque.
///
/// TODO: las alineaciones reales las manda el servidor junto con el partido. Hasta que
/// exista ese camino, estas once por equipo son lo que se edita en la banda; el resto
/// de la pantalla ya funciona igual con unas y con otras.
const List<Player> _defaultHomeSquad = <Player>[
  Player(number: 1, name: 'J. Mendoza', role: PlayerRole.gk),
  Player(number: 2, name: 'D. Palma', role: PlayerRole.rb),
  Player(number: 4, name: 'A. Loor', role: PlayerRole.cb),
  Player(number: 5, name: 'M. Carrillo', role: PlayerRole.cb),
  Player(number: 3, name: 'R. Bravo', role: PlayerRole.lb),
  Player(number: 6, name: 'E. Salazar', role: PlayerRole.dm),
  Player(number: 8, name: 'K. Zambrano', role: PlayerRole.cm),
  Player(number: 10, name: 'N. Vera', role: PlayerRole.am),
  Player(number: 7, name: 'S. Ortiz', role: PlayerRole.rw),
  Player(number: 9, name: 'L. Mora', role: PlayerRole.st),
  Player(number: 11, name: 'B. Cedeño', role: PlayerRole.lw),
];

const List<Player> _defaultAwaySquad = <Player>[
  Player(number: 1, name: 'F. Arteaga', role: PlayerRole.gk),
  Player(number: 2, name: 'H. Quimí', role: PlayerRole.rb),
  Player(number: 5, name: 'T. Rosado', role: PlayerRole.cb),
  Player(number: 6, name: 'V. Pineda', role: PlayerRole.cb),
  Player(number: 3, name: 'O. Chávez', role: PlayerRole.lb),
  Player(number: 8, name: 'I. Bermeo', role: PlayerRole.dm),
  Player(number: 10, name: 'P. Solórzano', role: PlayerRole.cm),
  Player(number: 7, name: 'G. Tomalá', role: PlayerRole.am),
  Player(number: 11, name: 'C. Ronquillo', role: PlayerRole.rw),
  Player(number: 9, name: 'W. Alvarado', role: PlayerRole.st),
  Player(number: 19, name: 'M. Intriago', role: PlayerRole.lw),
];

/// El estado del partido que se pinta sobre la señal, cuando lo lleva este móvil.
class MatchState extends ChangeNotifier implements MatchBoard {
  MatchState({
    this.homeName = 'BELLAVISTA',
    this.awayName = 'PROGRESO',
    List<Player>? homeSquad,
    List<Player>? awaySquad,
  }) : homeSquad = homeSquad ?? _defaultHomeSquad,
       awaySquad = awaySquad ?? _defaultAwaySquad;

  @override
  String homeName;
  @override
  String awayName;
  List<Player> homeSquad;
  List<Player> awaySquad;

  @override
  int homeGoals = 0;
  @override
  int awayGoals = 0;

  String homeFormation = '4-3-3';
  String awayFormation = '4-3-3';

  /// Qué plantilla se está mirando. No afecta a lo que sale al aire.
  @override
  MatchTeam lineupTeam = MatchTeam.home;

  @override
  bool streaming = false;

  /// Milisegundos ya acumulados por el cronómetro mientras estuvo parado.
  ///
  /// En milisegundos y no en segundos: guardar `elapsed.inSeconds` al parar redondea
  /// hacia abajo, y cada pausa o cada ±1 min con el reloj en marcha se comería hasta un
  /// segundo. Tras varias pausas, el reloj del overlay va por detrás del del árbitro.
  int _baseMs = 0;

  /// Cuándo se puso en marcha, en tiempo de pared. Es lo que permite que cerrar la app
  /// con el cronómetro corriendo y volver dos minutos después no regale dos minutos.
  DateTime? _runningSince;

  Timer? _ticker;
  SharedPreferences? _prefs;

  /// Lo que haya pasado desde que se construyó: si alguien toca el marcador antes de
  /// que termine de cargar lo guardado, gana lo que ha tocado.
  bool _touched = false;

  bool _disposed = false;

  @override
  bool get running => _runningSince != null;

  /// Va con la hora de pared y no con un reloj monótono a propósito: es lo único que
  /// sobrevive a cerrar la app. Si iOS corrige la hora hacia atrás, el tramo en marcha
  /// cuenta cero en vez de restar minutos al partido.
  @override
  Duration get elapsed => Duration(milliseconds: _elapsedMs);

  int get _elapsedMs {
    final DateTime? since = _runningSince;
    final int extra = since == null ? 0 : DateTime.now().difference(since).inMilliseconds;
    return _baseMs + (extra < 0 ? 0 : extra);
  }

  /// La formación de la plantilla que se está mirando.
  @override
  String get visibleFormation => lineupTeam == MatchTeam.home ? homeFormation : awayFormation;

  @override
  String get visibleTeamName => lineupTeam == MatchTeam.home ? homeName : awayName;

  /// Los once ya colocados, en el orden en que se leen.
  @override
  List<PlayerSlot> get visibleLineup {
    final List<Player> squad = lineupTeam == MatchTeam.home ? homeSquad : awaySquad;
    return formationByName(visibleFormation).lineUp(squad);
  }

  // ------------------------------------------------------------------------- //
  // Cronómetro
  // ------------------------------------------------------------------------- //

  @override
  void startClock() {
    if (running) {
      return;
    }
    _runningSince = DateTime.now();
    _startTicker();
    _changed();
  }

  @override
  void stopClock() {
    if (!running) {
      return;
    }
    _baseMs = _elapsedMs;
    _runningSince = null;
    _stopTicker();
    _changed();
  }

  void toggleClock() => running ? stopClock() : startClock();

  @override
  void resetClock() {
    _baseMs = 0;
    _runningSince = null;
    _stopTicker();
    _changed();
  }

  /// Corrige el cronómetro en minutos enteros. Nunca por debajo de cero: un partido en
  /// el minuto −1 no existe y el overlay lo enseñaría igual.
  @override
  void nudgeClock(int minutes) {
    final int next = _elapsedMs + minutes * Duration.millisecondsPerMinute;
    _baseMs = next < 0 ? 0 : next;
    if (running) {
      _runningSince = DateTime.now();
    }
    _changed();
  }

  // ------------------------------------------------------------------------- //
  // Marcador
  // ------------------------------------------------------------------------- //

  @override
  void addGoal(MatchTeam team, int delta) {
    if (team == MatchTeam.home) {
      homeGoals = (homeGoals + delta).clamp(0, 99);
    } else {
      awayGoals = (awayGoals + delta).clamp(0, 99);
    }
    _changed();
  }

  @override
  void resetScore() {
    homeGoals = 0;
    awayGoals = 0;
    _changed();
  }

  // ------------------------------------------------------------------------- //
  // Alineaciones y emisión
  // ------------------------------------------------------------------------- //

  @override
  void showLineup(MatchTeam team) {
    lineupTeam = team;
    _changed();
  }

  @override
  void setFormation(String name) {
    if (lineupTeam == MatchTeam.home) {
      homeFormation = name;
    } else {
      awayFormation = name;
    }
    _changed();
  }

  @override
  void toggleStreaming() {
    streaming = !streaming;
    _changed();
  }

  // Lo que el marcador local no tiene: todo sale del propio móvil, así que no hay
  // orden en camino, ni lista que viva en otro sitio, ni alineación que sacar al aire.

  @override
  List<String> get formationNames => <String>[for (final Formation f in formations) f.name];

  @override
  bool? get visibleLineupOnAir => null;

  @override
  String? get lineupNote => null;

  @override
  bool get canStream => true;

  @override
  String? get onAirNote => null;

  @override
  bool get busy => false;

  @override
  bool get confirmsDestructive => false;

  @override
  void toggleLineupOnAir() {}

  // ------------------------------------------------------------------------- //
  // Lo que sale al aire
  // ------------------------------------------------------------------------- //

  /// El marcador tal y como lo consume el overlay de la emisión.
  ///
  /// TODO: falta el camino por el que se publica. Tiene que ir al mismo servidor que ya
  /// recibe la emisión (el MediaMTX de `serverHost`), por el endpoint que el servidor
  /// exponga para el overlay; hoy no expone ninguno. Inventar aquí una conexión nueva
  /// sería un segundo camino que mantener y desincronizar.
  Map<String, Object?> toOverlayJson() => <String, Object?>{
    'home': _teamJson(homeName, homeGoals, homeFormation, homeSquad),
    'away': _teamJson(awayName, awayGoals, awayFormation, awaySquad),
    'clockSeconds': elapsed.inSeconds,
    'clockRunning': running,
    'onAir': streaming,
  };

  Map<String, Object?> _teamJson(String name, int goals, String formation, List<Player> squad) {
    return <String, Object?>{
      'name': name,
      'goals': goals,
      'formation': formation,
      'lineup': formationByName(formation)
          .lineUp(squad)
          .map(
            (PlayerSlot s) => <String, Object?>{
              'number': s.player.number,
              'name': s.player.name,
              'position': s.position,
            },
          )
          .toList(),
    };
  }

  // ------------------------------------------------------------------------- //
  // Persistencia
  // ------------------------------------------------------------------------- //

  /// Carga lo guardado. Si no hay nada o está roto, se queda con los valores de
  /// arranque: un marcador que no carga no puede impedir que empiece el partido.
  ///
  /// Se lee todo a variables locales y solo se aplica si todo se pudo leer. Aplicar
  /// campo a campo y fallar a mitad —un puesto que ya no existe en una plantilla
  /// guardada— dejaría, por ejemplo, el reloj marcado «en marcha» sin nada que lo haga
  /// avanzar.
  Future<void> load({SharedPreferences? prefs}) async {
    final SharedPreferences store = prefs ?? await SharedPreferences.getInstance();
    // `ZeroShell` no espera a esta carga: si la pantalla ya se cerró, no se arranca
    // ningún temporizador sobre un objeto liberado.
    if (_disposed) {
      return;
    }
    _prefs = store;
    if (_touched) {
      // Alguien ya tocó el marcador mientras se leía: lo suyo es lo nuevo.
      _save();
      return;
    }
    final String? raw = store.getString(matchStateKey);
    if (raw == null) {
      return;
    }
    final _Saved saved;
    try {
      saved = _Saved.parse(raw);
    } on Object {
      // Un JSON de otra versión, o roto, no vale una pantalla en blanco en la banda.
      return;
    }
    homeName = saved.homeName ?? homeName;
    awayName = saved.awayName ?? awayName;
    homeGoals = saved.homeGoals;
    awayGoals = saved.awayGoals;
    homeFormation = saved.homeFormation ?? homeFormation;
    awayFormation = saved.awayFormation ?? awayFormation;
    lineupTeam = saved.lineupTeam;
    streaming = saved.streaming;
    _baseMs = saved.baseMs;
    _runningSince = saved.runningSince;
    homeSquad = saved.homeSquad ?? homeSquad;
    awaySquad = saved.awaySquad ?? awaySquad;
    if (running) {
      _startTicker();
    }
    notifyListeners();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'homeName': homeName,
    'awayName': awayName,
    'homeGoals': homeGoals,
    'awayGoals': awayGoals,
    'homeFormation': homeFormation,
    'awayFormation': awayFormation,
    'lineupTeam': lineupTeam.name,
    'streaming': streaming,
    'baseMs': _baseMs,
    'runningSinceMs': _runningSince?.millisecondsSinceEpoch,
    'homeSquad': homeSquad.map((Player p) => p.toJson()).toList(),
    'awaySquad': awaySquad.map((Player p) => p.toJson()).toList(),
  };

  /// Todo cambio pasa por aquí: se marca, se guarda y se avisa.
  void _changed() {
    _touched = true;
    _save();
    notifyListeners();
  }

  void _save() {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null || _disposed) {
      return;
    }
    unawaited(prefs.setString(matchStateKey, jsonEncode(toJson())));
  }

  void _startTicker() {
    if (_disposed) {
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    super.dispose();
  }
}

/// Lo guardado, ya leído entero. Si algo no se puede leer, no se construye.
class _Saved {
  const _Saved({
    required this.homeName,
    required this.awayName,
    required this.homeGoals,
    required this.awayGoals,
    required this.homeFormation,
    required this.awayFormation,
    required this.lineupTeam,
    required this.streaming,
    required this.baseMs,
    required this.runningSince,
    required this.homeSquad,
    required this.awaySquad,
  });

  factory _Saved.parse(String raw) {
    final Map<String, Object?> json = jsonDecode(raw) as Map<String, Object?>;
    final int? sinceMs = json['runningSinceMs'] as int?;
    return _Saved(
      homeName: json['homeName'] as String?,
      awayName: json['awayName'] as String?,
      homeGoals: json['homeGoals'] as int? ?? 0,
      awayGoals: json['awayGoals'] as int? ?? 0,
      homeFormation: json['homeFormation'] as String?,
      awayFormation: json['awayFormation'] as String?,
      lineupTeam: MatchTeam.values.byName(json['lineupTeam'] as String? ?? 'home'),
      streaming: json['streaming'] as bool? ?? false,
      baseMs: json['baseMs'] as int? ?? 0,
      runningSince: sinceMs == null ? null : DateTime.fromMillisecondsSinceEpoch(sinceMs),
      homeSquad: _squadFrom(json['homeSquad']),
      awaySquad: _squadFrom(json['awaySquad']),
    );
  }

  final String? homeName;
  final String? awayName;
  final int homeGoals;
  final int awayGoals;
  final String? homeFormation;
  final String? awayFormation;
  final MatchTeam lineupTeam;
  final bool streaming;
  final int baseMs;
  final DateTime? runningSince;
  final List<Player>? homeSquad;
  final List<Player>? awaySquad;

  static List<Player>? _squadFrom(Object? raw) {
    if (raw is! List) {
      return null;
    }
    return raw.cast<Map<String, Object?>>().map(Player.fromJson).toList(growable: false);
  }
}
