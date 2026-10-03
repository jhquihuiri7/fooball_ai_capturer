# PROGRESS

Tablero de la migración a la arquitectura B en este repo: las tarjetas IOS y SPK de
`football-ai/docs/plan-dos-moviles/app-ios.md`. Se anota al cerrar cada tarea: ID ·
estado · qué quedó fuera · siguiente paso. Todo va en la rama `migracion/dos-moviles`;
`main` no recibe nada.

Una tarea que necesita el móvil no pasa a ✅ hasta que Alexander la ha probado en el
iPhone.

Leyenda: ✅ hecha · 🚧 en curso · ⛔ bloqueada · ⬜ pendiente

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
