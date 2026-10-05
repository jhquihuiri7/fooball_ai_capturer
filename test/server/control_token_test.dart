/// El token de mando (IOS-63) contra los dorados de `tools/control_token.py`: un token
/// emitido en Python se verifica aquí, y uno emitido aquí sale con los mismos bytes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/control_pairing.dart';
import 'package:football_ai_capture/src/server/control_token.dart';

List<Map<String, Object?>> _cases(String fn) {
  final Map<String, Object?> golden =
      jsonDecode(File('test/golden/control_token.json').readAsStringSync()) as Map<String, Object?>;
  return <Map<String, Object?>>[
    for (final Object? c in golden['cases']! as List<Object?>)
      if ((c! as Map<String, Object?>)['fn'] == fn) c as Map<String, Object?>,
  ];
}

void main() {
  group('dorados', () {
    final List<Map<String, Object?>> emitir = _cases('control_token.issue');
    final List<Map<String, Object?>> verificar = _cases('control_token.verify');

    test('hay casos de los dos', () {
      expect(emitir, hasLength(greaterThanOrEqualTo(2)));
      expect(verificar, hasLength(greaterThanOrEqualTo(9)));
    });

    for (final Map<String, Object?> c in emitir) {
      test('issue ${c['name']}', () {
        final Map<String, Object?> i = c['inputs']! as Map<String, Object?>;
        final String token = issueToken(
          utf8.encode(i['secret']! as String),
          ControlClaims(
            matchId: i['match_id'] as String?,
            scopes: (i['scopes']! as List<Object?>).cast<String>().toSet(),
            expiresS: i['expires_s']! as int,
          ),
        );
        expect(token, (c['expected']! as Map<String, Object?>)['token']);
      });
    }

    for (final Map<String, Object?> c in verificar) {
      test('verify ${c['name']}', () {
        final Map<String, Object?> i = c['inputs']! as Map<String, Object?>;
        final Map<String, Object?> esperado = c['expected']! as Map<String, Object?>;
        Map<String, Object?> resultado;
        try {
          final ControlClaims claims = verifyToken(
            utf8.encode(i['secret']! as String),
            i['token']! as String,
            matchId: i['match_id'] as String?,
            nowS: i['now_s']! as int,
          );
          resultado = <String, Object?>{
            'match_id': claims.matchId,
            'scopes': claims.scopes.toList()..sort(),
            'expires_s': claims.expiresS,
          };
        } on TokenError catch (e) {
          resultado = <String, Object?>{'status': e.status, 'error': e.message};
        }
        expect(resultado, esperado);
      });
    }
  });

  group('secreto derivado', () {
    final List<int> s = List<int>.generate(32, (int i) => i);

    test('el mismo que HMAC-SHA256 de Python, 43 caracteres', () {
      // python3: base64.urlsafe_b64encode(hmac.new(bytes(range(32)),
      //   b"zero-control-v1 m_20260703_2030_a1b2", hashlib.sha256).digest()).rstrip(b"=")
      final List<int> secreto = deriveControlSecret(s, 'm_20260703_2030_a1b2');
      expect(ascii.decode(secreto), 'P55UsFAh6ibSLqvQ7BKxUbQbuDqUTN01mU35McJp8SE');
      expect(secreto, hasLength(43));
    });

    test('otro partido, otro secreto: el token viejo da 410 o no abre', () {
      final List<int> a = deriveControlSecret(s, 'm_a');
      final String token = issueToken(
        a,
        const ControlClaims(matchId: 'm_a', scopes: <String>{panelScopeMatch}, expiresS: 100),
      );
      expect(verifyToken(a, token, matchId: 'm_a', nowS: 99).matchId, 'm_a');
      expect(
        () => verifyToken(a, token, matchId: 'm_b', nowS: 99),
        throwsA(isA<TokenError>().having((TokenError e) => e.status, 'status', 410)),
      );
      expect(
        () => verifyToken(deriveControlSecret(s, 'm_b'), token, matchId: 'm_b', nowS: 99),
        throwsA(isA<TokenError>().having((TokenError e) => e.status, 'status', 401)),
      );
    });
  });

  test('un match_id con tildes firma los bytes de json.dumps de Python', () {
    final String token = issueToken(
      utf8.encode('x' * 32),
      const ControlClaims(matchId: 'm_ñ', scopes: <String>{panelScopeMatch}, expiresS: 1),
    );
    final String datos = utf8.decode(base64Url.decode(base64Url.normalize(token.split('.').first)));
    expect(datos, '{"m":"m_\\u00f1","s":["match"],"e":1}');
  });

  test('el token del soporte lleva r y g, y se comprueba la generación', () {
    final List<int> k = utf8.encode('t' * 40);
    final String token = issueToken(
      k,
      const ControlClaims(
        matchId: null, rigId: 'rig_01', scopes: <String>{controlScopeTunnel}, expiresS: 50, generation: 2,
      ),
    );
    final ControlClaims c = verifyToken(k, token, matchId: null, nowS: 0, generation: 2, qr: 'QR Soporte');
    expect((c.rigId, c.generation), ('rig_01', 2));
    expect(
      () => verifyToken(k, token, matchId: null, nowS: 0, generation: 3, qr: 'QR Soporte'),
      throwsA(isA<TokenError>().having((TokenError e) => e.message, 'mensaje', contains('generacion'))),
    );
  });

  group('QR Mando del maestro', () {
    test('lleva las tres direcciones y un token que el otro móvil acepta', () {
      final List<int> s = utf8.encode('soporte' * 6);
      final String texto = controlPairingText(
        rigSecret: s,
        matchId: 'm_1',
        panels: <Uri>[masterApiUri('192.168.1.20'), masterApiUri('192.168.1.21'), Uri.parse('https://vps.example/zero')],
        nowS: 1000,
        scopes: <String>{panelScopeMatch, panelScopeStream},
      );
      final PanelPairing p = PanelPairing.parse(texto)!;
      expect(p.panel.toString(), 'http://192.168.1.20:$masterApiPort');
      expect(p.alternates.map((Uri u) => u.toString()), <String>[
        'http://192.168.1.21:$masterApiPort',
        'https://vps.example/zero',
      ]);
      expect(p.endpointAt(2, 'match').toString(), 'https://vps.example/zero/api/v1/match');
      expect(p.endpointAt(3, 'match').host, '192.168.1.20', reason: 'da la vuelta');
      final ControlClaims c = verifyToken(
        deriveControlSecret(s, 'm_1'), p.token, matchId: 'm_1', nowS: 1000 + controlTokenTtl.inSeconds - 1,
      );
      expect(c.scopes, <String>{panelScopeMatch, panelScopeStream});
      expect(PanelPairing.parse(p.qrText)!.alternates, p.alternates);
    });

    test('sin direcciones no hay QR', () {
      expect(
        () => controlPairingText(rigSecret: <int>[1], matchId: 'm', panels: <Uri>[], nowS: 0),
        throwsArgumentError,
      );
    });
  });
}
