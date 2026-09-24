/// El emparejamiento con el panel y el partido que devuelve (ADR 0017 de football-ai).
///
/// El JSON de estos tests es el que devuelve de verdad el panel (`PanelState.match_json`
/// más `scopes`, sacado de `tools/live_panel.py` el 2026-09-24): si el panel cambia su
/// forma, este fichero es el que tiene que cambiar con él.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/panel_match.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';

const String _tokenDePrueba = 'eyJtIjoibV8xIn0.c2lnbmF0dXJl-_x';

const String _delPanel =
    '{"match_id": "m_20260924_1530_abab", "boot": "a1b2c3d4", "rev": 7, '
    '"home": {"name": "BELLAVISTA", "goals": 1, "formation": "4-3-3", "players": 14}, '
    '"away": {"name": "PROGRESO", "goals": 0, "formation": null, "players": 0}, '
    '"clock_ms": 4044000, "clock_running": false, "clock_restored": false, '
    '"lineup_on_air": "home", "streaming": false, "can_stream": false, '
    '"formations": ["4-4-2", "4-3-3", "4-2-3-1", "4-1-4-1", "3-5-2", "3-4-3", "5-3-2", '
    '"5-4-1"], "save_error": null, "scopes": ["match"]}';

Map<String, Object?> _partido([
  Map<String, Object?> cambios = const <String, Object?>{},
]) => <String, Object?>{
  ...jsonDecode(_delPanel) as Map<String, Object?>,
  ...cambios,
};

void main() {
  group('el QR Mando', () {
    test('trae el panel y el token', () {
      final PanelPairing? pairing = PanelPairing.parse(
        'https://pod-8090.proxy.runpod.net/#mando=$_tokenDePrueba',
      );

      expect(pairing, isNotNull);
      expect(pairing!.panel.toString(), 'https://pod-8090.proxy.runpod.net');
      expect(pairing.token, _tokenDePrueba);
      expect(pairing.label, 'pod-8090.proxy.runpod.net');
    });

    test('en local lleva el puerto, y se nombra con él', () {
      final PanelPairing pairing = PanelPairing.parse(
        '  http://192.168.1.5:8090/#mando=$_tokenDePrueba\n',
      )!;

      expect(pairing.label, '192.168.1.5:8090');
      expect(
        pairing.endpoint('match', <String, String>{
          'since': 'a1b2c3d4:7',
        }).toString(),
        'http://192.168.1.5:8090/api/v1/match?since=a1b2c3d4%3A7',
      );
    });

    test('guardado y leído otra vez es el mismo', () {
      final PanelPairing pairing = PanelPairing.parse(
        'https://pod.example/panel/#mando=$_tokenDePrueba',
      )!;

      final PanelPairing again = PanelPairing.parse(pairing.qrText)!;

      expect(again.panel, pairing.panel);
      expect(again.token, pairing.token);
      expect(again.endpoint('match/goal').path, '/panel/api/v1/match/goal');
    });

    for (final String otro in <String>[
      '',
      '192.168.1.5',
      'srt://rig:clave@1.2.3.4:8890?panel=https://pod.example',
      'https://pod.example/',
      'https://pod.example/#otra=cosa',
      'https://pod.example/#mando=',
      'https://pod.example/#mando=con espacio',
      'ftp://pod.example/#mando=$_tokenDePrueba',
    ]) {
      test('«$otro» no es un QR Mando', () {
        expect(PanelPairing.parse(otro), isNull);
      });
    }
  });

  group('el partido del panel', () {
    test('se lee entero', () {
      final PanelMatch partido = PanelMatch.fromJson(_partido());

      expect(partido.matchId, 'm_20260924_1530_abab');
      expect(partido.since, 'a1b2c3d4:7');
      expect(partido.home.name, 'BELLAVISTA');
      expect(partido.team(MatchTeam.home).formation, '4-3-3');
      expect(partido.away.formation, isNull);
      expect(partido.clockMs, 4044000);
      expect(partido.lineupOnAir, MatchTeam.home);
      expect(partido.formations, hasLength(8));
      expect(partido.mayStream, isFalse);
    });

    test('con permiso de emitir lo dice', () {
      final PanelMatch partido = PanelMatch.fromJson(
        _partido(<String, Object?>{
          'scopes': <String>['match', 'stream'],
        }),
      );

      expect(partido.mayStream, isTrue);
    });

    for (final MapEntry<String, Object?> roto in <String, Object?>{
      'rev': -1,
      'clock_running': 'no',
      'home': null,
      'formations': <Object?>['4-4-2', 3],
      'lineup_on_air': 'arbitro',
      'scopes': null,
    }.entries) {
      test('un «${roto.key}» que no vale no se pinta a medias', () {
        expect(
          () => PanelMatch.fromJson(
            _partido(<String, Object?>{roto.key: roto.value}),
          ),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });
}
