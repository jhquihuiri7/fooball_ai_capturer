// El encuadre a mano de «Una cámara» en el maestro y la vista en vivo (IOS-116, ADR 0033):
// las órdenes `camera/*` contra un nativo falso, los encuadres guardados y el MJPEG.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/api_server.dart';
import 'package:football_ai_capture/src/server/camera_control.dart';
import 'package:football_ai_capture/src/server/match_engine.dart';

class _Reloj implements MatchTimeSource {
  int ms = 0;
  @override
  String get domain => 'soporte1';
  @override
  int nowMs() => ms;
}

const String _pin = '482913';

CameraState _estado({double u = 0.5, double v = 0.5, double zoom = 1, bool moving = false, bool soft = false}) =>
    CameraState(
      centerU: u,
      centerV: v,
      zoom: zoom,
      outline: <double>[u - 0.1, v - 0.1, u + 0.1, v - 0.1, u + 0.1, v + 0.1, u - 0.1, v + 0.1],
      moving: moving,
      soft: soft,
    );

/// La orden nativa campo a campo: un record con una lista no se compara por contenido.
void _esOrden(CameraNativeOrder o, String kind, List<double> values, {bool cut = false}) {
  expect((o.kind, o.cut), (kind, cut));
  expect(o.values, values);
}

/// El nativo de mentira: apunta lo que le piden y contesta lo que se le diga.
class _Nativo {
  final List<CameraNativeOrder> pedidas = <CameraNativeOrder>[];
  bool unaCamara = true;
  String error = '';
  CameraState estado = _estado();

  Future<CameraReply?> call(String kind, List<double> values, bool cut) async {
    pedidas.add((kind: kind, values: values, cut: cut));
    if (!unaCamara) {
      return null;
    }
    if (kind == 'frame' && error.isEmpty) {
      estado = _estado(u: (values[0] + values[2]) / 2, v: (values[1] + values[3]) / 2, zoom: 2.4, moving: !cut, soft: true);
    }
    if (kind == 'goto') {
      estado = _estado(u: values[0], v: values[1], zoom: values[2]);
    }
    return CameraReply(estado, error);
  }
}

void main() {
  group('lo que pide el mando', () {
    CameraPreset? ninguno(String _) => null;

    test('cada orden va a su orden nativa, con el corte', () {
      _esOrden(
        cameraNativeOrder('camera/frame', <String, Object?>{'x0': 0.1, 'y0': 0.2, 'x1': 0.5, 'y1': 0.4}, ninguno),
        'frame',
        <double>[0.1, 0.2, 0.5, 0.4],
      );
      _esOrden(cameraNativeOrder('camera/zoom', <String, Object?>{'factor': 1.25, 'cut': true}, ninguno), 'zoom',
          <double>[1.25], cut: true);
      _esOrden(cameraNativeOrder('camera/pan', <String, Object?>{'dx': -0.1, 'dy': 0}, ninguno), 'pan', <double>[-0.1, 0]);
      expect(cameraNativeOrder('camera/reset', <String, Object?>{}, ninguno).values, <double>[0]);
      expect(cameraNativeOrder('camera/reset', <String, Object?>{'to': 'full'}, ninguno).values, <double>[1]);
      const CameraPreset escenario = CameraPreset(name: 'Escenario', centerU: 0.5, centerV: 0.3, zoom: 2.2);
      _esOrden(
        cameraNativeOrder('camera/preset', <String, Object?>{'name': ' escenario '}, (String n) => n == 'escenario' ? escenario : null),
        'goto',
        <double>[0.5, 0.3, 2.2],
      );
    });

    test('lo mal escrito es un 400; lo que no existe, un 404', () {
      int estado(String name, Map<String, Object?> body) {
        try {
          cameraNativeOrder(name, body, ninguno);
        } on OrderError catch (e) {
          return e.status;
        }
        return 200;
      }

      expect(estado('camera/frame', <String, Object?>{'x0': 0.1, 'y0': 0.2, 'x1': 0.5}), 400);
      expect(estado('camera/frame', <String, Object?>{'x0': 'a', 'y0': 0.2, 'x1': 0.5, 'y1': 1}), 400);
      expect(estado('camera/zoom', <String, Object?>{'factor': double.nan}), 400);
      expect(estado('camera/zoom', <String, Object?>{'factor': 2, 'cut': 'sí'}), 400);
      expect(estado('camera/reset', <String, Object?>{'to': 'medio'}), 400);
      expect(estado('camera/preset', <String, Object?>{'name': ''}), 400);
      expect(estado('camera/preset', <String, Object?>{'name': 'x' * (cameraPresetNameMaxChars + 1)}), 400);
      expect(estado('camera/preset', <String, Object?>{'name': 'Portería'}), 404);
      expect(estado('camera/vuela', <String, Object?>{}), 404);
    });

    test('el estado y el encuadre guardado, en el JSON del ADR', () {
      final Map<String, Object?> j = _estado(u: 0.62, v: 0.48, zoom: 1.6).toJson();
      expect(j['center'], <double>[0.62, 0.48]);
      expect((j['outline']! as List<Object?>).length, 4);
      expect((j['outline']! as List<Object?>).first, <double>[0.52, 0.38]);
      const CameraPreset p = CameraPreset(name: 'Escenario', centerU: 0.5, centerV: 0.35, zoom: 2.2);
      final CameraPreset vuelta = CameraPreset.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(vuelta.toJson(), p.toJson());
      expect(() => CameraPreset.fromJson(<String, Object?>{'name': 'x', 'center': <double>[0.5], 'zoom': 1}),
          throwsFormatException);
    });
  });

  test('la tarjeta Cámara del mando web (IOS-117): las órdenes, la vista en vivo y los atajos', () {
    final String html = File('assets/panel/index.html').readAsStringSync();
    expect(html, contains('id="camara"'));
    for (final String orden in <String>['frame', 'zoom', 'pan', 'reset', 'preset']) {
      expect(html, contains("ordenCamara('$orden'"), reason: orden);
    }
    expect(html, contains("orden('camera/preset_save'"));
    expect(html, contains("orden('camera/preset_delete'"));
    expect(html, contains("orden('camera/' + ruta"));
    expect(html, contains("'/api/v1/rig/live/' + fuente"), reason: 'en la cancha, el MJPEG');
    expect(html, contains("'/api/v1/rig/thumb/overview'"), reason: 'por el VPS, la vista general a pocos fps');
    expect(html, contains("WHEP_PROGRAMA = '/whep/programa'"), reason: 'por el VPS, el programa por WebRTC');
    expect(html, contains('ArrowLeft'));
    expect(html, contains('Restablecer'));
    expect(html, contains('Lente entera'));
    expect(html, contains('setPointerCapture'), reason: 'el recuadro se dibuja con el dedo o el ratón');
  });

  group('en el maestro', () {
    late Directory dir;
    late _Reloj reloj;
    late MatchEngine engine;
    late _Nativo nativo;
    late MasterApi api;
    late MasterApiServer server;
    late HttpClient http;
    late List<Uint8List> miniaturas;

    MatchEngine abrir() => MatchEngine.open(file: File('${dir.path}/match.json'), time: reloj, random: Random(3));

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('ios116');
      reloj = _Reloj();
      engine = abrir();
      nativo = _Nativo();
      miniaturas = <Uint8List>[
        Uint8List.fromList(<int>[0xFF, 0xD8, 1, 2, 3]),
        Uint8List.fromList(<int>[0xFF, 0xD8, 4, 5, 6, 7]),
      ];
      int vuelta = 0;
      api = MasterApi(
        engine: engine,
        monotonicMs: () => reloj.ms,
        wallS: () => 1790000000,
        operatorPin: _pin,
        commandTimeout: const Duration(milliseconds: 200),
        camera: nativo.call,
        live: LiveViews(
          thumbnail: (String fuente) async => miniaturas[min(vuelta++ ~/ 2, miniaturas.length - 1)],
          interval: const Duration(milliseconds: 10),
        ),
      );
      server = await MasterApiServer.start(api, address: InternetAddress.loopbackIPv4, port: 0);
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.close();
      dir.deleteSync(recursive: true);
    });

    Future<(int, Map<String, Object?>)> pedir(String route, Map<String, Object?> body) async {
      final HttpClientRequest r = await http.post('127.0.0.1', server.port, '/api/v1/$route');
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_pin');
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
      final HttpClientResponse res = await r.close();
      final String texto = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(texto) as Map<String, Object?>);
    }

    test('sin «Una cámara» el estado no lleva cámara, y una orden es un 409', () async {
      expect(engine.toJson()['camera'], isNull);
      nativo.unaCamara = false;
      final (int st, Map<String, Object?> j) = await pedir('camera/frame', <String, Object?>{'x0': 0.1, 'y0': 0.1, 'x1': 0.3, 'y1': 0.3});
      expect(st, 409);
      expect(j['detail'], cameraWithoutSingle);
    });

    test('un recuadro va al nativo y el estado lleva cómo queda', () async {
      final int antes = engine.rev;
      final (int st, Map<String, Object?> j) =
          await pedir('camera/frame', <String, Object?>{'x0': 0.6, 'y0': 0.2, 'x1': 0.8, 'y1': 0.4});
      expect(st, 200);
      _esOrden(nativo.pedidas.single, 'frame', <double>[0.6, 0.2, 0.8, 0.4]);
      final Map<String, Object?> camara = j['camera']! as Map<String, Object?>;
      expect(camara['center'], <double>[0.7, 0.30000000000000004]);
      expect((camara['moving'], camara['soft'], camara['zoom']), (true, true, 2.4));
      expect(camara['presets'], isEmpty);
      expect(engine.rev, greaterThan(antes));
    });

    test('lo que el nativo no acepta es un 400 con su porqué', () async {
      nativo.error = 'el recuadro es más pequeño que 0.01 de la vista: 0.002';
      final (int st, Map<String, Object?> j) =
          await pedir('camera/frame', <String, Object?>{'x0': 0.5, 'y0': 0.5, 'x1': 0.502, 'y1': 0.501});
      expect(st, 400);
      expect(j['detail'], nativo.error);
    });

    test('guardar, ir y borrar un encuadre; se guardan con el evento', () async {
      await pedir('camera/frame', <String, Object?>{'x0': 0.4, 'y0': 0.2, 'x1': 0.6, 'y1': 0.4});
      final (int guardado, Map<String, Object?> j) = await pedir('camera/preset_save', <String, Object?>{'name': 'Escenario'});
      expect(guardado, 200);
      final List<Object?> encuadres = (j['camera']! as Map<String, Object?>)['presets']! as List<Object?>;
      expect(encuadres.single, <String, Object?>{'name': 'Escenario', 'center': <double>[0.5, 0.30000000000000004], 'zoom': 2.4});
      expect(nativo.pedidas.last.kind, 'status');

      final (int ido, _) = await pedir('camera/preset', <String, Object?>{'name': 'ESCENARIO', 'cut': true});
      expect(ido, 200);
      _esOrden(nativo.pedidas.last, 'goto', <double>[0.5, 0.30000000000000004, 2.4], cut: true);

      expect(abrir().graphics.cameraPresets.single.name, 'Escenario', reason: 'van con el evento');
      expect((await pedir('camera/preset_delete', <String, Object?>{'name': 'Escenario'})).$1, 200);
      expect((await pedir('camera/preset_delete', <String, Object?>{'name': 'Escenario'})).$1, 404);
      expect(abrir().graphics.cameraPresets, isEmpty);
    });

    test('caben nueve encuadres; el décimo es un 409 y uno con el mismo nombre lo sustituye', () async {
      engine.setCamera(_estado());
      for (int i = 1; i <= cameraPresetsMax; i++) {
        expect((await pedir('camera/preset_save', <String, Object?>{'name': 'E$i'})).$1, 200);
      }
      expect((await pedir('camera/preset_save', <String, Object?>{'name': 'E10'})).$1, 409);
      nativo.estado = _estado(u: 0.2);
      expect((await pedir('camera/preset_save', <String, Object?>{'name': 'e3'})).$1, 200);
      expect(engine.graphics.cameraPresets.length, cameraPresetsMax);
      expect(engine.graphics.cameraPreset('E3')!.centerU, 0.2);
    });

    test('setCamera solo sube rev si cambia, y la cámara no se guarda con el partido', () {
      final int antes = engine.rev;
      engine.setCamera(_estado());
      expect(engine.rev, antes + 1);
      engine.setCamera(_estado());
      expect(engine.rev, antes + 1);
      engine.setCamera(null);
      expect(engine.rev, antes + 2);
      engine.setCamera(_estado());
      expect(abrir().camera, isNull, reason: 'la lleva el nativo');
    });

    group('la vista en vivo', () {
      Future<HttpClientResponse> mirar(String fuente, {String? bearer = _pin}) async {
        final HttpClientRequest r = await http.get('127.0.0.1', server.port, '/api/v1/$cameraLiveRoute/$fuente');
        if (bearer != null) {
          r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
        }
        return r.close();
      }

      test('MJPEG de la vista general: cada miniatura nueva una vez', () async {
        final HttpClientResponse res = await mirar('overview');
        expect(res.statusCode, 200);
        expect(res.headers.contentType!.mimeType, 'multipart/x-mixed-replace');
        final List<int> llegado = <int>[];
        final Completer<void> dos = Completer<void>();
        final StreamSubscription<List<int>> sub = res.listen((List<int> trozo) {
          llegado.addAll(trozo);
          if (latin1.decode(llegado, allowInvalid: true).split('--$cameraLiveBoundary').length > 2 && !dos.isCompleted) {
            dos.complete();
          }
        });
        await dos.future.timeout(const Duration(seconds: 5));
        await sub.cancel();
        final String texto = latin1.decode(llegado, allowInvalid: true);
        final List<String> partes = texto.split('--$cameraLiveBoundary\r\n').where((String p) => p.isNotEmpty).toList();
        expect(partes.first, startsWith('content-type: image/jpeg\r\ncontent-length: 5\r\n\r\n'));
        expect(partes[1], startsWith('content-type: image/jpeg\r\ncontent-length: 6\r\n\r\n'),
            reason: 'la repetida no se manda dos veces');
      });

      test('sin token, 401; una fuente que no hay, 404; dos mandos por fuente y el tercero, 503', () async {
        expect((await mirar('overview', bearer: null)).statusCode, 401);
        final HttpClientResponse uno = await mirar('program');
        final HttpClientResponse dos = await mirar('program');
        expect((uno.statusCode, dos.statusCode), (200, 200));
        final HttpClientResponse tres = await mirar('program');
        expect(tres.statusCode, 503);
        expect(api.live!.viewers('program'), 2);
        expect((await mirar('left')).statusCode, 404, reason: 'en vivo solo la vista general y el programa');
      });
    });
  });
}
