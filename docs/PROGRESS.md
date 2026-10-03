# PROGRESS

Tablero de la migración a la arquitectura B en este repo: las tarjetas IOS y SPK de
`football-ai/docs/plan-dos-moviles/app-ios.md`. Se anota al cerrar cada tarea: ID ·
estado · qué quedó fuera · siguiente paso. Todo va en la rama `migracion/dos-moviles`;
`main` no recibe nada.

Una tarea que necesita el móvil no pasa a ✅ hasta que Alexander la ha probado en el
iPhone.

Leyenda: ✅ hecha · 🚧 en curso · ⛔ bloqueada · ⬜ pendiente

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
