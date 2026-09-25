/// La pestaña Partido con el marcador del panel (ADR 0017 de football-ai, TASK Z5a).
///
/// La pantalla es la misma que la del marcador local; lo que se prueba es lo que cambia
/// cuando lo lleva el panel: que enseñe lo que dice el panel, que cada botón sea una orden,
/// que una orden en camino deje la pantalla quieta y que lo que no se deshace pregunte.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_page.dart';
import 'package:football_ai_capture/src/panel_board.dart';
import 'package:football_ai_capture/src/panel_control.dart';

import 'fake_panel_control.dart';
import 'zero_fonts.dart';

void usePhone(WidgetTester tester, {double height = 1800}) {
  tester.view
    ..physicalSize = Size(402 * 3, height * 3)
    ..devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(loadZeroFonts);

  late FakePanelControl control;
  late PanelBoard board;

  Future<void> open(
    WidgetTester tester, {
    List<String> scopes = const <String>['match'],
  }) async {
    usePhone(tester);
    control = FakePanelControl(panelMatch(scopes: scopes));
    board = PanelBoard(control);
    addTearDown(() {
      board.dispose();
      control.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MatchPage(match: board)),
      ),
    );
    await tester.pump();
  }

  testWidgets('enseña el partido del panel, no uno propio', (
    WidgetTester tester,
  ) async {
    await open(tester);

    expect(find.bySemanticsLabel('Goles de BELLAVISTA: 1'), findsOneWidget);
    // 2 700 000 ms: el minuto 45 que dice el panel.
    expect(find.text('45:00'), findsWidgets);
  });

  testWidgets(
    'un gol es una orden, y lo que cambia es lo que conteste el panel',
    (WidgetTester tester) async {
      await open(tester);

      await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
      await tester.pump();

      expect(control.calls, <String>['goal home 1']);
      // Hasta que el panel no conteste, el marcador sigue en lo que había.
      expect(find.bySemanticsLabel('Goles de BELLAVISTA: 1'), findsOneWidget);

      control.publish(panelMatch(rev: 2, home: 2));
      await tester.pump();

      expect(find.bySemanticsLabel('Goles de BELLAVISTA: 2'), findsOneWidget);
    },
  );

  testWidgets('con una orden en camino, un segundo toque no sale', (
    WidgetTester tester,
  ) async {
    await open(tester);
    control.hold = Completer<CommandResult>();

    await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
    await tester.tap(find.text('+1 min'));
    await tester.pump();

    expect(control.calls, <String>['goal home 1']);
    expect(board.busy, isTrue);

    control.hold!.complete(const CommandResult(CommandOutcome.applied));
    await tester.pump();

    expect(board.busy, isFalse);
  });

  testWidgets('si otro mando se adelantó, lo dice con palabras', (
    WidgetTester tester,
  ) async {
    await open(tester);
    control.answer = const CommandResult(
      CommandOutcome.conflict,
      'home tiene 2 goles, no 1',
    );

    await tester.tap(find.bySemanticsLabel('Un gol más a BELLAVISTA'));
    await tester.pump();

    expect(board.message, contains('otro mando se adelantó'));
  });

  testWidgets(
    'reiniciar el marcador pregunta antes, y cancelar no manda nada',
    (WidgetTester tester) async {
      await open(tester);

      await tester.tap(find.text('Reiniciar marcador'));
      await tester.pumpAndSettle();
      expect(find.text('¿Poner el marcador a 0-0?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(control.calls, isEmpty);

      await tester.tap(find.text('Reiniciar marcador'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sí'));
      await tester.pumpAndSettle();

      expect(control.calls, <String>['score 0 0']);
    },
  );

  testWidgets(
    'sin permiso de emitir, Emitir no se puede pulsar y dice por qué',
    (WidgetTester tester) async {
      await open(tester);

      await tester.tap(find.text('Emitir'));
      await tester.pump();

      expect(control.calls, isEmpty);
      expect(find.textContaining('este mando no emite'), findsOneWidget);
    },
  );

  testWidgets('con permiso, parar la emisión pregunta antes', (
    WidgetTester tester,
  ) async {
    usePhone(tester);
    control = FakePanelControl(
      panelMatch(scopes: <String>['match', 'stream'], streaming: true),
    );
    board = PanelBoard(control);
    addTearDown(() {
      board.dispose();
      control.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MatchPage(match: board)),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Parar emisión'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sí'));
    await tester.pumpAndSettle();

    expect(control.calls, <String>['stream false']);
  });

  testWidgets(
    'la alineación: formación del panel, cuántos son y sacarla al aire',
    (WidgetTester tester) async {
      await open(tester);

      expect(find.text('BELLAVISTA · 4-3-3'), findsOneWidget);
      expect(find.textContaining('14 jugadores'), findsOneWidget);

      await tester.tap(find.text('3-5-2'));
      await tester.pump();
      await tester.tap(find.text('Sacar alineación al aire'));
      await tester.pump();

      expect(control.calls, <String>[
        'formation home 3-5-2',
        'lineup home true',
      ]);
    },
  );

  testWidgets('un equipo sin alineación en el panel no ofrece sacarla', (
    WidgetTester tester,
  ) async {
    await open(tester);

    await tester.tap(find.text('Visita'));
    await tester.pump();

    expect(find.text('PROGRESO · sin alineación'), findsOneWidget);
    expect(find.text('Sacar alineación al aire'), findsNothing);
    expect(find.textContaining('se carga desde su página'), findsOneWidget);
  });

  testWidgets('el aviso del mando va debajo de la cabecera', (
    WidgetTester tester,
  ) async {
    usePhone(tester);
    control = FakePanelControl(panelMatch());
    board = PanelBoard(control);
    addTearDown(() {
      board.dispose();
      control.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MatchPage(
            match: board,
            banner: const Text('sin panel desde hace 12 s'),
          ),
        ),
      ),
    );

    expect(find.text('sin panel desde hace 12 s'), findsOneWidget);
  });

  test('cada resultado se dice con palabras, y el bueno no dice nada', () {
    expect(
      PanelBoard.describe(const CommandResult(CommandOutcome.applied)),
      isNull,
    );
    for (final CommandOutcome outcome in CommandOutcome.values.skip(1)) {
      expect(PanelBoard.describe(CommandResult(outcome)), isNotEmpty);
    }
  });
}
