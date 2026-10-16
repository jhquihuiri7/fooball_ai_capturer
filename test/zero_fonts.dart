/// Carga las fuentes de verdad en los tests de pantalla.
///
/// Sin esto, `flutter_test` pinta con su fuente de pruebas, donde cada glifo es un
/// cuadrado del cuerpo entero: «Cámara izquierda» mide el doble que en Archivo, y una
/// comprobación de que algo cabe en 402 px no dice nada del móvil.
library;

import 'dart:io';

import 'package:flutter/services.dart';

Future<void> loadZeroFonts() async {
  const Map<String, List<String>> families = <String, List<String>>{
    'Archivo': <String>['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'],
    'IBM Plex Sans': <String>['Regular', 'Medium', 'SemiBold', 'Bold'],
    'IBM Plex Mono': <String>['Regular', 'Medium', 'SemiBold', 'Bold'],
  };
  const Map<String, String> files = <String, String>{
    'Archivo': 'Archivo',
    'IBM Plex Sans': 'IBMPlexSans',
    'IBM Plex Mono': 'IBMPlexMono',
  };
  for (final MapEntry<String, List<String>> family in families.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String weight in family.value) {
      final File file = File('assets/fonts/${files[family.key]}-$weight.ttf');
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
  // Las del gráfico del programa, la marca Gala Sports (IOS-100): sin ellas el marcador
  // sale en la fuente de pruebas, donde todas las cifras son el mismo cuadrado y un gol
  // no cambia ni un píxel.
  const Map<String, List<String>> marca = <String, List<String>>{
    'Barlow Condensed': <String>[
      'BarlowCondensed-SemiBold.ttf',
      'BarlowCondensed-Bold.ttf',
      'BarlowCondensed-ExtraBold.ttf',
    ],
    'Inter': <String>['Inter-Variable.ttf'],
  };
  for (final MapEntry<String, List<String>> family in marca.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String fichero in family.value) {
      final File file = File('assets/fonts/$fichero');
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
}
