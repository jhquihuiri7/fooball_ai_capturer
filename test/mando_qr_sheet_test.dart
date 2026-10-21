/// La hoja del QR Mando (IOS-63) y su botón tras el Bug A (2026-10-21): QR con el secreto
/// que dé el nativo (el del soporte o el propio del móvil), el motivo real cuando no lo
/// hay, el panel para entrar con el PIN y «REINTENTAR MANDO».
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/mando_qr_sheet.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/server/control_token.dart';
import 'package:football_ai_capture/src/server/master_host.dart';
import 'package:football_ai_capture/src/widgets/qr_view.dart';

const int _ahoraS = 1790000000;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mando-hoja'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> abrir(WidgetTester tester, MasterHost h) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MandoQrSheet(host: h, savePin: (_) async {})),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('«Una cámara» sin secreto del soporte: QR firmado con el propio del móvil', (
    WidgetTester tester,
  ) async {
    // Lo que da `controlSecret` en un móvil sin secreto del soporte: el del mando derivado
    // del secreto propio de este móvil. Para Dart es un secreto más.
    final List<int> propio = utf8.encode('secreto-propio-de-este-movil-0123456789ab');
    final MasterHost h = MasterHost(
      directory: dir,
      controlSecret: (String id) async => ascii.decode(deriveControlSecret(propio, id)),
      announceMatch: (_) async {},
      peerAddress: () async => '',
      operatorPin: () async => '',
      addresses: () async => <String>['172.20.10.1'],
      wallS: () => _ahoraS,
      port: 0,
    );
    // El servidor abre de verdad: fuera del tiempo falso.
    await tester.runAsync(() => h.becomeMaster('m_solo'));
    await abrir(tester, h);
    final QrView qr = tester.widget(find.byType(QrView));
    final PanelPairing p = PanelPairing.parse(qr.data)!;
    expect(p.panel.toString(), 'http://172.20.10.1:${h.boundPort}');
    verifyToken(deriveControlSecret(propio, 'm_solo'), p.token, matchId: 'm_solo', nowS: _ahoraS);
    expect(find.text('REINTENTAR MANDO'), findsNothing);
    await tester.runAsync(h.stepDown);
  });

  testWidgets('sin QR: el motivo, el panel para el PIN y REINTENTAR, que lo vuelve a componer', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host(dir)
      ..next = MandoPairing(
        reason: mandoReasonNoSecret,
        manual: <Uri>[Uri.parse('http://172.20.10.1:8090')],
      );
    await abrir(tester, h);
    expect(find.byType(QrView), findsNothing);
    expect(find.text('Sin QR: $mandoReasonNoSecret.'), findsOneWidget);
    expect(find.text('http://172.20.10.1:8090'), findsOneWidget);

    h.next = const MandoPairing(text: '{"panel":"http://172.20.10.1:8090","token":"t"}');
    await tester.tap(find.text('REINTENTAR MANDO'));
    await tester.pump();
    await tester.pump();
    expect(h.retries, 1);
    expect(find.byType(QrView), findsOneWidget);
    expect(find.text('REINTENTAR MANDO'), findsNothing);
  });

  testWidgets('sin red local no hay dirección que enseñar', (WidgetTester tester) async {
    final _Host h = _Host(dir)..next = const MandoPairing(reason: mandoReasonNoLan);
    await abrir(tester, h);
    expect(find.text('Sin QR: $mandoReasonNoLan.'), findsOneWidget);
    expect(find.textContaining('PIN del operador:'), findsNothing);
  });

  testWidgets('el botón: sirviendo; sin servir con problema, con el motivo; si no, nada', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host(dir);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MandoQrButton(host: h, savePin: (_) async {})),
    ));
    expect(find.text('QR MANDO'), findsNothing, reason: 'el esclavo no sirve el mando');

    h
      ..problem = '$mandoFailedPrefix: SocketException: puerto ocupado'
      ..changed();
    await tester.pump();
    expect(find.text('QR MANDO'), findsOneWidget);
    expect(find.text('Mando: $mandoFailedPrefix: SocketException: puerto ocupado'), findsOneWidget);

    h
      ..servingNow = true
      ..problem = null
      ..changed();
    await tester.pump();
    expect(find.text('QR MANDO'), findsOneWidget);
    expect(find.textContaining('Mando: '), findsNothing);
  });
}

/// Un mando sin servidor: la hoja y el botón solo leen `pairing`, `serving` y `problem`.
class _Host extends MasterHost {
  _Host(Directory dir)
    : super(
        directory: dir,
        controlSecret: (_) async => '',
        announceMatch: (_) async {},
        peerAddress: () async => '',
        operatorPin: () async => '',
      );

  MandoPairing next = const MandoPairing(reason: mandoReasonNotServing);
  bool servingNow = false;
  int retries = 0;

  @override
  bool get serving => servingNow;

  @override
  Future<MandoPairing> pairing({bool stream = false}) async => next;

  @override
  Future<void> retry() async => retries += 1;

  void changed() => notifyListeners();
}
