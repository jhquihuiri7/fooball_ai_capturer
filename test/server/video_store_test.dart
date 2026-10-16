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

  test('la reserva es la de lo que el partido va a grabar', () {
    int? libre;
    bool cuatroK = true;
    final VideoStore store = VideoStore(dir, freeBytes: () => libre, localRecording: () => cuatroK);
    Matcher sinSitio(String dice) => throwsA(
      isA<VideoError>()
          .having((VideoError e) => e.status, 'status', 507)
          .having((VideoError e) => e.message, 'message', contains(dice)),
    );
    const int gb = 1000 * 1000 * 1000;
    store.checkUpload('a.mp4', 900 * 1000 * 1000); // sin saber lo libre, no se comprueba

    // La 4K encendida y con sitio: el vídeo no puede dejarla sin sus 40 GB.
    libre = phoneDiskReserveBytes + gb;
    store.checkUpload('a.mp4', gb);
    expect(() => store.checkUpload('a.mp4', gb + 1), sinSitio('Guardar vídeo'));

    // La 4K apagada: basta con la copia del programa.
    cuatroK = false;
    store.checkUpload('a.mp4', videoMaxBytes);

    // Encendida pero sin sus 40 GB: no va a grabar, así que tampoco cuenta (el caso del
    // 2026-10-16, un iPhone con menos de 40 GB libres que no dejaba subir nada).
    cuatroK = true;
    libre = 30 * gb;
    store.checkUpload('a.mp4', videoMaxBytes);
    libre = videoMinFreeAfterBytes + 500;
    store.checkUpload('a.mp4', 500);
    expect(() => store.checkUpload('a.mp4', 501), sinSitio('copia del programa'));
  });

  test('subir: tope y adoptar solo un MP4', () {
    final VideoStore store = VideoStore(dir);
    expect(() => store.checkUpload('../x.mp4', 10), throwsA(isA<VideoError>()));
    expect(
      () => store.checkUpload('a.mp4', videoMaxBytes + 1),
      throwsA(isA<VideoError>().having((VideoError e) => e.status, 'status', 413)),
    );

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
