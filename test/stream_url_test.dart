import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/stream_url.dart';

void main() {
  group('buildStreamUrl', () {
    test('sin servidor no hay URL: solo se graba', () {
      expect(buildStreamUrl('', CameraRole.left), '');
      expect(buildStreamUrl('   ', CameraRole.left), '');
    });

    test('un host pelado es SRT, con el búfer de Starlink y un canal por lado', () {
      expect(
        buildStreamUrl('10.10.18.100', CameraRole.left),
        'srt://10.10.18.100:8890?streamid=publish:rig/izquierda&latency=1000',
      );
      expect(
        buildStreamUrl('pod.football.ai:9000', CameraRole.right),
        'srt://pod.football.ai:9000?streamid=publish:rig/derecha&latency=1000',
      );
    });

    test('RTMP lleva el canal en la ruta, con dos niveles', () {
      // Con un solo nivel el cliente RTMP parte mal la URL y no conecta.
      expect(
        buildStreamUrl('rtmp://203.0.113.5:17890', CameraRole.left),
        'rtmp://203.0.113.5:17890/rig/izquierda',
      );
      expect(buildStreamUrl('rtmp://10.0.0.5', CameraRole.right), 'rtmp://10.0.0.5:1935/rig/derecha');
      expect(buildStreamUrl('rtmps://pod.ejemplo.com', CameraRole.left),
          'rtmps://pod.ejemplo.com:443/rig/izquierda');
    });

    test('las credenciales se traducen a lo que espera MediaMTX en cada protocolo', () {
      expect(
        buildStreamUrl('rtmp://cam:s3creto@203.0.113.5:17890', CameraRole.left),
        'rtmp://203.0.113.5:17890/rig/izquierda?user=cam&pass=s3creto',
      );
      expect(
        buildStreamUrl('srt://cam:s3creto@relay.ejemplo.com', CameraRole.right),
        'srt://relay.ejemplo.com:8890?streamid=publish:rig/derecha:cam:s3creto&latency=1000',
      );
    });

    test('un esquema que no se sabe emitir no produce URL', () {
      expect(buildStreamUrl('http://ejemplo.com', CameraRole.left), '');
    });
  });

  test('en pantalla se enseña protocolo y host, nunca la clave', () {
    expect(describeStreamTarget('rtmp://cam:s3creto@203.0.113.5:17890'), 'RTMP a 203.0.113.5');
    expect(describeStreamTarget('10.10.18.100'), 'SRT a 10.10.18.100');
  });
}
