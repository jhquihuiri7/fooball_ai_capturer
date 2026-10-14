/// El QR Soporte del VPS (IOS-68; ADR 0022 §3 y NUBE-16 del repo football-ai).
///
/// Los casos los comparte con `VpsPairingTests.swift`: el publicador del programa lo lee
/// en Swift y el túnel en Dart, y los dos tienen que aceptar y rechazar lo mismo. El QR
/// bueno salió de `support_payload` del VPS.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/vps_pairing.dart';

import 'fake_capture_api.dart';

const String _casos = 'ios/ZeroKit/Tests/RigCoreTests/Fixtures/vps_pairing_cases.json';

Map<String, Object?> _doc() =>
    jsonDecode(File(_casos).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _cases() =>
    (_doc()['cases']! as List<Object?>).cast<Map<String, Object?>>();

String _qr(String name) =>
    _cases().firstWhere((Map<String, Object?> c) => c['name'] == name)['qr']! as String;

const int _ahora = 1800000000;

void main() {
  group('los casos compartidos con RigCore', () {
    final int docNow = _doc()['now_s']! as int;
    for (final Map<String, Object?> caso in _cases()) {
      test(caso['name']! as String, () {
        final String qr = caso['qr']! as String;
        final int nowS = (caso['now_s'] as int?) ?? docNow;
        final Map<String, Object?> esperado = caso['expected']! as Map<String, Object?>;
        if (esperado['ok'] case final Map<String, Object?> ok) {
          final VpsPairing p = VpsPairing.parse(qr, nowS: nowS);
          expect(
            <Object?>[p.srt.host, p.srt.port, p.srt.path, p.srt.user, p.srt.pass, p.srt.passphrase],
            <Object?>[ok['host'], ok['port'], ok['path'], ok['user'], ok['pass'], ok['passphrase']],
          );
          expect(p.tunnel.toString(), ok['tunnel_url']);
          expect(p.domain, ok['domain']);
          expect(p.rigId, ok['rig_id']);
          expect(p.rigKey, ok['rig_key']);
          expect(p.rigKeyExpiresS, ok['expires_s']);
          expect(p.qrText, qr.trim());
        } else {
          expect(
            () => VpsPairing.parse(qr, nowS: nowS),
            throwsA(
              isA<VpsPairingException>()
                  .having((VpsPairingException e) => _code(e.problem), 'problema', esperado['error'])
                  .having((VpsPairingException e) => e.field, 'campo', esperado['field']),
            ),
          );
        }
      });
    }
  });

  test('del Keychain no mira la caducidad: el SRT sigue valiendo', () {
    final VpsPairing p = VpsPairing.parse(_qr('del_vps'));
    expect(p.expiredAt(1800043200), isTrue);
    expect(p.expiredAt(1800043199), isFalse);
    expect(p.validFor(_ahora), const Duration(hours: 12));
    expect(p.validFor(1900000000), Duration.zero);
  });

  test('un JSON parece un QR Soporte; una dirección, no', () {
    expect(VpsPairing.looksLike('  {"v":1}'), isTrue);
    expect(VpsPairing.looksLike('srt://1.2.3.4:8890'), isFalse);
    expect(VpsPairing.looksLike('https://pod.example/#mando=x.y'), isFalse);
  });

  test('ningún secreto en los textos ni en los errores', () {
    final VpsPairing p = VpsPairing.parse(_qr('del_vps'), nowS: _ahora);
    final List<String> secretos = <String>[
      p.srt.pass,
      p.srt.passphrase,
      p.rigKey,
      p.rigKey.split('.').last,
    ];
    final List<String> textos = <String>['$p', '${p.srt}'];
    for (final Map<String, Object?> caso in _cases()) {
      try {
        VpsPairing.parse(caso['qr']! as String, nowS: (caso['now_s'] as int?) ?? _ahora);
      } on VpsPairingException catch (e) {
        textos.addAll(<String>['$e', e.message]);
      }
    }
    expect(textos.length, greaterThan(30));
    for (final String texto in textos) {
      for (final String secreto in secretos) {
        expect(texto.contains(secreto), isFalse, reason: texto);
      }
    }
    expect('$p', 'VpsPairing(vps.ejemplo.com, rig rig-01, caduca 1800043200)');
    expect('${p.srt}', 'srt://vps.ejemplo.com:8890 publish:programa:maestro:***');
  });

  test('peekClaims lee el token del soporte sin la firma, como peek_claims', () {
    final ControlClaims c = peekClaims(VpsPairing.parse(_qr('del_vps')).rigKey)!;
    expect(<Object?>[c.rigId, c.scopes, c.expiresS, c.generation], <Object?>[
      'rig-01',
      <String>{'tunnel'},
      1800043200,
      0,
    ]);
    for (final String malo in <String>['', 'sin-punto', 'e30.firma', 'eyJ9.firma']) {
      expect(peekClaims(malo), isNull, reason: malo);
    }
  });

  group('load', () {
    test('lee lo guardado en el Keychain', () async {
      final FakeCaptureApi api = FakeCaptureApi()..vpsPairing = _qr('del_vps');
      final VpsPairing? p = await VpsPairing.load(api);
      expect(p?.domain, 'vps.ejemplo.com');
      expect(p?.tunnel.toString(), 'wss://vps.ejemplo.com/tunnel/v1');
    });

    test('sin nada, o con algo que no se lee, es null', () async {
      expect(await VpsPairing.load(FakeCaptureApi()), isNull);
      expect(await VpsPairing.load(FakeCaptureApi()..vpsPairing = '{"v":2}'), isNull);
    });
  });
}

String _code(VpsPairingProblem p) => switch (p) {
  VpsPairingProblem.notSupport => 'not_support',
  VpsPairingProblem.version => 'version',
  VpsPairingProblem.field => 'field',
  VpsPairingProblem.expired => 'expired',
};
