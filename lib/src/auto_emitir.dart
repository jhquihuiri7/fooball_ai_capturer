/// EMITIR sin tocar la pantalla (modo de prueba): el camino de producción de los toques,
/// lanzado desde el Mac con dart-defines para dejar los dos iPhone emitiendo sin nadie
/// delante (`tools/emitir_auto.sh`).
///
/// No es el banco split (`RIG_SPLIT`): no hay `SplitBench` ni entorno de banco. Es la misma
/// `CaptureSession` que abre «Abrir cámara», con el enlace de la tarjeta «Enlace y emisión»,
/// y en el maestro la misma llamada que el botón EMITIR (`toggleRecording`) y que PARAR. El
/// esclavo no hace nada: arranca y para por la orden del maestro, como en producción.
///
/// Sin `AUTO_EMITIR`, nada de esto se crea y la app es la de siempre.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';

/// Cuánto se espera a LISTA en el maestro antes de rendirse y decir por qué: Aware tarda
/// en subir (en el banco, hasta ~100 s tras lanzar el segundo móvil).
const Duration autoEmitirReadyTimeout = Duration(minutes: 5);

/// Lo que se deja al esclavo, con el enlace ya conectado, para su reloj y su fase antes
/// de mandarle la orden. El maestro no ve la fase del esclavo; con el dedo, el operador
/// mira LISTA en las dos pantallas. Medido en el banco: reloj y fase en ~5-10 s.
const Duration autoEmitirSlaveSettle = Duration(seconds: 20);

/// Cómo se configura (dart-defines `AUTO_EMITIR*`, ver `main.dart`).
@immutable
class AutoEmitirConfig {
  const AutoEmitirConfig({
    this.stopAfter,
    this.save4k = false,
    this.readyTimeout = autoEmitirReadyTimeout,
    this.slaveSettle = autoEmitirSlaveSettle,
  });

  /// PARAR a este rato de EMITIR; null, no para solo.
  final Duration? stopAfter;

  /// «Guardar vídeo» (la 4K de cada móvil): apagado salvo `AUTO_EMITIR_4K=1`.
  final bool save4k;

  final Duration readyTimeout;
  final Duration slaveSettle;
}

/// Qué ha hecho el modo automático, para los tests y el registro.
enum AutoEmitirStep { esperando, asentando, emitiendo, parado, esclavo, sinLista, fallo }

/// Lleva una `CaptureSession` del maestro de LISTA a EMITIR y, si se pide, a PARAR.
class AutoEmitir {
  AutoEmitir({required this.session, required this.config, required this.log});

  final CaptureSession session;
  final AutoEmitirConfig config;

  /// Una línea por paso (ver [AutoEmitirLog]).
  final void Function(String line) log;

  AutoEmitirStep step = AutoEmitirStep.esperando;
  Timer? _timeout;
  Timer? _settle;
  Timer? _stop;
  String _last = '';
  bool _started = false;

  /// Empieza a mirar la sesión. Se llama una vez, con la sesión recién creada.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    log('auto-emitir: ${session.role.name} · enlace ${session.linkMode.name} · '
        '4K ${config.save4k ? 'sí' : 'no'} · parar a los '
        '${config.stopAfter == null ? '-' : '${config.stopAfter!.inSeconds} s'}');
    if (!session.programMode) {
      log('auto-emitir: sin programa (enlace ${session.linkMode.name}): no se emite');
      step = AutoEmitirStep.fallo;
      return;
    }
    session.addListener(_onChanged);
    _timeout = Timer(config.readyTimeout, _onTimeout);
    _onChanged();
  }

  void dispose() {
    _timeout?.cancel();
    _settle?.cancel();
    _stop?.cancel();
    session.removeListener(_onChanged);
  }

  /// Lo que la pantalla diría ahora, en una línea: solo se registra cuando cambia.
  String get _snapshot => 'fase ${session.phase.name} · enlace ${session.linkState.name}'
      '${session.linkPeer.isEmpty ? '' : ' (${session.linkPeer})'} · '
      'rol ${session.rigRole?.name ?? '-'} · emitiendo ${session.recording ? 'sí' : 'no'}'
      '${session.problem == null ? '' : ' · ${session.problem}'}';

  /// LISTA en el maestro: la cámara lista, el enlace conectado y el rol negociado.
  bool get _ready =>
      session.phase == SessionPhase.lista &&
      session.linkState == LinkState.connected &&
      session.rigRole == RigRole.master &&
      !session.recording;

  void _onChanged() {
    final String now = _snapshot;
    if (now != _last) {
      _last = now;
      log('auto-emitir: $now');
    }
    switch (step) {
      case AutoEmitirStep.esperando:
        if (session.rigRole == RigRole.slave) {
          // El esclavo no emite solo: arranca por la orden del maestro (IOS-58).
          step = AutoEmitirStep.esclavo;
          _timeout?.cancel();
          log('auto-emitir: este móvil es el esclavo: espera la orden del maestro');
        } else if (_ready) {
          step = AutoEmitirStep.asentando;
          _timeout?.cancel();
          log('auto-emitir: LISTA; ${config.slaveSettle.inSeconds} s para el reloj y la fase '
              'del esclavo antes de EMITIR');
          _settle = Timer(config.slaveSettle, () => unawaited(_emit()));
        }
      case AutoEmitirStep.emitiendo:
        if (!session.recording) {
          step = AutoEmitirStep.parado;
          _stop?.cancel();
          log('auto-emitir: el programa paró sin PARAR automático');
        }
      case AutoEmitirStep.asentando:
      case AutoEmitirStep.parado:
      case AutoEmitirStep.esclavo:
      case AutoEmitirStep.sinLista:
      case AutoEmitirStep.fallo:
        break;
    }
  }

  void _onTimeout() {
    if (step != AutoEmitirStep.esperando) {
      return;
    }
    step = AutoEmitirStep.sinLista;
    log('auto-emitir: sin LISTA en ${config.readyTimeout.inSeconds} s, no se emite: $_snapshot');
  }

  /// Lo mismo que el botón EMITIR con «Guardar vídeo» como se pidió.
  Future<void> _emit() async {
    if (!_ready) {
      // Se cayó el enlace (o algo) mientras se asentaba: se vuelve a esperar a LISTA.
      step = AutoEmitirStep.esperando;
      log('auto-emitir: ya no está LISTA tras asentar ($_snapshot): se espera otra vez');
      _timeout = Timer(config.readyTimeout, _onTimeout);
      return;
    }
    // El campo y no `setSaveVideo`: el interruptor, sin grabar, manda `record` al esclavo
    // y lo pone a emitir antes que el maestro. EMITIR lo lee igual (`save ?? saveVideo`).
    session.saveVideo = config.save4k;
    log('auto-emitir: EMITIR');
    await session.toggleRecording();
    if (!session.recording) {
      step = AutoEmitirStep.fallo;
      log('auto-emitir: EMITIR no arrancó: ${session.problem ?? 'sin motivo'}');
      return;
    }
    step = AutoEmitirStep.emitiendo;
    log('auto-emitir: EMITIENDO');
    final Duration? stopAfter = config.stopAfter;
    if (stopAfter != null) {
      _stop = Timer(stopAfter, () => unawaited(_stopNow()));
    }
  }

  /// Lo mismo que el botón PARAR.
  Future<void> _stopNow() async {
    if (step != AutoEmitirStep.emitiendo || !session.recording) {
      return;
    }
    step = AutoEmitirStep.parado;
    log('auto-emitir: PARAR (${config.stopAfter!.inSeconds} s)');
    await session.toggleRecording();
    log('auto-emitir: parado · ${session.recording ? 'sigue emitiendo' : 'ok'}');
  }
}

/// El registro del modo automático: al log del sistema (`flutter:` en Consola, también en
/// release) y a `Documents/bench/auto-emitir-<lado>-<t>.log`, que recoge
/// `tools/emitir_auto.sh` junto al informe y el latido.
class AutoEmitirLog {
  AutoEmitirLog(this._file);

  /// El fichero de esta pasada en `<documents>/bench`, con la hora de arranque.
  factory AutoEmitirLog.inDocuments(String documents, CameraRole role) {
    final int t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return AutoEmitirLog(File('$documents/bench/auto-emitir-${role.name}-$t.log'));
  }

  final File? _file;
  final Stopwatch _since = Stopwatch()..start();

  void call(String line) {
    final String stamped = '${(_since.elapsedMilliseconds / 1000).toStringAsFixed(1)}s $line';
    debugPrint(stamped);
    final File? file = _file;
    if (file == null) {
      return;
    }
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    } on FileSystemException {
      // Sin fichero queda el log del sistema: no puede parar la emisión.
    }
  }
}
