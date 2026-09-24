/// La subida de la grabación para calibrar, contra un panel de mentira en el propio test.
///
/// El panel falso habla el mismo protocolo que `tools/rig_recordings.py`: trozos con su
/// desplazamiento, 409 con dónde se quedó, `finish` al final. Lo que se prueba es lo que
/// pasa por Starlink: que un corte no obligue a empezar de cero ni deje basura.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/calibration_upload.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// Un panel mínimo que recibe una grabación por lado.
class _FakePanel {
  _FakePanel._(this._server);

  static Future<_FakePanel> start({
    String user = 'camara',
    String password = 'clave',
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakePanel panel = _FakePanel._(server)
      .._auth = 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
    server.listen(panel._handle);
    return panel;
  }

  final HttpServer _server;
  late String _auth;
  final Map<String, List<int>> received = <String, List<int>>{};
  final Set<String> finished = <String>{};

  /// Cuántos trozos se cortan a propósito antes de aceptarlos (simula Starlink).
  int dropNext = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final List<int> body = await request.fold<List<int>>(
      <int>[],
      (List<int> a, List<int> b) => a..addAll(b),
    );
    final HttpResponse response = request.response;
    if (request.headers.value(HttpHeaders.authorizationHeader) != _auth) {
      response.statusCode = HttpStatus.unauthorized;
      await response.close();
      return;
    }
    final String side = request.uri.queryParameters['side']!;
    final List<int> data = received.putIfAbsent(side, () => <int>[]);
    Map<String, Object?> reply;
    if (request.method == 'GET') {
      reply = <String, Object?>{
        'bytes': data.length,
        'done': finished.contains(side),
      };
    } else if (request.uri.queryParameters.containsKey('finish')) {
      finished.add(side);
      reply = <String, Object?>{
        'ok': true,
        'done': true,
        'calibrating': finished.length == 2,
      };
    } else {
      final int offset = int.parse(request.uri.queryParameters['offset']!);
      if (dropNext > 0) {
        dropNext--;
        // Se corta con el trozo ya leído: el cliente no sabe si llegó.
        await request.response.detachSocket().then((Socket s) => s.destroy());
        return;
      }
      if (offset == 0) {
        data.clear();
      } else if (offset != data.length) {
        response.statusCode = HttpStatus.conflict;
        response.write(
          jsonEncode(<String, Object?>{'ok': false, 'bytes': data.length}),
        );
        await response.close();
        return;
      }
      data.addAll(body);
      reply = <String, Object?>{'ok': true, 'bytes': data.length};
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(reply));
    await response.close();
  }
}

Future<File> _file(Directory dir, int size) async {
  final File file = File('${dir.path}/left-1.mov');
  await file.writeAsBytes(List<int>.generate(size, (int i) => i % 251));
  return file;
}

void main() {
  group('dónde está el panel', () {
    test('en un pod viene en el QR, porque va por el proxy de RunPod', () {
      const String qr =
          'rtmp://camara:clave@47.47.180.23:17377?panel=https://abc-8090.proxy.runpod.net';

      expect(panelUriFrom(qr), Uri.parse('https://abc-8090.proxy.runpod.net'));
    });

    test('sin eso es el servidor de la cancha, con el panel en su puerto', () {
      expect(
        panelUriFrom('192.168.1.20'),
        Uri.parse('http://192.168.1.20:8090'),
      );
      expect(
        panelUriFrom('rtmp://mac.local:1935'),
        Uri.parse('http://mac.local:8090'),
      );
    });

    test('sin servidor no hay panel', () {
      expect(panelUriFrom(''), isNull);
      expect(panelUriFrom('rtmp://h:1?panel=ftp://raro'), isNull);
    });

    test('las credenciales son las de las cámaras, del mismo campo', () {
      expect(
        cameraCredentialsFrom('rtmp://camara:cl%40ve@h:1?panel=https://p'),
        (user: 'camara', password: 'cl@ve'),
      );
      expect(cameraCredentialsFrom('rtmp://h:1'), isNull);
    });
  });

  group('la subida', () {
    late _FakePanel panel;
    late Directory dir;

    setUp(() async {
      panel = await _FakePanel.start();
      dir = await Directory.systemTemp.createTemp('subida');
    });

    tearDown(() async {
      await panel.close();
      await dir.delete(recursive: true);
    });

    CalibrationUploader uploader(
      CameraRole role, {
      String password = 'clave',
    }) => CalibrationUploader(
      panel: panel.uri,
      role: role,
      credentials: (user: 'camara', password: password),
      chunkBytes: 1000,
      retryDelay: Duration.zero,
    );

    test('llega entera, por trozos, y se avisa del progreso', () async {
      final File file = await _file(dir, 3500);
      final List<int> progress = <int>[];

      final bool calibrating = await uploader(
        CameraRole.left,
      ).upload(file, onProgress: (int sent, int total) => progress.add(sent));

      expect(panel.received['left'], await file.readAsBytes());
      expect(progress, <int>[1000, 2000, 3000, 3500]);
      expect(panel.finished, <String>{'left'});
      expect(calibrating, isFalse); // falta la del otro móvil
    });

    test('con la segunda, el panel se pone a calibrar', () async {
      await uploader(CameraRole.left).upload(await _file(dir, 1500));
      final File right = File('${dir.path}/right-1.mov')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      expect(await uploader(CameraRole.right).upload(right), isTrue);
    });

    test('un corte no obliga a empezar de cero', () async {
      // Starlink corta dos trozos seguidos: se pregunta dónde se quedó y se sigue.
      final File file = await _file(dir, 3500);
      panel.dropNext = 2;

      await uploader(CameraRole.left).upload(file);

      expect(panel.received['left'], await file.readAsBytes());
    });

    test(
      'con la clave mal se dice que hay que volver a escanear el QR',
      () async {
        final File file = await _file(dir, 10);

        expect(
          () => uploader(CameraRole.left, password: 'otra').upload(file),
          throwsA(
            isA<CalibrationUploadException>().having(
              (CalibrationUploadException e) => e.message,
              'message',
              contains('QR'),
            ),
          ),
        );
      },
    );

    test('una grabación vacía no se sube', () async {
      final File empty = File('${dir.path}/vacia.mov')
        ..writeAsBytesSync(<int>[]);

      expect(
        () => uploader(CameraRole.left).upload(empty),
        throwsA(isA<CalibrationUploadException>()),
      );
    });
  });
}
