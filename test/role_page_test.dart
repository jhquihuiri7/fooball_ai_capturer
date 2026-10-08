/// «Emparejar sin cable» (IOS-14): el plan B del enlace por Wi-Fi Aware se empareja una
/// vez desde la pantalla de lado. El lado elegido decide qué hoja saca el nativo (el
/// izquierdo enseña el código, el derecho lo teclea), y lo que sale se dice debajo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/role_page.dart';

import 'fake_capture_api.dart';
import 'zero_fonts.dart';

void main() {
  setUpAll(loadZeroFonts);

  Future<void> abrir(WidgetTester tester, FakeCaptureApi api) async {
    tester.view
      ..physicalSize = const Size(402 * 3, 1000 * 3)
      ..devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: RolePage(api: api)));
    await tester.pump();
  }

  Future<void> emparejar(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Emparejar sin cable'));
    await tester.tap(find.text('Emparejar sin cable'));
    await tester.pumpAndSettle();
  }

  testWidgets('el izquierdo empareja con su lado y dice con quién', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi()..pairedPeer = 'iPhone 16 Pro';
    await abrir(tester, api);

    await emparejar(tester);

    expect(api.pairRequests, <CameraRole>[CameraRole.left]);
    expect(find.text('Emparejado sin cable con iPhone 16 Pro.'), findsOneWidget);
  });

  testWidgets('el derecho pide su hoja, la del que elige', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi()..pairedPeer = 'iPhone 17';
    await abrir(tester, api);
    await tester.tap(find.text('DERECHA'));
    await tester.pump();

    await emparejar(tester);

    expect(api.pairRequests, <CameraRole>[CameraRole.right]);
    expect(find.text('Emparejado sin cable con iPhone 17.'), findsOneWidget);
  });

  testWidgets('cerrar la hoja sin emparejar no es un error', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi();
    await abrir(tester, api);

    await emparejar(tester);

    expect(find.text('Sin emparejar.'), findsOneWidget);
  });

  testWidgets('sin Wi-Fi Aware se dice por qué', (WidgetTester tester) async {
    final FakeCaptureApi api = FakeCaptureApi()..pairError = 'este iPhone no tiene Wi-Fi Aware';
    await abrir(tester, api);

    await emparejar(tester);

    expect(
      find.text('No se pudo emparejar: este iPhone no tiene Wi-Fi Aware'),
      findsOneWidget,
    );
    // El botón vuelve: se puede reintentar.
    expect(find.text('Emparejar sin cable'), findsOneWidget);
  });
}
