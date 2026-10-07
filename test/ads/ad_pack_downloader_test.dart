/// La descarga de los paquetes de anuncios (IOS-49) contra un VPS falso con las rutas de
/// tools/nube/ads.py: Bearer, `Range` con 206 y un corte a mitad de fichero.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/ads/ad_pack_downloader.dart';

import 'ad_pack_fixture.dart';

const String _token = 'rig-key-de-prueba';

/// El VPS falso: sirve el manifiesto de prueba y sus PNG.
class FakeAdServer {
  FakeAdServer._(this._server, this.manifest) {
    _server.listen(_handle);
  }

  static Future<FakeAdServer> start() async =>
      FakeAdServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), fixtureManifest());

  final HttpServer _server;
  final List<int> manifest;

  /// Las cabeceras Range que llegaron, por ruta (null sin Range).
  final List<(String, String?)> requests = <(String, String?)>[];

  /// Ficheros que se cortan a la mitad la próxima vez que se piden.
  final Set<String> cutNext = <String>{};

  /// Si no hace caso de Range (contesta 200 con el fichero entero).
  bool ignoreRange = false;

  /// Si sirve bytes que no son los del manifiesto.
  bool corrupt = false;

  String get sha => sha256Of(manifest);
  Uri get base => Uri.parse('http://${_server.address.host}:${_server.port}');
  Map<String, Object?> get adsChanged => <String, Object?>{
    'type': 'ads_changed',
    'manifest_sha256': sha,
    'url': '/ads/$sha/manifest.json',
  };

  Future<void> _handle(HttpRequest req) async {
    final String? range = req.headers.value(HttpHeaders.rangeHeader);
    requests.add((req.uri.path, range));
    if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $_token') {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    List<int>? body;
    if (req.uri.path == '/ads/$sha/manifest.json') {
      body = manifest;
    }
    for (final List<int> png in fixturePngs) {
      if (req.uri.path == '/ads/$sha/${sha256Of(png)}.png') {
        body = corrupt ? List<int>.filled(png.length, 0) : png;
      }
    }
    if (body == null) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    if (cutNext.remove(req.uri.path)) {
      // Cabeceras del fichero entero, media mitad y se corta la conexión.
      final Socket s = await req.response.detachSocket(writeHeaders: false);
      s.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n'));
      s.add(body.sublist(0, body.length ~/ 2));
      await s.flush();
      s.destroy();
      return;
    }
    int desde = 0;
    if (range != null && !ignoreRange) {
      desde = int.parse(RegExp(r'^bytes=(\d+)-$').firstMatch(range)!.group(1)!);
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $desde-${body.length - 1}/${body.length}');
    }
    req.response.add(body.sublist(desde));
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory root;
  late FakeAdServer vps;
  late AdPackDownloader dl;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ios49');
    vps = await FakeAdServer.start();
    dl = AdPackDownloader(root: root);
  });
  tearDown(() async {
    await vps.close();
    await dl.dispose();
    root.deleteSync(recursive: true);
  });

  void expectComplete(AdPack pack) {
    for (int i = 0; i < fixturePngs.length; i++) {
      expect(File('${root.path}/${pack.files[i].path}').readAsBytesSync(), fixturePngs[i]);
    }
    expect(File('${root.path}/current').readAsStringSync(), vps.sha);
    expect(root.listSync(recursive: true).where((FileSystemEntity e) => e.path.endsWith('.part')), isEmpty);
  }

  test('baja el manifiesto y los PNG con el token, y avisa del paquete', () async {
    final Future<AdPack> aviso = dl.packs.first;
    final AdPack pack = await dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token);
    expect(await aviso, same(pack));
    expect(pack.sha256, vps.sha);
    expect(pack.rotation.map((PackedAd a) => a.name), <String>['a-casa', 'b-promo']);
    expect(pack.event('gol')!.duration, const Duration(seconds: 2));
    expectComplete(pack);
    expect(vps.requests, hasLength(1 + fixturePngs.length));

    // El mismo aviso otra vez (tras cada welcome) no baja nada.
    expect(await dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token), same(pack));
    expect(vps.requests, hasLength(1 + fixturePngs.length));

    // Otro arranque de la app lo encuentra en disco sin red.
    expect(AdPackDownloader(root: root).loadCurrent()?.sha256, vps.sha);
  });

  test('la descarga se reanuda tras un corte con Range', () async {
    final String png = '/ads/${vps.sha}/${sha256Of(fixturePngs[0])}.png';
    vps.cutNext.add(png);
    await expectLater(
      dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token),
      throwsA(isA<IOException>()),
    );
    expect(dl.current, isNull);
    expect(File('${root.path}/current').existsSync(), isFalse, reason: 'un paquete a medias no es vigente');
    final int mitad = fixturePngs[0].length ~/ 2;
    expect(File('${root.path}/blobs/${sha256Of(fixturePngs[0])}.png.part').lengthSync(), mitad);

    final AdPack pack = await dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token);
    expect(vps.requests.where(((String, String?) r) => r.$1 == png).last.$2, 'bytes=$mitad-');
    expectComplete(pack);
  });

  test('un servidor que no hace caso de Range vale: se baja de cero', () async {
    final String png = '/ads/${vps.sha}/${sha256Of(fixturePngs[1])}.png';
    vps
      ..cutNext.add(png)
      ..ignoreRange = true;
    await expectLater(dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token), throwsA(anything));
    expectComplete(await dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token));
  });

  test('un PNG que no es el del manifiesto no se queda', () async {
    vps.corrupt = true;
    await expectLater(
      dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token),
      throwsA(isA<AdPackError>()),
    );
    expect(root.listSync(recursive: true).where((FileSystemEntity e) => e.path.endsWith('.png')), isEmpty);
    vps.corrupt = false;
    expectComplete(await dl.onAdsChanged(vps.adsChanged, base: vps.base, token: _token));
  });

  test('sin token, 401; un manifiesto que no es el del aviso, fuera', () async {
    await expectLater(
      dl.onAdsChanged(vps.adsChanged, base: vps.base, token: 'otro'),
      throwsA(isA<AdPackError>().having((AdPackError e) => e.message, 'message', contains('401'))),
    );
    final String otro = 'a' * 64;
    await expectLater(
      dl.onAdsChanged(<String, Object?>{'manifest_sha256': otro, 'url': '/ads/${vps.sha}/manifest.json'},
          base: vps.base, token: _token),
      throwsA(isA<AdPackError>()),
    );
  });

  test('ads_changed y el manifiesto mal formados se rechazan', () {
    expect(() => AdsChanged.fromJson(<String, Object?>{'manifest_sha256': 'x', 'url': '/a'}), throwsA(isA<AdPackError>()));
    expect(
      () => AdsChanged.fromJson(<String, Object?>{'manifest_sha256': 'a' * 64, 'url': 'https://otro/ads'}),
      throwsA(isA<AdPackError>()),
    );
    final List<int> v2 = utf8.encode(jsonEncode(<String, Object?>{'v': 2, 'files': <Object?>[], 'ads': <Object?>[]}));
    expect(() => AdPack.parse(sha256Of(v2), v2), throwsA(isA<AdPackError>()));
    final List<int> fuera = utf8.encode(
      jsonEncode(<String, Object?>{
        'v': 1,
        'files': <Object?>[],
        'ads': <Object?>[
          <String, Object?>{'name': 'x', 'role': 'rotation', 'fps': 30, 'width': 1, 'height': 1, 'frames': <int>[0]},
        ],
      }),
    );
    expect(() => AdPack.parse(sha256Of(fuera), fuera), throwsA(isA<AdPackError>()));
  });
}
