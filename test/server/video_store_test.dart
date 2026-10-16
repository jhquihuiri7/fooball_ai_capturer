/// Los vídeos del mando (IOS-103, ADR 0027): los nombres, la duración leída del MP4, el
/// tope y la reserva de grabación.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/server/video_store.dart';

import 'mp4_fixture.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('videos_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('los nombres que se aceptan', () {
    for (final String bueno in <String>['anuncio.mp4', 'Gol de Kaká (2).MP4', 'radio_mar-99.1.mp4']) {
      expect(VideoStore.validName(bueno), isTrue, reason: bueno);
    }
    for (final String malo in <String>[
      '.mp4',
      '.oculto.mp4',
      '../fuera.mp4',
      'a/b.mp4',
      'anuncio.mov',
      'anuncio.mp4.subida',
      '${'x' * videoNameMaxChars}.mp4',
    ]) {
      expect(VideoStore.validName(malo), isFalse, reason: malo);
    }
  });

  test('la duración sale del mvhd, con el moov delante o detrás y en las dos versiones', () {
    final File f = File('${dir.path}/a.mp4');
    for (final (int version, bool alFinal) in const <(int, bool)>[(0, true), (0, false), (1, true)]) {
      f.writeAsBytesSync(fakeMp4(durationMs: 31500, version: version, moovAlFinal: alFinal));
      expect(VideoStore.durationMs(f), 31500, reason: 'v$version, al final: $alFinal');
    }
    f.writeAsBytesSync(<int>[0, 0, 0, 8, ...'mdat'.codeUnits, 1, 2, 3]);
    expect(VideoStore.durationMs(f), isNull, reason: 'sin ftyp delante no es MP4');
    f.writeAsBytesSync(fakeMp4().sublist(0, 40));
    expect(VideoStore.durationMs(f), isNull, reason: 'cortado antes del moov');
  });

  test('subir: tope, reserva de grabación y adoptar solo un MP4', () {
    int? libre;
    final VideoStore store = VideoStore(dir, freeBytes: () => libre);
    expect(() => store.checkUpload('../x.mp4', 10), throwsA(isA<VideoError>()));
    expect(
      () => store.checkUpload('a.mp4', videoMaxBytes + 1),
      throwsA(isA<VideoError>().having((VideoError e) => e.status, 'status', 413)),
    );
    store.checkUpload('a.mp4', 1000); // sin saber lo libre, no se comprueba la reserva
    libre = phoneDiskReserveBytes + 500;
    expect(
      () => store.checkUpload('a.mp4', 1000),
      throwsA(isA<VideoError>().having((VideoError e) => e.status, 'status', 507)),
    );
    store.checkUpload('a.mp4', 400);

    store.directory.createSync();
    store.uploadFile('a.mp4').writeAsBytesSync(fakeMp4(durationMs: 9000));
    final VideoInfo info = store.adopt('a.mp4');
    expect((info.name, info.durationMs), ('a.mp4', 9000));
    expect(store.uploadFile('a.mp4').existsSync(), isFalse);

    store.uploadFile('b.mp4').writeAsStringSync('no soy un vídeo');
    expect(() => store.adopt('b.mp4'), throwsA(isA<VideoError>()));
    expect(store.uploadFile('b.mp4').existsSync(), isFalse);

    expect(store.list().map((VideoInfo v) => v.name), <String>['a.mp4']);
    expect(store.find('a.mp4')?.bytes, fakeMp4(durationMs: 9000).length);
    expect(store.delete('a.mp4'), isTrue);
    expect(store.delete('a.mp4'), isFalse);
    expect(store.list(), isEmpty);
  });
}
