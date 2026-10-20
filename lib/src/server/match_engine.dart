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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/overlay_spec.g.dart';
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
    this.eventKind,
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
  /// reserva de grabación que respetan los vídeos. `eventKind` es lo que se transmite (ADR
  /// 0031): lo elige quien abre la cámara, no se guarda con el partido.
  factory MatchEngine.open({
    required File file,
    required MatchTimeSource time,
    String? matchId,
    String home = 'LOCAL',
    String away = 'VISITANTE',
    Random? random,
    int? Function()? freeBytes,
    bool Function()? localRecording,
    EventKind eventKind = EventKind.football,
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
      eventKind,
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

  /// Lo que transmite este maestro (ADR 0031): el fútbol con todo, el espectáculo con EN VIVO,
  /// rótulos, franjas y vídeos, y el vóley sin gráfico por ahora.
  final EventKind eventKind;

  /// Si salen el marcador, la competición y el reloj (ADR 0032): el operador los quita, por
  /// ejemplo, en una premiación. No se guarda: tras reiniciar vuelven.
  bool scoreboardOnAir = true;

  /// El gol que se celebra (ADR 0032): de quién y cuándo empezó, en el tiempo monótono.
  ({MatchTeam team, int startedMs})? _celebration;

  /// El gol animado al aire y lo que lleva, o null: sale solo con cada `+1` y dura
  /// `OverlaySpec.goal['show_ms']`.
  ({MatchTeam team, int elapsedMs})? get goal {
    final ({MatchTeam team, int startedMs})? g = _celebration;
    if (g == null) {
      return null;
    }
    final int lleva = _time.nowMs() - g.startedMs;
    return lleva >= 0 && lleva < OverlaySpec.goal['show_ms']! ? (team: g.team, elapsedMs: lleva) : null;
  }

  /// La tanda de franjas en marcha (`graphics/strip_all`), o null.
  _Sequence? _stripSeq;

  /// El rótulo que se sacó solo (su nombre y hasta cuándo; null, fijo) y la tanda de rótulos
  /// (`graphics/caption_all`): uno u otra, nunca los dos (ADR 0031).
  ({String name, int? untilMs})? _caption;
  _Sequence? _captionSeq;

  /// Los vídeos que faltan de la tanda (`video/play_all`), en orden (ADR 0032).
  List<String> _videoQueue = const <String>[];

  /// Lo último que vio [tick] de lo que cambia solo con el tiempo (al empezar, nada).
  Object? _tickSeen = (null, null, null, null, null);

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
  static const String cardFixtures = 'fixtures';
  static const String cardInterview = 'interview';
  static const String cardResults = 'results';

  /// La tarjeta de pantalla completa al aire: [cardHalftime], [cardFulltime] o
  /// [cardNextMatch], o null. Comparte capa con la alineación: sacar una quita la otra.
  String? fullScreenCard;

  bool get halftimeOnAir => fullScreenCard == cardHalftime;
  bool get fulltimeOnAir => fullScreenCard == cardFulltime;
  bool get nextMatchOnAir => fullScreenCard == cardNextMatch;
  bool get fixturesOnAir => fullScreenCard == cardFixtures;
  bool get interviewOnAir => fullScreenCard == cardInterview;
  bool get resultsOnAir => fullScreenCard == cardResults;

  /// Hasta cuándo sale la franja, en el tiempo monótono de [MatchTimeSource]; null, oculta.
  int? stripUntilMs;

  /// Si la franja está fuera ahora (ADR 0027: oculta salvo cuando el operador la saca).
  bool get stripVisible => stripRemainingMs > 0;

  /// Lo que le queda fuera a la franja, en ms (0 si está oculta). En una tanda, lo que le
  /// queda a la que está fuera (ADR 0032).
  int get stripRemainingMs {
    final int ahora = _time.nowMs();
    final _Sequence? tanda = _stripSeq;
    if (tanda != null && tanda.currentAt(ahora) != null) {
      return tanda.remainingAt(ahora);
    }
    final int? hasta = stripUntilMs;
    return hasta == null ? 0 : max(0, hasta - ahora);
  }

  /// La franja guardada que está puesta: la de la tanda si hay una en marcha, si no la que
  /// eligió el operador (null si sus textos se editaron a mano).
  String? get stripPresetName => _stripSeq?.currentAt(_time.nowMs()) ?? graphics.stripPreset;

  /// Lo que dice la franja puesta.
  StripTexts get stripTexts {
    final String? enTanda = _stripSeq?.currentAt(_time.nowMs());
    if (enTanda != null) {
      for (final StripPreset p in graphics.stripPresets) {
        if (p.name.toUpperCase() == enTanda.toUpperCase()) {
          return p.texts;
        }
      }
    }
    return graphics.strip;
  }

  /// La imagen de la franja puesta, o null.
  StripImage? get stripImage {
    final String? nombre = stripPresetName;
    return nombre == null ? null : graphics.stripImageFor(nombre);
  }

  /// Las franjas que faltan de la tanda, en orden.
  List<String> get stripQueue => _stripSeq?.queueAt(_time.nowMs()) ?? const <String>[];

  /// El rótulo al aire (ADR 0031): el de la tanda, o el que se sacó solo mientras dure.
  CaptionPreset? get captionOnAir {
    final int ahora = _time.nowMs();
    final String? nombre = _captionSeq?.currentAt(ahora) ??
        switch (_caption) {
          null => null,
          (name: final String n, untilMs: final int? hasta) when hasta == null || hasta > ahora => n,
          _ => null,
        };
    return nombre == null ? null : graphics.caption(nombre);
  }

  /// Lo que le queda al rótulo al aire, en ms: 0 sin rótulo y [captionHoldRemainingMs] si
  /// está fijo.
  int get captionRemainingMs {
    final int ahora = _time.nowMs();
    final _Sequence? tanda = _captionSeq;
    if (tanda != null && tanda.currentAt(ahora) != null) {
      return tanda.remainingAt(ahora);
    }
    if (captionOnAir == null) {
      return 0;
    }
    final int? hasta = _caption?.untilMs;
    return hasta == null ? captionHoldRemainingMs : max(0, hasta - ahora);
  }

  /// Los rótulos que faltan de la tanda, en orden.
  List<String> get captionQueue => _captionSeq?.queueAt(_time.nowMs()) ?? const <String>[];

  /// Los vídeos que faltan de la tanda.
  List<String> get videoQueue => List<String>.unmodifiable(_videoQueue);

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

  /// El programa avisa de que el vídeo `id` acabó (o no pudo empezar): suena el siguiente de
  /// la tanda, si la hay, o vuelve el programa.
  void videoFinished(int id) {
    if (_video?.id != id) {
      return;
    }
    _video = null;
    _playNextQueued();
    _changed();
  }

  /// Pasa `info` desde ya, con una `id` nueva.
  void _playVideo(VideoInfo info) {
    _videoIds += 1;
    _video = VideoPlay(
      id: _videoIds,
      name: info.name,
      startedMs: _time.nowMs() + videoStartLeadMs,
      durationMs: info.durationMs,
    );
  }

  /// El siguiente vídeo de la tanda que siga existiendo (uno borrado se salta).
  void _playNextQueued() {
    while (_videoQueue.isNotEmpty) {
      final String nombre = _videoQueue.first;
      _videoQueue = _videoQueue.sublist(1);
      final VideoInfo? info = videos.find(nombre);
      if (info != null) {
        _playVideo(info);
        return;
      }
    }
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
        case 'graphics/halftime' ||
            'graphics/fulltime' ||
            'graphics/next_match' ||
            'graphics/fixtures' ||
            'graphics/interview' ||
            'graphics/results':
          _fullScreenCard(name.substring('graphics/'.length), body);
        case 'graphics/scoreboard':
          scoreboardOnAir = _onAir(body);
        case 'match/fixtures':
          try {
            graphics.setFixtures(Fixture.listFromJson(body));
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'match/fixture_start':
          _startFixture(body);
        case 'match/finish':
          _finishFixture();
        case 'graphics/strip_all':
          final int cada = _showSeconds(body, stripShowDefaultS);
          final List<String> nombres = <String>[for (final StripPreset p in graphics.stripPresets) p.name];
          if (nombres.isEmpty) {
            throw OrderError(409, 'no hay franjas guardadas que pasar');
          }
          stripUntilMs = null;
          _stripSeq = _Sequence(nombres, _time.nowMs(), cada * Duration.millisecondsPerSecond);
        case 'graphics/caption_save':
          final Object? anterior = body['previous_name'];
          final String? viejo = anterior is String ? anterior : null;
          try {
            final CaptionPreset rotulo = CaptionPreset.fromJson(body);
            final String? antes = viejo == null ? null : graphics.caption(viejo)?.name;
            graphics.saveCaption(rotulo, previousName: viejo);
            if (antes != null && antes != rotulo.name) {
              _renameCaption(antes, rotulo.name);
            }
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'graphics/caption_delete':
          final Object? nombre = body['name'];
          final String? borrado = nombre is String ? graphics.caption(nombre)?.name : null;
          if (borrado == null || !graphics.deleteCaption(borrado)) {
            throw OrderError(404, 'no hay ningún rótulo que se llame $nombre');
          }
          _dropCaption(borrado);
        case 'graphics/caption':
          _showCaption(body);
        case 'graphics/caption_all':
          final int cada = _showSeconds(body, captionShowDefaultS);
          final List<String> nombres = <String>[for (final CaptionPreset c in graphics.captions) c.name];
          if (nombres.isEmpty) {
            throw OrderError(409, 'no hay rótulos guardados que pasar');
          }
          _caption = null;
          _captionSeq = _Sequence(nombres, _time.nowMs(), cada * Duration.millisecondsPerSecond);
        case 'match/interview':
          try {
            graphics.setInterview(Interview.fromJson(body));
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'match/next':
          try {
            graphics.setNextMatch(NextMatch.fromJson(body));
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'graphics/strip_save':
          final Object? anterior = body['previous_name'];
          try {
            final StripPreset franja = StripPreset.fromJson(body);
            graphics.savePreset(franja, previousName: anterior is String ? anterior : null);
            if (anterior is String) {
              _stripSeq = _stripSeq?.renamed(anterior, franja.name);
            }
          } on GraphicsError catch (error) {
            throw OrderError(error.status, error.message);
          }
        case 'graphics/strip_delete':
          final Object? nombre = body['name'];
          if (nombre is! String || !graphics.deletePreset(nombre)) {
            throw OrderError(404, 'no hay ninguna franja que se llame $nombre');
          }
          _stripSeq = _stripSeq?.without(nombre, _time.nowMs());
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
          // Sacar u ocultar una franja corta la tanda (ADR 0032).
          _stripSeq = null;
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
          _videoQueue = const <String>[];
          _playVideo(info);
        case 'video/play_all':
          // Todos, en el orden de la lista, uno detrás de otro (ADR 0032).
          final List<VideoInfo> todos = videos.list();
          if (todos.isEmpty) {
            throw OrderError(409, 'no hay vídeos que pasar');
          }
          _videoQueue = <String>[for (final VideoInfo v in todos.skip(1)) v.name];
          _playVideo(todos.first);
        case 'video/stop':
          _video = null;
          _videoQueue = const <String>[];
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
      // El gol animado sale solo (ADR 0032), en el fútbol.
      if (eventKind.isFootball) {
        _celebration = (team: equipo, startedMs: _time.nowMs());
      }
      onGoal?.call(equipo);
    } else if (goal?.team == equipo) {
      // Quitar el gol que se está celebrando quita la animación: era un error.
      _celebration = null;
    }
  }

  /// `on_air` de una orden, true o false.
  bool _onAir(Map<String, Object?> body) {
    final Object? alAire = body['on_air'];
    if (alAire is! bool) {
      throw OrderError(400, 'on_air tiene que ser true o false');
    }
    return alAire;
  }

  /// Los `show_s` de una orden de tanda o de rótulo: de 1 a [stripShowMaxS], o `porDefecto`.
  int _showSeconds(Map<String, Object?> body, int porDefecto) {
    final Object segundos = body['show_s'] ?? porDefecto;
    if (segundos is! int || segundos < 1 || segundos > stripShowMaxS) {
      throw OrderError(400, 'show_s tiene que ser un entero de 1 a $stripShowMaxS');
    }
    return segundos;
  }

  /// `match/fixture_start` (ADR 0032): el partido `index` de la jornada pasa al marcador con
  /// sus nombres (y sus escudos, que van por nombre), sus goles si ya se jugó, el reloj a cero
  /// y parado, y sin tarjetas. Las alineaciones van por equipo.
  void _startFixture(Map<String, Object?> body) {
    final Object? indice = body['index'];
    if (indice is! int || indice < 0) {
      throw OrderError(400, 'index tiene que ser un entero no negativo');
    }
    if (indice >= graphics.fixtures.length) {
      throw OrderError(404, 'la jornada no tiene el partido ${indice + 1}');
    }
    final Fixture partido = graphics.fixtures[indice];
    _swapLineups(partido.home, partido.away);
    home = partido.home;
    away = partido.away;
    homeGoals = partido.homeGoals ?? 0;
    awayGoals = partido.awayGoals ?? 0;
    clock
      ..pause()
      ..reset();
    fullScreenCard = null;
    lineups.setOnAir(null);
    _celebration = null;
    scoreboardOnAir = true;
    graphics.setCurrentFixture(indice);
  }

  /// `match/finish` (ADR 0032): el marcador queda guardado en el partido de la jornada que se
  /// jugaba, que se da por terminado, y el reloj se para.
  void _finishFixture() {
    final int? indice = graphics.currentFixture;
    if (indice == null) {
      throw OrderError(409, 'no se juega ningún partido de la jornada: empieza uno antes');
    }
    graphics
      ..setFixtureResult(indice, homeGoals, awayGoals)
      ..setCurrentFixture(null);
    clock.pause();
  }

  /// Las alineaciones por equipo (ADR 0032): la del que deja de jugar se aparta por la clave
  /// de su nombre y la del que entra vuelve, si se guardó alguna vez.
  void _swapLineups(String nuevoLocal, String nuevoVisitante) {
    final File archivo = File('${_file.parent.path}/$lineupsArchiveFileName');
    Map<String, Object?> guardadas = <String, Object?>{};
    try {
      final Object? leido = archivo.existsSync() ? jsonDecode(archivo.readAsStringSync()) : null;
      if (leido is Map<String, Object?>) {
        guardadas = leido;
      }
    } on FormatException {
      // Un archivo roto se sustituye: las de los que juegan ahora siguen en lineups.json.
    }
    for (final Team t in lineups.teams.values) {
      guardadas[GraphicsStore.crestKey(t.name)] = t.toJson();
    }
    try {
      for (final (MatchTeam lado, String nombre) in <(MatchTeam, String)>[
        (MatchTeam.home, nuevoLocal),
        (MatchTeam.away, nuevoVisitante),
      ]) {
        final Team? actual = lineups.teams[lado];
        if (actual != null && GraphicsStore.crestKey(actual.name) == GraphicsStore.crestKey(nombre)) {
          continue;
        }
        final Object? suya = guardadas[GraphicsStore.crestKey(nombre)];
        Team? vuelve;
        try {
          vuelve = suya == null ? null : Team.fromJson(suya);
        } on LineupError {
          vuelve = null;
        }
        if (vuelve == null) {
          lineups.remove(lado);
        } else {
          lineups.set(lado, vuelve);
        }
      }
      archivo.parent.createSync(recursive: true);
      archivo.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(guardadas));
    } on LineupError catch (error) {
      throw OrderError(500, error.message);
    } on FileSystemException catch (error) {
      throw OrderError(500, 'no se pudieron apartar las alineaciones: ${error.message}');
    }
  }

  /// `graphics/caption` (ADR 0031): saca un rótulo guardado `show_s` segundos, o fijo con
  /// `hold`; con `show_s` 0, lo quita. Corta la tanda.
  void _showCaption(Map<String, Object?> body) {
    if (body['show_s'] == 0) {
      _caption = null;
      _captionSeq = null;
      return;
    }
    final Object? nombre = body['name'];
    final CaptionPreset? rotulo = nombre is String ? graphics.caption(nombre) : null;
    if (rotulo == null) {
      throw OrderError(404, 'no hay ningún rótulo que se llame $nombre');
    }
    final bool fijo = body['hold'] == true;
    final int? hasta =
        fijo ? null : _time.nowMs() + _showSeconds(body, captionShowDefaultS) * Duration.millisecondsPerSecond;
    _captionSeq = null;
    _caption = (name: rotulo.name, untilMs: hasta);
  }

  /// Un rótulo renombrado sigue al aire (o en su tanda) con su nombre nuevo.
  void _renameCaption(String antes, String despues) {
    final ({String name, int? untilMs})? puesto = _caption;
    if (puesto != null && puesto.name.toUpperCase() == antes.toUpperCase()) {
      _caption = (name: despues, untilMs: puesto.untilMs);
    }
    _captionSeq = _captionSeq?.renamed(antes, despues);
  }

  /// Un rótulo borrado sale del aire y de su tanda.
  void _dropCaption(String nombre) {
    if (_caption?.name.toUpperCase() == nombre.toUpperCase()) {
      _caption = null;
    }
    _captionSeq = _captionSeq?.without(nombre, _time.nowMs());
  }

  /// Lo que cambia solo con el tiempo (ADR 0031 y 0032): el paso de una franja o un rótulo de
  /// su tanda al siguiente, el final de una tanda, de un rótulo o del gol, y el vídeo que acabó
  /// sin aviso del programa. Si algo de eso cambió, sube `rev` para que los mandos lo vean.
  /// Lo llama el maestro una vez por segundo; devuelve si hubo cambio.
  bool tick() {
    final int ahora = _time.nowMs();
    if (_video != null && video == null) {
      _video = null;
      _playNextQueued();
    }
    if (_stripSeq?.endedAt(ahora) ?? false) {
      _stripSeq = null;
    }
    if (_captionSeq?.endedAt(ahora) ?? false) {
      _captionSeq = null;
    }
    final int? hastaRotulo = _caption?.untilMs;
    if (hastaRotulo != null && hastaRotulo <= ahora) {
      _caption = null;
    }
    if (_celebration != null && goal == null) {
      _celebration = null;
    }
    if (_timedState(ahora) == _tickSeen) {
      return false;
    }
    _changed();
    return true;
  }

  /// Lo que [tick] compara: lo que cambia solo con el tiempo, sin contar lo que le queda.
  Object _timedState(int ahora) => (
    _stripSeq?.indexAt(ahora),
    _captionSeq?.indexAt(ahora),
    _caption?.name,
    _celebration?.startedMs,
    _video?.id,
  );

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
    if ((tarjeta == cardFixtures || tarjeta == cardResults) && graphics.fixtures.isEmpty) {
      throw OrderError(409, 'no hay jornada: guarda sus partidos antes con match/fixtures');
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

  /// Adopta la imagen recién subida a `graphics.stripImageUploadFile` como la de la franja
  /// guardada `name` (enmienda del ADR 0027 del 2026-10-16).
  void adoptStripImage(String name, String mime) {
    graphics.adoptStripImage(name, mime);
    _changed();
  }

  /// Quita la imagen de la franja guardada `name`.
  void deleteStripImage(String name) {
    graphics.deleteStripImage(name);
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
    _tickSeen = _timedState(_time.nowMs());
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
      'event_kind': eventKind.wire,
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
      'strip_presets': <Map<String, Object?>>[
        for (final StripPreset p in graphics.stripPresets)
          <String, Object?>{...p.toJson(), 'image': graphics.stripImageFor(p.name)?.rev},
      ],
      'strip_preset': stripPresetName,
      'strip_queue': stripQueue,
      'fixtures_on_air': fixturesOnAir,
      'fixtures': <Map<String, Object?>>[
        for (final Fixture f in graphics.fixtures)
          <String, Object?>{
            ...f.toJson(),
            'home_crest': graphics.crestFor(f.home)?.rev,
            'away_crest': graphics.crestFor(f.away)?.rev,
          },
      ],
      'current_fixture': graphics.currentFixture,
      'results_on_air': resultsOnAir,
      'interview_on_air': interviewOnAir,
      'interview': graphics.interview.toJson(),
      'scoreboard_on_air': scoreboardOnAir,
      'goal': switch (goal) {
        null => null,
        (team: final MatchTeam t, elapsedMs: final int lleva) => <String, Object?>{
          'team': t.name,
          'remaining_ms': OverlaySpec.goal['show_ms']! - lleva,
        },
      },
      'captions': <Map<String, Object?>>[for (final CaptionPreset c in graphics.captions) c.toJson()],
      'caption': captionOnAir?.name,
      'caption_remaining_ms': captionRemainingMs,
      'caption_queue': captionQueue,
      'video_queue': videoQueue,
      'strip_remaining_ms': stripRemainingMs,
      'strip_texts': stripTexts.toJson(),
      'strip_image': stripImage?.rev,
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

/// Una tanda (ADR 0031 y 0032): los nombres, en orden, que salen uno tras otro `eachMs` cada
/// uno desde `startMs`. Lo que está fuera en cada instante sale del tiempo, no de un temporizador:
/// el programa no se queda un fotograma sin franja entre una y la siguiente.
class _Sequence {
  _Sequence(List<String> names, this.startMs, this.eachMs) : names = List<String>.unmodifiable(names);

  final List<String> names;
  final int startMs;
  final int eachMs;

  /// El índice del que está fuera en `ahora` (puede pasar del último: la tanda acabó).
  int indexAt(int ahora) => max(0, ahora - startMs) ~/ eachMs;

  bool endedAt(int ahora) => indexAt(ahora) >= names.length;

  /// El nombre del que está fuera, o null si la tanda acabó.
  String? currentAt(int ahora) => endedAt(ahora) ? null : names[indexAt(ahora)];

  /// Lo que le queda fuera al de ahora, en ms.
  int remainingAt(int ahora) => startMs + (indexAt(ahora) + 1) * eachMs - ahora;

  /// Los que faltan después del de ahora.
  List<String> queueAt(int ahora) =>
      endedAt(ahora) ? const <String>[] : List<String>.unmodifiable(names.sublist(indexAt(ahora) + 1));

  /// La tanda sin `nombre` (borrado): si era el de ahora, el siguiente sale ya; si no, todo
  /// sigue igual. Null si no queda ninguno.
  _Sequence? without(String nombre, int ahora) {
    if (endedAt(ahora)) {
      return null;
    }
    final int i = indexAt(ahora);
    final bool esAhora = names[i].toUpperCase() == nombre.toUpperCase();
    final List<String> quedan = <String>[
      for (final String n in names.sublist(esAhora ? i + 1 : i))
        if (n.toUpperCase() != nombre.toUpperCase()) n,
    ];
    if (quedan.isEmpty) {
      return null;
    }
    // El de ahora conserva lo que llevaba; si se borró, el siguiente empieza en este instante.
    final int inicio = esAhora ? ahora : startMs + i * eachMs;
    return _Sequence(quedan, inicio, eachMs);
  }

  /// La tanda con `antes` renombrado a `despues`.
  _Sequence renamed(String antes, String despues) => _Sequence(
    <String>[for (final String n in names) n.toUpperCase() == antes.toUpperCase() ? despues : n],
    startMs,
    eachMs,
  );
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
