/// «Emparejar sin cable» (IOS-14): el plan B del enlace por Wi-Fi Aware se empareja una
/// vez desde la pantalla de lado. El lado elegido decide qué hoja saca el nativo (el
/// izquierdo enseña el código, el derecho lo teclea), y lo que sale se dice debajo.
///
/// El VPS (IOS-68): el QR Soporte se escanea, se guarda en el Keychain y se ve con quién
/// y hasta cuándo; un QR que no vale no se guarda.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/role_page.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_capture_api.dart';
import 'zero_fonts.dart';

const String _casosVps = 'ios/ZeroKit/Tests/RigCoreTests/Fixtures/vps_pairing_cases.json';

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
    // `ensureVisible` desplaza sin pintar: sin este pump, el toque iría a donde estaba.
    await tester.pump();
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

  group('el VPS (IOS-68)', () {
    const int caduca = 1800043200;
    final Map<String, Object?> doc =
        jsonDecode(File(_casosVps).readAsStringSync()) as Map<String, Object?>;
    final List<Map<String, Object?>> casos =
        (doc['cases']! as List<Object?>).cast<Map<String, Object?>>();
    String qr(String nombre) =>
        casos.firstWhere((Map<String, Object?> c) => c['name'] == nombre)['qr']! as String;
    int ahora = 1800000000;

    Future<void> abrirVps(WidgetTester tester, FakeCaptureApi api) async {
      tester.view
        ..physicalSize = const Size(402 * 3, 1200 * 3)
        ..devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: RolePage(api: api, clockS: () => ahora)));
      await tester.pump();
    }

    Future<void> tocar(WidgetTester tester, String texto) async {
      await tester.ensureVisible(find.text(texto));
      await tester.pump();
      await tester.tap(find.text(texto));
      await tester.pumpAndSettle();
    }

    setUp(() => ahora = 1800000000);

    testWidgets('un escaneo lo guarda en el Keychain y dice con quién y hasta cuándo', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final FakeCaptureApi api = FakeCaptureApi()..scannable = qr('del_vps');
      await abrirVps(tester, api);
      expect(find.text('Sin emparejar'), findsOneWidget);

      await tocar(tester, 'Escanear QR Soporte');

      expect(api.vpsPairing, qr('del_vps'));
      expect(find.text('Emparejado con vps.ejemplo.com'), findsOneWidget);
      expect(find.text('rig rig-01 · caduca en 12 h'), findsOneWidget);
      // Solo al Keychain (el nativo): nada en shared_preferences ni en pantalla.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      for (final String clave in prefs.getKeys()) {
        expect('${prefs.get(clave)}', isNot(contains('clave-del-programa')));
      }
      expect(find.textContaining('frase-del-srt'), findsNothing);
    });

    testWidgets('otra versión o caducado no se guarda, y se dice por qué', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi()..scannable = qr('otra_version');
      await abrirVps(tester, api);

      await tocar(tester, 'Escanear QR Soporte');
      expect(find.text('Ese QR Soporte es de otra versión: actualiza la app.'), findsOneWidget);

      ahora = caduca;
      api.scannable = qr('del_vps');
      await tocar(tester, 'Escanear QR Soporte');
      expect(find.text('Ese QR Soporte caducó: recarga /pair en el VPS.'), findsOneWidget);

      api.scannable = 'https://pod.example/#mando=a.b';
      await tocar(tester, 'Escanear QR Soporte');
      expect(find.text('Ese QR no es el Soporte: en el panel del VPS, /pair.'), findsOneWidget);
      expect(api.vpsPairing, isEmpty);
      expect(find.text('Sin emparejar'), findsOneWidget);
    });

    testWidgets('lo guardado se ve al abrir, y desemparejar lo borra', (
      WidgetTester tester,
    ) async {
      ahora = caduca - 35 * 60;
      final FakeCaptureApi api = FakeCaptureApi()..vpsPairing = qr('del_vps');
      await abrirVps(tester, api);
      expect(find.text('Emparejado con vps.ejemplo.com'), findsOneWidget);
      expect(find.text('rig rig-01 · caduca en 35 min'), findsOneWidget);

      await tocar(tester, 'Desemparejar');

      expect(api.vpsPairing, isEmpty);
      expect(find.text('Sin emparejar'), findsOneWidget);
    });

    testWidgets('caducado en el Keychain sigue emparejado y pide escanear otra vez', (
      WidgetTester tester,
    ) async {
      ahora = caduca;
      final FakeCaptureApi api = FakeCaptureApi()..vpsPairing = qr('del_vps');
      await abrirVps(tester, api);

      expect(find.text('Emparejado con vps.ejemplo.com'), findsOneWidget);
      expect(
        find.text('rig rig-01 · la llave del túnel caducó: escanea otra vez'),
        findsOneWidget,
      );
      expect(find.text('Escanear otra vez'), findsOneWidget);
    });

    testWidgets('el QR Soporte leído desde «Servidor» no acaba en el campo', (
      WidgetTester tester,
    ) async {
      final FakeCaptureApi api = FakeCaptureApi()..scannable = qr('del_vps');
      await abrirVps(tester, api);

      await tocar(tester, 'Escanear QR');

      expect(api.serverHost, isEmpty);
      expect(api.vpsPairing, qr('del_vps'));
      expect(find.textContaining('clave-del-programa'), findsNothing);
      expect(find.text('Emparejado con vps.ejemplo.com'), findsOneWidget);
    });
  });
  group('enlace y emisión (IOS-58)', () {
    bool elegida(WidgetTester tester, String texto) => tester
        .widget<ZeroPill>(find.ancestor(of: find.text(texto), matching: find.byType(ZeroPill)))
        .selected;

    testWidgets('por defecto el pod de siempre; elegir otro lo guarda', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await abrir(tester, FakeCaptureApi());

      expect(elegida(tester, 'Pod'), isTrue);
      expect(find.textContaining('cada móvil emite su cámara'), findsOneWidget);

      await tester.ensureVisible(find.text('Aware'));
      await tester.tap(find.text('Aware'));
      await tester.pumpAndSettle();

      expect(elegida(tester, 'Aware'), isTrue);
      expect(elegida(tester, 'Pod'), isFalse);
      expect(find.textContaining('empareja antes sin cable'), findsOneWidget);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(linkModeKey), 'aware');
    });

    testWidgets('lo guardado se elige al abrir', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'wifi'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();

      expect(elegida(tester, 'Wi-Fi'), isTrue);
      expect(find.textContaining('sube el programa al VPS'), findsOneWidget);
    });

    testWidgets('«Una cámara (sin pareja)» se elige aparte y se guarda', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'aware'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();
      expect(elegida(tester, 'Una cámara (sin pareja)'), isFalse);

      await tester.ensureVisible(find.text('Una cámara (sin pareja)'));
      await tester.pump();
      await tester.tap(find.text('Una cámara (sin pareja)'));
      await tester.pumpAndSettle();

      expect(elegida(tester, 'Una cámara (sin pareja)'), isTrue);
      expect(elegida(tester, 'Aware'), isFalse);
      expect(find.textContaining('este móvil emite solo con su cámara'), findsOneWidget);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(linkModeKey), 'single');
    });

    testWidgets('«Una cámara» guardada se elige al abrir', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'single'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();

      expect(elegida(tester, 'Una cámara (sin pareja)'), isTrue);
      expect(elegida(tester, 'Pod'), isFalse);
    });

    testWidgets('IOS-99: la resolución solo aparece con «Una cámara»; 1080p de partida', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'aware'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();
      expect(find.text('720p'), findsNothing, reason: 'el soporte de dos va siempre a 1080p');

      await tester.ensureVisible(find.text('Una cámara (sin pareja)'));
      await tester.pump();
      await tester.tap(find.text('Una cámara (sin pareja)'));
      await tester.pumpAndSettle();

      expect(elegida(tester, '1080p'), isTrue);
      expect(elegida(tester, '720p'), isFalse);
      expect(find.textContaining('~12 de subida'), findsOneWidget);
    });

    testWidgets('IOS-99: elegir 720p lo dice y lo guarda, y se recuerda al abrir', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'single'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('720p'));
      await tester.pump();
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();

      expect(elegida(tester, '720p'), isTrue);
      expect(find.textContaining('~6 de subida'), findsOneWidget);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(singleResolutionKey), 'p720');

      await tester.pumpWidget(const SizedBox());
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();
      expect(elegida(tester, '720p'), isTrue);
    });

    testWidgets('un valor que ya no existe deja el pod', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{linkModeKey: 'nan'});
      await abrir(tester, FakeCaptureApi());
      await tester.pumpAndSettle();

      expect(elegida(tester, 'Pod'), isTrue);
    });
  });
}
