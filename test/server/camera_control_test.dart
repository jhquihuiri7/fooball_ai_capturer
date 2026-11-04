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
  group('con dos cámaras (ADR 0035)', () {
    test('camera/auto devuelve el encuadre al director', () {
      _esOrden(cameraNativeOrder('camera/auto', <String, Object?>{}, (String _) => null), 'auto', <double>[]);
    });

    test('el estado dice panorama y quién encuadra, y con una cámara no cambia nada', () {
      const CameraState una = CameraState(
        centerU: 0.5, centerV: 0.5, zoom: 1, outline: <double>[0, 0, 1, 0, 1, 1, 0, 1], moving: false, soft: false,
      );
      expect(una.toJson().containsKey('panorama'), isFalse);
      expect(una.toJson().containsKey('auto'), isFalse);
      const CameraState dos = CameraState(
        centerU: 0.5, centerV: 0.6, zoom: 1, outline: <double>[0, 0, 1, 0, 1, 1, 0, 1], moving: false, soft: false,
        panorama: true, auto: true,
      );
      expect(dos.toJson()['panorama'], isTrue);
      expect(dos.toJson()['auto'], isTrue);
      expect(dos, isNot(una), reason: 'el cambio de modo sube el estado');
    });

    test('camera/calibrate va al nativo, y cómo va sale en el estado', () {
      _esOrden(cameraNativeOrder('camera/calibrate', <String, Object?>{}, (String _) => null), 'calibrate', <double>[]);
      const CameraState sinPedir = CameraState(
        centerU: 0.5, centerV: 0.6, zoom: 1, outline: <double>[0, 0], moving: false, soft: false, panorama: true,
      );
      expect(sinPedir.toJson().containsKey('calibration'), isFalse);
      const CameraState pedida = CameraState(
        centerU: 0.5, centerV: 0.6, zoom: 1, outline: <double>[0, 0], moving: false, soft: false, panorama: true,
        calibration: '{"state":"solving","detail":"calculando"}',
      );
      expect(pedida.toJson()['calibration'], <String, Object?>{'state': 'solving', 'detail': 'calculando'});
      expect(pedida, isNot(sinPedir), reason: 'el progreso sube el estado');
    });

    test('los planos de la vista general se pueden mirar en vivo', () {
      expect(LiveViews.sources, containsAll(<String>['left', 'right']));
    });
  });

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
    expect(html, contains("tipo === 'volleyball'"), reason: 'el vóley va como el fútbol: también lleva la cámara');
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

  test('el mando en pestañas (IOS-125, ADR 0036): la barra de directo y dónde va cada tarjeta', () {
    // Sin los \r de un checkout de Windows, para que los finales de bloque se encuentren igual.
    final String html = File('assets/panel/index.html').readAsStringSync().replaceAll('\r\n', '\n');
    // El trozo de la página entre `desde` y lo primero de `hasta` que venga detrás.
    String trozo(String desde, List<String> hasta) {
      final int i = html.indexOf(desde);
      expect(i, greaterThanOrEqualTo(0), reason: desde);
      final int fin = hasta.map((String h) => html.indexOf(h, i + desde.length)).where((int j) => j >= 0).reduce(min);
      return html.substring(i, fin);
    }

    final String barra = trozo('id="directo"', <String>['</section>\n']);
    for (final String cosa in <String>['data-gol="home,1"', 'data-gol="away,1"', 'id="reloj"', 'id="toggle"',
        'id="repe-marcar"', 'id="chips"']) {
      expect(barra, contains(cosa), reason: 'en la barra de directo: $cosa');
    }
    final String pestanas = trozo('id="pestanas"', <String>['</nav>']);
    for (final String p in <String>['partido', 'camara', 'anuncios']) {
      expect(pestanas, contains('data-pestana="$p"'));
      expect(html.split('id="panel-$p"').length, 2, reason: 'un panel por pestaña: $p');
    }
    final List<String> fin = <String>['id="panel-', '</main>'];
    final String partido = trozo('id="panel-partido"', fin);
    final String camara = trozo('id="panel-camara"', fin);
    final String anuncios = trozo('id="panel-anuncios"', fin);
    final Map<String, List<String>> donde = <String, List<String>>{
      partido: <String>['t-partidos', 't-rotulos', 't-alin', 't-corregir', 't-pantalla', 't-equipos', 't-jornada',
          't-proximo', 't-entrevista', 't-icono'],
      camara: <String>['t-camara', 't-jugada', 't-voley', 'camaras-programa', 'id="estado"'],
      anuncios: <String>['t-franja', 't-videos'],
    };
    donde.forEach((String panel, List<String> tarjetas) {
      for (final String tarjeta in tarjetas) {
        expect(panel, contains(tarjeta));
      }
    });
    expect(trozo('id="preparar"', <String>['</details>\n  </div>']), contains('t-equipos'),
        reason: 'lo que se rellena antes del partido va plegado');
    expect(partido, contains('data-gol="home,-1"'), reason: 'corregir el marcador, fuera de la barra');
    // La vista en vivo, las miniaturas y los atajos, solo con Cámara delante.
    expect(html, contains("if (pestana === 'camara' && !vivoAbierto && !document.hidden) arrancaVivo();"));
    expect(html, contains("if (document.hidden || pestana !== 'camara') return;"));
    expect(html, contains("if (document.hidden || pestana !== 'camara' || miniaturasEnCurso) return;"));
    expect(html, contains("if (pestana !== 'camara' || !camaraActiva()"));
    expect(html, contains("if (nombre !== 'camara') { paraVivo(); return; }"));
    // Se abre en Partido, y cada navegador recuerda la suya.
    expect(html, contains("PESTANA_INICIAL = 'partido'"));
    expect(html, contains("localStorage.setItem(PESTANA_CLAVE, nombre)"));
  });

  test('las miniaturas del mando a 5 por segundo (IOS-126), y por el VPS como antes', () {
    final String html = File('assets/panel/index.html').readAsStringSync();
    expect(html, contains('const MINIATURAS_MS = 200;'));
    expect(html, contains('setInterval(miniaturas, MINIATURAS_MS)'));
    expect(html, contains('Cámaras y programa · 5 fps'));
    expect(html, contains('const ESTADO_SOPORTE_MS = 1000;'), reason: 'la tarjeta Soporte no necesita más');
    // La subida del maestro lleva el programa: por el VPS, lo de antes.
    expect(html, contains('const GENERAL_REMOTO_MS = 333;'));
    expect(html, contains('const PROGRAMA_REMOTO_MS = 1000;'));
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
        expect((await mirar('nada')).statusCode, 404, reason: 'en vivo solo las fuentes que hay');
      });
    });
  });
}
