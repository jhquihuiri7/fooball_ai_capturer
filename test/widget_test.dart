import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/main.dart';
import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

import 'fake_capture_api.dart';

Future<FilledButton> _recordButton(WidgetTester tester) async {
  // El botón va al final de una lista perezosa: hasta que no se desplaza, no existe.
  await tester.scrollUntilVisible(find.text('GRABAR'), 200);
  return tester.widget<FilledButton>(
    find.ancestor(of: find.text('GRABAR'), matching: find.byType(FilledButton)),
  );
}

Future<void> _openCapturePage(
  WidgetTester tester, {
  required FakeCaptureApi api,
  CameraRole role = CameraRole.left,
  bool standalone = false,
}) async {
  // Un viewport alto: la vista previa y las filas de estado no caben en los 800×600
  // por defecto, y una lista perezosa no construye lo que no se ve.
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: CapturePage(
        role: role,
        session: CaptureSession(role: role, api: api, standalone: standalone),
      ),
    ),
  );
  // Un pump vacía los microtasks: el `prepare` entero con una cámara falsa.
  await tester.pump();
}

void main() {
  testWidgets('lo primero que se pide es el lado del soporte', (WidgetTester tester) async {
    await tester.pumpWidget(const CaptureApp());

    expect(find.text('IZQUIERDA'), findsOneWidget);
    expect(find.text('DERECHA'), findsOneWidget);
    // El modo de un solo móvil existe y está apagado: encenderlo es una decisión.
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
  });

  testWidgets('la pantalla de captura dice de qué lado es', (WidgetTester tester) async {
    await _openCapturePage(tester, api: FakeCaptureApi(), role: CameraRole.right);

    expect(find.text('Cámara derecha'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('al entrar se abre la cámara sin que nadie pulse nada', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi();
    await _openCapturePage(tester, api: api);

    expect(api.accessRequests, 1);
    expect(api.configureCalls, 1);
    expect(find.text('esperandoReloj'), findsOneWidget);
    // Fuera de un iPhone no hay vista nativa: se dice, no se deja un hueco negro.
    expect(find.text('vista previa solo en iPhone'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('3840×2160'), 200);
    expect(find.text('3840×2160'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no se puede grabar mientras la cámara no esté lista', (WidgetTester tester) async {
    await _openCapturePage(tester, api: FakeCaptureApi());

    expect((await _recordButton(tester)).onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('en modo un solo móvil se graba sin reloj y la pantalla lo avisa',
      (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi();
    await _openCapturePage(tester, api: api, standalone: true);

    expect(find.textContaining('SIN RELOJ'), findsWidgets);
    expect((await _recordButton(tester)).onPressed, isNotNull);

    await tester.tap(find.text('GRABAR'));
    await tester.pump();

    expect(api.startCalls, 1);
    expect(find.text('PARAR'), findsOneWidget);
    expect(find.textContaining('GRABANDO'), findsOneWidget);
    expect(find.textContaining('left-1.mov'), findsOneWidget);

    await tester.tap(find.text('PARAR'));
    await tester.pump();

    expect(find.text('No está grabando'), findsOneWidget);
    expect(find.text('Último archivo'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('el estado se refresca solo, cada segundo', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi();
    await _openCapturePage(tester, api: api);
    expect(api.statusCalls, 0);

    await tester.pump(const Duration(seconds: 1));
    expect(api.statusCalls, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(api.statusCalls, 2);

    await tester.pumpWidget(const SizedBox());
  });
}
