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
const int calibrationChunkBytes = 8 * 1024 * 1024;

/// Fallos seguidos antes de rendirse. Veinte con tres segundos entre medias es aguantar un
/// minuto de corte, que es más que cualquier traspaso de satélite.
const int calibrationMaxRetries = 20;

/// Espera entre un fallo de la subida y el siguiente intento.
const Duration calibrationRetryDelay = Duration(seconds: 3);

/// Plazo de cada petición, trozo incluido: 8 MiB a 1 Mbit/s son ~70 s, con margen.
const Duration calibrationRequestTimeout = Duration(minutes: 3);
