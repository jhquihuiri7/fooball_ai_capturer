/// Lo que tiene que estar en la pantalla para que el partido salga bien.
///
/// No se comprueba que la app «se vea bonita»: se comprueban las cosas que, si fallan,
/// se descubren en la cancha y ya no tienen arreglo —que se pida el lado, que la cámara
/// se abra sola, que no se pueda grabar antes de tiempo, que un problema se lea antes
/// que la batería, y que el marcador y la cámara vivan en sitios separados—.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/main.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

import 'fake_capture_api.dart';
import 'zero_fonts.dart';

/// Un lienzo de móvil, que es donde vive esta app.
///
/// A los 800×600 por omisión la vista previa sola ocupa la pantalla entera y el
/// `ListView` ni construye el botón de grabar, así que las comprobaciones pasarían sin
/// mirar nada. Con [height] se pide un lienzo más alto cuando hay que ver una tarjeta
/// del final sin depender de un `scroll` frágil.
void usePhone(WidgetTester tester, {double height = 874}) {
  tester.view
    ..physicalSize = Size(402 * 3, height * 3)
    ..devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// El botón que lleva ese texto.
ZeroButton buttonWith(WidgetTester tester, String label) {
  return tester.widget<ZeroButton>(
    find.ancestor(of: find.text(label), matching: find.byType(ZeroButton)),
  );
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Abre la pantalla de captura como en el móvil: la sesión arranca sola en cuanto entra.
Future<CaptureSession> openCapture(
  WidgetTester tester, {
  FakeCaptureApi? api,
  // El derecho, por defecto: es el que espera reloj. El izquierdo es el maestro y queda
  // listo nada más abrir la cámara.
  CameraRole role = CameraRole.right,
  bool standalone = false,
  String serverHost = '',
  double height = 874,
}) async {
  usePhone(tester, height: height);
  final CaptureSession session = CaptureSession(
    role: role,
    api: api ?? FakeCaptureApi(),
    standalone: standalone,
    serverHost: serverHost,
  );
  await tester.pumpWidget(wrap(CapturePage(role: role, session: session)));
  // Un pump vacía los microtasks: el `prepare` entero con una cámara falsa.
  await tester.pump();
  return session;
}

/// La pantalla de captura tiene un refresco cada segundo: hay que desmontarla antes de
/// acabar, o el test termina con un temporizador vivo.
Future<void> closeCapture(WidgetTester tester, CaptureSession session) async {
  await tester.pumpWidget(const SizedBox());
  session.dispose();
}

void main() {
  setUpAll(loadZeroFonts);

  group('lado del soporte', () {
    testWidgets('lo primero que se pide es el lado', (WidgetTester tester) async {
      usePhone(tester);
      final FakeCaptureApi api = FakeCaptureApi()..serverHost = '10.10.18.100';
      await tester.pumpWidget(CaptureApp(api: api));
      await tester.pump();

      expect(find.text('IZQUIERDA'), findsOneWidget);
      expect(find.text('DERECHA'), findsOneWidget);
    });

    testWidgets('cada lado dice qué hace con el reloj', (WidgetTester tester) async {
      // Viene del ADR 0012: el izquierdo es el maestro y puede arrancar solo, el
      // derecho espera reloj. Quien monta el soporte no lee el ADR en la banda.
      usePhone(tester);
      await tester.pumpWidget(CaptureApp(api: FakeCaptureApi()));
      await tester.pump();

      expect(find.text('MAESTRO'), findsOneWidget);
      expect(find.text('SIGUE AL RELOJ'), findsOneWidget);
    });

    testWidgets('el servidor guardado aparece, y lo que se teclea se guarda', (
      WidgetTester tester,
    ) async {
      usePhone(tester);
      final FakeCaptureApi api = FakeCaptureApi()..serverHost = '10.10.18.100';
      await tester.pumpWidget(CaptureApp(api: api));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '10.10.18.100');
      expect(find.textContaining('guardado en el móvil'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'pod.football.ai');
      await tester.pump();
      expect(api.serverHost, 'pod.football.ai');
    });

    testWidgets('sin servidor guardado se busca en la red y se guarda lo encontrado', (
      WidgetTester tester,
    ) async {
      usePhone(tester);
      final FakeCaptureApi api = FakeCaptureApi()..discoverable = 'macbook.local';
      await tester.pumpWidget(CaptureApp(api: api));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'macbook.local');
      expect(api.serverHost, 'macbook.local');
      // Solo aquí se dice «Bonjour»: es la única vez que de verdad lo encontró Bonjour.
      expect(find.textContaining('encontrado por Bonjour'), findsOneWidget);
    });

    testWidgets('con servidor guardado no se busca: lo guardado manda', (
      WidgetTester tester,
    ) async {
      usePhone(tester);
      final FakeCaptureApi api = FakeCaptureApi()
        ..serverHost = 'pod.football.ai'
        ..discoverable = 'macbook.local';
      await tester.pumpWidget(CaptureApp(api: api));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'pod.football.ai');
    });

    testWidgets('elegir RTMP reescribe el servidor sin teclear el esquema', (
      WidgetTester tester,
    ) async {
      usePhone(tester);
      final FakeCaptureApi api = FakeCaptureApi()..serverHost = '10.10.18.100';
      await tester.pumpWidget(CaptureApp(api: api));
      await tester.pump();

      await tester.tap(find.text('RTMP'));
      await tester.pump();
      expect(api.serverHost, 'rtmp://10.10.18.100');

      await tester.tap(find.text('SRT'));
      await tester.pump();
      expect(api.serverHost, '10.10.18.100');
    });

    testWidgets('el botón de abrir nombra el lado elegido', (WidgetTester tester) async {
      usePhone(tester);
      await tester.pumpWidget(CaptureApp(api: FakeCaptureApi()));
      await tester.pump();

      expect(find.text('Abrir cámara izquierda'), findsOneWidget);

      await tester.tap(find.text('DERECHA'));
      await tester.pump();

      expect(find.text('Abrir cámara derecha'), findsOneWidget);
    });

    testWidgets('un solo móvil sin reloj arranca apagado y tiñe la tarjeta de rojo', (
      WidgetTester tester,
    ) async {
      // Encenderlo en un partido de verdad es volver con dos vídeos que no parean, y
      // eso no puede parecerse a cualquier otro ajuste.
      usePhone(tester);
      await tester.pumpWidget(CaptureApp(api: FakeCaptureApi()));
      await tester.pump();

      // El fondo se pinta con `Ink` para que el realce del toque quede encima.
      Color? cardColor() {
        final Ink card = tester.widget<Ink>(
          find
              .ancestor(of: find.text('Un solo móvil, sin reloj'), matching: find.byType(Ink))
              .first,
        );
        return (card.decoration! as BoxDecoration).color;
      }

      expect(cardColor(), ZeroColors.surface);

      await tester.tap(find.text('Un solo móvil, sin reloj'));
      await tester.pump();

      expect(cardColor(), ZeroColors.dangerRow);
    });
  });

  group('captura', () {
    testWidgets('la pantalla dice de qué lado es', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(tester, role: CameraRole.right);

      expect(find.text('Cámara derecha'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('al entrar se abre la cámara sin que nadie pulse nada', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = await openCapture(tester, api: api, height: 2000);

      expect(api.accessRequests, 1);
      expect(api.configureCalls, 1);
      expect(find.text('ESPERANDO RELOJ'), findsOneWidget);
      // Fuera de un iPhone no hay vista nativa: se dice, no se deja un hueco negro.
      expect(find.text('vista previa solo en iPhone'), findsOneWidget);
      expect(find.text('3840×2160'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('no se puede grabar mientras la cámara no esté lista', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(tester);

      expect(buttonWith(tester, 'GRABAR').onPressed, isNull);

      await closeCapture(tester, session);
    });

    testWidgets('el maestro queda listo nada más abrir la cámara', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(tester, role: CameraRole.left);

      expect(find.text('LISTA'), findsOneWidget);
      expect(buttonWith(tester, 'GRABAR').onPressed, isNotNull);

      await closeCapture(tester, session);
    });

    testWidgets('en modo un solo móvil se graba sin reloj y la pantalla lo avisa', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = await openCapture(tester, api: api, standalone: true);

      expect(find.textContaining('SIN RELOJ'), findsWidgets);
      expect(buttonWith(tester, 'GRABAR').onPressed, isNotNull);

      await tester.tap(find.text('GRABAR'));
      await tester.pump();

      expect(api.startCalls, 1);
      expect(find.text('PARAR'), findsOneWidget);
      expect(find.text('GRABANDO'), findsWidgets);
      expect(find.textContaining('left-1.mov'), findsOneWidget);

      await tester.tap(find.text('PARAR'));
      await tester.pump();

      expect(find.text('no está grabando · último: left-1.mov'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('GRABAR entrega al nativo la URL del servidor elegido', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = await openCapture(
        tester,
        api: api,
        role: CameraRole.left,
        serverHost: 'mediamtx.local',
      );

      await tester.tap(find.text('GRABAR'));
      await tester.pump();

      expect(
        api.lastSrtUrl,
        startsWith('srt://mediamtx.local:8890?streamid=publish:rig/izquierda'),
      );

      await tester.tap(find.text('PARAR'));
      await tester.pump();
      await closeCapture(tester, session);
    });

    testWidgets('el estado se refresca solo, cada segundo', (WidgetTester tester) async {
      final FakeCaptureApi api = FakeCaptureApi();
      final CaptureSession session = await openCapture(tester, api: api);
      expect(api.statusCalls, 0);

      await tester.pump(const Duration(seconds: 1));
      expect(api.statusCalls, 1);

      await tester.pump(const Duration(seconds: 1));
      expect(api.statusCalls, 2);

      await closeCapture(tester, session);
    });

    testWidgets('sin estado de cámara no se dibujan chips de relleno', (WidgetTester tester) async {
      // Un guion en el HUD se lee como un cero desde tres metros. Si el dato no existe,
      // la fila no existe. La cámara se queda midiendo la luz: todavía no hay estado.
      final FakeCaptureApi api = FakeCaptureApi()..configureGate = Completer<void>();
      final CaptureSession session = await openCapture(tester, api: api);

      expect(find.text('ABRIENDO CÁMARA'), findsOneWidget);
      expect(find.textContaining('×'), findsNothing);
      expect(find.textContaining('ISO'), findsNothing);
      expect(find.textContaining('FASE'), findsNothing);

      api.configureGate!.complete();
      await tester.pump();
      await closeCapture(tester, session);
    });

    testWidgets('con la cámara abierta el HUD lleva formato y exposición aplicada', (
      WidgetTester tester,
    ) async {
      final CaptureSession session = await openCapture(tester);

      expect(find.text('3840×2160 · 30p'), findsOneWidget);
      // Lo que quedó aplicado según el nativo (1/100, ISO 320), no lo pedido.
      expect(find.text('1/100 · ISO 320'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('los datos van en cuatro tarjetas con nombre', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(tester, height: 2400);

      for (final String card in <String>['SOPORTE', 'EMISIÓN', 'CÁMARA', 'DISPOSITIVO']) {
        expect(find.text(card), findsOneWidget, reason: 'falta la tarjeta $card');
      }

      await closeCapture(tester, session);
    });

    testWidgets('un problema se lee antes que los datos, no en la fila catorce', (
      WidgetTester tester,
    ) async {
      final CaptureSession session = await openCapture(
        tester,
        api: FakeCaptureApi(status: fakeStatus(stabilizationDisabled: false)),
        height: 1600,
      );

      expect(find.text('Problema'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Problema')).dy,
        lessThan(tester.getTopLeft(find.text('SOPORTE')).dy),
      );

      await closeCapture(tester, session);
    });

    testWidgets('una interrupción del nativo se lee en la tarjeta de atención', (
      WidgetTester tester,
    ) async {
      final CaptureSession session = await openCapture(tester, height: 1600);

      session.onInterrupted('llamada entrante');
      await tester.pump();

      expect(find.text('Interrupción'), findsOneWidget);
      expect(find.text('llamada entrante'), findsOneWidget);

      session.onResumed();
      await tester.pump();
      expect(find.text('Interrupción'), findsNothing);

      await closeCapture(tester, session);
    });

    testWidgets('la alarma va en rojo, nunca en naranja', (WidgetTester tester) async {
      final CaptureStatus hot = fakeStatus()..thermalState = ThermalState.serious;
      final CaptureSession session = await openCapture(
        tester,
        api: FakeCaptureApi(status: hot),
        height: 2400,
      );

      final Text value = tester.widget<Text>(find.text('serious · busca sombra'));
      expect(value.style!.color, ZeroColors.alarm);

      await closeCapture(tester, session);
    });

    testWidgets('lo que tenía que estar bien se confirma en acento claro', (
      WidgetTester tester,
    ) async {
      final CaptureSession session = await openCapture(tester, height: 2400);

      final Text value = tester.widget<Text>(find.text('desactivada'));
      expect(value.style!.color, ZeroColors.accentLight);

      await closeCapture(tester, session);
    });

    testWidgets('el chip de emisión sale del estado que da el nativo', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(
        tester,
        api: FakeCaptureApi(status: fakeStatus(streamState: StreamState.streaming)),
        serverHost: 'mediamtx.local',
        height: 1600,
      );

      expect(find.text('EMITIENDO'), findsOneWidget);

      session.onStatus(fakeStatus(streamState: StreamState.reconnecting, streamDetail: 'sin red'));
      await tester.pump();

      expect(find.text('RECONECTANDO'), findsOneWidget);
      expect(find.textContaining('sin red'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('el título de la cabecera no se corta al lado de un hueco vacío', (
      WidgetTester tester,
    ) async {
      final CaptureSession session = await openCapture(tester);

      expect(session.phase, SessionPhase.esperandoReloj);
      final RenderParagraph title = tester.renderObject<RenderParagraph>(
        find.text('Cámara derecha'),
      );
      expect(title.didExceedMaxLines, isFalse);

      await closeCapture(tester, session);
    });

    testWidgets('el banner va debajo del botón, no encima', (WidgetTester tester) async {
      final CaptureSession session = await openCapture(tester, role: CameraRole.left);

      expect(
        tester.getTopLeft(find.text('GRABAR')).dy,
        lessThan(tester.getTopLeft(find.text('no está grabando')).dy),
      );

      await closeCapture(tester, session);
    });

    testWidgets('mientras graba no se puede salir de la pantalla', (WidgetTester tester) async {
      // Un roce en el borde del soporte haría volver atrás en iOS y dejaría el fichero
      // escribiéndose sin pantalla que lo pare.
      usePhone(tester);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('lado')),
        ),
      );
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: CapturePage(role: CameraRole.left, session: session),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('GRABAR'));
      await tester.pump();

      await nav.currentState!.maybePop();
      // Sin `pumpAndSettle`: grabando, el punto del HUD late sin fin y nunca se asienta.
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('PARAR'), findsOneWidget);
      expect(find.text('Para la grabación antes de salir.'), findsOneWidget);

      await tester.tap(find.text('PARAR'));
      await tester.pump();
      await nav.currentState!.maybePop();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('lado'), findsOneWidget);
      await closeCapture(tester, session);
    });
  });

  group('dos lugares', () {
    testWidgets('el marcador no se ve desde la pantalla de captura', (WidgetTester tester) async {
      // Compartir pantalla es un toque accidental en GRABAR a mitad de partido.
      usePhone(tester);
      final CaptureSession session = CaptureSession(role: CameraRole.left, api: FakeCaptureApi());
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ZeroShell(role: CameraRole.left, session: session, match: match),
        ),
      );
      await tester.pump();

      expect(find.text('Cámara izquierda'), findsOneWidget);
      expect(find.text('CRONÓMETRO'), findsNothing);

      await tester.tap(find.text('Partido'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('CRONÓMETRO'), findsOneWidget);
      expect(find.text('MARCADOR'), findsOneWidget);

      await closeCapture(tester, session);
    });

    testWidgets('sumar un gol cambia el marcador', (WidgetTester tester) async {
      usePhone(tester);
      // Se libera dentro del cuerpo y no en un `addTearDown`: la comprobación de
      // handles vivos corre antes que los teardown.
      final SemanticsHandle semantics = tester.ensureSemantics();
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(wrap(MatchPage(match: match)));
      await tester.pump();

      expect(find.bySemanticsLabel('Goles de BELLAVISTA: 0'), findsOneWidget);
      // El botón se tiene que poder accionar con el lector de pantalla, no solo verse.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Un gol más a BELLAVISTA')),
        isSemantics(isButton: true, hasTapAction: true),
      );

      await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
      await tester.pump();

      expect(match.homeGoals, 1);
      expect(find.bySemanticsLabel('Goles de BELLAVISTA: 1'), findsOneWidget);
      expect(find.bySemanticsLabel('Goles de PROGRESO: 0'), findsOneWidget);

      semantics.dispose();
    });

    testWidgets('las píldoras dicen cuál está elegida, no solo con color', (
      WidgetTester tester,
    ) async {
      usePhone(tester, height: 1600);
      final SemanticsHandle semantics = tester.ensureSemantics();
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(wrap(MatchPage(match: match)));
      await tester.pump();

      expect(
        tester.getSemantics(find.text('4-3-3')),
        isSemantics(isButton: true, isSelected: true, isInMutuallyExclusiveGroup: true),
      );
      expect(tester.getSemantics(find.text('3-5-2')), isSemantics(isSelected: false));

      semantics.dispose();
    });

    testWidgets('cambiar de formación reordena la lista de verdad', (WidgetTester tester) async {
      usePhone(tester, height: 1600);
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(wrap(MatchPage(match: match)));
      await tester.pump();

      expect(find.text('BELLAVISTA · 4-3-3'), findsOneWidget);
      expect(find.text('ED'), findsOneWidget);

      await tester.tap(find.text('3-5-2'));
      await tester.pump();

      expect(find.text('BELLAVISTA · 3-5-2'), findsOneWidget);
      // En un 3-5-2 no hay extremos: hay carrileros.
      expect(find.text('ED'), findsNothing);
      expect(find.text('CAD'), findsOneWidget);
      expect(find.text('CAI'), findsOneWidget);
    });

    testWidgets('emitir no afirma que el marcador ya va sobre la señal', (
      WidgetTester tester,
    ) async {
      usePhone(tester, height: 1800);
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(wrap(MatchPage(match: match, destinations: 1)));
      await tester.pump();
      await tester.tap(find.text('Emitir'));
      await tester.pump();

      expect(find.text('AL AIRE'), findsOneWidget);
      expect(find.textContaining('sobre la señal'), findsNothing);
      expect(find.textContaining('todavía no se envía'), findsOneWidget);
    });

    testWidgets('sin servidor configurado no se prometen destinos', (WidgetTester tester) async {
      usePhone(tester, height: 1800);
      final MatchState match = MatchState();
      addTearDown(match.dispose);

      await tester.pumpWidget(wrap(MatchPage(match: match)));
      await tester.pump();

      expect(find.textContaining('sin destino configurado'), findsOneWidget);
    });
  });
}
