/// El mando del maestro con avisos de rol solapados (Bug A, 2026-10-21): `onRigRole`
/// lanza `becomeMaster` y `stepDown` sin esperar, y el nativo puede mandar otro rol
/// mientras el primero espera a `announceMatch`. Cada llamada empieza cuando acaba la
/// anterior, y manda la última.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/server/master_host.dart';

void main() {
  late Directory dir;
  late List<String> anunciados;
  late Completer<void> primerAnuncio;
  late int puerto;

  MasterHost host() => MasterHost(
    directory: dir,
    controlSecret: (_) async => 'secreto-del-mando-de-prueba',
    // El primer anuncio tarda (el nativo ocupado); los siguientes, al momento.
    announceMatch: (String id) async {
      anunciados.add(id);
      if (anunciados.length == 1) {
        await primerAnuncio.future;
      }
    },
    peerAddress: () async => '',
    operatorPin: () async => '',
    addresses: () async => <String>['192.168.7.20'],
    // Un puerto fijo, como el 8090 del móvil: dos servidores no caben.
    port: puerto,
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mando-solapado');
    anunciados = <String>[];
    primerAnuncio = Completer<void>();
    final ServerSocket libre = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    puerto = libre.port;
    await libre.close();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('dos «dirige» seguidos: un solo partido anunciado, sirve y sin problema', () async {
    final MasterHost h = host();
    final Future<void> primero = h.becomeMaster(null);
    await pumpEventQueue();
    final Future<void> segundo = h.becomeMaster(null);
    await pumpEventQueue();
    primerAnuncio.complete();
    await Future.wait(<Future<void>>[primero, segundo]);
    expect(h.serving, isTrue);
    expect(h.problem, isNull);
    expect(anunciados, hasLength(1), reason: 'el segundo ya encuentra el partido servido');
    expect(h.engine!.matchId, anunciados.single);
    await h.stepDown();
  });

  test('«dirige» lento y luego «esclavo»: queda sin servir', () async {
    final MasterHost h = host();
    final Future<void> dirige = h.becomeMaster(null);
    await pumpEventQueue();
    final Future<void> esclavo = h.stepDown();
    await pumpEventQueue();
    primerAnuncio.complete();
    await Future.wait(<Future<void>>[dirige, esclavo]);
    expect(h.serving, isFalse, reason: 'manda el último rol: el esclavo no sirve el mando');
    expect(h.engine, isNull);
  });

  test('«esclavo» y otra vez «dirige» durante el anuncio: sirve el último partido', () async {
    final MasterHost h = host();
    final Future<void> a = h.becomeMaster(null);
    await pumpEventQueue();
    final Future<void> b = h.stepDown();
    final Future<void> c = h.becomeMaster('m_enlace');
    await pumpEventQueue();
    primerAnuncio.complete();
    await Future.wait(<Future<void>>[a, b, c]);
    expect(h.serving, isTrue);
    expect(h.engine!.matchId, 'm_enlace');
    expect(h.problem, isNull);
    await h.stepDown();
  });
}
