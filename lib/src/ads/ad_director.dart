/// Qué anuncio va en la franja (IOS-49): porte de tools/ad_director.py sobre el partido
/// del maestro.
///
/// La rotación y el fotograma de cada instante los lleva el nativo (AdRotation, IOS-48):
/// aquí se le manda la lista del paquete con `setAdPlaylist` y, cuando el partido da un
/// flanco (un gol, el reloj que se para, ponerse al aire), el anuncio de ese evento con
/// `setAdOverride` durante [adEventLoops] vueltas. Pasadas, el nativo vuelve solo a la
/// rotación.
///
/// Los eventos se derivan del estado y no de los botones, como en la referencia: el
/// director compara dos cortes del partido ([MatchSignals]) y le da igual si el gol vino
/// del mando, del panel o de la API.
library;

import 'dart:async';
import 'dart:convert';

import 'package:football_ai_capture/src/ads/ad_pack_downloader.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

/// Lo que puede meter un anuncio fuera de turno; el valor es el nombre del anuncio.
enum AdTrigger {
  goal('gol'),
  halfTime('medio-tiempo'),
  onAir('arranque');

  const AdTrigger(this.adName);

  final String adName;
}

/// Lo único del partido que mira el director: un corte, no el partido entero.
class MatchSignals {
  const MatchSignals({required this.goals, required this.clockRunning, required this.live});

  /// El corte de un partido del maestro; «al aire» es que se emite.
  factory MatchSignals.of(MatchEngine engine) => MatchSignals(
    goals: engine.homeGoals + engine.awayGoals,
    clockRunning: engine.clock.running,
    live: engine.streaming,
  );

  /// Goles totales. Solo interesa que suba: corregir un gol de más no dispara nada.
  final int goals;
  final bool clockRunning;
  final bool live;
}

/// Qué evento hay entre dos cortes, o null (`trigger_between`). Si coinciden varios,
/// manda el gol.
AdTrigger? triggerBetween(MatchSignals before, MatchSignals after) {
  if (after.goals > before.goals) {
    return AdTrigger.goal;
  }
  if (before.clockRunning && !after.clockRunning) {
    return AdTrigger.halfTime;
  }
  if (!before.live && after.live) {
    return AdTrigger.onAir;
  }
  return null;
}

/// La franja nativa (IOS-48).
abstract interface class AdSink {
  /// La lista en JSON; devuelve "" o el error.
  Future<String> setAdPlaylist(String json);

  /// Un anuncio ya cargado desde ahora `loops` vueltas; nombre vacío lo quita.
  Future<void> setAdOverride(String name, int loops);
}

/// RigHostApi como [AdSink].
class RigAdSink implements AdSink {
  RigAdSink([RigHostApi? api]) : _api = api ?? RigHostApi();

  final RigHostApi _api;

  @override
  Future<String> setAdPlaylist(String json) => _api.setAdPlaylist(json);

  @override
  Future<void> setAdOverride(String name, int loops) => _api.setAdOverride(name, loops);
}

/// El JSON de `setAdPlaylist` para un paquete: todos los anuncios cargados (los de
/// evento también, para el override) y en `slots` solo la rotación, una vuelta cada uno.
String playlistJson(AdPack pack) => jsonEncode(<String, Object?>{
  'ads': <Object?>[
    for (final PackedAd ad in pack.ads)
      <String, Object?>{'name': ad.name, 'fps': ad.fps, 'frames': pack.framePaths(ad)},
  ],
  'slots': <Object?>[
    for (final PackedAd ad in pack.rotation) <String, Object?>{'name': ad.name, 'loops': 1},
  ],
});

class AdDirector {
  AdDirector(this.sink, {this.loops = adEventLoops});

  final AdSink sink;

  /// Vueltas de un anuncio de evento.
  final int loops;

  AdPack? _pack;
  MatchSignals? _previous;
  Timer? _eventEnds;
  String? _event;

  /// Por qué el nativo no cargó el último paquete, si no lo cargó.
  String? error;

  /// El paquete cargado en la franja.
  AdPack? get pack => _pack;

  /// El anuncio de evento que está en la franja, o null si va la rotación. Lo pinta el
  /// nativo; esto es para enseñarlo.
  String? get eventOnAir => _event;

  /// Nombres de la rotación, en orden.
  List<String> get rotation => <String>[for (final PackedAd a in _pack?.rotation ?? <PackedAd>[]) a.name];

  /// Pone un paquete en la franja: la rotación vuelve a empezar y se quita el evento.
  /// El paquete vale desde ya: las llamadas al nativo llegan en orden, así que un gol
  /// que entre mientras carga se cuela después de la lista.
  Future<void> load(AdPack pack) async {
    _pack = pack;
    _endEvent();
    final String fallo = await sink.setAdPlaylist(playlistJson(pack));
    error = fallo.isEmpty ? null : fallo;
  }

  /// Mira el partido y, si hay flanco con anuncio vendido, lo cuela. El primer corte
  /// nunca dispara: arrancar ya al aire no es ponerse al aire.
  Future<AdTrigger?> observe(MatchSignals signals) async {
    final MatchSignals? anterior = _previous;
    _previous = signals;
    if (anterior == null) {
      return null;
    }
    final AdTrigger? evento = triggerBetween(anterior, signals);
    final PackedAd? anuncio = evento == null ? null : _pack?.event(evento.adName);
    if (anuncio == null) {
      // Sin evento, o evento sin anuncio vendido: la rotación sigue como si nada.
      return null;
    }
    _endEvent();
    _event = anuncio.name;
    _eventEnds = Timer(anuncio.duration * loops, _endEvent);
    await sink.setAdOverride(anuncio.name, loops);
    return evento;
  }

  void _endEvent() {
    _eventEnds?.cancel();
    _eventEnds = null;
    _event = null;
  }

  void dispose() => _endEvent();
}
