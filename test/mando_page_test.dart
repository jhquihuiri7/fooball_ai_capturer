/// El móvil como mando del panel, de la pantalla de lado al marcador (ADR 0017 de
/// football-ai, TASK Z5b).
///
/// Lo que se prueba es lo que se vive en la banda: escanear el QR bueno y entrar,
/// escanear el malo y que lo diga, volver otro día y entrar sin escanear, quedarse sin
/// panel y que se vea, y que el partido termine y pida el QR nuevo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/mando_page.dart';
import 'package:football_ai_capture/src/match_page.dart';
import 'package:football_ai_capture/src/panel_control.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/role_page.dart';

import 'fake_capture_api.dart';
import 'fake_panel_control.dart';
import 'zero_fonts.dart';

const String _qrMando = 'https://pod-8090.proxy.runpod.net/#mando=abc.firma';
const String _qrOtroPartido =
    'https://pod-8090.proxy.runpod.net/#mando=otro.firma';

void usePhone(WidgetTester tester, {double height = 1800}) {
  tester.view
    ..physicalSize = Size(402 * 3, height * 3)
    ..devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(loadZeroFonts);

  /// Los mandos que se han creado, en orden, con el emparejamiento de cada uno.
  late List<(PanelPairing, FakePanelControl)> creados;

  setUp(() => creados = <(PanelPairing, FakePanelControl)>[]);

  PanelControl crear(PanelPairing pairing) {
    final FakePanelControl control = FakePanelControl();
    creados.add((pairing, control));
    return control;
  }

  /// Desmonta todo: el mando lleva temporizadores que no pueden quedar vivos.
  Future<void> cerrar(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  group('entrar como mando', () {
    Future<FakeCaptureApi> pulsarSoloMando(
      WidgetTester tester,
      FakeCaptureApi api,
    ) async {
      usePhone(tester, height: 1000);
      await tester.pumpWidget(
        MaterialApp(
          home: RolePage(api: api, mandoControl: crear),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Solo mando, sin cámara'));
      await tester.tap(find.text('Solo mando, sin cámara'));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets(
      'sin emparejar: escanea el QR Mando, lo guarda y abre el mando',
      (WidgetTester tester) async {
        final FakeCaptureApi api = FakeCaptureApi()..scannable = _qrMando;

        await pulsarSoloMando(tester, api);

        expect(api.panelPairing, _qrMando);
        expect(find.byType(MandoPage), findsOneWidget);
        expect(creados.single.$1.token, 'abc.firma');
        expect(creados.single.$2.started, isTrue);
        await cerrar(tester);
      },
    );

    testWidgets('el QR de Cámaras no vale para mandar, y se dice', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi()
        ..scannable = 'srt://rig:clave@1.2.3.4:8890?panel=https://pod.example';

      await pulsarSoloMando(tester, api);

      expect(find.byType(MandoPage), findsNothing);
      expect(find.textContaining('no es el de Mando'), findsOneWidget);
      expect(api.panelPairing, isEmpty);
    });

    testWidgets('con un emparejamiento guardado entra sin escanear', (
      WidgetTester tester,
    ) async {
      // Si escaneara, leería esto y no valdría: así se ve que no escanea.
      final FakeCaptureApi api = FakeCaptureApi()
        ..panelPairing = _qrMando
        ..scannable = 'no-es-un-qr';

      await pulsarSoloMando(tester, api);

      expect(find.byType(MandoPage), findsOneWidget);
      await cerrar(tester);
    });

    testWidgets('cancelar el escaneo no abre nada ni se queja', (
      WidgetTester tester,
    ) async {
      await pulsarSoloMando(tester, FakeCaptureApi());

      expect(find.byType(MandoPage), findsNothing);
      expect(find.textContaining('no es el de Mando'), findsNothing);
    });
  });

  group('el mando', () {
    Future<FakePanelControl> abrir(
      WidgetTester tester, {
      FakeCaptureApi? api,
    }) async {
      usePhone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: MandoPage(
            pairing: PanelPairing.parse(_qrMando)!,
            api: api ?? FakeCaptureApi(),
            controlFactory: crear,
          ),
        ),
      );
      await tester.pump();
      return creados.last.$2;
    }

    testWidgets('antes del primer partido dice a qué panel llama', (
      WidgetTester tester,
    ) async {
      await abrir(tester);

      expect(find.textContaining('Conectando con el panel'), findsOneWidget);
      expect(find.textContaining('pod-8090.proxy.runpod.net'), findsOneWidget);
      // Ni rastro del token en pantalla.
      expect(find.textContaining('abc.firma'), findsNothing);
      await cerrar(tester);
    });

    testWidgets('con el partido del panel, es la pestaña Partido de siempre', (
      WidgetTester tester,
    ) async {
      final FakePanelControl control = await abrir(tester);

      control.publish(panelMatch(home: 3, away: 2));
      await tester.pump();

      expect(find.byType(MatchPage), findsOneWidget);
      expect(find.bySemanticsLabel('Goles de BELLAVISTA: 3'), findsOneWidget);
      await cerrar(tester);
    });

    testWidgets('sin panel, lo dice debajo de la cabecera y no deja mandar', (
      WidgetTester tester,
    ) async {
      final FakePanelControl control = await abrir(tester);
      control.publish(panelMatch());
      await tester.pump();

      control.cut(PanelLink.offline);
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
      await tester.pump();

      expect(find.textContaining('Sin panel desde hace'), findsOneWidget);
      expect(control.calls, isEmpty);
      await cerrar(tester);
    });

    testWidgets(
      'si la transmisión terminó, pide el QR nuevo y se engancha a él',
      (WidgetTester tester) async {
        final FakeCaptureApi api = FakeCaptureApi()..scannable = _qrOtroPartido;
        final FakePanelControl viejo = await abrir(tester, api: api);
        viejo.publish(panelMatch());
        await tester.pump();

        viejo.cut(PanelLink.ended);
        await tester.pump();
        expect(find.textContaining('Esta transmisión terminó'), findsOneWidget);

        await tester.tap(find.text('Escanear QR'));
        await tester.pumpAndSettle();

        expect(creados, hasLength(2));
        expect(creados.last.$1.token, 'otro.firma');
        expect(creados.last.$2.started, isTrue);
        expect(api.panelPairing, _qrOtroPartido);
        // Con el mando nuevo, a la espera de su primer partido.
        expect(find.textContaining('Conectando con el panel'), findsOneWidget);
        await cerrar(tester);
      },
    );

    testWidgets('lo que no entró se dice debajo de la cabecera', (
      WidgetTester tester,
    ) async {
      final FakePanelControl control = await abrir(tester);
      control
        ..publish(panelMatch())
        ..answer = const CommandResult(CommandOutcome.unreachable);
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('no llegó al panel'), findsOneWidget);
      await cerrar(tester);
    });
  });
}
