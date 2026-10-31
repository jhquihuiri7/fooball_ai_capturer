/// Constantes de comportamiento de la app de captura.
///
/// Mismo criterio que `libs/vision/constants.py` en el repo `football-ai`: ningún
/// número de comportamiento incrustado en una expresión. Cada uno lleva su unidad y la
/// decisión del ADR 0012 que lo fija.
library;

/// Nanosegundos en un segundo.
const int nsPerSecond = 1000000000;

/// Nanosegundos en un milisegundo.
const int nsPerMillisecond = 1000000;

// --------------------------------------------------------------------------- //
// Reloj del soporte (ADR 0012, decisión 2)
// --------------------------------------------------------------------------- //

/// Muestras de reloj que se conservan. El enlace pregunta la hora en ráfaga al conectar
/// y después una vez cada 5 s (`RigLink.swift`): 240 muestras son una ventana de veinte
/// minutos, suficiente para ajustar la deriva y corta para seguirla si cambia con el calor.
const int clockMaxSamples = 240;

/// Múltiplo del mejor RTT por encima del cual una muestra se descarta.
///
/// El desfase se estima suponiendo que la ida tarda lo mismo que la vuelta, y esa
/// suposición solo es buena cuando la red no encoló nada. Una muestra con el triple de
/// RTT que la mejor no es una medida peor: es otra cosa, y promediarla contamina.
const double clockRttRejectFactor = 3.0;

/// Muestras mínimas para dar una estimación. Con menos, el offset es un único valor
/// sin forma de saber si fue un pico.
const int clockMinSamples = 3;

/// Segundos que tienen que abarcar las muestras para estimar deriva.
///
/// La deriva entre dos cristales son decenas de ppm: 20 ppm son 20 µs por segundo. Con
/// muestras de un solo minuto, esa pendiente queda por debajo del ruido del RTT y
/// ajustar una recta a eso produce una deriva inventada. Por debajo de este margen se
/// entrega solo el offset.
const int clockMinDriftSpanSeconds = 60;

// --------------------------------------------------------------------------- //
// Fase de exposición (ADR 0012; TASK A4)
// --------------------------------------------------------------------------- //

/// Nanosegundos. Fase por debajo de la cual el arranque se da por bueno.
///
/// Sin genlock los dos sensores exponen en instantes que caen donde quieren dentro del
/// intervalo de frame, y el sorteo se repite en cada arranque. A 5 ms, un balón a
/// 30 m/s se desdobla 15 cm en la costura, que a 1080p no se ve; a 16 ms —el peor caso
/// a 30 fps— serían 50 cm, que sí.
const int exposurePhaseToleranceNs = 5 * nsPerMillisecond;

/// Espera tras arrancar o reiniciar la captura antes de medir la fase.
///
/// Los PTS recientes de los dos móviles tienen que ser posteriores al reinicio, o se
/// mediría la fase vieja. El nativo guarda treinta frames, un segundo a 30 fps; se deja
/// algo de margen.
const Duration phaseSettleDelay = Duration(milliseconds: 1200);

/// Reintentos de arranque para sortear una fase mejor.
///
/// Cada intento es independiente, así que con tolerancia de 5 ms sobre un intervalo de
/// 33 ms la probabilidad de fallar un intento es ~0.7 y la de fallar seis seguidos,
/// ~0.12. Más intentos rinden poco y retrasan el saque inicial.
const int exposurePhaseMaxAttempts = 6;

// --------------------------------------------------------------------------- //
// Pantalla de captura
// --------------------------------------------------------------------------- //

/// Cada cuánto la pantalla vuelve a pedir el estado al nativo.
///
/// Batería, temperatura y frames perdidos cambian sin que nadie avise. Un segundo
/// basta para ver venir un apagón y no molesta: es una llamada síncrona y barata.
const Duration statusRefreshInterval = Duration(seconds: 1);

// --------------------------------------------------------------------------- //
// EMITIR en la arquitectura B (IOS-58)
// --------------------------------------------------------------------------- //

/// Fotogramas por segundo del programa por debajo de los cuales la fila va en rojo. El
/// programa marca 30 (ADR 0019 §1) y la aceptación de IOS-44 pide p5 ≥29,5; en una lectura
/// de un segundo se ven 29 o 31 por redondeo, así que el aviso es a partir de 28.
const int programFpsFloor = 28;

// --------------------------------------------------------------------------- //
// Emisión al servidor (ADR 0012; TASK A5)
// --------------------------------------------------------------------------- //

/// Puerto SRT del MediaMTX que recibe a los móviles (`srtAddress: :8890`).
const int streamPort = 8890;

/// Milisegundos de búfer de SRT. Starlink pierde paquetes en cada traspaso de satélite,
/// cada 15 s; con un segundo de margen el ARQ los recupera sin que se note.
const int streamLatencyMs = 1000;

/// Primer nivel del canal en MediaMTX: `rig/izquierda` y `rig/derecha`.
const String streamPathPrefix = 'rig';

/// Puertos por defecto de RTMP y RTMPS. En un pod de RunPod el puerto externo lo asigna
/// la plataforma y cambia en cada reinicio: ahí se escribe a mano (`rtmp://IP:PUERTO`).
const int rtmpPort = 1935;
const int rtmpsPort = 443;

// --------------------------------------------------------------------------- //
// Subir la grabación para calibrar el soporte
// --------------------------------------------------------------------------- //

/// Puerto del panel cuando el servidor es el Mac de la cancha (`tools/local.sh`). En un
/// pod el panel va por el proxy de RunPod, y su dirección llega en el QR (`?panel=`).
const int localPanelPort = 8090;

/// Bytes por trozo de la subida: 8 MiB, la mitad de lo que admite el panel
/// (`RECORDING_CHUNK_MAX_BYTES`). Por Starlink una conexión sola saca 1–2 Mbit/s hasta el
/// pod, así que un trozo son ~40 s: perder uno por un corte cuesta poco.
/// Segundos que se graban al pulsar CALIBRAR.
///
/// Diez bastan: el servidor no usa la grabación entera, escoge unos pocos instantes y
/// los empareja por el código de tiempo. Y el tamaño manda, porque esto se sube por la
/// red del campo: diez segundos a 45 Mbit/s son ~56 MB y suben en unos minutos, mientras
/// que tres minutos son 1 GB y hora y media (medido el 27-09-2026).
const Duration calibrationClipDuration = Duration(seconds: 10);

/// Cuánto se espera a que el panel termine de calibrar antes de rendirse.
///
/// Calibrar cuesta décimas, pero el panel lo hace cuando tiene **las dos** grabaciones, y
/// la del otro móvil puede ir más lenta por la red del campo.
const Duration calibrationResultTimeout = Duration(minutes: 3);

/// Cada cuánto se le pregunta al panel si ya calibró.
const Duration calibrationPollDelay = Duration(seconds: 2);

const int calibrationChunkBytes = 8 * 1024 * 1024;

/// Fallos seguidos antes de rendirse. Veinte con tres segundos entre medias es aguantar un
/// minuto de corte, que es más que cualquier traspaso de satélite.
const int calibrationMaxRetries = 20;

/// Espera entre un fallo de la subida y el siguiente intento.
const Duration calibrationRetryDelay = Duration(seconds: 3);

/// Plazo de cada petición, trozo incluido: 8 MiB a 1 Mbit/s son ~70 s, con margen.
const Duration calibrationRequestTimeout = Duration(minutes: 3);

// --------------------------------------------------------------------------- //
// Mando del panel (ADR 0017 del repo football-ai)
// --------------------------------------------------------------------------- //

/// Dónde va el token en el QR «Mando»: `https://<panel>/#mando=<token>`
/// (`PAIRING_FRAGMENT` en `tools/control_token.py`).
const String pairingFragmentKey = 'mando';

/// Las otras direcciones del mismo partido en el QR Mando del maestro, separadas por
/// espacios (IOS-63, ADR 0023): la IP del otro móvil y la URL del VPS.
const String pairingAlternatesKey = 'alt';

/// Puerto de la API del mando en el maestro (`MASTER_API_PORT`, IOS-62/63). El mismo que
/// el panel del Mac de la cancha: un mando no distingue a quién habla.
const int masterApiPort = localPanelPort;

/// Lo que precede al `match_id` al derivar el secreto del mando (ADR 0023 §3).
const String controlSecretContext = 'zero-control-v1 ';

/// Lo que vale un token de mando desde que se enseña el QR (`CONTROL_TOKEN_TTL_S`): el
/// día de partido con su montaje.
const Duration controlTokenTtl = Duration(hours: 12);

/// Donde vive la API del mando en el panel (`API_V1_PREFIX`).
const String panelApiPrefix = '/api/v1/';

/// Ámbito del token que deja emitir y parar la emisión (`SCOPE_STREAM`).
const String panelScopeStream = 'stream';

/// Cabecera con el nombre de este móvil, para la tarjeta Mando del panel (`DEVICE_HEADER`).
const String panelDeviceHeader = 'X-Zero-Device';

/// Plazo de la espera larga. El panel contesta como tarde a los 25 s
/// (`LONG_POLL_TIMEOUT_S`); con diez de margen, un plazo vencido es la red y no el panel.
const Duration panelLongPollTimeout = Duration(seconds: 35);

/// Plazo de una orden. Por Starlink hasta el pod una petición va y vuelve en menos de un
/// segundo; a los cinco, lo que haya se da por perdido y se reintenta.
const Duration panelRequestTimeout = Duration(seconds: 5);

/// Cuánto se reintenta una orden que no obtuvo respuesta, con la misma
/// `Idempotency-Key`. Diez segundos cubren un traspaso de satélite; más tarde, un
/// «Parar reloj» que por fin llega es peor que uno que falla y se ve fallar (ADR 0017).
const Duration panelCommandRetryWindow = Duration(seconds: 10);

/// Espera entre dos intentos de una orden.
const Duration panelCommandRetryDelay = Duration(milliseconds: 800);

/// Espera antes de volver a preguntar al panel tras un fallo de red. Sin ella, sin
/// cobertura, el bucle giraría en vacío gastando batería.
const Duration panelReconnectDelay = Duration(seconds: 2);

/// Cómo se presenta este móvil en la tarjeta Mando del panel. Fijo: desde iOS 16 el
/// nombre del dispositivo sin permiso especial es «iPhone» a secas, que tampoco distingue.
/// Con dos mandos a la vez la tarjeta los contará, pero no dirá cuál es cuál.
const String mandoDeviceName = 'Zero · mando';

/// Cada cuánto se repinta «sin panel desde hace N s» mientras el panel no contesta.
const Duration mandoSilenceRefresh = Duration(seconds: 1);

/// IOS-07: cuánto se enseña la vista previa al tocar la tarjeta mientras se emite.
/// Lo justo para encuadrar o comprobar algo; después vuelve a apagarse sola.
const Duration previewPeekDuration = Duration(seconds: 30);

// --------------------------------------------------------------------------- //
// El partido con autoridad en el maestro (IOS-60, ADR 0017/0023)
// --------------------------------------------------------------------------- //

/// Versión del fichero del partido (`MATCH_RECORD_VERSION` de `tools/match_record.py`).
const int matchRecordVersion = 1;

/// Entre dos guardados del cronómetro mientras corre (`CLOCK_SAVE_INTERVAL_S`): es lo
/// que puede perder un reinicio, y diez segundos se corrigen con el ±1 min.
const Duration matchClockSaveInterval = Duration(seconds: 10);

/// Lo más que una orden mueve el cronómetro de una vez (`CLOCK_NUDGE_MAX_S`): más de
/// una hora no es corregir un reloj de partido, es una errata.
const int matchClockNudgeMaxS = 3600;

/// Goles que suma o quita una orden de gol (`GOAL_STEP`).
const int matchGoalStep = 1;

/// Las formaciones que ofrece el editor (`FORMATIONS` de `tools/lineup.py`).
const List<String> matchFormations = <String>[
  '4-4-2', '4-3-3', '4-2-3-1', '4-1-4-1', '3-5-2', '3-4-3', '5-3-2', '5-4-1',
];

// --------------------------------------------------------------------------- //
// La API del mando servida por el maestro (IOS-62, ADR 0017/0022)
// --------------------------------------------------------------------------- //

/// Lo que espera `GET /api/v1/match?since=` si no cambia nada (`LONG_POLL_TIMEOUT_S`).
const Duration apiLongPollTimeout = Duration(seconds: 25);

/// Esperas largas a la vez (`MAX_LONG_POLLS`); la siguiente recibe un 503.
const int apiMaxLongPolls = 8;

/// Respuestas que recuerda la caché de `Idempotency-Key` (`IDEMPOTENCY_CACHE_SIZE`).
const int apiIdempotencyCacheSize = 256;

/// Cuánto vale una `Idempotency-Key` (`IDEMPOTENCY_TTL_S`): mucho más que la ventana de
/// reintento de la app, y poco para que conteste por una orden de otro momento.
const Duration apiIdempotencyTtl = Duration(minutes: 10);

/// Lo más largo que se enseña del nombre de un mando (`MAX_DEVICE_NAME_CHARS`).
const int apiMaxDeviceNameChars = 40;

/// Mandos que se recuerdan (`MAX_CONTROL_DEVICES`).
const int apiMaxControlDevices = 16;

/// Cuánto sigue en la lista un mando desde su última petición (`CONTROL_DEVICE_RECENT_S`).
const Duration apiControlDeviceRecent = Duration(seconds: 60);

/// Lo que espera el maestro la respuesta del VPS a un `relay_command`
/// (`COMMAND_TIMEOUT_S`, ADR 0022); si vence, 504.
const Duration apiCommandTimeout = Duration(seconds: 5);

/// Lo más grande que se lee de un cuerpo: una orden son unas decenas de bytes y una
/// alineación ~1 KiB; con más es un error o un abuso.
const int apiMaxBodyBytes = 64 * 1024;

// --------------------------------------------------------------------------- //
// Del mando: equipos, entretiempo, icono del campeonato y franja (ADR 0027)
// --------------------------------------------------------------------------- //

/// Caracteres como mucho del nombre de un equipo puesto desde el mando: con más, el
/// marcador se estira por encima del tercio de la pantalla.
const int matchTeamNameMaxChars = 24;

/// Segundos que sale la franja con «Sacar» si la orden no dice otros.
const int stripShowDefaultS = 15;

/// Segundos como mucho que se puede pedir la franja de una vez.
const int stripShowMaxS = 120;

/// Bytes como mucho del icono del campeonato: un PNG de 1024 px con alfa ronda 1 MB.
const int championshipIconMaxBytes = 4 * 1024 * 1024;

/// La marca del campeonato (los textos de la franja y el tipo del icono), junto al
/// partido. No se aparta con el partido viejo: es del campeonato, no de un partido.
const String graphicsFileName = 'grafico.json';

/// El icono del campeonato tal como se subió (PNG o JPEG).
const String championshipIconFileName = 'campeonato.img';

/// Donde vive el icono bajo `/api/v1/`: `PUT` lo sube, `GET` lo da y `DELETE` lo quita.
const String championshipAssetRoute = 'assets/championship';

/// La imagen de cada franja guardada (enmienda del ADR 0027 del 2026-10-16): bajo
/// `/api/v1/`, `assets/strip/<nombre de la franja>`; `PUT` la sube, `GET` la da y `DELETE`
/// la quita.
const String stripImageRoute = 'assets/strip';

/// La carpeta de las imágenes de las franjas, junto al partido: del campeonato.
const String stripImageDirName = 'franjas';

/// Bytes como mucho de la imagen de una franja: los del icono del campeonato.
const int stripImageMaxBytes = championshipIconMaxBytes;

/// Franjas guardadas como mucho (ADR 0029): las que caben en la tarjeta del mando sin
/// buscar.
const int stripPresetsMax = 12;

/// Caracteres como mucho del nombre de una franja guardada.
const int stripPresetNameMaxChars = 24;

/// La franja guardada con la que se empieza, con los textos que hubiera.
const String stripPresetDefaultName = 'PRINCIPAL';

/// Rótulos guardados como mucho (ADR 0031): los mismos que franjas.
const int captionPresetsMax = stripPresetsMax;

/// Segundos que sale un rótulo con «Sacar» si la orden no dice otros: lo que dura un rótulo
/// de noticiero. Hasta [stripShowMaxS], o fijo con `hold`.
const int captionShowDefaultS = 10;

/// Lo que se muestra como `caption_remaining_ms` de un rótulo fijo: no se va solo.
const int captionHoldRemainingMs = -1;

/// Lo que el operador apaga uno a uno con `graphics/element` (enmienda del ADR 0032 del
/// 2026-10-31), en el orden de `elements_on_air`: la competición, la barra (escudos, nombres
/// y goles), el reloj, EN VIVO, el logo de la casa y el icono de la copa. Es
/// `ON_AIR_ELEMENTS` de `tools/control_api.py`.
const List<String> onAirElements = <String>['competition', 'bar', 'clock', 'live', 'broadcaster', 'championship'];

/// Los que se van con el marcador entero (`graphics/scoreboard`). Si no queda ninguno, EN
/// VIVO sube arriba a la izquierda.
const Set<String> scoreboardElements = <String>{'competition', 'bar', 'clock'};

/// Los escudos de los equipos (ADR 0028): bajo `/api/v1/`, `assets/crest/home` y
/// `assets/crest/away`; `PUT` sube el del equipo que juega de ese lado, `GET` lo da y
/// `DELETE` lo quita.
const String teamCrestAssetRoute = 'assets/crest';

/// Los escudos por el nombre del equipo (ADR 0030), para los que no juegan ahora (los de la
/// jornada): `assets/crests/<nombre>`, con el nombre %-escapado.
const String teamCrestsByNameRoute = 'assets/crests';

/// La carpeta de los escudos, junto al partido: como el icono, del campeonato.
const String teamCrestDirName = 'escudos';

/// Bytes como mucho de un escudo: los del icono del campeonato.
const int teamCrestMaxBytes = championshipIconMaxBytes;

/// Los vídeos que se pasan en el programa (ADR 0027, decisión 4): bajo `/api/v1/`, `GET`
/// los lista y `PUT` y `DELETE` en `videos/<nombre>.mp4` suben y borran uno.
const String videosRoute = 'videos';

/// La carpeta de los vídeos, junto al partido. Como el icono, no se aparta con él.
const String videoDirName = 'videos';

/// Lo que se añade al nombre de un vídeo mientras se sube: se renombra al acabar bien.
const String videoUploadSuffix = '.subida';

/// Caracteres como mucho del nombre de un vídeo, `.mp4` incluido.
const int videoNameMaxChars = 80;

/// Bytes como mucho de un vídeo: 1 GB son 15 min a 8 Mbit/s, de sobra para un anuncio.
const int videoMaxBytes = 1 << 30;

/// Lo que una subida de vídeo deja libre como poco cuando la 4K local no va a grabar
/// (apagada, o sin sus [phoneDiskReserveBytes] libres): la copia del programa de un
/// partido de 2 h (~2,7 GB/h a 6 Mbit/s, 5,4 GB) más el suelo del disco de
/// `RecordingPolicy` (2 GB), redondeado a 8 GB decimales.
const int videoMinFreeAfterBytes = 8 * 1000 * 1000 * 1000;

/// Lo que tarda en sonar un vídeo desde `video/play`, en ms: el lector nativo tiene listos
/// los primeros fotogramas y el audio antes de que el programa los pida.
const int videoStartLeadMs = 300;

/// Margen, en ms, tras el final de un vídeo en que se espera el aviso del programa: sin
/// él, el vídeo se da por acabado.
const int videoEndGraceMs = 3000;

/// Cada cuánto el maestro manda la réplica aunque nada cambie (REPLICA_INTERVAL_S,
/// ADR 0023 §11).
const Duration replicaInterval = Duration(seconds: 5);

/// Las claves de idempotencia que viajan en la réplica: las de los últimos
/// IDEMPOTENCY_REPLICA_S, 64 como mucho (por encima de la ventana de reintento de 10 s).
const Duration idempotencyReplicaWindow = Duration(seconds: 30);
const int idempotencyReplicaMax = 64;

/// Donde guarda el esclavo la última pizarra, junto al partido.
const String replicaFileName = 'replica.json';

/// Lo más grande que puede ser una réplica (ADR 0023 §7), en bytes.
const int replicaMaxBytes = 64 * 1024;

/// La página del panel local que sirve el maestro en `/` (IOS-64).
const String panelAssetPath = 'assets/panel/index.html';

/// La carpeta del partido del maestro dentro de Documents (IOS-62).
const String matchDirectoryName = 'partido';

/// Las alineaciones del partido, junto al fichero del partido (`--lineups` del panel).
const String lineupsFileName = 'lineups.json';

/// Las alineaciones de los equipos que no juegan ahora, por la clave de su nombre (ADR 0032):
/// se apartan al empezar otro partido de la jornada y vuelven cuando el equipo juega.
const String lineupsArchiveFileName = 'alineaciones-equipos.json';

/// Ámbito del token que deja tocar el partido (`SCOPE_MATCH`).
const String panelScopeMatch = 'match';

/// Dónde se guarda «Este móvil dirige» (IOS-80).
const String prefersMasterKey = 'zero.prefersMaster';

/// Dónde se guarda el enlace elegido en la pantalla de lado (IOS-58), por su nombre
/// (`LinkMode.name`). Sin nada, el Multipeer de siempre.
const String linkModeKey = 'zero.linkMode';

/// Dónde se guarda la resolución de «Una cámara (sin pareja)» (IOS-99), por su nombre
/// (`ProgramResolution.name`). Sin nada, 1080p.
const String singleResolutionKey = 'zero.singleResolution';

/// Dónde se guarda el zoom de «Una cámara» (2026-10-30), como número: 0.5, 1 o 2.
const String singleZoomKey = 'zero.singleZoom';

/// Los zooms de «Una cámara», como en la app Cámara del iPhone: 0,5× es la lente entera (la
/// ultra gran angular), 1× el campo de la cámara principal y 2× el doble de cerca, que amplía
/// y se ve más blando. El nativo los traduce a un campo de visión (`FullLensView`).
const List<double> singleZooms = <double>[0.5, 1, 2];

/// El zoom de partida: la lente entera, como hasta el 2026-10-30.
const double singleDefaultZoom = 0.5;

/// PHONE_DISK_RESERVE_GB (IOS-57) en bytes: lo que tiene que quedar libre para que la
/// 4K local vaya encendida por defecto y arranque. Copia de `RecordingPolicy` en RigCore,
/// donde el nativo la hace cumplir.
const int phoneDiskReserveBytes = 40 * 1000 * 1000 * 1000;

/// Por debajo de esto libre, la copia local del programa no se abre y la abierta se cierra;
/// la emisión sigue (2026-10-24: la copia llenó el disco del 17 y se llevó la emisión).
/// Copia de `RecordingPolicy.programCopyFloorGb` en RigCore, donde el nativo la hace cumplir.
const int programCopyFloorBytes = 3 * 1000 * 1000 * 1000;

/// Lo que el nativo intenta dejar libre borrando copias viejas del programa: por debajo, se
/// avisa. Copia de `RecordingPolicy.programCopyTargetFreeGb`.
const int programCopyTargetFreeBytes = 12 * 1000 * 1000 * 1000;

/// Lo que ocupa la copia del programa por hora de emisión: 5,63 GB en 2 h 53 min el 24-oct
/// (1080p a ~6 Mbit/s y el AAC), redondeado a 2 GB.
const int programCopyBytesPerHour = 2 * 1000 * 1000 * 1000;

// --------------------------------------------------------------------------- //
// Anuncios de la franja (IOS-49, ADR 0008 y ADR 0022 §6)
// --------------------------------------------------------------------------- //

/// Vueltas que da un anuncio de evento antes de devolver el turno a la rotación
/// (`EVENT_LOOPS` de tools/ad_director.py): unos 40 s con anuncios de 20 s.
const int adEventLoops = 2;

/// La versión del manifiesto de anuncios que entiende la app (`AD_MANIFEST_VERSION`).
const int adManifestVersion = 1;

/// La carpeta de los anuncios dentro de Documents: la que lee `setAdPlaylist`.
const String adsDirectoryName = 'ads';

/// Lo más que se espera a una respuesta del VPS al bajar los anuncios. Un PNG de la
/// franja son decenas de KB; si en 30 s no llega nada, la red se cayó y se reintenta
/// con el siguiente `ads_changed` o al reconectar.
const Duration adDownloadTimeout = Duration(seconds: 30);

// --------------------------------------------------------------------------- //
// Emparejado con el VPS por el QR Soporte (IOS-68, ADR 0022 §3)
// --------------------------------------------------------------------------- //

/// La versión del JSON del QR Soporte (`PAIRING_VERSION` en tools/nube/pairing.py). Uno
/// de otra versión se rechaza: hay que actualizar la app.
const int vpsPairingVersion = 1;

/// El esquema del túnel. Solo con TLS: la URL va con el `rig_key` en la cabecera.
const String vpsTunnelScheme = 'wss';

/// La ruta de MediaMTX del programa (`PROGRAM_SRT_PATH`; `ProgramSrt.path` en RigCore).
const String programSrtPath = 'programa';

/// Caracteres de la passphrase del SRT: lo que admite SRTO_PASSPHRASE (ADR 0022 §2).
const int programSrtPassphraseMinChars = 10;
const int programSrtPassphraseMaxChars = 79;

/// Caracteres del streamid como mucho (ADR 0022 §1; `ProgramSrt.maxStreamIdLength`).
const int programStreamIdMaxChars = 512;

/// El mayor puerto UDP.
const int maxPort = 65535;
