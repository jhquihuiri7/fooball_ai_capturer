/// Los paquetes de anuncios del VPS (IOS-49, ADR 0022 §6 y la nota de NUBE-17).
///
/// El VPS publica los anuncios por contenido: un manifiesto v1
/// `{v, files [{sha256, bytes}], ads [{name, role, fps, width, height, frames}]}`, con
/// `frames` como índices en `files`, y cada PNG distinto una sola vez. Se baja a
/// `Documents/ads/` con la misma forma:
/// - `blobs/<sha256>.png`, cada PNG ya comprobado; mientras baja es `<sha256>.png.part`,
///   y una descarga cortada sigue donde iba con `Range`;
/// - `manifests/<sha256>.json`, el manifiesto con sus bytes de origen;
/// - `current`, el sha256 del último paquete completo, que se escribe el último: la app
///   arranca con él aunque la cancha no tenga red.
///
/// La entrada es `ads_changed {manifest_sha256, url}` del túnel; quien lo recibe (IOS-65)
/// llama a [AdPackDownloader.onAdsChanged] con la base del VPS y el token del soporte.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:football_ai_capture/src/constants.dart';

const String _blobsDir = 'blobs';
const String _manifestsDir = 'manifests';
const String _currentFile = 'current';
const String _partSuffix = '.part';

/// `role` de un anuncio que entra en la rotación.
const String adRoleRotation = 'rotation';

/// `role` de un anuncio que solo sale con su evento (`gol`, `medio-tiempo`, `arranque`).
const String adRoleEvent = 'event';

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// El paquete no vale o no se pudo bajar; el mensaje dice por qué.
class AdPackError implements Exception {
  AdPackError(this.message);

  final String message;

  @override
  String toString() => 'AdPackError: $message';
}

/// Un PNG del paquete.
class AdFile {
  const AdFile(this.sha256, this.bytes);

  final String sha256;
  final int bytes;

  /// Dónde queda, relativo a `Documents/ads/`.
  String get path => '$_blobsDir/$sha256.png';
}

/// Un anuncio del manifiesto.
class PackedAd {
  const PackedAd({
    required this.name,
    required this.role,
    required this.fps,
    required this.width,
    required this.height,
    required this.frames,
  });

  final String name;
  final String role;
  final int fps;
  final int width;
  final int height;

  /// Un índice en [AdPack.files] por fotograma.
  final List<int> frames;

  bool get isEvent => role == adRoleEvent;

  /// Lo que dura una vuelta, a su cadencia.
  Duration get duration => Duration(microseconds: frames.length * Duration.microsecondsPerSecond ~/ fps);
}

/// Un manifiesto v1 ya leído y comprobado.
class AdPack {
  const AdPack({required this.sha256, required this.files, required this.ads});

  /// Lee los bytes de un manifiesto y comprueba que son los de `sha256`.
  factory AdPack.parse(String sha256, List<int> bytes) {
    if (sha256Of(bytes) != sha256) {
      throw AdPackError('el manifiesto no es el $sha256');
    }
    final Object? doc;
    try {
      doc = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw AdPackError('manifiesto ilegible: ${error.message}');
    }
    if (doc is! Map<String, Object?> || doc['v'] != adManifestVersion) {
      throw AdPackError('el manifiesto no es v$adManifestVersion');
    }
    final List<AdFile> files = <AdFile>[
      for (final Object? f in _list(doc['files'], 'files'))
        if (f is Map<String, Object?> && f['sha256'] is String && _sha256Hex.hasMatch(f['sha256']! as String))
          AdFile(f['sha256']! as String, _int(f['bytes'], 'bytes'))
        else
          throw AdPackError('fichero mal descrito: $f'),
    ];
    final List<PackedAd> ads = <PackedAd>[];
    for (final Object? a in _list(doc['ads'], 'ads')) {
      if (a is! Map<String, Object?> || a['name'] is! String) {
        throw AdPackError('anuncio mal descrito: $a');
      }
      final String role = a['role'] is String ? a['role']! as String : '';
      if (role != adRoleRotation && role != adRoleEvent) {
        throw AdPackError('${a['name']}: role $role');
      }
      final List<int> frames = <int>[for (final Object? i in _list(a['frames'], 'frames')) _int(i, 'frames')];
      if (frames.isEmpty || frames.any((int i) => i >= files.length)) {
        throw AdPackError('${a['name']}: fotogramas fuera de files');
      }
      final int fps = _int(a['fps'], 'fps');
      if (fps == 0) {
        throw AdPackError('${a['name']}: 0 fps');
      }
      ads.add(
        PackedAd(
          name: a['name']! as String,
          role: role,
          fps: fps,
          width: _int(a['width'], 'width'),
          height: _int(a['height'], 'height'),
          frames: frames,
        ),
      );
    }
    return AdPack(sha256: sha256, files: files, ads: ads);
  }

  final String sha256;
  final List<AdFile> files;
  final List<PackedAd> ads;

  /// La rotación, por orden alfabético (como `ad_director.load_ad_directory`).
  List<PackedAd> get rotation =>
      ads.where((PackedAd a) => !a.isEvent).toList()..sort((PackedAd a, PackedAd b) => a.name.compareTo(b.name));

  /// El anuncio de evento `name`, si se vendió.
  PackedAd? event(String name) {
    for (final PackedAd a in ads) {
      if (a.isEvent && a.name == name) {
        return a;
      }
    }
    return null;
  }

  /// Los PNG de cada fotograma de `ad`, relativos a `Documents/ads/`.
  List<String> framePaths(PackedAd ad) => <String>[for (final int i in ad.frames) files[i].path];
}

List<Object?> _list(Object? value, String name) {
  if (value is! List<Object?>) {
    throw AdPackError('$name no es una lista');
  }
  return value;
}

int _int(Object? value, String name) {
  if (value is! int || value < 0) {
    throw AdPackError('$name tiene que ser un entero no negativo');
  }
  return value;
}

/// El sha256 en hexadecimal de unos bytes.
String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// `ads_changed` del túnel (ADR 0022 §5): el manifiesto vigente y su ruta en el VPS.
class AdsChanged {
  const AdsChanged(this.manifestSha256, this.url);

  /// Lee el mensaje; la `url` es una ruta absoluta del mismo dominio.
  factory AdsChanged.fromJson(Map<String, Object?> message) {
    final Object? sha = message['manifest_sha256'];
    final Object? url = message['url'];
    if (sha is! String || !_sha256Hex.hasMatch(sha) || url is! String || !url.startsWith('/') || url.startsWith('//')) {
      throw AdPackError('ads_changed mal formado: $message');
    }
    return AdsChanged(sha, url);
  }

  final String manifestSha256;
  final String url;
}

/// Baja los paquetes a `Documents/ads/` y avisa de cada uno completo.
class AdPackDownloader {
  AdPackDownloader({required this.root, HttpClient Function()? client}) : _client = client ?? HttpClient.new;

  /// `Documents/ads/`.
  final Directory root;
  final HttpClient Function() _client;
  final StreamController<AdPack> _packs = StreamController<AdPack>.broadcast();
  Future<void> _tail = Future<void>.value();

  /// El último paquete completo, o null.
  AdPack? current;

  /// Cada paquete que queda completo en disco.
  Stream<AdPack> get packs => _packs.stream;

  /// El paquete que quedó completo la última vez, sin red: lee `current`. null si no hay
  /// o le falta algo (se vuelve a bajar con el siguiente `ads_changed`).
  AdPack? loadCurrent() {
    try {
      final String sha = File('${root.path}/$_currentFile').readAsStringSync().trim();
      final AdPack pack = AdPack.parse(sha, File(_manifestPath(sha)).readAsBytesSync());
      final bool completo = pack.files.every((AdFile f) {
        final File png = File('${root.path}/${f.path}');
        return png.existsSync() && png.lengthSync() == f.bytes;
      });
      return current = completo ? pack : null;
    } on FileSystemException {
      return null;
    } on AdPackError {
      return null;
    }
  }

  /// Atiende un `ads_changed`: baja lo que falte y deja el paquete como vigente. Los
  /// avisos se atienden de uno en uno y en orden; uno que repite el vigente no baja nada.
  /// Lanza [AdPackError] o [IOException] si la descarga no termina: lo bajado se queda y
  /// el siguiente aviso (el que manda el VPS tras cada `welcome`) sigue donde iba.
  Future<AdPack> onAdsChanged(Map<String, Object?> message, {required Uri base, required String token}) {
    final AdsChanged aviso = AdsChanged.fromJson(message);
    final Future<AdPack> hecho = _tail.then((_) => _fetch(aviso, base, token));
    _tail = hecho.then<void>((_) {}, onError: (Object _) {});
    return hecho;
  }

  Future<AdPack> _fetch(AdsChanged aviso, Uri base, String token) async {
    final AdPack? vigente = current;
    if (vigente != null && vigente.sha256 == aviso.manifestSha256) {
      return vigente;
    }
    final HttpClient client = _client()..connectionTimeout = adDownloadTimeout;
    try {
      final List<int> bytes = <int>[];
      await _get(client, base.resolve(aviso.url), token, 0, bytes.addAll);
      final AdPack pack = AdPack.parse(aviso.manifestSha256, bytes);
      _writeAtomic(File(_manifestPath(pack.sha256)), bytes);
      final String carpeta = aviso.url.substring(0, aviso.url.lastIndexOf('/') + 1);
      for (final AdFile f in pack.files) {
        await _blob(client, base.resolve('$carpeta${f.sha256}.png'), token, f);
      }
      _writeAtomic(File('${root.path}/$_currentFile'), utf8.encode(pack.sha256));
      current = pack;
      _packs.add(pack);
      return pack;
    } finally {
      client.close(force: true);
    }
  }

  /// Un PNG: si ya está, nada; si quedó a medias, sigue desde ahí.
  Future<void> _blob(HttpClient client, Uri uri, String token, AdFile f) async {
    final File hecho = File('${root.path}/${f.path}');
    if (hecho.existsSync() && hecho.lengthSync() == f.bytes) {
      return;
    }
    final File parte = File('${hecho.path}$_partSuffix');
    hecho.parent.createSync(recursive: true);
    int desde = parte.existsSync() ? parte.lengthSync() : 0;
    if (desde > f.bytes) {
      parte.deleteSync();
      desde = 0;
    }
    if (desde < f.bytes) {
      RandomAccessFile? destino;
      try {
        await _get(client, uri, token, desde, (List<int> trozo) => destino!.writeFromSync(trozo), onStatus: (int s) {
          // 200 es el fichero entero (el servidor no hizo caso del Range): de cero.
          destino = parte.openSync(mode: s == HttpStatus.partialContent ? FileMode.append : FileMode.write);
        });
      } finally {
        destino?.closeSync();
      }
    }
    if (parte.lengthSync() != f.bytes || sha256Of(parte.readAsBytesSync()) != f.sha256) {
      parte.deleteSync();
      throw AdPackError('${f.sha256}.png no es el que nombra el manifiesto');
    }
    parte.renameSync(hecho.path);
  }

  /// GET con el token del soporte y, si `from` > 0, `Range: bytes=from-`.
  Future<void> _get(
    HttpClient client,
    Uri uri,
    String token,
    int from,
    void Function(List<int>) sink, {
    void Function(int status)? onStatus,
  }) async {
    final HttpClientRequest req = await client.getUrl(uri).timeout(adDownloadTimeout);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (from > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    }
    final HttpClientResponse res = await req.close().timeout(adDownloadTimeout);
    if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
      await res.drain<void>();
      throw AdPackError('GET ${uri.path}: HTTP ${res.statusCode}');
    }
    onStatus?.call(res.statusCode);
    await for (final List<int> trozo in res.timeout(adDownloadTimeout)) {
      sink(trozo);
    }
  }

  String _manifestPath(String sha) => '${root.path}/$_manifestsDir/$sha.json';

  void _writeAtomic(File file, List<int> bytes) {
    file.parent.createSync(recursive: true);
    final File tmp = File('${file.path}.tmp')..writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
  }

  Future<void> dispose() => _packs.close();
}
