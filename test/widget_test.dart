import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/main.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

void main() {
  testWidgets('lo primero que se pide es el lado del soporte', (WidgetTester tester) async {
    await tester.pumpWidget(const CaptureApp());

    expect(find.text('IZQUIERDA'), findsOneWidget);
    expect(find.text('DERECHA'), findsOneWidget);
  });

  testWidgets('la pantalla de captura dice de qué lado es', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CapturePage(role: CameraRole.right)),
    );
    await tester.pump();

    expect(find.text('Cámara derecha'), findsOneWidget);
  });

  testWidgets('no se puede grabar mientras la cámara no esté lista', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CapturePage(role: CameraRole.left)),
    );
    await tester.pump();

    final FilledButton boton = tester.widget<FilledButton>(
      find.ancestor(of: find.text('GRABAR'), matching: find.byType(FilledButton)),
    );
    expect(boton.onPressed, isNull);
  });
}
