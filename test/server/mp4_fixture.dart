/// Un MP4 mínimo para los tests de los vídeos (ADR 0027): las cajas que mira
/// `VideoStore.durationMs`, sin imagen de verdad.
library;

import 'dart:typed_data';

List<int> _box(String tipo, List<int> cuerpo) {
  final ByteData cabecera = ByteData(8)..setUint32(0, 8 + cuerpo.length);
  return <int>[...cabecera.buffer.asUint8List(0, 4), ...tipo.codeUnits, ...cuerpo];
}

/// `ftyp`, un `mdat` de `mdatBytes` y el `moov` con su `mvhd` (versión 0 o 1); el `moov`
/// al final si `moovAlFinal`, como lo deja una cámara sin `faststart`.
Uint8List fakeMp4({
  int durationMs = 12000,
  int timescale = 600,
  int version = 0,
  int mdatBytes = 64,
  bool moovAlFinal = true,
}) {
  final int duracion = durationMs * timescale ~/ 1000;
  final ByteData mvhd = ByteData(version == 1 ? 32 : 20);
  mvhd.setUint8(0, version);
  if (version == 1) {
    mvhd
      ..setUint32(20, timescale)
      ..setUint64(24, duracion);
  } else {
    mvhd
      ..setUint32(12, timescale)
      ..setUint32(16, duracion);
  }
  final List<int> moov = _box('moov', _box('mvhd', <int>[...mvhd.buffer.asUint8List(), ...List<int>.filled(80, 0)]));
  final List<int> ftyp = _box('ftyp', <int>[...'isom'.codeUnits, 0, 0, 2, 0, ...'isomiso2avc1mp41'.codeUnits]);
  final List<int> mdat = _box('mdat', List<int>.filled(mdatBytes, 0x55));
  return Uint8List.fromList(<int>[...ftyp, if (!moovAlFinal) ...moov, ...mdat, if (moovAlFinal) ...moov]);
}
