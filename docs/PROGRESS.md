# PROGRESS

Tablero de la migración a la arquitectura B en este repo: las tarjetas IOS y SPK de
`football-ai/docs/plan-dos-moviles/app-ios.md`. Se anota al cerrar cada tarea: ID ·
estado · qué quedó fuera · siguiente paso. Todo va en la rama `migracion/dos-moviles`;
`main` no recibe nada.

Una tarea que necesita el móvil no pasa a ✅ hasta que Alexander la ha probado en el
iPhone.

Leyenda: ✅ hecha · 🚧 en curso · ⛔ bloqueada · ⬜ pendiente

---

## 2026-10-04 · IOS-30 — álgebra y geometría del soporte (rig.py) · ✅

**Hecho**
- `RigCore/Geometry/`: `Mat3.swift` (3×3 y Vec3 en Double, SIN simd: mismas
  fórmulas y mismo orden de operaciones que numpy), `RigGeometry.swift`
  (CameraSide, CameraIntrinsics con `scaled` del medio píxel y redondeo
  banker's como Python, `fromHfov`, CameraPose `matrix = R_yaw·R_pitch·R_roll`
  y `fromMatrix`, RigDirection.toUnit, `angularDistanceRad`), `RigModel.swift`
  (directionOf, project, projectRays, sees, inOverlap, rotation, withPose y el
  códec de rig.json v1 — otra versión se RECHAZA) y `CameraMount.swift` (la F
  del giro de 180°, involutiva, con el punto y la matriz dando lo mismo).
- `RigModelTests`: un runner por `fn` recalcula los 31 casos del dorado
  rig.json con `Golden.mismatch` — TODOS dentro de tolerancia a la primera.
  `RigModel.fuse` se salta A PROPÓSITO (IOS-32) y el meta-test exige que lo
  saltado sea exactamente eso. `Fixtures/soporte-pod.json` (la calibración
  nominal del pod: 4K, ±40°, roll π en la izquierda) carga y responde; cuando
  haya un soporte.json de partido real, se sustituye el fixture.
- `GoldenAccess.swift`: accesores de GoldenValue reutilizables por IOS-31+.
- El meta-test del manifiesto aprende que la muestra del N0 es JSONL (línea a
  línea), no un documento de casos: el sync de EV-02 lo había roto.

**Siguiente paso**: IOS-31 (reprojection) → IOS-32 (la fusión quita su salto)
→ IOS-36 → IOS-33/34/35 → IOS-37, la cadena entera del director en RigCore.

## 2026-10-04 · SPK-51 — D-FINE-N en el ANE del A19 · ✅ medido (la decisión la firma REF-33)

**La medida (iPhone18,3, 1000 predicciones tras calentar, CPU_AND_NE)**
- **0 % del coste en el ANE** en las DOS formas: las 1754 ops del programa caen
  fuera ENTERAS (MLComputePlan: ops_off_ane = ops_total). La atención deformable
  (tensores de rango 5, los ~33 que el ane_lint de ML-10 ya marcó) expulsa el
  programa del ANE y Core ML lo manda a GPU.
- p50 (borde de cubo, pesimista): banda 1920×576 **150 ms**; retranqueo 1536×512
  **100 ms**. A 7,5 Hz el ciclo entero dispone de ~133 ms: no cabe, y además
  compite con Metal (la térmica pasó de nominal a serious en 269 s de banco).
- compile 155/131 ms; load **3,5/3,9 s** (la especialización del primer arranque).
- Dorado del Mac frente al iPhone: 0 violaciones (delta 0.0 exacto en logits y
  boxes — tan exacto que conviene un contraejemplo; apuntado abajo).

**Recomendación para REF-33**: ni 1920×576 ni 1536×512 salvan un 0 % de ANE —
**se activa el plan B CNN del ADR 0020 (YOLOX-Tiny o CenterNet-MNv4)**. La
decisión formal es de REF-33/propietario.

**Pendiente menor**: verificar el delta 0.0 exacto del dorado D-FINE con un
contraejemplo (una entrada perturbada debe dar delta > 0): si el lector casara
mal los nombres, 0 violaciones saldría gratis.

## 2026-10-04 · SPK-52 — ROI-lite en el ANE: mosaico, lote de ROIs y multifunción · ✅

**La medida (mismas condiciones)**
- **100,00 % del coste en el ANE** en las CUATRO formas (las 192 ops «fuera»
  son const/reshape con coste 0 del MLComputePlan). ANE-limpio por diseño ✓.
- Mosaico 10 m [1,3,896,1920]: **p50 12 ms** ✓ (objetivo ≤14). Mosaico 6 m
  [1,3,1296,1920]: **16 ms** — se pasa del objetivo: dato para que REF-33 elija
  la altura del mosaico (10 m sí cabe).
- Lote de 2 ROIs: 256 → **1 ms**; 320 → 1-2 ms ✓✓ (objetivo ≤3 ms).
- compile ≤51 ms; load ≤515 ms.

**La multifunción (2026-10-04, segunda pasada, térmica nominal entera)**
- Exportada con `tools/export_multifunction.py` del repo de entrenamiento
  (global 896×1920 / roi 2×256×256, pesos deduplicados): **1,036× el peso de un
  export suelto** ✓ (≤1,1×). Informe en `bench/model-bench-1791128969.json`.
- **100 % del ANE en las dos funciones**. global p50 **8 ms** (mejor aún que el
  suelto de la primera pasada: aquella corrió con térmica serious tras la GPU
  del D-FINE); roi p50 **0,5 ms**.
- **Cambiar de función no cuesta nada medible**: 200 predicciones alternadas
  global/roi dan p90 = 8 ms = el p50 del propio global (p99 12, un cubo de
  cola) ✓ objetivo ≤1 ms de sobrecoste. El arnés gana `function` en bench.json
  (MLModelConfiguration.functionName) y el paso de cambio alternado.

**Los cinco criterios de la tarjeta, medidos y en verde.** La altura del
mosaico (10 m sí cabe, 6 m da 16 ms) la decide REF-33 con estas cifras.

## 2026-10-03 · SPK-50 — arnés de banco de modelos en el iPhone (ModelBenchTests) · ✅

**Hecho**
- `Tests/RigMediaTests/Device/ModelBenchTests.swift` (en ZeroKit, sin target
  nuevo): lee `BenchResources/bench.json` (modelos, computeUnits, predicciones)
  y por cada modelo compila el .mlpackage (tiempos de compile y load por
  separado), lee el MLComputePlan (ops totales, ops fuera del ANE y % del coste
  en el ANE), mide p50/p90/p99 tras calentar con os_signpost (el bucle de
  predicción es SÍNCRONO a propósito: en contexto async Swift resuelve
  `prediction` a su sobrecarga async y el await ensucia la medida) y comprueba
  el bundle dorado de ML-12 contra la ruta coreml_fp16 con su tolerancia.
- El informe sigue el esquema de BenchRunner (IOS-08): Documents/bench del
  runner + XCTAttachment + volcado al log entre MODELBENCH-REPORT-BEGIN/END.
  `BenchReport` gana un init público (el memberwise era interno).
- `Device/GoldenBundle.swift`: el lector del bundle de ML-12 (manifest, .bin
  little-endian f4/f2/u1/i4, sufijos _NNN por muestra, tolerancia OBLIGATORIA).
- `BenchResources/` como recurso del target (solo el README en git); sin
  `bench.json` el banco se salta solo (Mac/CI en verde). `bench_pull.sh` acepta
  un BUNDLE opcional: el runner de XCTest escribe en su propio contenedor.

**Tests**: `GoldenBundleTests` (3, con datos sintéticos, corren en el Mac) y el
skip limpio de `ModelBenchTests` sin recursos. `swift build --build-tests` y
`check_layers.sh` en verde.

**La pasada en el iPhone (2026-10-04, iPhone18,3, iOS 26.6.1)**: 7 modelos en
una tacada, informe en `bench/model-bench-1791127899.json`, bajado con
`bench_pull.sh` ✓. Dos realidades medidas por el camino:
- **«Tool-hosted testing is unavailable on device destinations»**: los tests de
  un paquete SPM no corren en un iPhone físico sin app anfitriona. El carril del
  dispositivo es el de IOS-08 (`BENCH=model-bench` por BenchRunner, recursos en
  Documents/bench-resources); el XCTest queda para el Mac y el simulador, donde
  `xcodebuild test -only-testing:ModelBenchTests` sí vale.
- El primer informe murió al codificar: la CARGA del D-FINE pasó de 1 s, el cubo
  de desborde del histograma percentila a INFINITO y JSON no codifica inf.
  Arreglo: compile/load como contadores en ms exactos (son una medida, no una
  distribución) y cubos con cola larga (hasta 60 s) para el predict.
- La app muere si el teléfono se BLOQUEA a mitad de banco (iOS suspende al
  bloquear): el banco pide Bloqueo automático en Nunca.
- El % del ANE se informa bien donde hay con qué: ROI-lite da 100,00 % (es
  ANE-limpio por diseño); el smoke de 8 canales da 0 % — canales no múltiplos
  de 16, exactamente lo que marca el ane_lint de ML-10. El criterio «≥95 % con
  el smoke» suponía un paquete que nunca podía dárselo; el arnés INFORMA, y las
  cifras de aceptación de verdad son las de SPK-51/52.
- El dorado de ML-12 se comprobó en el iPhone: demo delta 4.9e-4 < 5e-2, 0
  violaciones. (El refactor del motor a Sources entró con el commit del sync de
  REF-44, 6549ad4.)

## 2026-10-03 · SPK-03 — spike: concurrencia de VideoToolbox · ✅ aprobado SIN la HEVC 4K del maestro

**Hecho**
- Banco `vt-concurrency` en BenchRunner (IOS-08): cámara 4K30 propia, HEVC 4K de
  45 Mbit/s a archivo, 4K→1080p por VTPixelTransferSession (hardware, no kernels),
  H.264 1080p por IOS-50 (6 Mbit/s master, 25 slave) y, en el master, la vuelta por
  IOS-51 con SPS/PPS en banda. Registra lo de la tarjeta: err_12915 (en creaciones y
  transferencias), fps_x100, did_drop, hevc_dropped, vt_errors, histogramas de
  intervalo de captura y de escalado, térmica cada 5 min. Parámetros: profile,
  duration_s (humo con duration_s=30).
- VtConcurrencyBenchTests (3): parámetros, perfiles y valores de tarjeta.
  Paquete 112/112, capas limpias, build ✓.

**Primera pasada (master CON HEVC, iPhone18,3, 2026-10-03, 30 min)**: NO pasa —
49 307 fotogramas, fps medios 27,38 (criterio p5 ≥29,5), 4660 didDrop. Pero 0
err_12915, 0 errores VT, 0 descartes del HEVC y térmica nominal las 8 muestras: es
contención, no calor. Pista: solo 18 683/49 307 llegaron al H.264 — el pool del
codificador se agotaba. Dos culpas propias del banco, corregidas para la repetición:
la decodificación iba EN LÍNEA en el hilo de la cámara (ahora en su cola, como en la
realidad) y el pool agotado se perdía en silencio (ahora contadores pool_starved,
encoder_dropped y decoder_dropped). BENCH_PARAMS llega ya de Dart al informe.

**Segunda pasada (master CON HEVC, banco corregido, 2026-10-03)**: sigue sin dar —
24,0 fps y 10 328 didDrop con 0 err_12915, 0 pool_starved, 0 descartes de colas y
térmica nominal→fair. El dato ya es limpio: **este iPhone no sostiene cámara 4K30 +
HEVC 4K 45 Mbit/s + H.264 1080p + decodificación a la vez**; es contención del motor
de vídeo, no del banco ni del calor.

**Tercera pasada (master SIN HEVC, `BENCH_PARAMS={"hevc":"0"}`)**: ÉXITO — 30,00 fps,
37 083 fotogramas, didDrop 3 (el arranque), 0 err_12915, 0 en todas las colas,
térmica nominal las siete muestras, encoded = decoded = 37 082, escalado p99 5 ms.
La regla de la tarjeta aplica: **el spike queda aprobado sin la HEVC 4K del maestro,
y la escalera térmica (IOS-06) es quien la suelta primero en partido**.

**Consecuencia para el propietario**: el hallazgo toca también al perfil slave (H.264
25 Mbit/s + HEVC 4K): con la HEVC puesta no va a sostener 30 fps en este hardware. La
pasada slave formal se hará con los dos móviles montados (junto a SPK-02, con los
hubs), ya con esta expectativa.

---

## 2026-10-03 · IOS-51 — decodificador H.264 a IOSurface para Metal · ✅

**Hecho**
- `RigCore/Media/NalUnits.swift` (puro): AVCC ↔ Annex B con códigos de arranque de 3
  y 4 bytes, catálogo de tipos y recorrido que para ante una longitud corrupta.
- `RigMedia/Video/VideoDecoder.swift`: VTDecompressionSession con el formato sacado
  de los SPS/PPS EN BANDA (el emisor los pega a cada IDR: `H264ParameterSets`),
  destino NV12 sobre IOSurface compatible con Metal, RealTime, cola de salida de 2
  huecos (dropOldest) y SEI leída por fotograma. Tras un hueco (`reportGap()`, lo
  llama el transporte), un error o antes del primer SPS: `onNeedsIDR` y todo lo que
  no sea IDR se tira hasta reabrir.
- Tests: NalUnitsTests (4) y VideoDecoderTests (2): la ida y vuelta con IOS-50
  (30 fotogramas 720p, SEI 30/30, PSNR ≥38 en la muestra, IOSurface presente) y el
  hueco inyectado que pide IDR, no deja salir nada sin referencia y se reabre con el
  IDR. Paquete 109/109, capas limpias, build ✓.

**Fuera**: el p99 ≤10 ms en el iPhone queda como objetivo para el banco de regresión
(IOS-18), igual que la latencia del codificador.

**Siguiente**: IOS-52 (transporte de las partes) espera IOS-11/16 de campo y SPK-02.

---

## 2026-10-03 · IOS-15 — volcado NV12 crudo para el salto de dominio · 🚧 falta el partido de prueba

**Hecho**
- `RigMedia/Obs/Nv12Dumper.swift`: cada N segundos (60 por defecto) guarda el
  fotograma de ANTES del codificador en Documents/nv12/<lado>-<rigMs>.nv12. Formato
  acordado para ML-18: `[u32 BE longitud][cabecera JSON][plano Y][plano CbCr]`, planos
  sin el relleno del stride y cabecera con schema, rig_ms, side, tamaño, FourCC y el
  color (matriz, primarias, transferencia). Copia síncrona (el búfer es de quien
  llama), escritura en cola propia, cuentas written/failures, `drain()` para tests.
- Gancho en `CaptureEngine.captureOutput` tras el pipeline: se activa lanzando con
  `NV12_DUMP_S=<segundos>` (y `NV12_DUMP_SIDE`) en el entorno, igual que el secreto
  del enlace: es modo banco, sin interruptor en pantalla.
- Nv12DumperTests (2): fichero con cabecera y planos pelados byte a byte, y el
  intervalo respetado por tiempo del soporte. Paquete 103/103, capas, build ✓.

**Pendiente para el ✅**: un partido de prueba con el volcado activo deja ficheros
legibles por ML-18 sin didDrop ni caída de fps (se puede colar en la próxima
grabación larga lanzando la app con el entorno puesto).

---

## 2026-10-03 · IOS-50 — codificador H.264 de baja latencia con SEI rigMs · ✅

**Hecho**
- `RigCore/Media/H264Sei.swift` (puro): SEI user_data_unregistered con UUID propio
  («football-ai.rig0»), rigMs y viewId, DENTRO de la unidad de acceso (ADR 0022), con
  la prevención de emulación del Anexo B —un rigMs pequeño la pisa siempre— y los
  ayudantes AVCC (insert/find). 6 tests, incluido escape/unescape como inversos.
- `RigMedia/Video/VideoEncoder.swift`: VTCompressionSession H.264 High en baja
  latencia (EnableLowLatencyRateControl, RealTime, sin reordenar), GOP atado a
  `PROGRAM_GOP_S` = 2 s (ADR 0021), AverageBitRate + DataRateLimits con margen 1,5×,
  MaxAllowedFrameQP 45, IDR bajo demanda, bitrate en marcha, pool expuesto y salida
  AVCC a una BoundedQueue (16, dropOldest). El pool se fija a NV12 Metal-compatible:
  sin atributos, VT entrega su formato comprimido '&8v0', cuya memoria no es
  stride×alto y una escritura por CPU se sale del búfer.
- `VideoConstants.swift` con unidades y porqués (los márgenes, provisionales hasta el
  banco en el iPhone).
- Aceptación en macOS: 300 fotogramas 1080p a 6 Mbit/s codificados y decodificados,
  **SEI recuperada en 300/300** y PSNR ≥38 dB; ≥5 IDR en 10 s; el IDR forzado sale
  IDR con cambio de bitrate a mitad. Paquete 101/101, capas limpias, build ✓.

**Fuera**: la latencia p99 ≤20 ms en el iPhone queda como objetivo medible cuando el
banco de regresión (IOS-18) encadene los bancos de vídeo.

**Siguiente**: IOS-51 (decodificador a IOSurface) o IOS-15 (volcado NV12).

---

## 2026-10-03 · IOS-13 — reloj del soporte en nativo con casos compartidos · ✅

**Hecho**
- `RigCore/Time/RigClock.swift`: puerto fiel de `lib/src/rig_clock.dart` (misma
  aritmética entera, filtro por RTT ×3, 240 muestras, recta con ventana ≥60 s y tiempo
  centrado), con cerrojo porque el enlace añade muestras desde su cola y la cámara
  pregunta por fotograma. `solveClockSample` incluido.
- Casos compartidos en `ios/ZeroKit/Tests/RigCoreTests/Fixtures/rig_clock_cases.json`
  (fuera de Golden/, que lo controla el manifiesto): los genera
  `flutter test tools/gen_rig_clock_cases.dart` desde la referencia Dart y los leen
  `test/rig_clock_test.dart` (candado de regresión) y `RigClockTests.swift` (paridad
  ±1 ns y ±1e-6 ppm). 7 casos de reloj y 4 de despeje, con truncado hacia cero,
  filtro, deriva limpia y con ruido, y el tope de 240.
- `RigLinkSession` alimenta su `RigClock` con cada clock_pong y emite
  `onClockEstimate`; `CaptureEngine.rigClock` aplica el desfase por fotograma sin
  pasar por Pigeon (con Multipeer sigue `setClockOffsetNs` desde Dart).
- Dart recibe `onClockEstimate(offsetNs, driftPpm, samples, uncertaintyNs)` y
  `CaptureSession` sale de esperandoReloj con él; la etiqueta del reloj prefiere la
  estimación nativa. La tarjeta decía RigFlutterApi, pero va en `CaptureFlutterApi`:
  RigFlutterApi lo monta la página de bancos y el aviso moriría al salir de ella.
- Paquete 93/93, 215 tests Dart, analyze limpio, build de dispositivo ✓.

**Siguiente**: IOS-15 (volcado NV12) y, con los hubs, la aceptación de campo de
IOS-11/12/16.

---

## 2026-10-03 · IOS-12 — RigLink sobre Network.framework · 🚧 falta el campo (hubs)

**Hecho**
- `RigNet/RigLinkSession.swift`: el apretón hello → auth → clave de sesión → tag por
  trama; el reloj por MEDIOS (clock_ping/clock_pong, ráfaga de 10 × 250 ms y después
  cada 5 s, solo pregunta el esclavo, sellos pegados al envío); PTS, color y órdenes
  por CONTROL encapsulando el RigMessage de hoy en tramas legacy; ventana de 64 en
  medios; órdenes solo del maestro.
- `RigLinkSessionTests` con un transporte falso con buzón (un socket cerrado no
  entrega): conecta con el mismo secreto, rechaza con el malo o con dos del mismo
  lado, la ráfaga del reloj y los sellos crecientes, el pong repetido que la ventana
  tira, los PTS que llegan o vencen a vacío con el cable cortado, y las órdenes que
  solo viajan del maestro. Paquete 90/90.
- El interruptor en `CaptureHostApiImpl`: `RIG_LINK_MULTIPEER=0` levanta
  `RigLinkNW` (adaptador del protocolo `PeerLinking`, nuevo en Runner) sobre
  `NWLinkTransport`; sin la variable sigue el Multipeer de hoy. El secreto entra por
  `RIG_LINK_SECRET` (base64) hasta que IOS-97 lo lleve al Keychain; sin secreto,
  error claro. RigNet enlazado al target Runner. flutter analyze limpio, 212 tests
  Dart, build de dispositivo ✓.

**Pendiente para el ✅** (con los hubs): la aceptación de campo con dos iPhone por
Ethernet — conectar, reloj vivo, órdenes y PTS — con RIG_LINK_MULTIPEER=0.

---

## 2026-10-03 · IOS-16 — medios del enlace por UDP y hello con HMAC · 🚧 falta el campo (hubs)

**Hecho**
- `RigNet/LinkAuth.swift` (la decisión 3 del ADR 0023, con CryptoKit — en RigNet a
  propósito: RigCore solo importa Foundation): la huella de la TXT (8 hex), el `mac`
  del auth mutuo sobre los dos hello tal como viajaron, la clave de sesión por HKDF de
  los dos nonces, el `session` (4 bytes derivados), el `tag` de 16 B por trama sobre
  cabecera‖payload (`LinkFrame.signableBytes()`, nuevo), y el secreto del mando
  derivado por partido (base64url, 43 caracteres). Comparaciones en tiempo constante.
- `RigCore/Wire/ReplayWindow.swift`: la ventana de 64 contra repeticiones, estilo
  IPsec: desorden dentro de la ventana sí, duplicado o retrasado no, con cuentas.
- `NWLinkTransport` gana el canal de medios: `_footballai-media._udp` anunciado con la
  misma TXT, envío con el `Fragmenter` (seq propio por trama), recepción con el
  `Reassembler`, y las cuentas de la tarjeta: huecos de `seq` como pérdidas y llegadas
  separadas >100 ms como parones. La basura por medios se cuenta y NO cierra (solo
  control cierra, §2). En los tests el UDP ata el puerto TCP+1 cuando el efímero ya se
  conoce.
- Tests (paquete 83/83): auth que abre con el secreto bueno y cierra con el malo o con
  un hello tocado; misma sesión en los dos lados y distinta al reconectar; tag que
  pilla un payload alterado; token del mando por partido; ventana de 64 completa; y el
  loopback de medios con una trama de 2,5 datagramas que llega entera y el parón
  contado.

**Pendiente para el ✅** (con los hubs): hello malo rechazado entre dos iPhone reales y
el informe de RTT/pérdidas/parones por Ethernet. El Keychain lo aprovisiona IOS-97.

**Siguiente**: IOS-12 (RigLinkSession sobre este transporte).

---

## 2026-10-03 · IOS-11 — transporte de control del enlace por Ethernet · 🚧 falta el campo (hubs)

**Hecho**
- `RigNet/LinkTransport.swift`: el contrato que verá RigLinkSession (IOS-12): onFrame
  con su canal, onState, onPath (qué interfaz lleva internet), stats y send. Quien lo
  usa no sabe si debajo hay Network.framework, un loopback o un transporte falso.
- `RigNet/NWLinkTransport.swift` (control TCP): el izquierdo anuncia
  `_footballai-rig._tcp` con la TXT {lado, huella} y el derecho busca con NWBrowser,
  en cualquier orden de arranque; `requiredInterfaceType` Ethernet (`.wifi` para el
  banco, `nil` para el loopback de los tests). Reconexión con espera creciente y
  **tope de 2 s** (decisión 3 del ADR 0023). Tramas separadas por su `length` con
  `LinkFrame.decode`; la basura por control cierra la conexión y se cuenta (§2).
  Una conexión nueva en el que escucha sustituye a la vieja (el patrón anti-fantasma
  de RigLink). NWPathMonitor dice qué interfaz lleva internet. Los medios UDP y el
  hello autenticado van en IOS-16.
- RigNetTests (target nuevo, loopback de macOS): conexión y tramas en los dos
  sentidos, reconexión tras caerse el que escucha (contra el mismo puerto), la basura
  que cierra, y el tope del backoff. 4/4; paquete entero 72/72.

**Pendiente para el ✅** (el campo, cuando lleguen los hubs USB-C PD+Ethernet y el
switch de la lista de compras): conexión <2 s en cualquier orden, reconexión <3 s al
reenchufar el cable, RTT p50 <2 ms y el informe diciendo qué interfaz lleva internet.

**Siguiente**: IOS-16 (hello autenticado y medios UDP), que desbloquea IOS-12.

---

## 2026-10-03 · IOS-10 — protocolo del enlace: tramas, tipos y fragmentación · ✅

El cable entre los dos móviles, escrito antes de abrir ningún socket (el formato manda
el ADR 0023 §1-§2, que es quien define la tarjeta).

**Hecho**
- `RigCore/Wire/LinkConstants.swift`: LINK_DATAGRAM_PAYLOAD_B=1200 (cabe en el MTU
  mínimo de IPv6), LINK_MAX_FRAME_B=1 MiB y LINK_REASSEMBLY_FRAMES=4, los tres que la
  tarjeta manda fijar aquí.
- `RigCore/Wire/LinkFrame.swift`: la trama del ADR —magic «ZL», versión, type, flags
  (IDR, vista extrapolada), session, seq, rig_ms u64, length— más el tag de 16 B, que
  no va en hello/auth. El catálogo entero con sus 24 códigos fijos (hello…color_means),
  el canal de cada tipo (control TCP / medios UDP) y el decode de stream con tres
  salidas: trama, faltan bytes, o inválida (y por control se cierra). Una length
  disparatada es «inválida», no una reserva de 50 MB.
- Payload de `detections` cerrado: infer_ms u16 + n u16 + **10 B por caja** (u16×4
  nativos, clase u8, score u8). La tarjeta decía «9 B», pero su propia aceptación
  —30 cajas ≤300 B— da 10; anotado en el código.
- `RigCore/Wire/Fragmenter.swift` + `Reassembler`: troceo a ≤1200 B con cabecera
  {magic, session, seq, índice, total}; reensamblado por seq con 4 tramas a medias
  como mucho (acotado por número, como FramePairer); duplicados ignorados, totales
  contradictorios y basura contados, fragmento perdido = trama fuera y contada.
- El `Reader` de RigMessage asciende a `BigEndianReader` del módulo: una sola
  implementación de lectura/escritura big-endian para todo el cable.

**Aceptación**: todos los tipos van y vuelven iguales; 10.000 tramas aleatorias o
truncadas sin reventar; reensamblado desordenado ✓; fragmento perdido descarta y
cuenta ✓; 30 detecciones = 300 B ✓. `swift test` 68/68, capas limpias, build ✅.

**Siguiente**: IOS-12/IOS-13 (reloj y emparejado sobre el enlace) o IOS-16; IOS-11
necesita los hubs físicos.

---

## 2026-10-03 · IOS-09 — enganche del pipeline sin retener los búferes de la cámara · ✅

**Hecho**
- `RigMedia/Pipeline/RigPipeline.swift`: `ingest(sampleBuffer, rigNs)` no bloquea —
  apunta y vuelve—; una cola propia copia los dos planos NV12 al FrameRing con
  MTLBlitCommandEncoder y suelta el búfer de la cámara al completar. Con un blit en
  vuelo, el nuevo se descarta sin retener nada: **uno retenido como mucho**, por
  construcción. Guarda por fotograma rigNs, PTS local, índice y la matriz intrínseca
  del adjunto (columnas de matrix_float3x3 → filas, saltando el relleno). Consumidores
  vacíos (`onFrame`): el detector llega con IOS-23+.
- `CaptureEngine.captureOutput`: la llamada va tras `RigTimecode.write` y antes de
  `publisher.append`, como pide la tarjeta; la grabación y la emisión no cambian. El
  pipeline se crea al configurar la cámara con el tamaño real aplicado.
- Banco `pipeline-noop` registrado en BenchRunner (IOS-08): fotogramas sintéticos 4K
  por el blit, histograma de la copia, contadores stored/dropped; parámetros frames/
  width/height.
- RigPipelineTests (3): la luma copiada de verdad al anillo con sus metadatos; el
  segundo fotograma con uno en vuelo se descarta sin retenerse (gancho de test que
  frena el blit); los índices entregados conservan el orden.

**Aceptación**
- Mac: `swift test` 56/56; analyze 0; `flutter test` 212; build ✅; capas limpias.
- **El banco `pipeline-noop`, medido en el iPhone el 2026-10-03**: 300 fotogramas 4K
  en 0,58 s, **300 almacenados y 0 descartados**, térmica nominal → nominal; blit p50
  en el cubo de ≤1 ms de pared y p99 en el de ≤8 ms (el calentamiento de Metal en los
  primeros fotogramas). A 30 fps el blit es ~2 % del presupuesto del fotograma.
- **El remojo, grabado por Alexander el 2026-10-03** (left-1791044161.mov, 9,85 GB):
  31,34 min, 56 396 fotogramas, fps medios 29,991 (el nominal exacto), **56 396/56 396
  códigos de tiempo legibles, 0 fallos**. Tres huecos de PTS: 500 y 100 ms en el
  primer segundo (el arranque del writer) y uno de 66,7 ms —un fotograma— en el
  minuto 23. Un fotograma perdido en media hora con el pipeline activo: cerrado.

**Siguiente**: IOS-10 (el enlace con Network.framework).

---

## 2026-10-03 · IOS-08 — modo banco, informes JSON y contrato Pigeon del pipeline · ✅ pasada en el iPhone el 2026-10-03

La prueba de una sola acción, montada de punta a punta.

**Hecho**
- `pigeons/rig_api.dart` (nuevo contrato del pipeline, separado del de la cámara):
  `runBench(name, paramsJson)` asíncrono y `RigFlutterApi.onBenchProgress`. Generado
  con `includeErrorClass: false` para no redeclarar el PigeonError de CaptureApi (el
  primer intento rompió el build y quedó aprendido).
- `RigMedia/Obs/BenchRunner.swift`: registro de bancos (`noop` prueba la tubería),
  informe Codable con utsname.machine, versión de iOS, línea térmica (al empezar y al
  acabar), histogramas por etapa, contadores y parámetros; escrito en
  Documents/bench/<nombre>-<epoch>.json con claves ordenadas.
- `ios/Runner/RigHostApiImpl.swift` (async/await, registrado con la gema) +
  AppDelegate lo retiene. `lib/src/bench_page.dart`: con
  `--dart-define=BENCH=<nombre>` arranca sola, enseña progreso y la ruta del informe.
- `tools/bench_pull.sh` (devicectl, UDID del iPhone de Alexander por defecto) y
  `tools/bench_summary.dart` (corre en Mac y Windows; `summarize()` probado).

**Aceptación**
- Mac: `swift test` 53/53 (BenchReportTests fija las claves del JSON como contrato de
  bench_summary carácter a carácter); `flutter test` 212; analyze 0; build ✅.
- **La pasada, hecha el 2026-10-03 por WiFi y sin tocar la pantalla**: build con
  `BENCH=noop`, instalada y lanzada con devicectl; el JSON apareció a los segundos con
  `iPhone18,3` (el 17 base) e iOS 26.6.1; `bench_pull.sh` lo bajó (corregido el
  destino: devicectl copia la carpeta como `bench/`, no `bench/bench/`) y
  `bench_summary.dart` lo resumió. La misma tubería corrió después `pipeline-noop`.

**Siguiente**: IOS-09 cerró su banco con esta misma pasada.

---

## 2026-10-03 · IOS-07 — modo partido: pantalla mínima en los móviles del soporte · ✅

Emitiendo, el móvil ya no gasta GPU ni brillo en enseñarse a sí mismo.

**Hecho**
- `capture_page.dart`: mientras se emite, la vista `capture-preview` se **desmonta**
  (el UiKitView sale del árbol y la capa nativa se libera) y queda una tarjeta negra a
  1 Hz con «GRABANDO · reloj» y la pista del toque. Un toque la enseña
  `previewPeekDuration` (30 s, en constants.dart) y se vuelve a esconder sola; si la
  emisión para en mitad del vistazo, el temporizador se cancela.
- Pigeon `setScreenDim(bool)`: el brillo a 0,05 (no a cero: un móvil «apagado» en la
  cancha invita a que alguien lo encienda) guardando el que había, y restaurado al
  salir. Lo dispara la **sesión** al entrar y salir de `grabando` —no la página—, para
  que un stop por orden del maestro también restaure; el vistazo lo levanta y lo
  vuelve a bajar.
- `Info.plist`: `CADisableMinimumFrameDurationOnPhone` estaba en `true` (ProMotion a
  120 Hz liberado) y la tarjeta pide `false`: corregido. La UI no necesita más de
  60 Hz y el calor sí importa.

**Aceptación**
- widget_test (fake_async): al GRABAR se desmonta la vista y `setScreenDim(true)`; al
  PARAR vuelve y restaura; el toque la enseña y a los 30 s se esconde y re-atenúa,
  con la secuencia exacta [true, false, true] en el fake. `flutter test` 211;
  `flutter analyze` 0; build de dispositivo ✅.
- El «−50 % de GPU en 10 min» es un objetivo de Instruments: se mide en la próxima
  sesión con el móvil enchufado (va junto al vistazo de signposts de IOS-05).

**Siguiente**: IOS-08 (modo banco), que es la prueba de una sola acción de Alexander.

---

## 2026-10-03 · IOS-06 — temperatura y presión con escalera de degradación · ✅

El orden del propietario, en código: primero se suelta la IA, después la calidad del
programa, después la emisión; la grabación local, la última.

**Hecho**
- `RigCore/Runtime/DegradationLadder.swift` (lógica pura, como el muelle del servidor):
  ThermalLevel y PressureLevel espejo de ProcessInfo y AVCaptureDevice; el objetivo es
  el peor de los dos sensores, y sin carga sube un escalón (a batería sola no hay
  margen). Empeorar es inmediato; mejorar exige sostener `recoverS` y baja UN escalón
  cada vez. `LadderActions` acumulativas: L1 jugadores a 5 Hz y balón global fuera; L2
  IA apagada; L3 programa a 720p y ×0,6; L4 el esclavo para su parte y el maestro pide
  la cesión (sin esclavo sano sigue como L3). La grabación local no la toca ningún
  nivel.
- `RigCore/Runtime/LadderConstants.swift`: recoverS=60 s, 7,5→5 Hz, 1080→720, ×0,6 —
  todo PROVISIONAL hasta M19 (SPK-54/SPK-07), anotado en el propio fichero.
- `RigMedia/Thermal/ThermalMonitor.swift`: thermalStateDidChangeNotification + KVO de
  systemPressureState (solo iOS), convertidos a los niveles puros.
- Contrato pigeon: enum `SystemPressure` y campos `pressure` y `ladderLevel` en
  CaptureStatus; regenerado. CaptureEngine engancha el monitor al configurar la cámara
  y avanza la escalera en cada foto de estado (1 Hz) con el reloj de host; cargando =
  charging o full.
- Etiquetas: filas «Presión» y «Escalera» en la tarjeta DISPOSITIVO, en rojo desde
  serious / L2.

**Aceptación**
- La tabla de secuencias en DegradationLadderTests: subida inmediata, recaída que
  reinicia el contador, bajada de un escalón por recoverS, sensores al peor, batería
  +1, L4 por rol y la grabación intocable. `swift test` 50/50; `flutter analyze` 0;
  `flutter test` 209; build de dispositivo ✅.
- La prueba de Xcode (Device Conditions → Thermal State) queda para cuando la escalera
  gobierne de verdad el pipeline (IOS-25/IOS-44/IOS-50 consumen las acciones): hoy la
  IA que «se apaga primero» aún no existe en la app.

**Siguiente**: IOS-07.

---

## 2026-10-03 · IOS-05 — os_signpost, Logger, telemetría de 1 Hz y MetricKit · ✅

Lo que el móvil dice de sí mismo, sin que nadie tenga que estar delante.

**Hecho**
- `RigMedia/Obs/Signposts.swift`: OSSignposter en Points of Interest con las nueve
  etapas (capture, blit, preprocess, infer, decode, render, encode, link, srt),
  `measure {}` para bloques y eventos puntuales. El código nuevo usa `os.Logger`.
- `RigCore/Runtime/LatencyHistogram.swift`: cubos fijos sin reservas (finos por debajo
  de los 33 ms de un frame), p50/p90/p99 por el borde superior del cubo —pesimista por
  un cubo, que para vigilar la escalera es lo que se quiere— y el último cubo recoge
  los atípicos.
- `RigCore/Runtime/TelemetrySnapshot.swift` (Codable): el contrato de REF-45 en
  snake_case —rig_ms, fps, did_drop, descartes por cola, etapas con p50/p90/p99 y los
  Hz reales, infer_ms_by_model, térmica y presión, nivel de la escalera, batería y
  carga, memoria disponible, RTT y pérdidas del enlace, bitrate del programa— con
  `jsonLine()` determinista (claves ordenadas).
- `RigMedia/Obs/TelemetryWriter.swift`: una línea JSONL por segundo en
  Documents/telemetry/, por cola acotada (8 fotos: la telemetría se tira, el vídeo
  no); un solo hilo escribe (cola serie), y el modo sin auto-drenado deja los tests
  sin carreras.
- `RigMedia/Obs/MetricKitSubscriber.swift`: los payloads de MXMetricManager y los
  diagnósticos a Documents/metrics/, solo iOS (`#if canImport(MetricKit) && os(iOS)`).

**Aceptación, medida en el Mac**
- `swift test`: 44/44. El p99 del histograma cae en el cubo correcto con datos
  sintéticos (99×10 ms + 1×200 ms → p99 = 12, máx = 250); la codificación del snapshot
  es estable carácter a carácter y hace ida y vuelta; el JSONL escribe una línea por
  foto y, saturado, tira lo viejo y conserva lo nuevo con las cuentas exactas.
- El intervalo por etapa en Instruments se comprueba en el iPhone cuando toque sesión
  con Instruments; el signpost queda emitiendo desde ya.

**Siguiente**: IOS-06 (la escalera de degradación), que consume este snapshot.

---

## 2026-10-03 · IOS-04 — colas acotadas, pools IOSurface y anillo de fotogramas · ✅

Los cimientos de memoria del pipeline: nada se reserva dentro del bucle de frames y
ante saturación se descarta y se cuenta, como en el servidor.

**Hecho**
- `RigCore/Runtime/BoundedQueue.swift`: anillo genérico de capacidad fija, con
  `dropOldest` y `dropNewest` y contadores exactos (pushed = popped + dropped). No
  sincroniza: el cerrojo lo pone quien la usa.
- `RigMedia/Metal/MetalContext.swift`: MTLDevice, cola, CVMetalTextureCache y la
  `default.metallib` de `Bundle.module`; si el CLI no la trae, cae a
  `makeLibrary(source:)` con el noop. Las vistas MTLTexture salen de aquí: NV12
  r8/rg8, BGRA y r16Float.
- `RigMedia/Metal/Shaders.metal`: el primer `.metal` del paquete (solo `rig_noop`),
  que es lo que hace existir `Bundle.module` y la metallib; los kernels reales llegan
  con IOS-20+.
- `RigMedia/Metal/PixelBufferPool.swift`: CVPixelBufferPool IOSurface + Metal,
  precalentado; con `kCVPixelBufferPoolAllocationThresholdKey`, `take()` da `nil` en
  vez de reservar por encima del tope.
- `RigMedia/Capture/FrameRing.swift`: K fotogramas NV12 propios indexados por rigMs,
  búsqueda del más cercano con distancia máxima, y recuento de referencias con
  generaciones: un hueco referenciado no se reutiliza y una liberación tardía de una
  generación vieja no puede soltar al ocupante nuevo (la generación sube al reclamar,
  no al terminar el fill).
- `RigMedia/Constants/PipelineConstants.swift`: `frameRingSlots = 4` (≈50 MB en 4K) y
  `pixelPoolHeadroom = 2`, con unidades y motivo.

**Aceptación, medida en el Mac**
- 10.000 ciclos de take tras el precalentamiento reciclan las MISMAS IOSurface (≤2
  ids distintas con capacidad 2): Allocations plano por construcción.
- Los contadores de la cola cuadran bajo 1.000 operaciones mezcladas.
- El fotograma referenciado sobrevive a tres stores seguidos y la liberación doble
  del lease viejo no libera al nuevo. `swift test`: 35/35.

**Siguiente**: IOS-05.

---

## 2026-10-03 · IOS-03 — arnés de vectores dorados en XCTest · ✅

El primer `--sync` real de REF-10 dejó los ocho ficheros del servidor en
`Tests/RigCoreTests/Golden/` y `test/golden/` (commit a96b126a9 de football-ai), y el
arnés los lee y los vigila.

**Hecho**
- `Tests/RigCoreTests/Support/Golden.swift`: el esquema v1 entero —documento, casos,
  tolerancias y tensores f64/f32/u8/i32 en base64 little-endian—, la verificación del
  manifiesto (versión, source_commit y sha256 de cada fichero, con CryptoKit) y la
  comparación recursiva con tolerancia absoluta y relativa; los ángulos dan la vuelta
  en ±π y las matrices se comparan elemento a elemento como tensores.
- `Golden/` declarado como recurso del target en Package.swift (`Bundle.module`).
- `tools/sync_golden.sh`: solo comprueba los dos manifiestos (los ficheros los deja el
  `--sync` del servidor); sale con 0 y nombra lo que no cuadra.
- GoldenLoaderTests (10 tests): el manifiesto real verifica; un sha alterado, un
  fichero ausente y un schema 2 se rechazan nombrando al culpable; los siete documentos
  reales parsean con más de 60 casos; un caso real pasa contra sí mismo; alterar `fx`
  de `ultra_gran_angular_4k` falla nombrando el caso; los tensores decodifican exacto
  (filas unitarias de una rotación a 1e-12); tolerancias y vuelta en ±π.

**Aceptación**: `swift test` 22/22 en el Mac; `sync_golden.sh` da «8 ficheros al día»
en los dos destinos; el sha alterado se rechaza.

**Quedó fuera**
- Evaluar los casos contra la réplica Swift: eso es cada tarjeta de réplica (IOS-30 en
  adelante); el arnés solo carga, verifica y compara.

**Siguiente**: IOS-04.

---

## 2026-10-03 · IOS-02 — paquete Swift local ZeroKit y contrato de capas · ✅

`ios/ZeroKit` con las tres capas nativas, referenciado una sola vez en Runner.xcodeproj
con la gema `xcodeproj`. Swift 6 estricto en RigCore y Swift 5 en el resto (decisión 17
del plan).

**Hecho**
- `Package.swift`: swift-tools 6.0, iOS 26 y macOS 26 (los tests corren en el Mac con
  `swift test`, sin simulador), productos RigCore, RigMedia y RigNet.
- **Movido a RigCore** (Swift puro, solo Foundation): la parte pura de RigTimecode
  (`Time/RigTimecodeWord.swift`), `RigMessage` con su `Reader`
  (`Wire/RigMessage.swift`) y `CameraLook` (`Wire/CameraLook.swift`), que viajaba
  dentro del mensaje y no tocaba ningún framework.
- **Movido a RigMedia**: el pintado sobre `CVPixelBuffer`
  (`Capture/RigTimecodePainter.swift`), como extensión de RigTimecode: Runner sigue
  llamando `RigTimecode.write(valueMs:into:)` igual que antes.
- **RigNet**: el marcador del módulo; el enlace UDP (IOS-52) y libsrt (IOS-55) llegan
  a esta capa.
- **El catálogo del cable**: `RigCommand` lo genera pigeon y no puede entrar en
  RigCore, así que `RigMessage.command` lleva `RigWireCommand` (el byte del formato) y
  RigLink mapea en el borde. `RigLinkTests.testPigeonCommandsAndWireCatalogNeverDiverge`
  falla si los dos enums dejan de ser el mismo conjunto.
- `tools/check_layers.sh`: la réplica del `.importlinter` del servidor; falla nombrando
  el import si RigCore importa algo distinto de Foundation (probado en negativo).
- `RigTimecode.swift` borrado de Runner; RunnerTests queda con lo que es de Runner
  (bitrate, limpieza, segmentos, RigLink) y los tests movidos viven en RigCoreTests y
  RigMediaTests.

**Aceptación, medida el 2026-10-03**
- `swift test --package-path ios/ZeroKit`: 12 tests ✅ en el Mac.
- `flutter build ios` ✅; `flutter analyze` 0 avisos; `flutter test` 207 ✅;
  RunnerTests en simulador iOS 26: 10 ✅.
- CRC de «123456789» = 0xF4 (RigCoreTests) ✅. `check_layers.sh` sale con 0 ✅.
- Grabación nueva con la app troceada: 5.247/5.247 códigos legibles a 30,000 fps.

**Quedó fuera**
- RigNet no se linka aún en Runner: se añade cuando entre el primer tipo real.
- Los dorados del servidor llegarán a `Tests/RigCoreTests/Golden/` con el `--sync` de
  su REF-10.

**Siguiente**: IOS-03.

---

## 2026-09-30 · IOS-01 — iOS 26 como mínimo y limpieza de los «NO COMPILADO» · ✅ probada el 2026-10-03

La rama `migracion/dos-moviles` sale de `origin/bundle-id-zero` y no de `main`, por
decisión del propietario: así arranca con el bundle id `com.logicielapplab.zero` y el
entitlement de Wi-Fi Aware, que main no tiene.

**Hecho**
- `project.pbxproj`: `IPHONEOS_DEPLOYMENT_TARGET` 15.0 → 26.0 en Debug, Release y
  Profile del proyecto. `SWIFT_VERSION` se queda en 5.0.
- `CapturePreview.swift`: fuera la rama `videoOrientation` anterior a iOS 17; la vista
  previa gira solo con `videoRotationAngle`.
- Fuera los comentarios «NO COMPILADO» de `CaptureEngine.swift`, `UltraWideCamera.swift`
  y `CaptureHostApiImpl.swift`, y la frase del README, que ahora dice que el mínimo es
  iOS 26.
- `flutter analyze`: 0 avisos. `flutter test`: 207 en verde.

**Fuera, y por qué**
- RunnerTests no fija `IPHONEOS_DEPLOYMENT_TARGET` en sus configuraciones: lo hereda
  del proyecto, así que ya pide 26.0 sin tocarlo.
- `AppFrameworkInfo.plist` ya no lleva `MinimumOSVersion` con Flutter 3.44: no hay nada
  que cambiar ahí.

**La prueba, hecha el 2026-10-03 (Mac de Alexander + su iPhone):**
- `flutter build ios --no-codesign` con Xcode 26.6 ✅; RunnerTests en el simulador
  iPhone 17 / iOS 26.5 ✅ (todas las suites).
- Emisión real contra el servidor local: HEVC 3840×2160, 30,01 fps medidos por PTS,
  434/434 códigos legibles en 16 s de captura.
- Grabación local: el segmento de 174,8 s dio **5.247/5.247 códigos legibles**, 30,000
  fps, cero huecos >50 ms y código estrictamente creciente; el segmento corto, 342/342
  con el único hueco en el arranque de la cámara (0,23 s), como siempre.
- `timecodeFailures=0` confirmado por Alexander en la pantalla de la app.
- Pendiente de repetir la pasada en el segundo iPhone cuando esté a mano; el criterio
  por móvil está cumplido en el probado.

**Siguiente**: IOS-02 (paquete ZeroKit), que depende de esta.
