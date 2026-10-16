/// Los vídeos MP4 que el operador sube desde el mando para pasarlos en el programa
/// (ADR 0027, decisión 4).
///
/// Viven junto al partido, en `videos/`, y como el icono no se apartan con el partido
/// viejo: un vídeo del patrocinador sirve para todos. Cada uno se escribe a disco por
/// trozos mientras llega, sin pasar entero por la memoria, y solo se adopta si llegó
/// entero, es MP4 y se le lee la duración.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:football_ai_capture/src/constants.dart';

/// Un vídeo que no se acepta, con el código HTTP y el porqué para el mando.
class VideoError implements Exception {
  VideoError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'VideoError($status): $message';
}

/// Un vídeo de la lista: su nombre, lo que ocupa y lo que dura.
class VideoInfo {
  const VideoInfo({required this.name, required this.bytes, required this.durationMs});

  final String name;
  final int bytes;
  final int durationMs;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'bytes': bytes, 'duration_ms': durationMs};
}

class VideoStore {
  /// `freeBytes` dice lo que queda libre en el disco del móvil, o null si no se sabe
  /// (entonces la reserva no se comprueba).
  VideoStore(Directory partido, {int? Function()? freeBytes})
    : directory = Directory('${partido.path}/$videoDirName'),
      _freeBytes = freeBytes ?? (() => null);

  final Directory directory;
  final int? Function() _freeBytes;

  /// Letras, cifras, espacios y `._()-`, sin barras ni puntos al principio, y `.mp4`.
  static final RegExp _nombre = RegExp(
    r'^[\p{L}\p{N}][\p{L}\p{N} ._()\-]{0,' '${videoNameMaxChars - 5}' r'}\.mp4$',
    unicode: true,
    caseSensitive: false,
  );

  /// Si `name` es un nombre de vídeo que se puede guardar.
  static bool validName(String name) => _nombre.hasMatch(name);

  File file(String name) => File('${directory.path}/$name');

  /// Dónde se escribe la subida de `name` mientras llega.
  File uploadFile(String name) => File('${directory.path}/$name$videoUploadSuffix');

  /// Los vídeos guardados, por nombre. Uno que no se puede leer no sale.
  List<VideoInfo> list() {
    if (!directory.existsSync()) {
      return const <VideoInfo>[];
    }
    final List<VideoInfo> videos = <VideoInfo>[];
    for (final FileSystemEntity e in directory.listSync()) {
      final String nombre = e.uri.pathSegments.last;
      if (e is! File || !validName(nombre)) {
        continue;
      }
      final int? ms = durationMs(e);
      if (ms != null) {
        videos.add(VideoInfo(name: nombre, bytes: e.lengthSync(), durationMs: ms));
      }
    }
    return videos..sort((VideoInfo a, VideoInfo b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// El vídeo `name` si existe y se puede leer; null si no.
  VideoInfo? find(String name) {
    if (!validName(name)) {
      return null;
    }
    final File f = file(name);
    final int? ms = f.existsSync() ? durationMs(f) : null;
    return ms == null ? null : VideoInfo(name: name, bytes: f.lengthSync(), durationMs: ms);
  }

  /// Lo que se comprueba antes de leer el cuerpo de una subida de `bytes` (el
  /// Content-Length, o -1 si no lo trae): el nombre, el tope y la reserva de grabación
  /// (`phoneDiskReserveBytes`).
  void checkUpload(String name, int bytes) {
    if (!validName(name)) {
      throw VideoError(
        HttpStatus.badRequest,
        'el nombre: hasta $videoNameMaxChars letras, cifras, espacios o ._()- y que acabe en .mp4',
      );
    }
    if (bytes > videoMaxBytes) {
      throw VideoError(HttpStatus.requestEntityTooLarge, 'el vídeo pasa de ${videoMaxBytes ~/ (1 << 30)} GB');
    }
    // La reserva de la 4K local (IOS-57): un vídeo no puede quitarle sitio al partido.
    final int? libre = _freeBytes();
    if (libre != null && libre - (bytes < 0 ? 0 : bytes) < phoneDiskReserveBytes) {
      throw VideoError(
        HttpStatus.insufficientStorage,
        'no hay sitio: el vídeo dejaría menos de ${phoneDiskReserveBytes ~/ 1000000000} GB para grabar el partido',
      );
    }
  }

  /// Adopta la subida de `name` si es un MP4 que se lee; la borra y lanza [VideoError]
  /// si no.
  VideoInfo adopt(String name) {
    final File subida = uploadFile(name);
    final int? ms = durationMs(subida);
    if (ms == null) {
      subida.deleteSync();
      throw VideoError(HttpStatus.unsupportedMediaType, 'no es un MP4 que se pueda leer');
    }
    final int bytes = subida.lengthSync();
    subida.renameSync(file(name).path);
    return VideoInfo(name: name, bytes: bytes, durationMs: ms);
  }

  /// Borra `name`; false si no existía.
  bool delete(String name) {
    final File f = file(name);
    if (!validName(name) || !f.existsSync()) {
      return false;
    }
    f.deleteSync();
    return true;
  }

  /// La duración en ms de un MP4, de su `moov/mvhd`; null si no empieza por `ftyp` o no
  /// se encuentra. Solo lee las cabeceras de las cajas: el `moov` puede ir al final.
  static int? durationMs(File f) {
    RandomAccessFile? raf;
    try {
      raf = f.openSync();
      final int fin = raf.lengthSync();
      int pos = 0;
      bool primera = true;
      while (pos + 8 <= fin) {
        final (String tipo, int cabecera, int tam) = _box(raf, pos, fin);
        if (tam < cabecera) {
          return null;
        }
        if (primera && tipo != 'ftyp') {
          return null;
        }
        primera = false;
        if (tipo == 'moov') {
          return _mvhd(raf, pos + cabecera, pos + tam);
        }
        pos += tam;
      }
      return null;
    } on FileSystemException {
      return null;
    } finally {
      raf?.closeSync();
    }
  }

  /// Busca `mvhd` entre `desde` y `hasta` (el contenido de `moov`).
  static int? _mvhd(RandomAccessFile raf, int desde, int hasta) {
    int pos = desde;
    while (pos + 8 <= hasta) {
      final (String tipo, int cabecera, int tam) = _box(raf, pos, hasta);
      if (tam < cabecera) {
        return null;
      }
      if (tipo == 'mvhd') {
        raf.setPositionSync(pos + cabecera);
        final ByteData d = ByteData.sublistView(raf.readSync(32));
        if (d.lengthInBytes < 32) {
          return null;
        }
        final int version = d.getUint8(0);
        // v0: versión y flags (4), creación y modificación (4 + 4), escala y duración (4 + 4).
        // v1: lo mismo con creación, modificación y duración de 8 bytes.
        final int escala = version == 1 ? d.getUint32(20) : d.getUint32(12);
        final int duracion = version == 1 ? d.getUint64(24) : d.getUint32(16);
        return escala == 0 ? null : duracion * Duration.millisecondsPerSecond ~/ escala;
      }
      pos += tam;
    }
    return null;
  }

  /// El tipo, el tamaño de la cabecera y el de la caja que empieza en `pos`; el tamaño 0
  /// es «hasta el final».
  static (String, int, int) _box(RandomAccessFile raf, int pos, int fin) {
    raf.setPositionSync(pos);
    final Uint8List h = raf.readSync(16);
    final ByteData d = ByteData.sublistView(h);
    final String tipo = String.fromCharCodes(h.sublist(4, 8));
    final int tam = d.getUint32(0);
    if (tam == 1) {
      return h.length < 16 ? (tipo, 16, 0) : (tipo, 16, d.getUint64(8));
    }
    return (tipo, 8, tam == 0 ? fin - pos : tam);
  }
}
