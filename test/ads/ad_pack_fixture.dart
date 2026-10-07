/// Paquetes de anuncios de prueba, con la forma del manifiesto v1 de tools/nube/ads.py.
library;

import 'dart:convert';

import 'package:football_ai_capture/src/ads/ad_pack_downloader.dart';

/// Unos «PNG» de prueba: el downloader solo mira bytes y sha256.
final List<List<int>> fixturePngs = <List<int>>[
  List<int>.generate(5000, (int i) => i % 251),
  List<int>.generate(3000, (int i) => (i * 7) % 253),
];

/// Un manifiesto con `promo` (rotación, 3 fotogramas a 30 fps) y `gol` (evento, 60
/// fotogramas a 30 fps: 2 s la vuelta), y sus bytes.
List<int> fixtureManifest() => utf8.encode(
  jsonEncode(<String, Object?>{
    'ads': <Object?>[
      <String, Object?>{'fps': 30, 'frames': <int>[0, 0, 1], 'height': 108, 'name': 'b-promo', 'role': 'rotation', 'width': 1920},
      <String, Object?>{'fps': 30, 'frames': List<int>.filled(60, 1), 'height': 108, 'name': 'gol', 'role': 'event', 'width': 1920},
      <String, Object?>{'fps': 25, 'frames': <int>[1], 'height': 108, 'name': 'a-casa', 'role': 'rotation', 'width': 1920},
    ],
    'files': <Object?>[
      for (final List<int> png in fixturePngs) <String, Object?>{'bytes': png.length, 'sha256': sha256Of(png)},
    ],
    'v': 1,
  }),
);

AdPack fixturePack() {
  final List<int> bytes = fixtureManifest();
  return AdPack.parse(sha256Of(bytes), bytes);
}
