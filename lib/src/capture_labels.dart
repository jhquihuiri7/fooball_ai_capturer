/// Lo que la pantalla de captura enseña, agrupado en tarjetas y con el color que le toca.
///
/// Vive fuera de [CaptureSession] a propósito. La sesión ya da las etiquetas en
/// español (`linkLabel`, `streamLabel`, `exposureLabel`…); lo que se decide aquí es
/// solo cómo se enseñan: en qué tarjeta va cada dato, qué confirma algo que tenía que
/// estar bien y qué es una alarma. No hay ni una decisión que pueda cambiar lo que graba
/// el móvil.
///
/// Dos reglas que se siguen sin excepción:
///
/// - **No se rellena con guiones.** Si un dato no existe todavía, la fila no se dibuja
///   o dice por qué no existe. Un `—` en la pantalla se lee como «cero» a tres metros.
/// - **El acento solo confirma.** Va en lo que tenía que estar bien y lo está
///   (estabilización desactivada, exposición bloqueada, 0 frames perdidos). Un dato
///   normal va en blanco, y una alarma, en rojo.
library;

import 'package:football_ai_capture/src/capture_session.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/stream_url.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

/// Bits por segundo a los que el nativo escribe el fichero local.
///
/// Es una copia de `AVVideoAverageBitRateKey` en `ios/Runner/CaptureEngine.swift`, no
/// una decisión de esta pantalla. No coincide con `CaptureSettings.bitrateBps` (la de
/// la emisión) porque el fichero local no pasa por Starlink y se graba con más calidad.
/// Si el nativo cambia, esto tiene que cambiar con él: de aquí sale el aviso de disco.
const int localRecordingBitsPerSecond = 45000000;

/// Minutos de grabación que tiene que aguantar el disco: 90 de partido, 15 de
/// descanso —se sigue grabando: parar y volver a arrancar es sortear otra vez la fase—
/// y 10 de margen para la prórroga y el calentamiento.
const int matchRecordingMinutes = 115;

/// Bytes que ocupa un partido entero grabado en local.
const int matchRecordingBytes = localRecordingBitsPerSecond ~/ 8 * 60 * matchRecordingMinutes;

/// Una fila de la pantalla de captura: qué pone, qué vale y de qué color va el valor.
class CaptureReading {
  const CaptureReading(this.label, this.value, {this.tone = ZeroTone.neutral});

  final String label;
  final String value;
  final ZeroTone tone;
}

/// `04:12`. Sin horas: un partido no llega, y `00:04:12` ocupa el doble a la misma
/// distancia de lectura. Nunca negativo: un reloj que se corrige hacia atrás no puede
/// pintar `00:-4` en el HUD.
String formatClock(Duration d) {
  final Duration safe = d.isNegative ? Duration.zero : d;
  final int minutes = safe.inMinutes;
  final int seconds = safe.inSeconds.remainder(60);
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

/// Todo lo que la pantalla de captura enseña en un instante.
///
/// Se construye en cada `build`: es barato y así nunca enseña un dato viejo.
class CaptureReadout {
  const CaptureReadout(this.session);

  final CaptureSession session;

  CaptureStatus? get _status => session.status;

  String get sideWord => session.role == CameraRole.left ? 'izquierda' : 'derecha';

  /// El título de la cabecera. En modo de un solo móvil lo dice ahí mismo: es lo que
  /// hace que lo grabado no sirva para el soporte, y no puede quedarse en la fila 4.
  String get cameraTitle =>
      session.standalone ? 'Cámara $sideWord · SIN RELOJ' : 'Cámara $sideWord';

  // ------------------------------------------------------------------------- //
  // Cabecera y HUD
  // ------------------------------------------------------------------------- //

  /// El chip de la cabecera. Solo `LISTA` y `GRABANDO` van en acento; lo demás es una
  /// espera o un fallo, y ninguna de las dos cosas merece el color de «esto está bien».
  String get statusChipLabel => switch (session.phase) {
    SessionPhase.preparando => 'ABRIENDO CÁMARA',
    SessionPhase.esperandoReloj => 'ESPERANDO RELOJ',
    SessionPhase.ajustandoFase => 'AJUSTANDO FASE',
    SessionPhase.lista => 'LISTA',
    SessionPhase.grabando => 'GRABANDO',
    SessionPhase.fallo => 'FALLO',
  };

  bool get statusChipIsGood =>
      session.phase == SessionPhase.lista || session.phase == SessionPhase.grabando;

  /// `3840×2160 · 30p`. `null` mientras no haya `status`: el chip no se dibuja.
  String? get formatChipLabel {
    final CaptureStatus? applied = _status;
    if (applied == null) {
      return null;
    }
    return '${applied.width}×${applied.height} · ${applied.actualFps.round()}p';
  }

  /// `1/100 · ISO 320`: lo que el nativo dice que quedó aplicado, no lo pedido.
  String? get exposureChipLabel {
    final CaptureStatus? applied = _status;
    if (applied == null || !applied.exposureLocked || applied.exposureSeconds <= 0) {
      return null;
    }
    return '1/${(1 / applied.exposureSeconds).round()} · ISO ${applied.iso}';
  }

  /// `FASE 3.2 ms`. `null` mientras no se haya medido.
  String? get phaseChipLabel {
    final int? measured = session.exposurePhaseNs;
    if (measured == null) {
      return null;
    }
    return 'FASE ${(measured / 1e6).toStringAsFixed(1)} ms';
  }

  // ------------------------------------------------------------------------- //
  // Banner de grabación
  // ------------------------------------------------------------------------- //

  /// Grabando: minutos, archivo y segmento, tal como los da la sesión. Parado: el
  /// último archivo, que es lo que se busca en Finder al acabar.
  String get recordingBannerLabel {
    if (session.recording) {
      return session.recordingLabel;
    }
    final String? last = session.recordingFileName;
    if (last != null) {
      return 'no está grabando · último: $last';
    }
    return session.canRecord ? 'no está grabando' : 'cámara no lista';
  }

  // ------------------------------------------------------------------------- //
  // Tarjeta SOPORTE
  // ------------------------------------------------------------------------- //

  ZeroTone get _linkTone {
    switch (session.linkState) {
      case LinkState.connected:
        return ZeroTone.ok;
      case LinkState.searching:
        // El maestro puede grabar solo: que espere al derecho no es una alarma. El
        // derecho sin maestro no tiene hora, y eso sí lo es.
        return session.isClockMaster ? ZeroTone.neutral : ZeroTone.bad;
      case LinkState.off:
        return ZeroTone.neutral;
    }
  }

  ZeroTone get _clockTone {
    if (session.standalone) {
      return ZeroTone.neutral;
    }
    return session.clockLabel == 'sin reloj' ? ZeroTone.bad : ZeroTone.ok;
  }

  List<CaptureReading> get rigReadings => <CaptureReading>[
    CaptureReading('Enlace', session.linkLabel, tone: _linkTone),
    CaptureReading('Reloj', session.clockLabel, tone: _clockTone),
    CaptureReading(
      'Fase de exposición',
      session.phaseLabel,
      tone: session.exposurePhaseNs == null ? ZeroTone.neutral : ZeroTone.ok,
    ),
    CaptureReading(
      'Modo',
      session.modeLabel,
      tone: session.standalone ? ZeroTone.bad : ZeroTone.neutral,
    ),
  ];

  // ------------------------------------------------------------------------- //
  // Tarjeta EMISIÓN
  // ------------------------------------------------------------------------- //

  StreamState get _streamState => _status?.streamState ?? StreamState.off;

  /// El chip de la tarjeta: la palabra, sin el detalle, que va en su fila.
  String get streamChipLabel => switch (_streamState) {
    StreamState.off => 'APAGADA',
    StreamState.connecting => 'CONECTANDO',
    StreamState.streaming => 'EMITIENDO',
    StreamState.reconnecting => 'RECONECTANDO',
    StreamState.failed => 'FALLO',
  };

  bool get streamIsUp => _streamState == StreamState.streaming;

  bool get streamInTrouble => session.streamInTrouble;

  /// `srt · mediamtx.local/rig/izquierda`: protocolo, servidor y canal, sin la clave.
  /// Es la forma de leerlo, no la URL que se entrega al nativo (`streamUrl`).
  String get streamDestinationLabel {
    final String server = session.serverHost.trim();
    if (server.isEmpty) {
      return 'sin servidor · solo graba en el móvil';
    }
    final Uri? uri = Uri.tryParse(server.contains('://') ? server : 'srt://$server');
    if (uri == null || uri.host.isEmpty || session.streamUrl.isEmpty) {
      return 'no se entiende «$server» · solo graba';
    }
    final String port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme} · ${uri.host}$port/${streamPath(session.role)}';
  }

  /// Fracción del bitrate de emisión por calor. Copia de `bitrateFraction` en
  /// `ios/Runner/CaptureEngine.swift`: el nativo la aplica, aquí solo se enseña.
  double get _heatFraction => switch (_status?.thermalState ?? ThermalState.nominal) {
    ThermalState.nominal || ThermalState.fair => 1.0,
    ThermalState.serious => 2.0 / 3.0,
    ThermalState.critical => 0.4,
  };

  String get bitrateLabel {
    final double mbps = defaultSettings(session.role).bitrateBps * _heatFraction / 1e6;
    final String value = mbps.toStringAsFixed(mbps == mbps.roundToDouble() ? 0 : 1);
    return _heatFraction < 1 ? '$value Mbit/s · bajada por calor' : '$value Mbit/s · fijo';
  }

  ZeroTone get _localNetworkTone => switch (session.localNetworkAllowed) {
    null => ZeroTone.neutral,
    true => ZeroTone.ok,
    false => ZeroTone.bad,
  };

  List<CaptureReading> get streamReadings {
    final CaptureStatus? applied = _status;
    final bool live = _streamState != StreamState.off;
    return <CaptureReading>[
      CaptureReading(
        'Destino',
        streamDestinationLabel,
        tone: session.serverHost.trim().isNotEmpty && session.streamUrl.isEmpty
            ? ZeroTone.bad
            : ZeroTone.neutral,
      ),
      // El detalle de un corte (qué dijo el servidor) solo cuando lo hay: en reposo,
      // el chip ya lo dice todo.
      if (streamInTrouble) CaptureReading('Estado', session.streamLabel, tone: ZeroTone.bad),
      CaptureReading(
        'Bitrate',
        bitrateLabel,
        tone: streamIsUp && _heatFraction == 1 ? ZeroTone.ok : ZeroTone.neutral,
      ),
      if (applied != null && live)
        CaptureReading(
          'Frames perdidos',
          '${applied.streamDroppedFrames}',
          tone: applied.streamDroppedFrames == 0 ? ZeroTone.ok : ZeroTone.bad,
        ),
      CaptureReading('Red local', session.localNetworkLabel, tone: _localNetworkTone),
    ];
  }

  // ------------------------------------------------------------------------- //
  // Tarjeta CÁMARA
  // ------------------------------------------------------------------------- //

  List<CaptureReading> get cameraReadings {
    final CaptureStatus? applied = _status;
    if (applied == null) {
      return const <CaptureReading>[];
    }
    return <CaptureReading>[
      // `running` solo es verdad un rato después de configurar. Mientras no lo sea, es
      // lo primero de la tarjeta; cuando lo es, sobra.
      if (!applied.running)
        const CaptureReading('Cámara en marcha', 'todavía no', tone: ZeroTone.bad),
      CaptureReading('Resolución', '${applied.width}×${applied.height}'),
      CaptureReading('Cadencia real', applied.actualFps.toStringAsFixed(2)),
      CaptureReading(
        'Estabilización',
        applied.stabilizationDisabled ? 'desactivada' : 'ACTIVA',
        tone: applied.stabilizationDisabled ? ZeroTone.ok : ZeroTone.bad,
      ),
      CaptureReading(
        'Exposición',
        session.exposureLabel,
        tone: applied.exposureLocked ? ZeroTone.ok : ZeroTone.bad,
      ),
      CaptureReading(
        'Balance de blancos',
        session.whiteBalanceLabel,
        tone: applied.whiteBalanceLocked ? ZeroTone.ok : ZeroTone.bad,
      ),
      CaptureReading(
        'Foco',
        applied.focusLocked ? 'bloqueado' : 'AUTOMÁTICO',
        tone: applied.focusLocked ? ZeroTone.ok : ZeroTone.bad,
      ),
      // Tener intrínsecas es lo normal, no una confirmación: va neutro, como en el
      // diseño. Solo su ausencia merece color.
      CaptureReading(
        'Intrínsecas',
        applied.intrinsicsAvailable ? 'por frame' : 'NO DISPONIBLES',
        tone: applied.intrinsicsAvailable ? ZeroTone.neutral : ZeroTone.bad,
      ),
      CaptureReading(
        'Código de tiempo',
        session.timecodeLabel,
        tone: applied.timecodeFailures == 0 ? ZeroTone.ok : ZeroTone.bad,
      ),
    ];
  }

  // ------------------------------------------------------------------------- //
  // Tarjeta DISPOSITIVO
  // ------------------------------------------------------------------------- //

  String _thermalLabel(ThermalState state) => switch (state) {
    ThermalState.nominal => 'nominal',
    ThermalState.fair => 'templado',
    ThermalState.serious => 'serious · busca sombra',
    ThermalState.critical => 'critical · el móvil va a cortar',
  };

  List<CaptureReading> get deviceReadings {
    final CaptureStatus? applied = _status;
    if (applied == null) {
      return const <CaptureReading>[];
    }
    final bool hot = applied.thermalState.index >= ThermalState.serious.index;
    // El fichero local va a 45 Mbit/s: unos 20 GB por hora, casi 39 GB un partido con
    // descanso. Con menos, AVAssetWriter se queda sin sitio a mitad y no avisa dos veces.
    final bool tight = applied.freeDiskBytes < matchRecordingBytes;
    final String free = '${(applied.freeDiskBytes / 1e9).toStringAsFixed(1)} GB';
    return <CaptureReading>[
      CaptureReading(
        'Temperatura',
        _thermalLabel(applied.thermalState),
        tone: hot ? ZeroTone.bad : ZeroTone.ok,
      ),
      CaptureReading(
        'Batería',
        '${(applied.batteryLevel * 100).round()} %',
        tone: applied.batteryLevel < 0.2 ? ZeroTone.bad : ZeroTone.neutral,
      ),
      CaptureReading(
        'Disco libre',
        tight ? '$free · no llega al final del partido' : free,
        tone: tight ? ZeroTone.bad : ZeroTone.neutral,
      ),
      CaptureReading(
        'Frames perdidos',
        '${applied.droppedFrames}',
        tone: applied.droppedFrames == 0 ? ZeroTone.ok : ZeroTone.bad,
      ),
    ];
  }

  // ------------------------------------------------------------------------- //
  // Tarjeta de atención
  // ------------------------------------------------------------------------- //

  /// Lo que hay que leer antes que nada: lo que impide grabar y lo que acaba de cortar
  /// la sesión. Vacío casi siempre, que es como tiene que ser.
  List<CaptureReading> get troubleReadings => <CaptureReading>[
    if (session.problem != null) CaptureReading('Problema', session.problem!, tone: ZeroTone.bad),
    if (session.interruption != null)
      CaptureReading('Interrupción', session.interruption!, tone: ZeroTone.bad),
  ];
}
