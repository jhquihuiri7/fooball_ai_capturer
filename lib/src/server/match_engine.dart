/// El partido con autoridad en el maestro (IOS-60): las órdenes del mando, el
/// cronómetro y el DTO, porte de `ORDERS`/`apply_order` de `tools/live_panel.py`.
///
/// Las órdenes se validan enteras antes de tocar nada; el gol y el marcador llevan
/// `expect`, y si el partido ya no es el que vio quien mandó, 409 con el partido de
/// verdad. Cada cambio sube `rev` y se guarda. El cronómetro solo lee tiempo monótono
/// (el reloj del soporte de IOS-13, o un Stopwatch sin enlace): cambiar la hora del
/// sistema a mitad de partido no lo mueve.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/server/graphics_store.dart';
import 'package:football_ai_capture/src/server/lineups.dart';
import 'package:football_ai_capture/src/server/match_record.dart';
import 'package:football_ai_capture/src/server/video_store.dart';

/// Tiempo monótono en ms y el reloj al que pertenece (ADR 0023 §4).
abstract class MatchTimeSource {
  int nowMs();

  /// El `clock_domain`: dos lecturas solo se restan si es el mismo.
  String get domain;
}

/// Sin enlace: un Stopwatch, monótono, cuyo dominio muere con el proceso. Tras reiniciar
/// la app el cronómetro vuelve, por tanto, parado y con `clock_restored`.
class StopwatchTimeSource implements MatchTimeSource {
  StopwatchTimeSource({Random? random})
    : domain = 'sw${_hex(random ?? Random.secure(), 8)}',
      _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  final String domain;

  @override
  int nowMs() => _watch.elapsedMilliseconds;
}

/// Aparta el partido `id` y sus alineaciones con su nombre: un partido viejo no se
/// borra nunca, pero tampoco se mezcla con el nuevo.
void _archive(File file, String id) {
  for (final File f in <File>[file, File('${file.parent.path}/$lineupsFileName')]) {
    if (f.existsSync()) {
      final String nombre = f.uri.pathSegments.last.replaceFirst('.json', '');
      f.renameSync('${f.parent.path}/$nombre-$id.json');
    }
  }
}

/// Las alineaciones guardadas y, si el fichero no se pudo leer, por qué. Un fichero roto
/// no deja el maestro sin arrancar: se aparta a `.roto` (para no pisarlo al guardar) y
/// se empieza sin alineaciones.
(LineupBook, String?) _loadLineups(File file) {
  try {
    return (LineupBook.load(file), null);
  } on LineupError catch (error) {
    try {
      file.renameSync('${file.path}.roto');
    } on FileSystemException {
      // Si no se puede apartar, el siguiente guardado lo sustituye.
    }
    return (LineupBook(file: file), error.message);
  }
}

String _hex(Random random, int bytes) =>
    List<String>.generate(bytes, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

/// El cronómetro: lo acumulado y, si corre, desde cuándo.
class MatchClock {
  MatchClock(this._time);

  final MatchTimeSource _time;
  int accumulatedMs = 0;
  int? startedMs;

  /// Volvió parado de un reinicio con el reloj en marcha y nadie lo ha tocado aún.
  bool restored = false;

  bool get running => startedMs != null;

  int get elapsedMs => accumulatedMs + (startedMs == null ? 0 : _time.nowMs() - startedMs!);

  void start() {
    restored = false;
    startedMs ??= _time.nowMs();
  }

  void pause() {
    restored = false;
    final int? inicio = startedMs;
    if (inicio != null) {
      accumulatedMs += _time.nowMs() - inicio;
      startedMs = null;
    }
  }

  void reset() {
    restored = false;
    accumulatedMs = 0;
    startedMs = startedMs == null ? null : _time.nowMs();
  }

  /// Adelanta o atrasa, sin dejarlo nunca en negativo.
  void nudge(int seconds) {
    restored = false;
    accumulatedMs = max(0, accumulatedMs + seconds * 1000);
  }
}

/// Una orden que no se aplica: 400 mal escrita, 404 sin con qué cumplirla, 409 el
/// partido ya no es el que vio quien la mandó (`current` lleva el de verdad).
class OrderError implements Exception {
  OrderError(this.status, this.message);

  final int status;
  final String message;
  Map<String, Object?>? current;

  @override
  String toString() => 'OrderError($status): $message';
}

class MatchEngine {
  MatchEngine._(
    this._file,
    this._time,
    this.clock,
    this.matchId,
    this.boot,
    (LineupBook, String?) lineups,
    int? Function()? freeBytes,
    bool Function()? localRecording,
  ) : lineups = lineups.$1,
      lineupsError = lineups.$2,
      graphics = GraphicsStore(_file.parent),
      videos = VideoStore(_file.parent, freeBytes: freeBytes, localRecording: localRecording);

  /// Abre el partido guardado en `file`, o empieza uno nuevo si no hay fichero.
  /// Con el mismo `clock_domain` el cronómetro sigue en marcha; con otro vuelve
  /// parado y con `clock_restored` (ADR 0023). Las alineaciones van aparte, en
  /// `lineups.json` junto a `file` (el mismo formato que `--lineups` del panel).
  ///
  /// `matchId` es el partido que trae el enlace (IOS-80): si el guardado es otro, se
  /// aparta (`match-<id>.json`, con sus alineaciones) y se empieza este de cero.
  /// `freeBytes` dice lo libre del disco y `localRecording` si se quiere la 4K local: la
  /// reserva de grabación que respetan los vídeos.
  factory MatchEngine.open({
    required File file,
    required MatchTimeSource time,
    String? matchId,
    String home = 'LOCAL',
    String away = 'VISITANTE',
    Random? random,
    int? Function()? freeBytes,
    bool Function()? localRecording,
  }) {
    final Random azar = random ?? Random.secure();
    final MatchClock reloj = MatchClock(time);
    MatchRecord? guardado = loadRecord(file);
    if (guardado != null && matchId != null && guardado.matchId != matchId) {
      _archive(file, guardado.matchId);
      guardado = null;
    }
    final MatchEngine engine = MatchEngine._(
      file,
      time,
      reloj,
      guardado?.matchId ?? matchId ?? 'm_${_hex(azar, 6)}',
      _hex(azar, 8),
      _loadLineups(File('${file.parent.path}/$lineupsFileName')),
      freeBytes,
      localRecording,
    );
    if (guardado == null) {
      engine
        ..home = home
        ..away = away;
      engine._save();
      return engine;
    }
    engine
      ..home = guardado.home
      ..away = guardado.away
      ..homeGoals = guardado.homeGoals
      ..awayGoals = guardado.awayGoals;
    reloj.accumulatedMs = guardado.accumulatedMs;
    if (guardado.running && guardado.clockDomain == time.domain && guardado.startedRigMs != null) {
      reloj.startedMs = guardado.startedRigMs;
    } else {
      reloj.restored = guardado.running;
    }
    return engine;
  }

  final File _file;
  final MatchTimeSource _time;
  final MatchClock clock;
  final String matchId;

  /// Las dos alineaciones y cuál está al aire (IOS-61).
  final LineupBook lineups;

  /// Por qué no se pudieron leer las alineaciones guardadas, si no se pudieron.
  final String? lineupsError;

  /// Los textos de la franja y el icono del campeonato (ADR 0027): del campeonato, así
  /// que sobreviven al partido.
  final GraphicsStore graphics;

  /// Las tarjetas de pantalla completa (ADR 0027 y 0029), por el nombre de su orden.
  static const String cardHalftime = 'halftime';
  static const String cardFulltime = 'fulltime';
  static const String cardNextMatch = 'next_match';

  /// La tarjeta de pantalla completa al aire: [cardHalftime], [cardFulltime] o
  /// [cardNextMatch], o null. Comparte capa con la alineación: sacar una quita la otra.
  String? fullScreenCard;

  bool get halftimeOnAir => fullScreenCard == cardHalftime;
  bool get fulltimeOnAir => fullScreenCard == cardFulltime;
  bool get nextMatchOnAir => fullScreenCard == cardNextMatch;

  /// Hasta cuándo sale la franja, en el tiempo monótono de [MatchTimeSource]; null, oculta.
  int? stripUntilMs;

  /// Si la franja está fuera ahora (ADR 0027: oculta salvo cuando el operador la saca).
  bool get stripVisible => stripRemainingMs > 0;

  /// Lo que le queda fuera a la franja, en ms (0 si está oculta).
  int get stripRemainingMs {
    final int? hasta = stripUntilMs;
    return hasta == null ? 0 : max(0, hasta - _time.nowMs());
  }

  /// Los vídeos que se suben desde el mando (ADR 0027): como el icono, sobreviven al partido.
  final VideoStore videos;

  /// El vídeo que se pidió por última vez: `id` sube con cada `video/play`, para que el
  /// programa distinga volver a pasar el mismo. No se guarda: tras reiniciar no suena nada.
  VideoPlay? _video;
  int _videoIds = 0;

  /// El vídeo que suena en el programa, o null. Pasado su final y un margen sin que el
  /// programa avise, cuenta como acabado.
  VideoPlay? get video {
    final VideoPlay? v = _video;
    if (v == null || _time.nowMs() - v.startedMs > v.durationMs + videoEndGraceMs) {
      return null;
    }
    return v;
  }

  /// Lo que le queda al vídeo que suena, en ms.
  int get videoRemainingMs {
    final VideoPlay? v = video;
    return v == null ? 0 : max(0, min(v.durationMs, v.startedMs + v.durationMs - _time.nowMs()));
  }

  /// El programa avisa de que el vídeo `id` acabó (o no pudo empezar): vuelve el programa.
  void videoFinished(int id) {
    if (_video?.id != id) {
      return;
    }
    _video = null;
    _changed();
  }

  /// Identificador de este arranque: cambia en cada uno.
  final String boot;
  int rev = 0;
  String home = 'LOCAL';
  String away = 'VISITANTE';
  int homeGoals = 0;
  int awayGoals = 0;
  bool streaming = false;

  /// Si hay túnel al relé (ADR 0022): sin él, `can_stream` es false.
  bool _canStream = false;
  bool get canStream => _canStream;
  set canStream(bool value) {
    if (_canStream == value) {
      return;
    }
    _canStream = value;
    _changed();
  }

  /// Por qué ha dejado de guardarse el partido, si ha dejado.
  String? saveError;
  int? _savedAtMs;

  /// Un gol sumado: marca el clip y pide el plano de situación (ADR 0013).
  void Function(MatchTeam team)? onGoal;

  /// `clips/mark`; sin búfer de repetición no hay con qué cumplirla (404).
  void Function()? onClipMark;

  final StreamController<void> _changes = StreamController<void>.broadcast(sync: true);

  /// Un evento por cada subida de `rev`: despierta las esperas largas de la API.
  Stream<void> get changes => _changes.stream;

  /// Aplica una orden por su ruta bajo `/api/v1/` y devuelve el partido como quedó, o
  /// lanza [OrderError] sin haber tocado nada.
  Map<String, Object?> apply(String name, Map<String, Object?> body) {
    try {
      switch (name) {
        case 'match/goal':
          _goal(body);
        case 'match/score':
          _score(body);
        case 'match/clock':
          _clock(body);
        case 'match/lineup':
          _lineup(body);
        case 'match/teams':
          _teams(body);
        case 'graphics/halftime' || 'graphics/fulltime' || 'graphics/next_match':
          _fullScreenCard(name.substring('graphics/'.length), body);
        case 'match/next':
          try {
            graphics.setNextMatch(NextMatch.fromJson(body));
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'graphics/strip_save':
          final Object? anterior = body['previous_name'];
          try {
            graphics.savePreset(StripPreset.fromJson(body), previousName: anterior is String ? anterior : null);
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'graphics/strip_delete':
          final Object? nombre = body['name'];
          if (nombre is! String || !graphics.deletePreset(nombre)) {
            throw OrderError(404, 'no hay ninguna franja que se llame $nombre');
          }
        case 'graphics/strip':
          final Object segundos = body['show_s'] ?? stripShowDefaultS;
          if (segundos is! int || segundos < 0 || segundos > stripShowMaxS) {
            throw OrderError(400, 'show_s tiene que ser un entero de 0 a $stripShowMaxS');
          }
          // Con `name`, la franja guardada que toca (ADR 0029).
          final Object? franja = body['name'];
          if (franja != null && (franja is! String || !graphics.selectPreset(franja))) {
            throw OrderError(404, 'no hay ninguna franja que se llame $franja');
          }
          stripUntilMs = segundos == 0 ? null : _time.nowMs() + segundos * Duration.millisecondsPerSecond;
        case 'graphics/strip_texts':
          try {
            graphics.setStrip(StripTexts.fromJson(body));
          } on GraphicsError catch (error) {
            throw OrderError(400, error.message);
          }
        case 'video/play':
          final Object? nombre = body['name'];
          final VideoInfo? info = nombre is String ? videos.find(nombre) : null;
          if (info == null) {
            throw OrderError(404, 'no hay ningún vídeo que se llame $nombre');
          }
          _videoIds += 1;
          _video = VideoPlay(
            id: _videoIds,
            name: info.name,
            startedMs: _time.nowMs() + videoStartLeadMs,
            durationMs: info.durationMs,
          );
        case 'video/stop':
          _video = null;
        case 'clips/mark':
          final void Function()? marca = onClipMark;
          if (marca == null) {
            throw OrderError(404, 'el maestro no tiene bufer de repeticion');
          }
          marca();
        case 'stream/start':
          if (!canStream) {
            throw OrderError(409, 'sin tunel al rele: no se puede emitir');
          }
          streaming = true;
        case 'stream/stop':
          streaming = false;
        default:
          throw OrderError(404, 'orden desconocida: $name');
      }
    } on OrderError catch (error) {
      if (error.status == HttpStatus.conflict) {
        error.current = toJson();
      }
      rethrow;
    }
    _changed();
    return toJson();
  }

  MatchTeam _team(Map<String, Object?> body) {
    for (final MatchTeam t in MatchTeam.values) {
      if (body['team'] == t.name) {
        return t;
      }
    }
    throw OrderError(400, 'team tiene que ser home o away');
  }

  int _countOf(Object? value, String name) {
    if (value is! int || value < 0) {
      throw OrderError(400, '$name tiene que ser un entero no negativo');
    }
    return value;
  }

  void _goal(Map<String, Object?> body) {
    final MatchTeam equipo = _team(body);
    final Object? delta = body['delta'];
    if (delta != 1 && delta != -1) {
      throw OrderError(400, 'delta tiene que ser 1 o -1');
    }
    final int visto = _countOf(body['expect'], 'expect');
    final int goles = equipo == MatchTeam.home ? homeGoals : awayGoals;
    if (goles != visto) {
      throw OrderError(409, '${equipo.name} tiene $goles goles, no $visto');
    }
    final int nuevo = delta == 1 ? goles + matchGoalStep : max(0, goles - matchGoalStep);
    if (equipo == MatchTeam.home) {
      homeGoals = nuevo;
    } else {
      awayGoals = nuevo;
    }
    if (delta == 1) {
      onGoal?.call(equipo);
    }
  }

  void _score(Map<String, Object?> body) {
    final Object? visto = body['expect'];
    if (visto is! Map<String, Object?>) {
      throw OrderError(400, 'expect tiene que ser {home, away}');
    }
    final int nuevoLocal = _countOf(body['home'], 'home');
    final int nuevoVisitante = _countOf(body['away'], 'away');
    final int antesLocal = _countOf(visto['home'], 'expect.home');
    final int antesVisitante = _countOf(visto['away'], 'expect.away');
    if (homeGoals != antesLocal || awayGoals != antesVisitante) {
      throw OrderError(
        409,
        'el marcador es $homeGoals-$awayGoals, no $antesLocal-$antesVisitante',
      );
    }
    homeGoals = nuevoLocal;
    awayGoals = nuevoVisitante;
  }

  void _clock(Map<String, Object?> body) {
    switch (body['action']) {
      case 'start':
        clock.start();
      case 'pause':
        clock.pause();
      case 'reset':
        clock.reset();
      case 'nudge':
        final Object? segundos = body['seconds'];
        if (segundos is! int || segundos == 0 || segundos.abs() > matchClockNudgeMaxS) {
          throw OrderError(
            400,
            'seconds tiene que ser un entero distinto de cero, hasta $matchClockNudgeMaxS',
          );
        }
        clock.nudge(segundos);
      default:
        throw OrderError(400, 'action tiene que ser start, pause, reset o nudge');
    }
  }

  /// Formación, tarjeta al aire o las dos (`_order_lineup`). Las plantillas se escriben
  /// en el editor ([saveLineup]); desde el mando solo se recolocan.
  void _lineup(Map<String, Object?> body) {
    final MatchTeam equipo = _team(body);
    final Object? formacion = body['formation'];
    final Object? alAire = body['on_air'];
    if (formacion == null && alAire == null) {
      throw OrderError(400, 'falta formation u on_air');
    }
    if (formacion != null && formacion is! String) {
      throw OrderError(400, 'formation tiene que ser un texto, p. ej. 4-4-2');
    }
    if (alAire != null && alAire is! bool) {
      throw OrderError(400, 'on_air tiene que ser true o false');
    }
    final Team? guardado = lineups.teams[equipo];
    if (guardado == null) {
      throw OrderError(409, '${equipo.name} no tiene alineacion guardada');
    }
    if (formacion is String) {
      try {
        lineups.set(equipo, relineup(guardado, formacion));
      } on LineupError catch (error) {
        throw OrderError(400, error.message);
      }
    }
    if (alAire == true) {
      lineups.setOnAir(equipo);
      fullScreenCard = null;
    } else if (alAire == false && lineups.onAirSide == equipo) {
      // Ocultar la propia, nunca la del otro equipo que haya salido después.
      lineups.setOnAir(null);
    }
  }

  /// Saca o quita una tarjeta de pantalla completa. Quitarla solo quita esa: el «quitar»
  /// atrasado de otra no tumba la que está.
  void _fullScreenCard(String tarjeta, Map<String, Object?> body) {
    final Object? alAire = body['on_air'];
    if (alAire is! bool) {
      throw OrderError(400, 'on_air tiene que ser true o false');
    }
    if (!alAire) {
      if (fullScreenCard == tarjeta) {
        fullScreenCard = null;
      }
      return;
    }
    if (tarjeta == cardNextMatch && graphics.nextMatch == null) {
      throw OrderError(409, 'no hay próximo partido: guárdalo antes con match/next');
    }
    fullScreenCard = tarjeta;
    lineups.setOnAir(null);
  }

  /// Los nombres desde el mando (ADR 0027): uno o los dos, recortados y sin saltos.
  void _teams(Map<String, Object?> body) {
    final Map<MatchTeam, String> nuevos = <MatchTeam, String>{};
    for (final MatchTeam lado in MatchTeam.values) {
      final Object? nombre = body[lado.name];
      if (nombre == null) {
        continue;
      }
      final String limpio = nombre is String ? nombre.trim() : '';
      if (limpio.isEmpty || limpio.length > matchTeamNameMaxChars || limpio.contains('\n')) {
        throw OrderError(400, '${lado.name}: un nombre de 1 a $matchTeamNameMaxChars caracteres');
      }
      nuevos[lado] = limpio;
    }
    if (nuevos.isEmpty) {
      throw OrderError(400, 'falta home o away');
    }
    home = nuevos[MatchTeam.home] ?? home;
    away = nuevos[MatchTeam.away] ?? away;
  }

  /// Adopta el icono del campeonato recién subido a `graphics.uploadFile` (ADR 0027).
  void adoptChampionshipIcon(String mime) {
    graphics.adoptIcon(mime);
    _changed();
  }

  /// Quita el icono del campeonato.
  void deleteChampionshipIcon() {
    graphics.deleteIcon();
    _changed();
  }

  /// El nombre del equipo que juega de `side`.
  String teamName(MatchTeam side) => side == MatchTeam.home ? home : away;

  /// Adopta el escudo recién subido a `graphics.crestUploadFile` como el del equipo que
  /// juega de `side` ahora (ADR 0028): va con su nombre, no con el lado.
  void adoptTeamCrest(MatchTeam side, String mime) => adoptCrestFor(teamName(side), mime);

  /// Lo mismo para el equipo `name`, juegue ahora o no (los del próximo partido, ADR 0029).
  void adoptCrestFor(String name, String mime) {
    graphics.adoptCrest(name, mime);
    _changed();
  }

  /// Quita el escudo del equipo `name`.
  void deleteCrestFor(String name) {
    graphics.deleteCrest(name);
    _changed();
  }

  /// El equipo de una ranura de escudo: `home` y `away`, los que juegan; `next_home` y
  /// `next_away`, los del próximo partido (null si no lo hay).
  String? crestTeam(String slot) => switch (slot) {
    'home' => home,
    'away' => away,
    'next_home' => graphics.nextMatch?.home,
    'next_away' => graphics.nextMatch?.away,
    _ => null,
  };

  /// Guarda la alineación de un equipo desde el editor (`/api/lineup` del panel). Su
  /// nombre pasa también al marcador. [LineupError] si no se acepta.
  Team saveLineup(MatchTeam side, String name, String formation, String roster, {String coach = ''}) {
    final Team equipo = buildTeam(name, formation, roster, coach: coach);
    lineups.set(side, equipo);
    if (side == MatchTeam.home) {
      home = equipo.name;
    } else {
      away = equipo.name;
    }
    _changed();
    return equipo;
  }

  /// Sustituye las plantillas por las importadas (el alineaciones.json del pod) y pasa
  /// sus nombres al marcador. [LineupError] si no se pueden guardar.
  void importLineups(Map<MatchTeam, Team> teams) {
    for (final MapEntry<MatchTeam, Team> e in teams.entries) {
      lineups.set(e.key, e.value);
      if (e.key == MatchTeam.home) {
        home = e.value.name;
      } else {
        away = e.value.name;
      }
    }
    _changed();
  }

  void _changed() {
    rev += 1;
    _save();
    _changes.add(null);
  }

  /// Guarda el cronómetro si corre y toca; lo llama quien lleve el compás (1 Hz basta).
  void saveIfDue() {
    final int? ultimo = _savedAtMs;
    if (clock.running &&
        (ultimo == null || _time.nowMs() - ultimo >= matchClockSaveInterval.inMilliseconds)) {
      _save();
    }
  }

  /// El partido tal y como se guarda (para la réplica, IOS-82).
  MatchRecord record() => MatchRecord(
    matchId: matchId,
    home: home,
    away: away,
    homeGoals: homeGoals,
    awayGoals: awayGoals,
    accumulatedMs: clock.accumulatedMs,
    running: clock.running,
    startedRigMs: clock.startedMs,
    clockDomain: _time.domain,
  );

  void _save() {
    try {
      saveRecord(
        _file,
        MatchRecord(
          matchId: matchId,
          home: home,
          away: away,
          homeGoals: homeGoals,
          awayGoals: awayGoals,
          accumulatedMs: clock.accumulatedMs,
          running: clock.running,
          startedRigMs: clock.startedMs,
          clockDomain: _time.domain,
        ),
      );
      saveError = null;
      _savedAtMs = _time.nowMs();
    } on MatchRecordError catch (error) {
      // Un fallo no deshace el cambio: el marcador ya cambió. Se dice en el DTO.
      saveError = error.message;
    }
  }

  /// El `MatchStateDTO` del ADR 0017, el mismo que lee `PanelMatch.fromJson`; `scopes`
  /// lo pone la API según el token (IOS-62).
  Map<String, Object?> toJson({Set<String> scopes = const <String>{panelScopeMatch}}) {
    Map<String, Object?> equipo(MatchTeam lado, String nombre, int goles) {
      final Team? alineacion = lineups.teams[lado];
      return <String, Object?>{
        'name': nombre,
        'goals': goles,
        'formation': alineacion?.formation,
        'players': alineacion?.players ?? 0,
        'crest': graphics.crestFor(nombre)?.rev,
      };
    }
    return <String, Object?>{
      'match_id': matchId,
      'boot': boot,
      'rev': rev,
      'home': equipo(MatchTeam.home, home, homeGoals),
      'away': equipo(MatchTeam.away, away, awayGoals),
      'clock_ms': clock.elapsedMs,
      'clock_running': clock.running,
      'clock_restored': clock.restored,
      'lineup_on_air': lineups.onAirSide?.name,
      'halftime_on_air': halftimeOnAir,
      'fulltime_on_air': fulltimeOnAir,
      'next_match_on_air': nextMatchOnAir,
      'next_match': switch (graphics.nextMatch) {
        null => null,
        final NextMatch n => <String, Object?>{
          ...n.toJson(),
          'home_crest': graphics.crestFor(n.home)?.rev,
          'away_crest': graphics.crestFor(n.away)?.rev,
        },
      },
      'strip_presets': <Map<String, Object?>>[for (final StripPreset p in graphics.stripPresets) p.toJson()],
      'strip_preset': graphics.stripPreset,
      'strip_remaining_ms': stripRemainingMs,
      'strip_texts': graphics.strip.toJson(),
      'championship_icon': graphics.hasIcon ? graphics.iconRev : null,
      'video': switch (video) {
        null => null,
        final VideoPlay v => <String, Object?>{'name': v.name, 'remaining_ms': videoRemainingMs},
      },
      'streaming': streaming,
      'can_stream': canStream,
      'formations': matchFormations,
      'save_error': saveError,
      'scopes': scopes.toList()..sort(),
    };
  }
}

/// Un vídeo que suena en el programa (ADR 0027): la `id` de su `video/play`, su nombre,
/// cuándo empezó en el tiempo monótono y lo que dura.
class VideoPlay {
  const VideoPlay({required this.id, required this.name, required this.startedMs, required this.durationMs});

  final int id;
  final String name;
  final int startedMs;
  final int durationMs;
}
