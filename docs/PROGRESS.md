# PROGRESS

Tablero de la migración a la arquitectura B en este repo: las tarjetas IOS y SPK de
`football-ai/docs/plan-dos-moviles/app-ios.md`. Se anota al cerrar cada tarea: ID ·
estado · qué quedó fuera · siguiente paso. Todo va en la rama `migracion/dos-moviles`;
`main` no recibe nada.

Una tarea que necesita el móvil no pasa a ✅ hasta que Alexander la ha probado en el
iPhone.

Leyenda: ✅ hecha · 🚧 en curso · ⛔ bloqueada · ⬜ pendiente

---

## 2026-10-30 · La caída del 25-oct a las 20:53 y el zoom de «Una cámara» · 🚧 el zoom, sin probar en el iPhone

**La caída (25-oct, 17 en «Una cámara», de 19:33 a 20:53)**, leída del 17 y del VPS en solo
lectura:
- El 17 salía a internet por **Starlink** (129.222.179.220, de SpaceX). Perdió el **15,1 % de los
  paquetes** (362 025 de 2 390 658, con 308 582 reenviados).
- El SRT se rompió y se rehízo **40 veces en 80 min**, desde el minuto 2: en el VPS, «closed: EOF»
  y vuelta a los segundos. En el informe: 37 reconexiones, 2 por atasco, y el último error «SRT:
  sin respuesta del servidor».
- Cada corte paró el relé a YouTube («el panel dejó de publicar») y lo volvió a arrancar.
- Entre las 20:47 y las 20:51 los cortes se juntaron, con conexiones solapadas («terminated»). A
  las 20:53:58 se volvió a pulsar EMITIR.
- Facebook rechazó toda la tarde: «Operation not permitted», 190 veces. Es de la clave o del
  permiso de Facebook.
- El micro aguantó una llamada a los 70 min: volvió solo a los 16 s.
- **Qué mejoraría**: que YouTube no vea los cortes, con la tarjeta de espera del VPS (NUBE-18, a
  medias). No se tocan los plazos del SRT: el `SRTO_PEERIDLETIMEO` por defecto (5 s) y el vigía
  de atasco (5 s) van juntos, y cambiarlos sin probar en Starlink podría dejar la emisión
  atascada más rato.

**El zoom de «Una cámara»** (lo pidió Alexander: la lente entera se veía como el 0,5×). ADR 0025,
enmienda del 2026-10-30 (football-ai b5162a7).
- Píldoras 0,5× / 1× / 2× junto a la calidad, guardadas en `zero.singleZoom`. Viajan en
  `startProgram(resolution, zoom)` (Pigeon regenerado) hasta `ProgramRunConfig.single(zoom:)`.
- La vista se cierra a `FullLensView.hfovRad(of:width:height:zoom:)`: 1× = 69,4° (la principal
  de 26 mm), 2× = 38,2°, y nunca más que la lente entera. Se queda la ultra gran angular.
- A 2× amplía y se ve más blando (~1 350 px del sensor para 1 920).
- **Probado**: tests de RigCore (`FullLensViewTests`, `ProgramRunTests`) y de Flutter (153).
  Compila para iOS. **Sin probar en el iPhone.**

**Con dos móviles** cada uno usa su **ultra gran angular (0,5×)**: el soporte cose las dos para
cubrir el campo entero, y la calibración es de esa lente. El director encuadra dentro de ese
panorama.

## 2026-10-24 · BUG: el disco lleno tumbó la emisión tras ~5 h de partidos (17, 1.0.0 (15) de TestFlight) · 🚧 arreglado en la (16), sin probar en el iPhone

Leído del 17 (solo lectura: el listado de devicectl y los informes `program-live`/`program-split`
de ayer y hoy, en el scratchpad `espacio/`):
- **Zero ocupaba 97,7 GB** (2 641 ficheros), acumulados desde el 4-oct:
  - ~66 GB son restos de nuestras pruebas de desarrollo: `bench/` 41,3 GB, `bench4k/` 18,4 GB
    y `nv12/` 6,4 GB.
  - ~31 GB son copias locales del programa en la raíz: un `program-*.mov` por emisión, unos
    2 GB/h. Se graban siempre al EMITIR, sin «Guardar vídeo», y no se borran nunca.
  - Ayer 6,3 GB (157 min) y hoy 10,8 GB (173 + 126 min y varias cortas).
- **Cómo se cayó**: hoy se empezó con 11 GB libres. Tras la emisión de 14:53 quedaban 4,6 GB, y
  la de 17:46 los bajó a 0,5 GB. Su último latido es de las 19:52:57 (aún publicando). Después,
  nada: ni latido ni informe final, que no cabía. A las 19:53 hay un `…-2.mov` vacío. La copia
  .mov (un extra) llenó el disco y se llevó la emisión.
- **Lo que sí funcionó (Bug C)**: a las 15:31 otra app tomó el micro (llamada, ruta a 44,1 kHz).
  La app lo quitó, lo devolvió sola a los 18,7 s, y el sonido siguió: 22,7 s de silencio en
  2 h 53 min. Primer caso real del arreglo de la (15), y funciona.
- **Arreglo propuesto**:
  1. Un vigía de disco: la copia .mov no arranca, o se cierra, si el disco baja de un mínimo,
     y la pantalla y el panel lo dicen. La emisión nunca depende de la copia.
  2. Las copias del programa con tope (los últimos N partidos o X GB) o desactivables.
  3. Nada de `bench/`, `bench4k/` ni `nv12/` en la app de TestFlight. Y un botón «Liberar espacio».
- **Arreglo (16), 25-oct** (f9559c0, 36b582e). Alexander pidió no borrar los datos del 17:
  son el caso de prueba.
  - `RecordingPolicy.programCopy*` (RigCore, con tests): con menos de 12 GB libres se borran las
    copias viejas del programa, de la más vieja a la más nueva, nunca la de la pasada ni nada
    de `bench/`. Con menos de 3 GB, la copia se cierra (entera) y no se reabre.
  - `SplitBench.makeRoomForProgramCopy`: lo aplica al abrir la copia, cada minuto y cuando el
    escritor falla. Ya no fuerza un IDR por cada reapertura fallida, que es lo que atascó la
    emisión. Los informes llevan `program_copy` y `app_events` lo cuenta.
  - Pantalla: «Disco libre» dice para cuántas horas de copia queda (sin 4K). La tarjeta de
    atención avisa en palabras de cualquiera: «Zero borra solo las copias viejas…» y «ya no
    guarda la copia, pero la emisión sigue».
  - Con lo que tiene ahora el 17 (~28 GB libres) no se borra nada: la limpieza empieza por
    debajo de 12 GB. Los 66 GB de pruebas no los toca nunca.
  - **Probado**: los tests de `RecordingPolicy` (8), los de Flutter (540 pasan; los 8 dorados de
    `test/graphics` fallan igual sin estos cambios: el macOS 27 dibuja distinto) y la app
    compila para iOS. **Sin probar en el iPhone.**
- **De paso, con la Xcode 27.1**: 2 tests de `ProgramRecorderTests` fallan en el Mac (macOS
  27, `finishWriting` no responde). En el iPhone (iOS 27.0.1, la (15) de TestFlight compilada
  con esa Xcode) las copias se escribieron bien el 24-oct: `mov_failures` vacío y 310 183
  fotogramas. Es del Mac.
- **Limpieza hecha el 25-oct a las 17:41, con el sí de Alexander** (v17 de desarrollo en el 17,
  `RIG_PURGE_BENCH=1 RIG_PURGE_COPIES=1`). Zero pasó de 97,7 GB a 0,8 GB. Siguen `rig.json`, el
  detector de `bench-resources/`, `calib/`, `n0/` y `partido/`. Informe en `bench/purge-1792971686.json`.
- **IPA 1.0.0 (17)** con el vigía del disco y la limpieza de copias:
  `build/ios/ipa/Zero-1.0.0-17.ipa`.

## 2026-10-21 · Prueba del cosido desatendida con la 1.0.0 (15) (17 IZQ maestro + 16 Pro DER, Aware, en casa) · ✅ cose y emite; 3 cosas que mirar

Con el trípode en casa (pared, cama y mesita a 1-3 m) y sin tocar las pantallas:
- **EMITIR 10 min** (`tools/emitir_auto.sh … 600 --link aware`,
  `bench/emitir-auto-cosido-20261021-1228/`). Enlace a los 10 s. 17 975 fotogramas a 30,0
  fps (p5 29,1), 1 tramo SRT sin reconexiones, latencia añadida p95 143 ms y copia .mov
  completa. Medias sincronizadas (p50 1 ms) y partes del 16 Pro a 85 ms, 0 perdidas.
  **Audio**: micro a 48 kHz en los dos, 0 fallos, 0 ceros, 0 micros rehechos. El esclavo
  parpadeó 2 veces (0,3 s y 0,13 s), y de ahí salen 25 instantes saltados. Con la escena
  fija, el director encuadra casi siempre una lente: solo cose el 1 %.
- **Barrido de la costura 5 min** (`tools/banco_dos_moviles.sh split … 300` con Aware,
  `bench/dos-moviles-costura-20261021-1243/`). 8 991 fotogramas a 30 fps, 6 246 cosidos (69 %),
  99 sin la parte a tiempo (1,6 %, dos tropiezos cortos), 0 rasgados.
- **Lo que se ve** (fotogramas del .mov):
  1. **Paralaje en la franja de fundido**: la mesita a ~1,5 m sale medio transparente. Es de
     la distancia; en una cancha (10-60 m) apenas se nota.
  2. **Color**: la mitad del 16 Pro sale más cálida (pared beige frente a blanca). Las
     ganancias de color solo corrigen ±2,5 %.
  3. **Una cuña negra** en el borde izquierdo con la vista casi toda a la derecha (yaw
     ≥ 0,41 rad: `sides: ["right"]` aunque el borde cruza la costura). Ese borde no lo cubre
     la imagen real del 16 Pro, que **no tiene `rig.json`** (va con el soporte nominal) ni el
     detector. Con el móvil derecho calibrado del soporte no debería salir; si sale, es la
     elección de lados del compositor.
- Al acabar, la (15) normal (sin los defines automáticos) quedó instalada en los dos a las
  12:54, con Zero cerrada.

## 2026-10-21 · BUGS ABIERTOS de la prueba del cosido del 20-oct (17 + 16 Pro por Wi-Fi Aware, app 1.0.0 (9)) · 🐞 C diagnosticado y con arreglo en la (15), sin probar en el iPhone; A ✅ (probado en el iPhone); B ✅ cerrado el 21-oct por Alexander: el enlace vuelve solo; la espera es de iOS (FB23509767), de 31 a 139 s tras reiniciar un móvil y ~216 s tras cambiar de lado; la (14), que solo alarga el plazo a 240 s, queda sin probar

Leído de los dos iPhone (solo lectura) y del VPS. Ficheros: `Documents/bench/link-diag-*`,
`program-live-*`, `program-split-*` y `Documents/partido/*.json` de los dos, del 20-oct
entre las 20:46 y las 21:12 (hora local).

### Bug A · El QR Mando no aparece en el 17 cuando dirige (en el 16 Pro sí)
- 20:46-20:51: 17 IZQUIERDA (maestro) + 16 Pro DERECHA por Aware, enlace arriba a los 20 s,
  EMITIR 161 s al VPS (4 787 fotogramas, 1 conexión). El mando sí funcionaba por dentro: el
  16 Pro recibió la pizarra del 17 (`partido/replica.json` del 16 Pro, 20:51). **El QR no
  salía en el 17**, ni tras matar la app y emparejar de nuevo. Con los papeles al revés, el
  16 Pro sí lo enseñaba.
- El QR sale de `MasterHost.pairingText`: es null si no hay motor, si no hay secreto, o si
  **no hay ninguna dirección para el panel**: ni IPv4 de la LAN (`lanAddresses`, interfaces
  `en*`), ni la del otro móvil, ni la URL del VPS (el túnel de IOS-65 no existe). El secreto
  está (el enlace autentica con él). **Hipótesis principal: el 17 no estaba en ninguna Wi-Fi**
  (solo Aware y datos móviles), así que no tenía IPv4 en `en0`. En el VPS, los dos
  publicaron desde la misma IP de la operadora móvil (190.63.102.122): o los dos iban por
  datos, o el 16 Pro estaba en una Wi-Fi sin internet que sí le daba IPv4 de LAN. **Falta
  confirmarlo con Alexander:** ¿el 17 estaba conectado a alguna Wi-Fi?
- **Confirmado con Alexander (21-oct): el 17 compartía sus datos (Punto de acceso
  personal)** y el 16 Pro y el móvil del mando (un Samsung) estaban conectados a esa red. Ya
  pasó otro día con un tercer móvil prestado haciendo de punto de acceso. En iOS, el móvil
  que comparte datos no tiene IPv4 en `en0`: la red que sirve va por `bridge100`
  (172.20.10.1), y `lanAddresses` solo mira las interfaces `en*`. El 16 Pro, cliente de esa
  red, sí tiene 172.20.10.x en `en0`: por eso con él de maestro el QR salía. Matar la app no
  cambia nada porque la red sigue igual; el orden (EMITIR antes o después del QR) tampoco.
  **Arreglo:** `lanAddresses` también con `bridge*` (el punto de acceso), detrás de `en*`.
- Además, la hoja pone «Sin secreto del soporte no se puede firmar el QR», que **es falso en
  este caso**: hay que decir el motivo real («sin red local: conecta este móvil a una Wi-Fi»).
- Arreglo esperado: el motivo correcto en la hoja; el QR con la dirección del enlace o del
  VPS cuando no hay LAN (IOS-65); y el estado del mando (`serving`, `problem`, direcciones)
  en el latido y el informe, que hoy no lo llevan.
- **Segunda causa (21-oct), el iPhone prestado en «Una cámara»:** falló tras EMITIR y ni
  matando la app volvió; luego el 17 en la misma red sí. Un móvil que nunca recibió
  `RIG_LINK_SECRET` desde un Mac no tiene S: `controlSecret` daba "" y el QR no se podía
  firmar nunca (la hoja decía «sin secreto»). EMITIR no tiene que ver: en «Una cámara»
  `onRigRole` llega **una sola vez** por apertura de la cámara: `CapturePage.initState` →
  `prepare` → `startLink(.single)` → `RigSoloLink.start` → `session.startAlone` →
  `onRole(.master, 0, nil)` → `flutter.onRigRole` → `becomeMaster(null)` → partido →
  `announceMatch` (= `setMatchId`, que solo apunta el partido en la sesión y no vuelve a
  avisar) → `controlSecret` → PIN → `bind` en el 8090. EMITIR (`_api.start` +
  `startProgram`) no llama a `startLink` ni a `onRigRole`. Donde sí se solapan:
  con dos móviles (`start()` avisa del rol al momento y la negociación otra vez al
  conectar, y en cada reconexión o relevo) y entre dos pantallas de captura (volver atrás y
  entrar: el `stepDown` del host viejo va sin esperar; son dos hosts distintos, para eso está
  REINTENTAR MANDO).
- **Arreglado en d15fd6c (sin probar en el iPhone):**
  - `lanAddresses` mira `en*`, después `bridge*` (el punto de acceso) y después `ap*`.
  - Sin S, el mando se firma con un secreto propio del móvil: 32 bytes aleatorios, creados
    una vez y guardados en el Keychain (`football-ai.enlace` / `secreto-mando-propio`,
    ThisDeviceOnly). Solo lo verifica ese maestro: con un móvil no hay nadie más. Con S, lo
    de siempre (lo verifican los dos móviles y el VPS).
  - La hoja dice el motivo real («sin red local…», «sin secreto…», «el mando no arrancó:
    …»), enseña `http://IP:puerto` para entrar a mano con el PIN y tiene REINTENTAR MANDO
    (vuelve a arrancar el mando sin matar la app ni parar la emisión). El botón QR MANDO no
    desaparece si el mando no arrancó: sigue, con el motivo debajo.
  - `becomeMaster`/`stepDown`/`retry` en cola. Antes, dos avisos de rol solapados abrían
    dos servidores en el mismo puerto (uno caía con «Address already in use» y el problema
    no se veía) o dejaban sirviendo a un móvil que ya era esclavo
    (`test/server/master_host_race_test.dart`, rojo antes del arreglo).
  - El estado del mando va al latido y al informe (`mando`: `serving`, `port`, `match_id`,
    `addresses`, `can_pair`, `problem` y `key`: `rig`, `device` o `device_unsaved`), y cada
    cambio a `app_events` («mando: sirve en 172.20.10.1 puerto 8090» / «mando: no sirve: …»).
  - Un QR con solo la dirección del otro móvil ya no sale (el otro no sirve el mando hasta
    un relevo): sin dirección propia ni VPS, «sin red local».
- **Qué probar en el iPhone:** (1) el 17 compartiendo datos, de maestro: QR MANDO sale con
  172.20.10.1 y el Samsung conectado a esa red lo escanea y mueve el marcador; (2) un móvil
  sin S (o el prestado) en «Una cámara»: sale el QR y el mando entra; matar la app y volver:
  el QR anterior sigue valiendo para el mismo partido; (3) sin Wi-Fi ni punto de acceso: la
  hoja dice «sin red local»; conectar a una Wi-Fi y REINTENTAR MANDO saca el QR; (4) el
  `program-live-*.json` de una EMITIR trae `mando` y las líneas «mando: …» en `app_events`.
- Por mirar, sin arreglo: si iOS suspende la app (al fondo), puede recuperar el socket que
  escucha en el 8090 y el mando dejar de entrar aunque el botón siga; REINTENTAR MANDO no lo
  cubre porque `serving` sigue en verdad.

### Bug B · Al cerrar y abrir el que publica con el que busca abierto, no vuelven a enlazar
- 20:53-21:01 (20-oct, 16 Pro maestro y publica, 17 esclavo y busca): el 17 **ve** al 16 Pro
  (anuncios de control y medios), pero el control no se sostiene: «ve al otro pero no conecta:
  sin respuesta en 10 s» (8 intentos en 100 s), «Wi-Fi Aware: connectionFailed», «Operation
  canceled», «Connection reset by peer». Una vez enlaza (20:57:53, a los 30 s) y se cae a los
  12 s («cerrada por el otro»). Sin control no hay `clock_pong`: la fila Reloj nunca en verde.
- En el 16 Pro (publica): «publicando; no ha llegado nadie en 117 s (4 citas, 6 rehechas)» y, a
  las 20:59, **«cita de medios acabada (Wi-Fi Aware: serviceAlreadyPublishing): renewLater» cada
  5 s**.
- **Reproducido el 21-oct, sin cambiar los papeles** (`bugs/hoy/` del scratchpad de la sesión):
  09:43:48 el 17 (izquierdo, publica) enlaza con el 16 Pro (derecho, busca) en 10 s. Alexander
  mata Zero en el 17 y la abre: 09:45:09 el 17 publica y en 90 s nadie llega a su cita (3 citas,
  4 rehechas). El 16 Pro, que siguió abierto, 10 intentos, todos «sin respuesta en 10 s», y
  «medios: la suscripción no ha dado con nadie en 99 s». Sin cambiar de papel: **el bug es
  cerrar y abrir el que publica con el que busca abierto**.

**Diagnóstico (21-oct, con el código y los `link-diag` de los dos días)**
1. **El que busca se queda colgado de un datapath viejo.** Línea de tiempo del 16 Pro (t desde
   su arranque; el reloj del 17 va ~7 s por detrás del suyo, medido con las llegadas del
   20-oct): a los 66,0 s el vigía de silencio tira el enlace y se cancela todo. A los 79,8 s
   (0,3 s después de que el 17 nuevo publique, con ese desfase) ve **el anuncio nuevo**, no uno
   viejo de caché:
   el +1 coincide con el arranque del 17 y cada −1/+1 posterior con sus citas rehechas a los 30
   y 67 s. Conecta control y medios, y **la de medios queda lista en 0,0 s** (en la buena de
   las 09:43, 1 s): ya había un datapath montado con el 17, el del proceso muerto, aunque el
   16 Pro llevaba 14 s sin ninguna conexión. El 17 no ve llegar nada, ni control ni medios.
   Cada TCP de control se queda en `preparing` («sin respuesta en 10 s»), y la conexión de
   medios de los 79,8 s sigue abierta hasta el final (85 s): `resubscribe(.media)` cambiaba el
   browser y no la conexión, y el vigía de medios solo actúa con el control arriba. El 20-oct,
   con los papeles cambiados, lo mismo en el 17: medios «lista» en 0,0-0,1 s y el control
   «sin respuesta» 8 veces. Apple lo reconoce con su propio ejemplo (FB23509767, foro de
   desarrolladores 836085, iOS 26.5): el TCP por Wi-Fi Aware se queda en `preparing` tras
   reiniciar la app; recrearlo cada 10 s cura a veces a los 1,5-2 min, y lo seguro es dejar los
   móviles quietos «un par de minutos». Lo nuestro del 15-oct cuadra: cerrar Zero en los dos y
   esperar 1 min enlazó.
2. **`serviceAlreadyPublishing` es nuestro.** 16 Pro, `link-diag-left-1792551579`: el control
   sube a los 30,5 s y los medios del 17 no llegan; a los 67,5 s el vigía de la publicación
   (546917d) cambia la cita de medios y `retire()`, con el control arriba, **guarda la vieja
   sin cancelar y sigue publicada** (lo de 0d10448 era para citas caducadas, que ya no
   publican). La nueva cae con `serviceAlreadyPublishing` → `renewLater` → a los 5 s otra igual
   (67,5, 72,6 y 77,7 s), y cada una se queda en `retiredListeners` hasta que cae el control.
3. **Una lectura vieja tiraba el enlace dos veces.** Al tirar el control se cancela la conexión
   y su `receive` acaba después: contaba como otra caída y abría dos suscripciones (16 Pro hoy a
   los 66,0/66,3/66,5 s; 20-oct a los 306,5 s y 85,3 s).
4. **El que publica guardaba la conexión de medios del par que se fue** (`dropMedia` no hacía
   nada en él) y el que busca, una de medios caída o en espera sin cancelar.
5. **Dos conexiones montando a la vez el datapath con el mismo par** cayeron las dos (17,
   20-oct 20:57:57: medios `connectionTerminated`, control `connectionFailed`), y un transporte
   nuevo 4,5 s después de parar el viejo falló al instante (20:58:29: `connectionTerminated`,
   «Connection refused»).
6. Lo que no se puede saber con estos ficheros: si el datapath viejo lo retiene el wifip2pd del
   que busca o el del que publica, y cuánto tarda en soltarlo (por eso la pausa crece). La
   hipótesis del punto de acceso en el 17 ni se confirma ni se descarta.

**Arreglo (sin probar en el iPhone)**
- **411d3ae, el que publica**: nunca dos citas vivas del mismo canal. La vieja que sigue viva se
  cancela y la nueva sale cuando la vieja dice `.cancelled` (tope 2 s); la que ya acabó se
  retira como antes. Al caer un enlace que estaba arriba suelta la conexión de medios del par y
  abre las dos citas nuevas. El vigía no cambia la cita de medios con un control a medio montar
  y le da su plazo entero desde que sube el control.
- **8b131f8, el que busca: borrón.** Suelta el intento o la conexión de control, la de medios,
  las dos suscripciones y sus anuncios, y no abre nada en una pausa; después se suscribe de
  cero. Es lo que hacía matar la app, sin tocar la cámara ni la emisión. Por Wi-Fi Aware: al
  perder un control que estaba arriba, 2 s; tras 3 intentos seguidos sin subir, 60 s, y 120 s
  cada borrón siguiente hasta que suba. Los medios se conectan cuando sube el control (ninguna
  conexión de medios retiene el datapath mientras el control no sube). Una de medios caída se
  cancela; la lectura de una conexión ya tirada no cuenta. Bonjour no cambia. La fila Enlace
  dice «en pausa 60 s más para que Wi-Fi Aware suelte el enlace viejo (borrón 1; …)».
- **e28e177, el diagnóstico**: a quién va cada intento (anuncio, interfaz y, con iOS 26.4, el
  emparejado y su id), la ruta al caer y al subir («control caído (sin respuesta en 10 s) ·
  ruta satisfied por nan0, local …»; «satisfied» sin dirección local se señala, es la firma de
  FB22904826, que solo cura reiniciar el móvil), y en `link-diag`/latido `last_attempt`,
  `live_connections`, `retired_listeners`, `listeners_cancelling`, `subscriptions`,
  `failed_attempts`, `search_resets` y `quiet_s`. Cada conexión de medios que se tira, con su
  motivo. Las líneas de siempre no cambian.
- `docs/GUIA-CANCHA.md`: la fila de la pausa («no cierres Zero en la pausa»).
- **Comprobado en el Mac**: `swift test --skip ModelBench` 601 tests, 4 saltados, 0 fallos
  (nuevos: `PublicationReplacementTests` 2, rojos sin el arreglo porque en el Mac dos listeners
  vivos en el mismo puerto chocan con EADDRINUSE; `SearchResetTests` 6, dos con Bonjour de
  verdad; y en `LinkDiagnosisTests`); sin la guarda de la lectura, el loopback reproduce las dos
  caídas. `tools/check_layers.sh` limpio. RigNet con `swiftc -typecheck` para
  arm64-apple-ios26.0 (la parte de Wi-Fi Aware solo compila para iOS): 0 errores, 0 avisos. El
  Runner no se toca (usa la cita como tipo; nadie la implementa fuera de RigNet).
  `test_cancha.py` 27 OK.
- **Queda fuera**: que el que publica también se calle (si con esto sigue sin enlazar y matar
  los dos sí, el datapath viejo está en el que publica); que un transporte nuevo espere a que el
  viejo del mismo proceso acabe de cancelarse (volver atrás y entrar a la cámara en menos de un
  segundo).

**Qué probar con los dos iPhone** (los dos con este código: el que busca nuevo conecta los
medios tras el control, y un publicador viejo podía cambiarle la cita de medios en ese momento)
1. 17 IZQUIERDA, 16 Pro DERECHA, Aware, «Abrir cámara» en los dos hasta LISTA (Enlace y Reloj
   en verde). Apuntar si el 17 comparte datos (punto de acceso).
2. **Matar el maestro con el esclavo abierto**: en el 17, deslizar Zero fuera en el selector de
   apps; sin tocar el 16 Pro, abrir Zero en el 17 a los 10 s (IZQUIERDA, Aware, «Abrir
   cámara»). Cronometrar desde que se abre hasta Enlace y Reloj en verde en los dos. Mirar la
   fila Enlace del 16 Pro: «ve al otro…» y, si no sube en ~36 s, «en pausa 60 s más…». **Bien**:
   enlaza solo en ≤ 2 min. Repetir con 5 s, 30 s y 2 min entre matar y abrir.
3. **Matar el esclavo con el maestro abierto**: lo mismo en el 16 Pro. **Bien**: enlaza en
   ≤ 30 s y el 17 apunta «el enlace cayó: citas nuevas»; si tarda más, apuntar si el 16 Pro
   hizo «borrón (» y cuántos.
4. **Papeles cambiados**: 16 Pro IZQUIERDA (publica) y 17 DERECHA (busca), Aware; pasos 2 y 3
   otra vez, y un EMITIR corto. **Bien**: ningún «serviceAlreadyPublishing» y el Reloj del 17
   en verde.
5. Recoger `Documents/bench/link-diag-*.json` de los dos (los traen los guiones de la cancha) y
   buscar: «borrón (» y «fin de la pausa» (cuántos hicieron falta), «control: ruta» (por qué
   interfaz sube), «· ruta satisfied por nan0, local ninguna» (FB22904826: reiniciar ese
   iPhone), «la cita vieja no acabó en 2 s» y «serviceAlreadyPublishing» (no tienen que salir).
6. Si con el primer borrón (60 s) no enlaza y con el segundo (120 s) sí, la pausa buena es la
   larga: subir la primera. Si no enlaza nunca y matar los dos y esperar sí, el siguiente paso
   es que también se calle el que publica. Plan B mientras: «Una cámara (sin pareja)» en el 17.

### Bug B · Prueba de la 1.0.0 (11), 21-oct 10:50, y cambio de la (12)
- **Probado en los iPhone** (17 IZQUIERDA publica, 16 Pro DERECHA busca, Aware): paso 3
  (matar el esclavo con el maestro abierto). El 17 perdió el control a las 10:50:39
  («connectionTerminated») y publicó citas nuevas sin `serviceAlreadyPublishing`. El 16 Pro se
  reabrió ~37 s después, vio el anuncio al instante y 4 intentos se quedaron «sin respuesta en
  10 s» con «ruta satisfied por en0,nan0, local ninguna»: 3 seguidos, borrón de 60 s y otro tras
  la pausa. El 5.º subió en 2 s (control y medios). **El reloj volvió solo a los 104 s de abrir,
  139 s después de la caída**: nadie tocó nada.
- **Causa**: es el fallo de iOS FB23509767 (foro de Apple 836085). Tras reiniciar la app en un
  móvil, el datapath viejo no deja montar uno nuevo durante «1.5 - 2 minutes», y «creating a
  completely new NetworkBrowser and NetworkListener doesn't speed up this process». Apple lo
  reconoce y sigue sin arreglar. Esta mañana (09:45, al revés: matar el que publica) fueron
  >112 s de intentos fallidos, la misma ventana. La app no puede acortarla.
- **Lo que sí empeoraba la app**: el borrón por intentos metía pausas de 60 s y luego 120 s.
  La de 60 s no soltó nada (el primer intento tras ella también falló). Con mala suerte, la
  de 120 s detrás llevaba la vuelta a más de 4 min.
- **Cambio (12)**: `WiFiAwareTimings.staleDatapathS = 150`. Durante 150 s sin enlace (desde
  la caída o el arranque), el que busca no hace borrón por intentos y sigue probando cada
  ~10 s; pasado ese plazo vuelven el tope de 3 y las pausas. La fila Enlace del que busca
  añade, con intentos fallidos por Aware: «Si un móvil se reinició, iOS tarda unos 2 min en
  dejar enlazar: no cierres Zero». Volver a cerrar la app reinicia la espera.
- **Probado**: los 111 tests de RigNet en el Mac (4 saltados) y `SearchResetTests` y
  `LinkDiagnosisTests` con casos nuevos. La (12) está instalada en los dos a las 11:06.
  **Sin probar todavía en los iPhone.**
- **Queda fuera**: acortar los ~2 min (es de iOS); que el operador no tenga que reiniciar
  Zero (el Bug C de audio es el motivo más probable en la cancha).

### Bug B · Prueba de la 1.0.0 (12), 21-oct 11:13-11:23, y arreglo de la (13)
- **La (12) no cambió nada por Aware**: `WiFiAwareRendezvous` no declaraba `staleDatapathS` y
  tomaba el `nil` por defecto del protocolo. Esa cita solo compila para iOS y ningún test del
  Mac lo vio. En los registros sigue saliendo «borrón (3 intentos…) 60 s» a los 31 s.
  **(13), 0173ac3**: la cita de Aware lo declara y el protocolo ya no tiene valor por
  defecto. Toda cita tiene que decirlo, así que el compilador lo exige al construir la app.
- **A (matar el esclavo 16 Pro)**: caída a las 11:14:25 y control arriba a las 11:16:44,
  **139 s**, igual que en la (11) (139 s): el plazo de iOS cuenta desde la caída.
- **B (matar el maestro 17)**: **no enlazó**. El 17 reabierto publicó y el 16 Pro hizo 3
  intentos fallidos («connectionFailed» al instante y «sin respuesta en 10 s») y borrón; a
  los ~50 s se pasó a C. Pareció inmediato porque el 17, como maestro, está LISTO solo, y el
  16 Pro siguió en LISTA con el Reloj en verde con la hora de antes. **(13), 86553e4**: el
  esclavo con la hora retenida y sin enlace dice `SIN ENLACE` en el chip y el Reloj sale en
  rojo con «retenido, sin enlace» (`CaptureSession.clockHeldWithoutLink`).
- **C (papeles cambiados: 16 Pro publica, 17 busca)**: control arriba a los 146 s del cambio
  (11:20:41). A las 11:21:45 **los dos** cortaron por «silencio de 3 s» sin que nadie cerrara
  la app (el datapath murió solo; por averiguar qué pasó en ese momento). Volvió a los 96 s
  (11:23:21), tras un borrón de 60 s.
- **El 20-oct, con el punto de acceso del 17**: de 14 arranques solo 2 aguantaron más de 2 min
  (100 y 117 s, el resto entre 20 y 95 s). Cada cierre y apertura volvía a empezar la espera de
  iOS, así que no era que no funcionara: se cortaba antes de tiempo. Además salía
  `serviceAlreadyPublishing` (arreglado en la (11)). El punto de acceso no explica los 2 min:
  hoy, con wifi de casa, se repiten igual. Sí rompía el QR (Bug A, arreglado).
- **Probado**: 111 tests de RigNet (4 saltados) y 128 de `capture_session_test`, `widget_test`
  y `capture_labels_*`. `flutter analyze` limpio. La (13) está instalada en los dos a las 11:29.
  **Sin probar en el iPhone.**

### Bug B · Prueba de la 1.0.0 (13), 21-oct 11:37-11:46, y plazo de la (14)
- **Probado en los iPhone** (desde la caída hasta el control arriba):
  - **A (matar el esclavo 16 Pro)**: 31 s; Alexander cronometró ~13 s desde que lo abrió. El
    16 Pro subió al primer intento, 3,5 s después de abrir. Esta vez el 17 vio la caída como
    «silencio de 3,2 s» y no como «connectionTerminated», y no hubo datapath retenido.
  - **B (matar el maestro 17)**: 62 s. El 16 Pro pasó a SIN ENLACE (86553e4 funciona) y
    Alexander, creyendo que se había roto, salió y volvió a entrar sin cerrar Zero. Siguió
    intentando sin borrón (0173ac3 funciona) y subió ~30 s después.
  - **C (cambiar de lado)**: 219 s, los «3 min 40 s» de Alexander. El 17, que ahora busca, hizo
    10 intentos «sin respuesta en 10 s» en 150 s, borrón de 60 s y subió al primero tras la
    pausa. En la (12) el cambio de lado tardó 215 s: **cambiar de lado es el peor caso (~3,5
    min)**. Hasta ahora: reiniciar un móvil, de 31 a 139 s; cambiar de lado, ~216 s.
- **(14)**: `staleDatapathS` pasa de 150 a 240 s, para que la pausa del borrón no empiece
  antes de que iOS suelte, también al cambiar de lado. El aviso de la fila Enlace dice ahora:
  «Tras reiniciar un móvil, iOS tarda hasta 2,5 min en dejar enlazar, y hasta 4 min tras
  cambiar de lado: no cierres Zero».
- **Para la cancha**: decidir los lados antes de enlazar y no cambiarlos.
- **Visto de paso**: un intento del 17 salió con «ruta satisfied por pdp_ip0» (datos
  móviles) y otros «por en0». Los que suben dicen «sin interfaz». Por mirar si conviene
  prohibir esas interfaces en la conexión de Aware.
- **Probado**: 111 tests de RigNet (4 saltados). La (14) está instalada en los dos a las 11:49.
  **Sin probar en el iPhone.**

### Bug C · (sigue) el audio en silencio (entrada del 2026-10-16)
- Dato nuevo de Alexander: **entró una llamada y el sonido siguió; se dañó un poco
  después**. No basta «interrupción de la llamada» como causa directa.
- **Diagnóstico del 21-oct**, leído del 17 (solo lectura). La grabación del programa que
  guarda el propio 17 (`Documents/program-m_f50b97dd8d1a-1792209597.mov` y `…1792211460.mov`)
  da el sonido al segundo, y se cruza con los `app_events` de `program-live-left-1792209597.json`:
  - 22:12:12 «cámara interrumpida: otra app usa el micrófono», y Zero pasa al fondo 10 s.
    **El sonido acaba a las 22:12:13.** `yieldMicrophone` quita el micro de la sesión y solo
    lo devolvía el fin de una interrupción del audio o de una llamada, una sola vez y sin
    reintentar. Volvió a las 22:20:48.
  - Ceros de 22:24:03 a 22:29:31 y desde 22:29:53 **sin ningún aviso de la cámara**, con el
    micro puesto. Tras PARAR/EMITIR (22:31), ceros los 259 s: EMITIR no toca el micro.
  - Sin vídeos del mando esa noche (sin `ad_cues` ni vídeos): el sustituto de IOS-103 queda
    descartado.
  - Causas que dan ceros exactos con el micro puesto: el audio de la app interrumpido sin
    que la cámara lo diga (no se miraba); el micro silenciado por el sistema; o la entrada a
    otra frecuencia (un micro Bluetooth va a 16 o 24 kHz), que `AacEncoder` rechazaba con
    `.format` búfer a búfer. **Los informes no guardaban nada del micro**, así que no se
    puede saber cuál fue.
- **Arreglo (15)**:
  - `AacEncoder` pasa cualquier frecuencia a 48 kHz, también con un cambio a mitad.
  - `MicWatch` (RigMedia) y `CaptureEngine.checkMicrophone`, cada segundo: si el micro está
    fuera, no entrega búferes en 3 s, da ceros exactos 5 s o falla 3 s, y no hay llamada en
    curso, **se rehace solo**. Reintenta a los 5, 15, 30 y 60 s, y luego cada 60 s. Desde el
    segundo intento también rehace la salida de audio y reactiva la sesión de audio.
  - El informe en directo y el final llevan `audio` (búferes, ceros, frecuencia, intentos).
    `app_events` apunta el micro que se va, vuelve o se rehace, las interrupciones del audio,
    la ruta con su frecuencia y el reinicio de los servicios de audio. `app_events` guarda
    ahora los 24 primeros y los 40 últimos (antes, solo los 64 primeros).
- **Probado**: los 607 tests de ZeroKit (4 saltados), entre ellos los de 44,1 y 16 kHz con
  cambio a mitad y los de `MicWatchTests`. Compila para iOS. La (15) está instalada en los dos
  a las 12:21. **Sin probar en el iPhone**: falta provocar el corte (otra app que tome el micro,
  o una llamada) emitiendo y ver que vuelve solo.
- Petición: ver en el panel de administrador si hay sonido (un medidor de nivel del audio
  del programa).

### También visto
- 16 Pro, 21:02, «Una cámara»: la app pasó al fondo a los 90,9 s («cámara interrumpida») y
  el latido sigue sin cerrar a los 629 s (2 907 fotogramas, SRT «waiting»): no volvió.

## 2026-10-19 · IOS-110 a IOS-113 — El tipo de evento, el espectáculo y la noche de partidos · 🚧 probado en Windows; falta verlo en el iPhone

ADR 0031 y 0032 de football-ai (REF-65 y REF-66, e102763 y 5bc4622), pedidos por Jhonatan
tras la primera transmisión. Lo pidió sin preguntas: las decisiones que tomé están en los dos
ADR.

**Hecho**
- **IOS-110, el tipo de evento.** La app abre en «¿Qué vas a transmitir?» (`EventPage`):
  Fútbol, Espectáculo y Vóleibol. Fútbol lleva a la pantalla de lado de siempre (con un «‹»
  para volver); los otros dos, a la misma `RolePage` en su variante de una cámara: solo la
  calidad (1080p o 720p) y el VPS, y abre «Una cámara (sin pareja)», que dirige siempre. El
  tipo (`EventKind`) viaja de `ZeroShell` a `CapturePage`, `MasterHost` y `MatchEngine`; sin
  fútbol no hay pestaña Partido.
- **IOS-111, el espectáculo.** El estado lleva `event_kind`. Los rótulos guardados
  (`graphics/caption_save`, `caption_delete`, `caption` con `show_s` o `hold`, y
  `caption_all`), en `grafico.json`. El gráfico del espectáculo: sin marcador, con EN VIVO
  arriba a la izquierda, la esquina de la casa con el icono del evento, la franja y el
  rótulo (`ScoreboardState.scoreboard`, `lowerThirdTitle`/`Subtitle`); sin tarjetas ni
  alineaciones. El vóley no pinta nada ni pone anuncios. El mando web enseña las tarjetas de
  cada tipo (`data-tipos`) con la nueva de Rótulos, y el mando nativo remite al web fuera del
  fútbol.
- **IOS-112, el gol, el marcador a demanda, la franja alta y las tandas.** Cada `+1` saca
  ¡GOL! (`goal_banner_painter.dart`, portado de `goal_card.py`): entra en 0,45 s, se queda y
  sale en 0,35 s; el maestro pinta a 20 fps solo mientras se mueve (`ProgramGraphics.animating`).
  Un `−1` del mismo equipo lo quita. `graphics/scoreboard` quita la barra, la competición y el
  reloj (EN VIVO sube arriba). La franja mide 132 px (OverlaySpec). `graphics/strip_all` y
  `video/play_all`: la franja que está fuera sale del tiempo (sin hueco entre dos) y
  `MatchEngine.tick`, cada segundo, avisa a los mandos y pasa el vídeo que acabó sin aviso.
- **IOS-113, la noche de partidos.** `match/fixture_start` pone un partido de la jornada en el
  marcador (nombres, escudos por nombre, goles si ya se jugó, reloj a cero); `match/finish`
  guarda el marcador en la jornada y para el reloj; `graphics/results` es la tarjeta
  RESULTADOS. `current_fixture` y los goles de cada partido van en `grafico.json`, y volver a
  guardar la jornada los conserva. Las alineaciones van por equipo
  (`alineaciones-equipos.json`). El mando web: «Partido de la jornada» con Empezar, Reabrir y
  Finalizar, «Marcador y reloj» y «Resultados» en Al aire, «Pasar todas» y «Pasar todos», el
  próximo partido desde la jornada, y los avisos de gol, marcador oculto y partido en juego.
- OverlaySpec, los renders de referencia y el dorado del túnel sincronizados desde
  football-ai (5bc4622). `MetalBench` usa el alto de la franja de OverlaySpec.

**Comprobado**: `flutter analyze` limpio. Tests nuevos del motor (`event_night_test.dart`),
de la API, del gráfico (el gol a fps, el espectáculo, el vóley y la tanda) y de las
pantallas. Los painters contra Python: ¡GOL! 0,19 %, el espectáculo con su rótulo 0,83 % y
los resultados 1,14 % de píxeles distintos. El mando web, servido por la API de verdad y
fotografiado con Edge en los tres tipos. Fallan en Windows los 8 dorados de imagen de siempre
y, a ratos, «se pinta en ≤50 ms».

**Pendiente, en este orden**:
1. En el Mac: compilar el Swift (`MetalBench` usa ya la franja de OverlaySpec), regenerar los
   dorados de `test/graphics` (cambian con la franja de 132 px) y sacar la build de TestFlight.
2. En el iPhone: un espectáculo con un rótulo, y una noche con dos partidos de la jornada, un
   gol, Finalizar y Resultados.
3. Solo con esa build ya en el iPhone: publicar los anuncios de 132 px, ya rendrizados y
   validados en football-ai (`remotion/out/franja-132/`, 933b620). Antes no: la 1.0.0+8 solo
   carga anuncios de 108 y se quedaría sin franja de anuncios. El VPS ya está desplegado con
   ese código (2026-10-19) y sigue sirviendo el paquete vigente.

## 2026-10-16 · BUG ABIERTO: el programa sale sin sonido a tramos y solo lo arregla matar Zero · 🐞 sin diagnosticar, no olvidar

Visto en directo (17 en «Una cámara», 1.0.0 (8) o posterior, emitiendo al VPS → YouTube y
Facebook), medido en el VPS sin tocar el iPhone (grabaciones de
`/opt/football-vps/recordings/programa`, `volumedetect` por segmento de 60 s):
- Sonido bien hasta las 22:12 (hora local); **silencio digital exacto (−91 dB, todo ceros)**
  de 22:13 a 22:21, sonido de 22:21 a 22:25, silencio de 22:25 a 22:29, sonido de 22:29 a
  22:31 y silencio desde las 22:31.
- La pista AAC llega siempre (48 kHz, estéreo): **es la app la que mete ceros** en lugar
  del micrófono. El relé copia el audio tal cual (`-c copy`), no es el VPS.
- **PARAR y EMITIR no lo arregla** (siguió en silencio). **Matar Zero y volver a abrirla sí**
  (22:35, sonido de vuelta: media −19 dB, máx −5 dB).
- Algunas transiciones coinciden con una reconexión SRT (22:31) o con un segmento corto de la
  grabación (22:12:24, 22:21:50): un cambio en el flujo; otras (22:25) no.

**Hipótesis, por orden** (sin datos del iPhone todavía):
1. Una interrupción de `AVAudioSession` (llamada, otra app con micrófono, Siri, cambio de
   ruta a un auricular Bluetooth) tras la que la captura de audio no se reanuda, y el
   respaldo de silencio de `AudioCapture` (los `silence_samples`/`silence_ticks` del informe
   de audio) se queda puesto hasta que el proceso muere; PARAR/EMITIR no rehace la sesión de
   audio.
2. El sustituto de audio del vídeo del mando (IOS-103, `AudioSubstitute`/`ProgramVideoHub`,
   escrito en Windows y probado solo en tests) que se queda activo sin vídeo, o con un vídeo
   sin pista de audio («sin pista de audio suena a silencio y no al micro»).
3. La reanudación tras el fondo de 79588aa/4fb5bf4 (VideoToolbox y vista previa) sin
   equivalente para el audio.

**Siguiente paso:** leer del 17 (solo lectura) los `audio-*.json`, el informe
`program-split-left-*.json` (`app_events`, `audio`, `vt_session_resets`) y el latido de esa
emisión; mirar en el código qué hace `AudioCapture` ante
`AVAudioSession.interruptionNotification` y `routeChangeNotification`, y si EMITIR rehace la
sesión de audio. Arreglo esperado: reanudar el micrófono al acabar la interrupción (y al
cambiar de ruta) sin matar la app, y que la fila de audio de la pantalla avise en rojo de
«audio en silencio N s».

## 2026-10-16 · IOS-109 — La franja con una imagen, un título y un subtítulo · 🚧 probado en Windows; falta verlo emitido en el iPhone

Enmienda del ADR 0027 de football-ai (REF-64, c984f9c), pedida por Jhonatan: una franja
inferior más sencilla, con un título, un subtítulo y una imagen que se sube.

**Hecho**
- `StripTexts` es `{title, subtitle}`. Cada franja guardada tiene su imagen en `franjas/`
  (`assets/strip/<nombre>`: `PUT`, `GET`, `DELETE`, PNG o JPEG hasta 4 MB); renombrar la
  franja se lleva su imagen y borrarla, también. El estado lleva `strip_image` (la de la
  puesta) e `image` en cada franja guardada, como el dorado del túnel de football-ai.
- `grafico.json` se lee por partes: un formato viejo de la franja (el claim y los mensajes)
  vuelve a los textos de partida sin llevarse el icono, los escudos ni lo demás.
- El painter: la franja con la imagen contenida a la izquierda y el título y el subtítulo a su
  derecha, recortados si no caben; con anuncios encima, solo el fondo. Fuera el isotipo, el
  claim, las ranuras y la marca del producto. `ProgramGraphics` decodifica la imagen cuando
  cambia su versión.
- El mando web: cada franja guardada con su imagen en pequeño; el editor con nombre, título,
  subtítulo e imagen (se sube a la franja al guardarla) y «Quitar imagen».

**Comprobado**: `flutter analyze` limpio; la API (los textos, las franjas con su imagen,
renombrar y borrar), la geometría contra `boxes.json` y la franja con imagen frente a
`directo_franja.png` (0,91 % de píxeles distintos). Fallan en Windows los 8 dorados de imagen
y, a ratos, «se pinta en ≤50 ms».

**Pendiente**: regenerar en el Mac los dorados de `test/graphics`; en el iPhone, guardar una
franja con su imagen desde el Samsung y sacarla.

## 2026-10-16 · IOS-108 — El marcador reordenado · 🚧 probado en Windows; falta verlo emitido en el iPhone

Enmienda del ADR 0026 de football-ai (REF-63, 2a46f56), pedida por Jhonatan: el logo de la
casa y el de la copa arriba a la derecha, el reloj al lado de la barra, EN VIVO debajo y fuera
el chip de cámara.

**Hecho**
- `scoreboard_painter.dart`: encima de la barra, solo la competición; el reloj en una caja
  como el cuerpo de la barra, a su derecha y a su altura, con la sombra de la barra; EN VIVO,
  un chip rojo bajo la barra; sin chip de cámara. Arriba a la derecha, el chip de la esquina
  con el isotipo de Gala Sports y, a su izquierda, el icono de la copa si lo hay (deja de ir
  en el chip de la competición), con un filete en medio.
- OverlaySpec, los renders de referencia del marcador y los tests de la geometría.

**Comprobado**: `flutter analyze` limpio; la geometría contra `boxes.json` (el reloj, contra
la barra, que mide con el texto) y el marcador con escudos frente a `directo_escudos.png`
(0,63 %). Fallan en Windows los 8 dorados de imagen, que ya eran del Mac y además cambian.

**Pendiente**: regenerar en el Mac los dorados de `test/graphics`; verlo emitido.

## 2026-10-16 · IOS-107 — La jornada y las entrevistas desde el mando · 🚧 probado en Windows; falta verlo emitido en el iPhone

ADR 0030 de football-ai, pedido por Jhonatan: todos los partidos de la jornada (con sus
escudos, la hora y un subtítulo opcional como FINAL o TERCER Y CUARTO LUGAR) y una tarjeta para
la sección de entrevistas, las dos con el velo y la cancha desenfocada.

**Hecho**
- `GraphicsStore`: la jornada (`Fixture`, de 1 a 8 partidos) y la entrevista (`Interview`,
  quién habla y su cargo), del campeonato. Órdenes `match/fixtures` (sustituye la jornada
  entera), `graphics/fixtures` (409 sin partidos), `match/interview` y `graphics/interview`;
  las dos tarjetas se suman a las de pantalla completa, una a la vez.
- Los escudos por nombre: `assets/crests/<nombre>` (`PUT`, `GET`, `DELETE`), para los equipos
  de la jornada que no juegan ahora.
- El estado: `fixtures_on_air`, `fixtures` (con los escudos de cada equipo),
  `interview_on_air` e `interview`, como el dorado del túnel de football-ai 3e473fa.
- Los painters: `fixtures_card_painter.dart`, portado de `tools/fixtures_card.py`; la de
  entrevistas es la del entretiempo con `interview` (sin equipos, con quién habla y su
  cargo). `CardRaster.fixtures` y `ProgramGraphics` las sacan con el velo y la cancha
  desenfocada.
- El mando web: «Jornada» y «Entrevistas» en «Al aire»; la tarjeta «Jornada» con un partido
  por fila (local, visitante, hora y subtítulo; agregar, quitar, guardar) y los escudos de
  sus equipos debajo; la tarjeta «Entrevistas» con quién habla y su cargo.

**Comprobado**: `flutter analyze` limpio; la API (la jornada, sus límites, los escudos por
nombre, las entrevistas, una tarjeta a la vez), la jornada frente a `fixtures.png` (0,80 % de
píxeles distintos), las entrevistas frente a `interview.png` (0,56 %) y `ProgramGraphics`.
Fallan en Windows los 8 dorados de imagen del Mac y, a ratos, «se pinta en ≤50 ms».

**Pendiente**: en el iPhone, cargar una jornada con sus escudos desde el Samsung y sacarla, y
la de entrevistas.

## 2026-10-16 · IOS-105 e IOS-106 — Final del partido, próximo partido y varias franjas desde el mando · 🚧 probado en Windows; falta verlo emitido en el iPhone

ADR 0029 de football-ai, pedido por Jhonatan: como el entretiempo, una tarjeta de final del
partido y otra del próximo partido; y en la franja inferior, varias franjas guardadas para
sacar la que toque.

**Hecho**
- El motor: una tarjeta de pantalla completa al aire de tres (`fullScreenCard`:
  entretiempo, final, próximo partido), una a la vez y también frente a la alineación. Órdenes
  `graphics/fulltime`, `graphics/next_match` (409 sin datos) y `match/next`; quitar una que
  no está no tumba la que está.
- `GraphicsStore`: el próximo partido (`NextMatch`) y las franjas guardadas (`StripPreset`,
  hasta 12, PRINCIPAL de partida), del campeonato. Órdenes `graphics/strip_save` (añadir,
  sustituir o renombrar con `previous_name`; editar la puesta cambia la franja),
  `graphics/strip_delete` y `graphics/strip` con `name`. `graphics/strip_texts` sigue y deja
  la franja sin nombre.
- Los escudos del próximo partido: `assets/crest/next_home|next_away` (409 sin próximo
  partido), por el nombre de cada equipo como los del ADR 0028.
- El estado: `fulltime_on_air`, `next_match_on_air`, `next_match` (con los escudos de sus
  equipos), `strip_presets` y `strip_preset`, como el dorado del túnel de football-ai 62e39b1.
- Los painters: `HalftimeLayout` y `HalftimeCardPainter` con `title` (la de final) y `next`
  (la de próximo partido: el cuándo en la caja inclinada teal y el dónde debajo).
  `ProgramGraphics` saca la que toque con el velo y la cancha desenfocada; los escudos
  decodificados se guardan por versión y se sueltan los que dejan de usarse.
- El mando web: «Final del partido» y «Próximo partido» en «Al aire»; la tarjeta «Próximo
  partido» con el formulario y los escudos; y en «Franja inferior», la lista de franjas con
  «Sacar 15 s», «Editar» y «Borrar», y «Agregar franja».

**Comprobado**: `flutter analyze` limpio; la API (una tarjeta a la vez, el próximo partido y
sus escudos, las franjas), la de final frente a `fulltime.png` (0,46 % de píxeles
distintos), la de próximo partido frente a `next_match.png` (0,69 %), la geometría y
`ProgramGraphics`. Fallan en Windows los 8 dorados de imagen del Mac, como antes.

**Pendiente**: en el iPhone, sacar desde el Samsung la de final y la de próximo partido, y
guardar dos franjas y sacar cada una. Regenerar en el Mac `goldens/halftime.png`.

## 2026-10-16 · Arreglo: los goles y el reloj del mando web no respondían · ✅ en el código; falta comprobarlo en el iPhone

Jhonatan lo vio en el mando que abre la URL: ni «+ Gol» ni «− 1», ni iniciar, pausar o poner
a cero el reloj hacían nada. Lo rompió IOS-102: para que los formularios nuevos (equipos,
franja) los atendiera su `submit`, el reparto de clics descartaba los botones con
`type === 'submit'`, y el `type` de un `<button>` sin atributo vale «submit» aunque no esté
en un formulario. Ahora el reparto mira si el botón es de un formulario (`b.form`) y todos
los botones declaran su `type`. Un test de `api_server_test.dart` lo vigila.

## 2026-10-16 · IOS-104 — Los escudos de los equipos desde el mando · 🚧 probado en Windows; falta verlo emitido en el iPhone

ADR 0028 de football-ai, pedido por Jhonatan: subir desde el mando el escudo de cada equipo,
como el icono del campeonato. El escudo va con el nombre del equipo (en una liga los mismos
equipos vuelven cada fecha) y sustituye al genérico con siglas, entero y sin deformar en su
caja, en el marcador, el entretiempo y la alineación.

**Hecho**
- `GraphicsStore`: los escudos por la clave del equipo (el nombre en mayúsculas y sin
  espacios de sobra) en `escudos/`, con el fichero nombrado por los bytes UTF-8 de la clave en
  hexadecimal; del campeonato, como el icono. `TeamCrest` lleva su versión.
- La API: `PUT`, `GET` y `DELETE /api/v1/assets/crest/home|away`, para el equipo que juega
  de ese lado. La subida del icono se generaliza (`_putImage`): la puerta, el tope de 4 MB, a
  disco por trozos y solo PNG o JPEG. Cada equipo del estado lleva `crest` (su versión o
  null), como el dorado del túnel de football-ai 4ec503b.
- Los painters: `GalaBrand.paintTeamCrest` y los escudos en el marcador (la sombra sigue lo
  que se pinta: sin la silueta del genérico), el entretiempo y la alineación, sin siglas
  cuando son de verdad. `ProgramGraphics` decodifica de nuevo solo el escudo que cambió de
  versión; las cachés del marcador, el entretiempo y la alineación cuentan con ella.
- El mando web: en «Equipos», el escudo de cada equipo con su nombre, Cargar escudo y Quitar,
  y la nota de que va con el nombre.

**Comprobado**: `flutter analyze` limpio; la API (401, 415, 413, verlo, que siga al nombre al
cambiar de lado, que sobreviva al partido, quitarlo), el marcador con escudos frente a
`directo_escudos.png` (0,63 % de píxeles distintos), el entretiempo frente a
`halftime_escudos.png` (0,29 %), la alineación y `ProgramGraphics`. Fallan en Windows los 8
dorados de imagen del Mac (1a07741), como antes, y a ratos «se pinta en ≤50 ms» con la suite
entera.

**Pendiente**: en el iPhone, subir los escudos desde el Samsung y verlos en el marcador, el
entretiempo y la alineación emitidos. Regenerar en el Mac los dorados de `test/graphics` que
cambien (ninguno lleva escudo de verdad).

## 2026-10-16 · Entretiempo a pantalla completa, con la cancha desenfocada detrás (IOS-102, enmienda del ADR 0027) · 🚧 Dart probado en Windows; el Swift, sin compilar

Jhonatan lo vio en el iPhone: la tarjeta de entretiempo dejaba libre el hueco de la franja y
tapaba la cancha con un fondo opaco. Pidió que ocupe toda la pantalla y que el fondo sea un
blur translúcido, para que se siga viendo lo que pasa en la cancha.

**Hecho**
- La tarjeta (`halftime_card_painter.dart`, de football-ai f4757c4): un velo azul profundo
  al 60 % (`OverlaySpec.halftime['veil_alpha']`) en toda la pantalla, franja incluida. Las
  cajas no cambian.
- Pigeon: `setBackdropBlur(on)` en `RigHostApi`. `OverlayBridge.setBackdropBlur` solo cruza
  el canal cuando cambia. Con el entretiempo fuera, `ProgramGraphics` publica la tarjeta,
  pide el desenfoque y quita el marcador, que se vería a través del velo; al salir, todo
  vuelve.
- Nativo: `OverlayStore.backdropBlur` y `RigMedia/Metal/BackdropBlur.swift`. Mientras está
  pedido, `MetalProgramComposer` compone en tres pasadas sobre texturas propias reservadas al
  crear el compositor: la cancha sola, un gaussiano de MPS por plano (sigma 24 px sobre 1920;
  la croma, la mitad) y otra composición de una lente desde la cancha borrosa con el gráfico
  encima. Sin la franja de anuncios. `ComposeProgramKernel` gana el `encode` sobre texturas
  y `planes(of:)`.

**Comprobado**: `flutter analyze` limpio; los tests de la tarjeta (el velo en las esquinas y
en la franja, 0,31 % de píxeles distintos de Python), del puente y de `ProgramGraphics` (la
secuencia tarjeta → desenfoque → sin marcador, y al revés) pasan. En Windows fallan los 8
dorados de imagen de `test/graphics`, porque Alex los regeneró hoy en el Mac (1a07741) y son
de su plataforma; `halftime.png`, además, cambia de verdad. Escrito sin compilar:
`BackdropBlurTests` (las franjas pierden el detalle, el cuadrado del gráfico sigue igual, el
borde no se oscurece, y el compositor solo desenfoca si se pide).

**Pendiente (Mac e iPhone)**: compilar y pasar `BackdropBlurTests`. A vigilar:
`MPSImageGaussianBlur` sobre `r8Unorm` y `rg8Unorm`. Regenerar `goldens/halftime.png` con
`flutter test --update-goldens test/graphics/halftime_card_painter_test.dart`. En el
iPhone: sacar el entretiempo emitiendo y ver la cancha desenfocada en movimiento detrás, sin
marcador ni franja, y los ms de GPU del compositor en el informe con la tarjeta fuera.

## 2026-10-16 · IOS-103 — Vídeos MP4 desde el mando, a pantalla completa y con su sonido · 🚧 Dart probado en Windows; el Swift, sin compilar

ADR 0027 de football-ai, decisiones 4 y 6. El operador sube MP4 desde el mando, los pasa en
el programa a pantalla completa por encima del gráfico y con su sonido, y al acabar vuelven
el programa y el micro. En dos commits: el servidor y el mando web (1/2) y el nativo (2/2).

**Hecho**
- `VideoStore` (`Documents/partido/videos/`, como el icono no se aparta con el partido):
  `PUT /api/v1/videos/<nombre>.mp4` a disco por trozos, con la puerta, el nombre, el tope de
  1 GB y la reserva de grabación (507 si no; ver la corrección de abajo) antes del cuerpo; solo se adopta si empieza por `ftyp` y se le lee la duración
  del `moov/mvhd` (delante o detrás, v0 y v1). `GET /api/v1/videos` la lista y `DELETE` borra
  (409 si suena).
- El motor: `video/play` (`{name}`) y `video/stop`, con su `id` de reproducción. El cero va
  `videoStartLeadMs` (300 ms) por delante para que el lector tenga listo el principio. El
  estado lleva `video: {name, remaining_ms}` o null, como el dorado del túnel de football-ai
  19ad9e8. Si el nativo no avisa del final, el vídeo se da por acabado a su duración más
  `videoEndGraceMs`.
- El mando web: la tarjeta «Vídeos» con la lista (duración y tamaño), Pasar y Borrar en cada
  uno, lo que suena con su cuenta atrás y Parar, y la subida con barra de progreso
  (XMLHttpRequest). El nombre se limpia en el navegador a lo que acepta el maestro.
- Pigeon: `playVideo(id, path, leadMs)` (asíncrono, devuelve "" o el error) y `stopVideo`
  en `RigHostApi`; `onVideoEnded(id)` en `CaptureFlutterApi`, que `CaptureSession` pasa a
  `MatchEngine.videoFinished`. `ProgramVideo` (Dart) lleva al nativo lo que dice el motor, una
  vez por reproducción, con los cambios del motor y cada segundo; lo que el nativo no puede
  abrir no se queda «sonando».
- `RigMedia/Video/ProgramVideoPlayer.swift`: dos AVAssetReader (vídeo y audio, para que uno
  no espere al otro); el vídeo escalado a 1920×1080 NV12 con bandas por VTPixelTransferSession
  en un anillo de 12 fotogramas de un pool preasignado, y enderezado con la composición de sus
  propiedades si viene girado; el audio a 48 kHz estéreo en una cola de 500 ms por delante.
  `ProgramVideoHub` tiene uno a la vez y avisa una vez al acabar (no al parar).
- El fotograma: `SplitBench.program(_:t:)` lo cambia por el del vídeo antes de la miniatura y
  el codificador, así tapa también el gráfico, la franja, SIN SEÑAL y el fotograma repetido de
  un hueco de cámara.
- El sonido: `AacEncoder` gana un sustituto (`ProgramAudioSubstitute`) al que pide cada trozo
  de su eje ya corregido, venga del micro o del silencio del vigilante: el AAC del programa
  lleva el vídeo con su sello y sin huecos, y `onAligned` (la 4K) sigue con el micro.

**Comprobado**: `flutter analyze` limpio y `flutter test` en verde (476): el almacén y su
lectura del MP4, la API (subida, 401, 415, 400, 409, lista, borrar), el estado y el margen
sin aviso, y el conductor. Escritos sin compilar: `ProgramVideoPlayerTests` (MP4 generados en
el test: el fotograma de cada instante, las bandas de 4:3 y de un vídeo vertical, el sonido
en el eje, un vídeo mudo, el aviso del hub, un fichero que no es vídeo) y
`AudioSubstituteTests` (el AAC lleva el tono del sustituto solo en su tramo y la 4K el micro).
El Chrome sin cabeza ya no arranca en esta máquina: la tarjeta se revisó con la sintaxis de
Node y la limpieza de nombres, no en pantalla.

**Corrección del 2026-10-16 (probado en el iPhone por Jhonatan)**: subir cualquier vídeo daba
«no hay sitio: el vídeo dejaría menos de 40 GB». La reserva era siempre la de la 4K local,
y con menos de 40 GB libres la 4K ya no arranca (`RecordingPolicy`): el vídeo no le quitaba
nada. Ahora los 40 GB solo se guardan si «Guardar vídeo» está encendido y caben hoy; si no,
basta con dejar `videoMinFreeAfterBytes` (8 GB: la copia del programa de 2 h y el suelo
del disco). El aviso dice cuál de las dos falta y qué hacer. Enmienda del ADR 0027.

**Pendiente (Mac e iPhone)**: compilar ZeroKit y el Runner y pasar los dos tests nuevos;
dudosos de compilar: `AVVideoComposition.videoComposition(withPropertiesOf:)` y la
`AVAssetReaderAudioMixOutput` con sus ajustes. En el iPhone: subir un MP4 de ~30 s desde el
Samsung, pasarlo y ver y oír en el programa emitido que tapa el gráfico, que suena en sincronía
y que al acabar vuelven el gráfico y el micro; probar Parar a mitad y un vídeo vertical.
**Queda fuera**: el vídeo no se ve en la vista previa local de la app ni en la tarjeta de
SIN SEÑAL del VPS (NUBE-18), solo en el programa; sin programa en marcha (sin EMITIR) solo
suena su audio en el AAC y el motor lo quita a su duración.

## 2026-10-16 · IOS-102 — Equipos, entretiempo, icono del campeonato y franja a demanda desde el mando · 🚧 hecho y probado en Windows; falta verlo emitido en el iPhone

ADR 0027 de football-ai, decisiones 1, 2, 3, 5 y 6. Lo pidió el propietario: desde el mando,
los nombres, el entretiempo con su icono, el icono junto al marcador y la franja que sale
15 s. En dos commits: el servidor y el mando web (1/2) y los painters (2/2).

**Hecho**
- El motor y la API (1/2): `match/teams`, `graphics/halftime` (una tarjeta a la vez con la
  alineación), `graphics/strip` (15 s por defecto, 0 la quita, hasta 120) y
  `graphics/strip_texts`; el icono por `PUT`/`GET`/`DELETE /api/v1/assets/championship`,
  escrito a disco por trozos con la puerta antes del cuerpo, tope de 4 MB y solo PNG o JPEG.
  Los textos de la franja y el icono son del campeonato (`GraphicsStore`) y sobreviven al
  partido. El estado lleva `halftime_on_air`, `strip_remaining_ms`, `strip_texts` y
  `championship_icon`, como el dorado del túnel de football-ai.
- El mando web (1/2): las tarjetas Equipos, Al aire (con el entretiempo), Franja (sacar 15 s
  con su cuenta atrás, ocultar, editar el claim y los tres mensajes) e Icono del campeonato.
- Los painters (2/2): `halftime_card_painter.dart`, portado de `tools/halftime_card.py`
  (sin icono, el isotipo); el marcador con el icono en el chip de la competición y la franja
  solo cuando está fuera, con los textos del estado. `ProgramGraphics` decodifica el icono
  cuando cambia su versión, publica el entretiempo en la capa de tarjetas (en lugar de la
  alineación) y la tarjeta de alineación usa el nombre del marcador.

**Comprobado**: `flutter analyze` limpio y `flutter test` en verde (467). La tarjeta de
entretiempo difiere un 0,32 % de píxeles del PNG de Python; el icono cae en la caja de
`directo_icono` (292,94; 51) y la tarjeta en las de `halftime`. El dorado nuevo
`test/graphics/goldens/halftime.png` salió de Windows: hay que regenerarlo en el Mac con
`flutter test --update-goldens test/graphics`.

**Pendiente**: verlo emitido en el iPhone (aceptación de la tarjeta). Siguiente: IOS-103,
los vídeos.

## 2026-10-15 · IOS-101 — «Una cámara»: el programa es la lente tal cual · 🚧 escrito sin compilar (Windows)

Jhonatan probó «Una cámara» con el 17 y el programa salía como un acercamiento de la lente:
el director encuadraba dentro de la franja del campo con la geometría nominal (un soporte a
~5 m), y su plano más abierto no llegaba a la lente entera. Pidió que, con una cámara, la
transmisión sea la imagen tal cual. Enmienda del ADR 0025 en football-ai.

**Hecho**
- `RigCore/Direction/FullLensView.swift`: el campo más ancho que cabe entero en la lente a
  16:9, por su eje óptico y con el giro del móvil descontado, al 99 % para que el redondeo de
  la vista no deje bordes negros. Sin giro, 105,5° de los 106° de la ultra gran angular.
- `ProgramRunConfig.single` va sin director, y `RigLinkNW` ya no monta
  `DirectorLoop.singleCamera`: la vista fija de `scriptedView` mira por el eje de la lente con
  ese campo (antes, 60°). En el N0 sus vistas salen como `lens`. Con dos móviles, nada cambia.
- El detector sigue corriendo para el N0 y no mueve nada.

**Comprobado**: las cuentas de `FullLensViewTests`, replicadas en Python con la misma
proyección (sin giro, la lente entera menos el 1 %; con giros de hasta 0,12 rad ninguna
esquina se sale; un 1 % más abierta ya se sale). **Sin compilar**: en Windows no hay Swift.

**Pendiente**: compilar y pasar `FullLensViewTests` y `ProgramRunTests` en el Mac; probar en
el iPhone con «Una cámara» que el programa enseña lo mismo que la miniatura de la lente. El
chip «CÁMARA IA · AUTO» del gráfico no cambia con una cámara (anotado en el ADR).

## 2026-10-15 · El mando web del maestro, rediseñado para el móvil (IOS-64) · 🚧 probado con un maestro simulado; falta en la cancha

El propietario usa un Samsung de operador: la app Zero no corre en Android (todo lo nativo
—cámara, QR, Keychain— es solo de iOS, y el APK de release no lleva permiso de internet),
pero el QR Mando es un enlace y la cámara del Samsung lo abre en Chrome. La página que sirve
el maestro (`assets/panel/index.html`) era una lista de botones sin forma; pidió que se
viera mejor y fuera cómoda en el móvil.

**Hecho**
- La página con la marca Gala Sports en oscuro (ADR 0026 de football-ai) y primero para
  el móvil: marcador arriba con los goles inclinados (local teal, visitante blanco) y el
  reloj; «+ GOL» de 72 px por equipo y «−1» aparte; el reloj con un solo botón que es
  Iniciar/Pausar/Reanudar según su estado, ±1 min y «Cero» con confirmación; las
  alineaciones como interruptores que dicen si están al aire (y se apagan sin alineación);
  «Marcar jugada»; miniaturas plegables con el programa grande; el estado del soporte en
  fichas legibles en vez de JSON; EN VIVO y el estado de la conexión en la cabecera; los
  errores en un aviso abajo. Dos columnas desde 900 px.
- El reloj avanza solo mientras corre (antes se quedaba quieto hasta el siguiente cambio
  del partido), y las miniaturas no se piden con la página en segundo plano.
- La API no cambia: mismas rutas, el token del fragmento, la espera larga y la clave de
  idempotencia. Fuentes de Google Fonts si hay red; si no, las condensadas del sistema.

**Comprobado**: `api_server_test` en verde; capturas en Chrome sin cabeza a 360, 390 y
1200 px contra un maestro simulado. Sin probar contra el iPhone de verdad.

## 2026-10-15 · IOS-100 — el gráfico con la marca Gala Sports en Dart · 🚧 hecho y probado en Flutter; falta verlo emitido en el iPhone

El propietario pidió que lo que sale en pantalla siga su sistema de diseño Gala Sports
(ADR 0026 de football-ai). La referencia se hizo allí en REF-56, REF-57 y REF-58
(e5a31b6, 04dc57b, f1ddb40 y 08630ef); esto la porta a la app.

**Hecho**
- `lib/src/graphics/gala_brand.dart`, el port de `tools/brand.py`: tokens por nombre, las
  dos familias (Inter con el eje `wght` explícito), el corte a -30°, el escudo genérico con
  sus siglas, la sombra-grafismo y el isotipo (decodificado una vez).
- `scoreboard_painter.dart`: el `Scoreboard` arriba a la izquierda (fila de estado con EN
  VIVO, competición y reloj tabular; barra inclinada con escudos y goles teal/blanco), el
  chip de cámara y la franja con el isotipo y la raya. `paintScoreboard` carga el isotipo.
- `lineup_card_painter.dart` (oscura, dorsales inclinados, escudo) y `slate_painter.dart`
  (azul profundo, Barlow Condensed 800).
- Barlow Condensed 600/700/800 e Inter variable en `assets/fonts/` (los TTF de la
  referencia) y el isotipo en `assets/brand/`; anotados en DEPENDENCIES.
- El OverlaySpec nuevo (Dart y Swift) y los renders de referencia, copiados a mano de
  football-ai 08630ef: `export_golden --sync` no corre en Windows. Solo esos ficheros; el
  resto del `--sync` sigue siendo del Mac. En Swift solo se lee `stripHeight`, que no cambia.
- Tests: la geometría contra las cifras de Python, el reloj de ancho fijo, las siglas; los
  goldens de imagen regenerados; `test/zero_fonts.dart` carga también las fuentes de la marca.

**Comprobado (Windows)**
- `flutter analyze`: sin avisos. `flutter test`: 452 pasan, 1 falla: «se pinta en ≤50 ms»
  de la alineación (51 ms), que ya fallaba en esta máquina antes del cambio.
- La alineación de Dart difiere un 2,17 % de píxeles de la de Python (el umbral es 3 %).
  Marcador, franja y alineación comparados a ojo con los renders de Python: iguales salvo
  el ancho de los nombres (±2 px).

**Pendiente**
- **Los goldens de imagen se regeneraron en Windows**; en el Mac el texto rasteriza
  distinto y fallarán hasta `flutter test --update-goldens test/graphics` allí.
- Compilar en el Mac y verlo emitido en el iPhone (Alexander).

## 2026-10-15 · Noche: emisiones al VPS con el dedo en EMITIR («Una cámara»), lo que se cortaba y por qué · 🚧 el vigía y la latencia que crece, instalados en el 17 sin probar aún

Alexander emitió desde el 17 en «Una cámara (sin pareja)» al VPS (167.71.31.225, QR Soporte
del Keychain) y a YouTube, con la app que iba compilando el Mac (hasta ffe1f05 a las 21:31).
Informes en `bench/partido-20261015-{1605,2023,2039}` y en el scratchpad de la sesión.

**Lo que funcionó:** EMITIR desde la pantalla, el QR Soporte, el programa entero a 30 fps en
el móvil siempre (copia .mov al 100 %), y en el VPS, cuando la red lo dejaba, 30 fps a
5-6 Mbit/s con el relé a YouTube estable (15:53-16:02, 20:54-20:58, 20:52-20:58).

**Lo que se cortaba, de fuera a dentro:**
1. **La red del móvil.** Entre 18:26 y 18:52 el 17 saltó entre la Wi-Fi floja y los datos
   móviles (la Asistencia Wi-Fi): el VPS vio otra IP pública (190.63.x.x) en un tramo, RTT
   de 1,2 a 2,8 s, 2-43 % de los fotogramas entregados. Regla nueva en GUIA-CANCHA: datos
   apagados y la Wi-Fi del Starlink cerca.
2. **YouTube.** Un rato daba el directo por terminado por su cuenta (Alexander lo arregló en
   YouTube Studio; «era algo del YouTube»). Recomendación: detención automática apagada.
3. **El publicador se quedaba reteniendo para siempre** (la causa de «32 s de vídeo y 18 min
   de nada» a las 20:19 y «5 min 46 s y nada» a las 20:52): el búfer de envío de libsrt pasó
   la latencia (1 514-1 520 ms > 1 500) en un bache de Wi-Fi y nunca bajó de 750 → `drain()`
   retenía en cada tic (80 975 `send_holds`), la cola se congestionaba y pedía un IDR cada
   segundo, la conexión seguía viva y el VPS sin vídeo. Arreglado en bfaab04 (el vigía de
   atasco reconecta) y ffe1f05 (la latencia SRT sube 1,5 → 2,5 → 4 s al reconectar cuando
   la red lo pide; el umbral de retención es latencia/2; el atasco reconecta al segundo).
4. **El relé del VPS** moría con cada corte del programa y relanzaba fallando hasta el
   siguiente SPS («Invalid argument»): 6 200 arranques. Lo cubre NUBE-18 (en marcha en
   football-ai): un solo directo hacia YouTube con tarjeta de espera.
5. **iOS mató Zero al ir al fondo** (18:32, 0x8BADF00D): la vista previa rehacía la sesión
   en el hilo principal. Arreglado en 79588aa.

**Primera prueba de ffe1f05 en el 17 (21:41, 487 s, «Una cámara» al VPS):** 1 atasco y 1
reconexión del vigía (`stall_reconnects` 1, `connects` 2), y siguió: 13 917 de 14 584 fotogramas
enviados (95 %), último vídeo a los 484 s, `send_holds` 612 (antes, 80 975), bitrate de vuelta a
3 Mbit/s, 5 746 paquetes perdidos en la Wi-Fi recuperados. Antes de ffe1f05, el mismo bache
dejaba la emisión muerta hasta PARAR.

**Instalado en el 17 a las 21:31: ffe1f05** (vigía + latencia que crece + vista previa +
foco de Jonathan). **La IPA 1.0.0 (4) de TestFlight es de 09f9bc4: lleva el vigía y la vista
previa, no la latencia que crece.** Sin probar en el iPhone todavía: el próximo informe del
17 (`publish.sessions[*].latency_ms`, `latency_raises`, `stall_reconnects`) lo dirá.

## 2026-10-15 · La latencia SRT sube cuando la red lo pide (1500 → 2500 → 4000 ms) y el atasco reconecta al segundo · 🚧 probado con el socket falso; falta la emisión real

**El caso, medido emitiendo de verdad al VPS (MediaMTX 1.21 en 167.71.31.225) desde el Wi-Fi
de casa con bufferbloat.** Sesión de las 20:52 (476 s): perfecta 346 s (30 fps, 5-6 Mbit/s en
el VPS) y al empeorar la Wi-Fi (`srt_packets_lost` 1712, `rtt_ms_max` 779, `send_buffer_ms_max`
**1514**, por encima de la latencia SRT de 1500) el publicador se quedó reteniendo (`send_holds`
9965, `congestions` 131, un IDR por segundo) y no envió nada en los últimos 130 s con la
conexión viva. La de las 20:19: lo mismo a los 32 s, 18 min sin enviar. Las de 18:44-18:52: RTT
1,2-2,8 s (> la latencia), 2-15 % de los fotogramas enviados. El vigía de bfaab04 reconecta
cuando no sale vídeo en 5 s, pero **con el RTT bajo carga por encima de la latencia SRT,
libsrt no entrega a tiempo, tira por TLPKTDROP, el búfer de envío se queda por encima del
umbral de retención (750 ms, constante fija) y el publicador retiene**: reconectar con la
misma latencia se atasca otra vez en segundos (visto a las 21:01). Alexander prefiere emitir
con 1-2 s más de retardo antes que cortarse.

**Hecho** (ZeroKit RigCore + RigNet, Runner, Dart; un commit).
- **La escalera de latencia** `ProgramSrt.latencyStepsMs = [1500, 2500, 4000]` (ms, tope 4000)
  y `ProgramSrtLatency` (RigCore): la latencia de la pasada, que solo sube. El publicador la
  pasa a `connect` (SRTO_LATENCY se fija al conectar; nada que hacer con la conexión viva) y
  sube al escalón siguiente al cerrarse una conexión que publicaba (a) por atasco del vigía
  (sin vídeo 5 s, o búfer > latencia 4 s), (b) por **congestión sostenida** (nuevo: la muestra
  congestionada `sustainedCongestionReconnectS` = 10 s seguidos y queda escalón; en el tope no
  reconecta, no ganaría nada; `SrtError.sustainedCongestion`), o (c) por un corte normal si en
  esa conexión `rtt_ms_max` o `send_buffer_ms_max` pasaron de la mitad de la latencia
  (`latencyRaiseDivisor` = 2). No baja en la pasada; otro publicador (otra pasada, u otro
  maestro) empieza en 1500.
- **El umbral de retención es la mitad de la latencia en uso**
  (`ProgramPublish.congestionSendBufferMs(latencyMs:)`, divisor 2: 750 / 1250 / 2000 ms), ya no
  la constante 750: `drain()`, `requestIdr()` y la muestra lo leen de `ProgramSrtLatency`.
- **Reconectar por atasco espera 1 s** (`ProgramPublish.stallReconnectDelayS`,
  `ReconnectBackoff.Failure.stalled`), no los 3 s de un corte: la conexión la cerramos nosotros
  con el servidor contestando y MediaMTX (overridePublisher) acepta al nuevo. Desde que deja de
  salir vídeo: 5 s del vigía + 1 s + el conectar ≈ 6,5 s (antes ≈ 8,5). IDR al conectar, como ya.
- **El IDR que no llega ya lo cubría bfaab04**, confirmado con test: tras pedir un IDR la cola
  tira todo lo que no sea IDR, `firstUnsentVideoAtMs` corre y a los 5 s el vigía reconecta con
  «cola esperando IDR» en el log (`testAnIdrThatNeverArrivesIsAStallAndReconnects`). No hace
  falta otro plazo de 2 GOP.
- `Stats` nuevas: `latency_ms` (la en uso o la de la próxima conexión) y `latency_raises`; van
  al informe (`publish.sessions[*]`) y al latido (`publish`). Log: «conectado a host:port ·
  latencia SRT 2,5 s» y «latencia SRT 1,5 s → 2,5 s: atasco (rtt máx N ms, búfer máx M ms)» o
  «latencia SRT en el tope (4 s); …».
- **Pantalla**: la fila SRT de la tarjeta Programa dice «publicando a host:port · latencia
  1,5 s [· N reconexiones]» y «conectando a host:port · latencia 2,5 s…» (el Runner pone la
  latencia en `srtDetail` cuando publica o conecta; el porqué del fallo, como antes, cuando
  reconecta o falla). Sin tocar Pigeon.

**Comprobado** (worktree `../wt-srt-lat`; el árbol principal y los iPhone, sin tocar)
- `swift test --skip ModelBench`: **574 tests, 4 saltados, 0 fallos** (11 nuevos: 5 en
  `ProgramSrtTests` —escalera, subida y tope, umbral derivado, «pide más», texto—, 6 en
  `ProgramPublisherTests`: atasco → 1 s y 2500 con el umbral nuevo dejando pasar 900 ms de
  búfer; corte con RTT 1200 → 2500 y sigue esperando 3 s; corte con red sana → sigue en 1500;
  tres atascos → 1500/2500/4000/4000 con 2 subidas y otra pasada en 1500; 10 s de congestión →
  2500 y en el tope no reconecta; IDR que nunca llega → atasco). `ProgramSendQueueTests`:
  `.stalled` espera 1 s y vigía + espera ≤ 7 s.
- El Runner con `swiftc -typecheck` (iOS 26) contra RigCore, RigNet y RigMedia emitidos para
  iOS desde este árbol y Flutter y HaishinKit del DerivedData: **0 errores, 34 avisos**, ninguno
  en lo nuevo. `tools/check_layers.sh`: limpio.
- Dart: `flutter test --no-pub` de `capture_labels_srt_test.dart` (nuevo, 2 tests: la fila SRT
  con latencia, reconexiones, conectando y reconectando), `capture_labels_ladder_test.dart` y
  `widget_test.dart`: **45 tests, All tests passed**.

**No probado en hardware.** Ni que MediaMTX acepte la reconexión al segundo con el publicador
anterior aún «publishing» (cuenta con overridePublisher; a las 20:15 la reconexión a los 3 s
funcionó), ni que con 2500-4000 ms de latencia el relé del VPS y el reproductor sigan bien
(`stream_url.dart` fija su propia latencia de lectura; mirar si hay que subirla a la par).

**Qué mirar en el próximo informe del 17** (`publish.sessions[*]` y el latido `publish`):
`latency_ms` > 1500 y `latency_raises` ≥ 1 en un tramo tras un atasco dicen que subió; con
2500 el tramo siguiente debe tener `send_holds` y `congestions` muy por debajo del anterior y
`video_frames_sent` cerca de `program_frames`; `last_error` «SRT congestionado 10 s seguidos…»
es la subida por congestión sostenida (no debe repetirse más de 2 veces por pasada: la
escalera tiene 3 escalones); en el VPS el corte por atasco no debe pasar de ~7 s (5 + 1 +
conectar). En la pantalla, «· latencia 2,5 s» en la fila SRT. Si con 4 s de latencia
(`latency_ms` 4000) sigue reteniendo, el problema no es el RTT: es ancho de banda, y lo que
toca es la escalera de bitrate.

**Decisión pendiente de Alexander: enmienda a SPK-07 / ADR 0023 (y ADR 0022).** La latencia
SRT ya no es fija de 1500 ms: empieza ahí y crece hasta 4000 cuando la red lo pide, sin bajar
en la pasada. El retardo cristal→VPS pasa de ~1,75 s a hasta ~4,25 s en redes malas. Si se
acepta, va al ADR 0023 (el «≤1,75 s de cristal a VPS» pasa a ser «≤1,75 s con la red sana;
hasta ~4,25 s antes que cortarse») y al ADR 0022 §8 (la reconexión por atasco al segundo).
Queda fuera: `tools/cancha.py` no enseña aún `latency_ms`/`latency_raises` en la línea SRT, y
la latencia del reproductor (`stream_url.dart`) no sigue a la del publicador.

## 2026-10-15 · El atasco del SRT: la conexión viva 19 min sin sacar un fotograma, y el vigía que la reconecta · 🚧 probado con el socket falso; falta la emisión real

**El caso, medido emitiendo de verdad al VPS (MediaMTX 1.21, SRT a 1500 ms) por un Wi-Fi con
bufferbloat (RTT 130 ms en reposo, 1-2,4 s bajo carga).** Sesión de las 20:19 (`bench/partido-
20261015-2039/…/program-split-left-1792118304.json`, publish.sessions[0]): 18,9 min
«publishing» con la conexión viva todo el rato (`connects` 1, `reconnects` 0, el VPS cerró con
EOF solo al PARAR), `video_frames_sent` **921 de 33 914**, `last_sent_rig_ms` a los **32 s** de
empezar y nada más en los 1100 s restantes; `send_holds` 80 975, `congestions` 1032 e
`idr_requests` 1033 (uno por segundo cada uno), `send_buffer_ms_max` **1520** y la red ya
sana (`rtt_ms` 142, 0 % pérdidas). La de las 20:13 (`program-split-left-1792116945.json`): 2093
de 4903 enviados, `rtt_ms` 2445, `congestions` 83, `send_holds` 7197, bitrate en el suelo. Las
de 18:44-18:52: 43 de 2651, 79 de 1372, 863 de 5647.

**El diagnóstico (hipótesis 1, confirmada en los síntomas).** `drain()` retiene mientras
`sendBufferMs()` > 750, y esa lectura de libsrt es «el paquete más nuevo menos el más viejo
sin confirmar»: si el otro lado deja de confirmar, la lectura se congela y la retención no
acaba nunca. 1520 ms es exactamente la latencia más los 20 ms del TLPKTDROP de libsrt: el
búfer pasó la latencia una vez (libsrt tiró 277 paquetes), MediaMTX/gosrt no volvió a mover
el ACK, y desde entonces cada segundo la cola se congestionaba, tiraba todo, pedía un IDR, el
IDR llegaba retenido y se tiraba al segundo siguiente. Nada cerraba la conexión: libsrt solo
la da por rota si el otro lado deja de contestar, y contestaba. Lo que no se sabe desde aquí
es por qué el receptor no avanzó el ACK tras el drop del emisor (¿gosrt no atiende el
UMSG_DROPREQ?); hay que mirarlo en el log de MediaMTX de esa hora. La hipótesis 2 (el IDR no
llega) no es la raíz: `programEncoder` es un solo objeto con el GOP a 2 s y `forceIDR`
funciona; pero la petición de un IDR cada segundo mientras se retiene sí agravaba el atasco
(a 1 Mbit/s, un IDR forzado por segundo es casi todo el bitrate).

**Hecho (commit único, ZeroKit + Runner + cancha).**
- **Vigía de atasco** en `ProgramPublisher.tick()` (`stalled(_:)`): si la conexión está
  `publishing`, llegan fotogramas del codificador y en `ProgramPublish.stallReconnectS` (5 s)
  ninguno ha entrado en SRT, se cierra y se reconecta como tras un corte (3 s, IDR al
  conectar). También si el búfer de envío lleva `bufferOverLatencyReconnectS` (4 s, dos GOP)
  por encima de la latencia SRT, aunque algo siga saliendo (libsrt ya tira paquetes sueltos
  y lo que sale llega roto). Sin fotogramas llegando (segundo plano) no es un atasco. Errores
  nuevos `SrtError.stalled` y `.sendBufferOverLatency`, que salen en `last_error` y en el
  `srtDetail` de la pantalla.
- **IDR pendiente mientras se retiene**: `requestIdr()` no pide el IDR si SRT está retenido
  (llegaría retenido y la cola lo tiraría al segundo); lo deja pendiente y `drain()` lo pide en
  cuanto el búfer baja. Un IDR forzado por retención, no uno por segundo.
- `Stats` nuevas: `stall_reconnects` y `last_sent_age_s` (segundos desde el último fotograma
  de vídeo que entró en SRT). **El latido** lleva ahora el publicador entero en `publish`
  (hoy solo tenía `srt_state`, y por eso el atasco solo se vio en el informe final).
- `tools/cancha.py`: la línea SRT dice «N por atasco» y, en el informe o el latido, «último
  vídeo enviado hace N s · E fotogramas enviados de F»; aviso si pasa de `VIDEO_PARADO_S`
  (10 s, el doble del vigía). De informes anteriores sale de `last_sent_rig_ms` y el reloj
  del soporte.

**Comprobado** (worktree aparte; el árbol principal y los iPhone, sin tocar)
- `swift test --skip ModelBench`: **563 tests, 4 saltados, 0 fallos** en el árbol ya rebasado
  sobre 79588aa (5 nuevos de aquí; 555 antes de rebasar).
- El Runner con `swiftc -typecheck` (iOS 26, Swift 5) contra RigCore, RigMedia y RigNet
  emitidos para iOS desde este árbol ya rebasado (`swiftc -emit-module` en el scratchpad;
  RigMedia con un `Bundle.module` de tres líneas en vez del que genera SwiftPM) y Flutter y
  HaishinKit del DerivedData de antes: **0 errores, 32 avisos**, ninguno en lo nuevo.
- `tools/check_layers.sh`: limpio. `python3 tools/test_cancha.py`: 27 OK (uno nuevo,
  `test_el_srt_dice_hace_cuanto_salio_el_ultimo_video`: el informe atascado, el curado por el
  vigía, uno viejo sin `last_sent_age_s` y el latido).
- Tests nuevos: `testAStalledConnectionIsReconnectedAfterFiveSecondsWithoutVideoOut` (el búfer
  del socket falso en 900 ms para siempre: a los 3 s no, a los 5 s reconecta, IDR al volver,
  `last_sent_age_s` vuelve a 0), `testNoVideoArrivingIsNotAStall`,
  `testASendBufferAboveTheLatencyForTwoGopsReconnects`,
  `testTheBufferDroppingBelowTheLatencyResetsTheCount` y
  `testTheStallWatchdogOutlastsTheQueueAndTheRetryWait`; el de la congestión, actualizado al
  IDR pendiente.

**No probado en hardware.** Ni la reconexión contra MediaMTX con el publicador anterior aún
«publishing» (cuenta con `overridePublisher`, como la reconexión tras corte que ya funcionó
hoy a las 20:15: `SRT no envía (5004)` → reconectó), ni que `srt_getsndbuffer` baje de verdad
tras reconectar.

**Qué mirar en el próximo informe del 17** (`publish.sessions[*]` y el latido `publish`):
`stall_reconnects` > 0 con `last_error` «SRT vivo pero 5 s sin sacar vídeo…» o «…por encima de
la latencia…» confirma que el vigía pilló el atasco; `last_sent_age_s` < 10 al acabar y
`video_frames_sent` cerca de `program_frames` dicen que el programa siguió llegando;
`idr_requests` debería quedar cerca de `congestions` solo si no hubo retenciones largas (con
el IDR pendiente, muy por debajo de 1/s). En el VPS, la grabación no debe parar más de
~10 s seguidos (5 del vigía, 3 de espera, el conectar).

**Pendiente (decisión, no se toca ahora).** Con RTT medido > latencia SRT (hoy 2445 ms contra
1500), el ARQ no llega a tiempo y libsrt tira por su cuenta: o se sube la latencia a
2500-3000 ms cuando el RTT lo pida (medirlo al conectar, o adaptarla con `rtt_ms_max`), o se
fija por el QR Soporte según la red del campo. Va al ADR 0022 cuando se decida; SPK-07 lo
tenía que fijar con medidas y estas son las primeras. Y mirar en el log de MediaMTX por qué
el receptor no movió el ACK tras el drop (si es gosrt, reportarlo).

## 2026-10-15 · El 0x8BADF00D del 17 al fondo: la vista previa ya no rehace la sesión en el hilo principal (79588aa) · 🚧 sin probar en el iPhone

**El fallo.** 18:32:57, el 17 emitiendo en «Una cámara (sin pareja)», Zero al fondo: iOS la
mató (`Runner-2026-10-15-183257.ips`: `EXC_CRASH SIGKILL`, FRONTBOARD `0x8BADF00D` «Failed to
terminate gracefully after 5.0s», WatchdogVisibility Background). El hilo principal estaba en
`-[AVCaptureVideoPreviewLayer _initWithSession:makeConnection:]` → `setSession:` →
`_addVideoPreviewLayer:` → **`_removeAllPreviewLayers`** → `setSession:` (la capa anterior) →
`commitConfiguration` → `_buildAndRunGraph` → `AVRunLoopCondition _waitInMode:`; y el hilo
`com.apple.coremedia.capturesession.notifications` en `objc_sync_enter` dentro de
`_handleConfigurationCommittedNotificationWithPayload:`, contra el cerrojo que tenía el
principal. Quién lo llamaba: `CapturePreviewFactory.create` → `CaptureEngine.makePreviewLayer`
→ `AVCaptureVideoPreviewLayer(session:)`, **una capa nueva por cada montaje de la vista de
plataforma** (el vistazo sobre la tarjeta, PARAR, EMITIR), y AVFoundation solo admite una: quita
la anterior rehaciendo el grafo de captura, en el hilo que lo pide, con la sesión corriendo. Con
la cámara interrumpida por el fondo (`videoDeviceNotAvailableInBackground`) esa espera no
vuelve; cuando iOS pidió terminar, el principal no estaba para contestar.

**Hecho** (`CaptureEngine`, `CapturePreview`, `AppDelegate`, `SplitBench`; `PreviewAttachGate`,
`BoundedWait` y `LifecycleConstants` en RigMedia).
- **Una sola capa de vista previa** para toda la vida de la sesión. Cada vista nueva se la trae
  (`removeFromSuperlayer` + `addSublayer`: Core Animation, sin tocar la sesión). Montar y
  desmontar la vista ya no rehace el grafo, tampoco en primer plano (antes lo hacía en cada
  vistazo, con la 4K grabando).
- **La sesión se le pone en la cola de captura**, nunca en el principal, y solo cuando la app
  está delante y `session.isInterrupted` es falso (`PreviewAttachGate`). Si no, espera a
  `willEnterForeground` y a `AVCaptureSessionInterruptionEnded` (en ese orden al volver del
  fondo). La vista vuelve a aplicar el giro al recibir `.capturePreviewAttached`.
- `applicationWillTerminate` (no existía): cierra la 4K con el plazo de
  `LifecycleConstants.terminationFlushS` (1 s, `BoundedWait`) y no toca sesión, enlace ni vista
  previa. Al fondo ya la cerraba `interruptionBegan`.
- `app_events` del latido y del informe: «cámara interrumpida: la app pasó a segundo plano»,
  «cámara de vuelta», «vista previa espera: …», «vista previa con sesión».

**La emisión al volver del fondo ya se reanuda sola; no hace falta EMITIR.** Evidencia en
`bench/partido-20261015-1605`: la pasada de 16:05 fue al fondo en 447,1 s y volvió en 450,7 s; el
programa siguió hasta los 489 s (`publishing_s` 488, `connects` 1, `reconnects` 0,
`program_encoder` rehecho 2 veces). La de 16:08, con tres idas de 12-24 s: `reconnects` 1 tras
«SRT no envía (2001): Connection was broken». AVFoundation reanuda la sesión, el motor reabre
la 4K en otro segmento, VideoToolbox se rehace (4fb5bf4) y `ProgramPublisher` reconecta. Lo
que se ve «conectando» es el relé del VPS, que espera al siguiente IDR. Lo que el dueño vio
hoy a las 18:32 era la app muerta, no una emisión parada.

**Comprobado** (en el worktree `../wt-fondo`; el árbol principal y los iPhone sin tocar):
- `swift test --skip ModelBench`: **558 tests, 4 saltados, 0 fallos** (8 nuevos:
  `PreviewAttachGateTests` 5, `BoundedWaitTests` 3). Build en el scratchpad, borrado.
- `tools/check_layers.sh`: limpio.
- El Runner, sin `flutter build`: `swiftc -typecheck` de todos sus `.swift` contra RigCore,
  RigNet y RigMedia emitidos para iOS desde este árbol y los módulos de Flutter y HaishinKit
  del DerivedData: **0 errores y los mismos 34 avisos** que 296f058, texto a texto.

**Para Alexander, en el 17**: abrir la cámara (la vista previa tiene que salir y girar como
siempre), EMITIR, vistazo sobre la tarjeta, PARAR; luego EMITIR y dejar Zero al fondo medio
minuto dos o tres veces: la app sigue viva, el programa vuelve solo y el `program-live-*.json`
trae «cámara interrumpida» / «cámara de vuelta». Si alguna vez la vista previa saliera negra al
volver a la pantalla de captura, mirar en el log `[preview]`: la capa comparte la sesión y la
conexión se rehace con `configure`.

## 2026-10-15 · El foco: enfocar en el centro y congelar, no la posición 1 · 🚧 sin compilar; falta la prueba en el iPhone

**El caso.** El programa de «Una cámara» salía blando aunque entraran 6 Mbit/s. Alexander
grabó la misma habitación con la app Cámara a 0,5× (la misma ultra gran angular) y con Zero
(`WhatsApp Video 2026-10-15 at 7.02.30 PM` y `7.03.21 PM`). Recortada a la zona que enseña
Zero y ampliada 2×, la de la app Cámara sigue más nítida (el zigzag de la almohada, las
flores de la colcha y los bordes de la mesita a 2-3 m), aun pasando por WhatsApp a 1024×576.
No es ni la lente ni la luz: es cómo Zero pone la cámara. Lo único que pone a ciegas es el
foco, bloqueado en `lensPosition` 1.0, y para AVFoundation 1 es «lo más lejos que llega la
lente», no el infinito.

**Después, a petición de Jhonatan: con «Una cámara» el foco es automático continuo, como la
app Cámara** (`CaptureSettings.autoFocus`, que la sesión pide con `singleCamera`): enfoca en el
centro sin restringir distancias, con el enfoque suave del vídeo, y no se congela nunca. La
fila Foco dice «automático, como la cámara del iPhone». Con el soporte de dos sigue lo de
abajo. Sin `flutter analyze` ni tests pasados en este último cambio: se subió para que Alex
compilara.

**Hecho** (el soporte de dos): el foco, como la exposición, se mide y se congela.
- `lockSettings` deja la cámara enfocando sola en el centro (`focusPointOfInterest`), solo en
  lo lejano (`autoFocusRangeRestriction = .far`) y sin el enfoque suave.
- `waitForMetering` espera también a `!isAdjustingFocus`, dentro de los mismos 3 s como mucho.
- `lockFocus` (nuevo) bloquea la lente donde quedó y el log dice `[foco] congelado en la
  posición …`.
- Si la lente no enfoca sola, la reserva es la de siempre: la posición 1 o el foco fijo.

**Tests**: `RunnerTests.testFocusIsMeasuredAtTheCentreAndTheReserveIsTheFarEnd` (el punto y la
reserva). El enfoque en sí pide la cámara. **Sin compilar** (Windows).

**Para Alexander, una prueba**: compilar, instalar y repetir lo mismo que con la app Cámara (la
habitación, «Una cámara», con el móvil quieto y apuntando a algo a 2-4 m al abrir la cámara).
Tiene que verse como la app Cámara. En el log, el número de `[foco]`: si sale muy por debajo
de 1, era eso.

**Riesgo con el soporte de dos**: cada móvil enfoca lo suyo, y el foco cambia un poco la
focal. Si la costura empeora, recalibrar con el foco nuevo.

## 2026-10-15 · La primera emisión al VPS de verdad: el 17 en «Una cámara (sin pareja)» → VPS (167.71.31.225.sslip.io) → YouTube · ✅ mientras Zero estuvo delante

Jonathan desplegó el VPS en el droplet de siempre (subido a 2 vCPU / 2 GB). El 17 con
AUTO_EMITIR (`AUTO_LINK=single`, 600 s) y el destino del QR Soporte del VPS por entorno
(`RIG_SRT_*`, leído del `/pair/qr.svg` sin imprimir nada); las credenciales del `.env` de
Alexander no eran las del despliegue («authentication failed»). Datos en
`bench/partido-20261015-1605`.

- **8,1 min sin un fallo mientras Zero estuvo delante:** 14 553 fotogramas, 29,8 fps, 0
  desgarros, 0 retrocesos, latencia añadida p95 143 ms, la copia .mov con el 100 %, **SRT
  con 1 tramo y 0 reconexiones**, detector 2 422 pasadas, memoria plana, `fair`.
- **En el VPS** (`deploy/vps-estado.sh`): programa h264 1920×1080 + aac publicando, **relé a
  YouTube «emitiendo»**, la grabación en segmentos de 60 s.
- **A los 446 s Zero se fue al fondo** (alguien usó el 17): el programa se para (la cámara
  no corre en segundo plano), el relé cae a «conectando» y al volver VideoToolbox se rehace
  (`program_encoder` 2) y el modo automático arranca otra emisión (1,5 min, con dos idas al
  fondo más: 16,8 fps de media). En la cancha: **no salir de Zero en el móvil que emite**.

## 2026-10-15 · IOS-81 (arreglo) — el maestro arranca en una lente mientras no oye al esclavo · 🚧 sin compilar; falta la pasada con los dos iPhone

Del modo de un móvil que escribió Jhonatan antes de ver a79d736 (rama local
`respaldo/ios-98-99-jhonatan`), lo único que «Una cámara» no cubre: con el **soporte de dos**,
si el esclavo no ha llegado al pulsar EMITIR, el maestro encuadraba la mitad negra hasta oírlo
caer. `PeerHealth` arranca en `down` y solo avisa de los cambios, así que sin esclavo no
llegaba ningún aviso y `peerDown` se quedaba en falso (se vio el 2026-10-10 mientras tardaba el
canal de medios). Jhonatan pidió conservar lo de Alexander y rescatar esto.

**Hecho**: `SplitBench.start` toma el estado inicial del latido en su cola, antes del primer tic;
`setUpIfNeeded` aplica la lente al montar. Con el esclavo arriba al EMITIR no cambia nada; al
llegar después, `onPeerState(.up)` devuelve las dos lentes, como ya hacía IOS-81. Con «Una
cámara» tampoco cambia: ya iba en una lente.

**Tests**: `PeerHealthTests.testArrancaCaidoYSinNadieNoAvisa` fija lo que el arreglo da por
hecho. **Sin compilar** (Windows). Para Alexander: `swift test` y, con los dos iPhone, EMITIR en
el 17 con el 16 Pro aún sin enlazar. El programa sale de una lente sin negro y pasa a dos cuando
enlaza.

## 2026-10-15 · IOS-99 — «Una cámara» a 720p o 1080p · 🚧 en código, con los tests de Dart; falta compilar en el Mac y la pasada en el iPhone

Lo pidió Jhonatan: con un solo móvil, elegir entre 720p y 1080p (ADR 0025 de football-ai,
aceptado hoy). Va encima de «Una cámara (sin pareja)» de a79d736, la entrada de abajo.
Jhonatan escribió antes en Windows un modo de un móvil propio (IOS-98); al ver a79d736 se
quedó en la rama local `respaldo/ios-98-99-jhonatan`, sin subir, y esto se rehízo sobre el
de Alexander.

**Hecho**
- En «Enlace y emisión», con **«Una cámara (sin pareja)»** elegida, dos píldoras más:
  **1080p** (de partida) y **720p**. La nota dice lo que pide de subida cada una. Se guarda
  en `zero.singleResolution`, como el enlace. Con los otros enlaces no se ve: el soporte de dos
  va siempre a 1080p.
- Pigeon `RigHostApi.startProgram(ProgramResolution)`. La sesión manda la elegida con «Una
  cámara» y 1080p en otro caso; la tarjeta Programa dice «Resolución · 720p».
- `ProgramOutput` en RigCore (nuevo): 1920×1080 con techo de 6 Mbit/s y 1280×720 con 3, copia
  de `PROGRAM_OUTPUTS` de `tools/program_contract.py` de football-ai.
  `ProgramRunConfig.output`, y `.single(detectorPackage:output:)`. `production` sigue en 1080p.
- `SplitBench`: la composición sigue a 1080p (gráfico, franja, director y miniaturas no
  cambian). El codificador del programa se crea al tamaño de la salida y escala él mismo (el
  `VTPixelTransferSession` interno de `VTCompressionSession`). El publicador y la escalera
  (L3 ×0,6) usan el techo de la salida. El informe trae `program_output`.

**Comprobado aquí (Windows)**
- `flutter analyze` sin avisos. `flutter test`: 441 pasan; fallan los 7 dorados de imagen del
  gráfico, por la plataforma (también en 6bdfafd en esta máquina). «Se pinta en ≤50 ms» falla
  a veces. Nuevos: 2 en `capture_session_test` (la resolución que llega al nativo, y 1080p
  con el soporte) y 2 en `role_page_test` (las píldoras solo con «Una cámara», 720p que se
  guarda y se recuerda).
- **El Swift no se ha compilado.** Tests nuevos para el Mac en `ProgramRunTests`: el soporte
  siempre a 1080p, salidas 16:9 que no amplían la composición, y el techo de 720p con la
  densidad por píxel del de 1080p.

**Lo que solo dirá el iPhone**: que `VTCompressionSession` a 1280×720 acepta el fotograma de
1920×1080 y lo escala. Si no (fallos al codificar, `program_encode_failures` en el informe), el
plan B del ADR es un `VTPixelTransferSession` explícito hacia el pool del codificador, como
`Thumbnailer`.

**Para Alexander, en la pasada de «Una cámara»**: `swift test` y el build. Luego, con 720p
elegido, EMITIR al VPS. En football-ai, `./deploy/vps-estado.sh` tiene que decir
`programa publicando: h264|1280|720|30/1`, y la tarjeta del móvil ≤3 Mbit/s.

## 2026-10-15 · «Una cámara (sin pareja)»: EMITIR con un solo móvil, sin enlace · 🚧 en código y tests; sin probar en el iPhone

Lo pidió Alexander para la cancha de mañana: poder transmitir solo con el lado izquierdo, sin
parear, con todo lo que tiene la app, y sin dañar lo que ya vale. a79d736 (la app) y c914802
(los guiones).

**Qué es.** Una opción nueva y explícita en «Enlace y emisión» de la pantalla de lado: la
píldora ancha **«Una cámara (sin pareja)»**, debajo de Pod/Wi-Fi/Aware/Cable (`LinkMode.single`,
se guarda en `zero.linkMode` como las demás). Sin elegirla, nada cambia. Vale en los dos lados.
- **«Abrir cámara»** no abre ningún enlace (ni Bonjour, ni Aware, ni el secreto): `RigSoloLink`
  lleva una `RigLinkSession` sola (`RigLinkSession.alone` + `startAlone`, sobre
  `NoLinkTransport`) que dirige desde el primer instante, con el reloj de host como reloj del
  soporte (la 4K, de referencia, no espera reloj). **LISTA** en cuanto la cámara está bien:
  sin enlace, sin reloj del otro ni fase. La pantalla: Enlace «Una cámara · sin pareja: una
  cámara», Reloj «propio: una cámara, sin pareja», Modo «una cámara · sin pareja».
- **EMITIR** arranca la misma pasada de producción (`ProgramRunConfig.single`): director con su
  IA, detector CenterNet, gráfico y franja con anuncios, la copia `program-*.mov`, el latido y
  el informe, la escalera térmica y el SRT al VPS si hay QR Soporte (si no, SIN DESTINO).
  «Guardar vídeo» graba la 4K propia como hoy. Programa 1080p de la captura 4K, como siempre.
  Sin parte (ni su codificador ni su render), sin órdenes, sin vistas, sin pizarra al otro.
- **El director, dentro de su lente**: `DirectorLoop.singleCamera` construye el lienzo con
  `CylindricalCanvas.fit(…, sides: [lado])` (la geometría de `rig.json` de ese lado, o la
  nominal) y `singleLens`: las vistas piden solo ese lado, así que no hay retrocesos que
  contar; el maestro no espera ninguna parte (`peerDown`). `DirectorService(soloSide:)` mete
  cada ciclo de detección al llegar: con un solo lado, el emparejador lo retenía 3 ciclos.
  Medido en un test con el soporte del pod y el nominal: el plano más abierto, centrado en su
  lente, tiene 57,6° de ancho (lo limita la franja de pitch del campo, como con dos) y **0 %
  de píxeles fuera de la imagen**.
- El informe y el latido llevan `single_camera: true`; `tools/cancha.py` dice «EMITIR con una
  cámara (sin pareja)» y «✅ una cámara (sin pareja): N fotogramas de su lente; sin esclavo ni
  parte, a propósito», y no cuenta la falta de esclavo.
- **AUTO_EMITIR** acepta `AUTO_LINK=single` (con `AUTO_ROLE=left|right`): emite en cuanto está
  LISTA, sin los 20 s del esclavo. **`tools/emitir_auto.sh <secreto> <s> --link single [--lado
  left|right]`** compila, instala, lanza y recoge solo ese móvil (IZQ o DER), sin exigir ni
  tocar el otro.
- **No cambia**: el banco split (su entorno sigue mandando en `LinkChoice.resolve`), EMITIR con
  dos, AUTO_EMITIR con aware/wifi, el plan B, Multipeer y «Un solo móvil, sin reloj»
  (`standalone`, GRABAR). Lo demuestran los tests de siempre en verde y los nuevos.

**Comprobado** (worktree aparte; el árbol principal y los iPhone, sin tocar)
- `swift test --skip ModelBench`: **546, 4 saltados, 0 fallos** (539 antes; nuevos:
  `SoloLinkTests` 3, `ProgramRunTests` 2, `DirectorLoopTests` 1 —los dos lados, la vista nunca
  sale de su lente aunque el grupo esté al otro lado— y `DirectorServiceTests` 1).
- `tools/check_layers.sh`: limpio.
- El Runner con `swiftc -typecheck` contra los módulos de ZeroKit emitidos para iOS desde este
  árbol: **0 errores y los mismos 34 avisos** que el de 6bdfafd con el mismo método,
  comparados uno a uno (sin xcodebuild: el Mac tenía 2,7 GB libres).
- `flutter test --no-pub`: **444, todos bien** (435 antes; nuevos: 4 en `capture_session_test`,
  1 en `widget_test`, 2 en `role_page_test`, 2 en `auto_emitir_test`). Un arreglo de prueba:
  el ayudante `emparejar` de `role_page_test` tocaba antes de pintar tras `ensureVisible` (con la
  fila nueva, el botón queda bajo el pliegue). `flutter analyze --no-pub`: sin avisos.
- `bash tools/test_guiones_cancha.sh`: **178 bien** (18 nuevos de `--link single`, el izquierdo
  solo con el 16 Pro desconectado y el derecho con `--lado right`).
  `python3 tools/test_cancha.py`: **26 OK**.

**NO probado en el iPhone.** Nada de esto ha corrido en un móvil: ni la pantalla, ni la pasada
sola, ni el director con una lente en vivo, ni el SRT con una cámara.

**Para probarlo con un solo iPhone por cable** (el 17; ~5 min de EMITIR, sin nadie delante):

    cd /Users/alexander/Trabajacion/fooball_ai_capturer && git pull --ff-only
    tools/emitir_auto.sh ~/.config/football-ai/secreto-soporte 300 --link single
    # con el 16 Pro en su lugar:  … --link single --lado right
    # otro iPhone como izquierdo: IZQ=<id de devicectl> tools/emitir_auto.sh … --link single

En el veredicto: «MAESTRO · izquierdo … · EMITIR con una cámara (sin pareja)», «✅ una cámara
(sin pareja): N fotogramas de su lente», programa ~30 fps, copia .mov ≈ 100 %, «SRT: sin
destino» sin QR Soporte, detector con pasadas, ningún «retrocesos» > 0 y «VEREDICTO: ✅». En el
registro, «LISTA (una cámara, sin pareja): EMITIR» a los pocos segundos. Mirar la copia .mov a
ojo: el director se mueve dentro de la lente, sin bandas negras. Después, para la pantalla de
lado de la cancha, `tools/plan_b_cancha.sh preparar` (las tres apps con esto; pide ~5 GB libres
en el Mac) y `volver`: la `emitir.app` de `build/cancha` es de 526a348 y **no trae este modo**.

**Decidido aquí, pendiente de revisión de Alexander**
- **Es un modo degradado explícito, no un cambio de arquitectura.** Los ADR 0019 y 0023
  describen dos móviles; «Una cámara» reutiliza la pasada del maestro sin enlace y no cambia el
  protocolo, el reloj ni los roles del soporte de dos. Si se queda, se anota en el ADR 0019.
- **El lado dice cómo va montado el móvil**: IZQUIERDA es girado 180° (como en el soporte),
  DERECHA derecho (`mountedUpsideDown = side == .left`, de siempre). El 17 solo, en su sitio del
  soporte, es IZQUIERDA; un móvil derecho en otro trípode tendría que elegir DERECHA (y la
  geometría de `rig.json` de ese lado). No se ha añadido una opción de orientación.
- **El plano más abierto es el mismo que con dos** (57,6°, lo limita la franja de pitch del
  campo `directorPitchLimitsRad`, ahora constante con unidades): no se ha abierto el pitch para
  enseñar la lente entera, que metería cielo y suelo cercano.
- El secreto del soporte sigue en el lanzamiento de `emitir_auto.sh` (lo guarda en el Keychain
  aunque «Una cámara» no lo use) para que la firma del guion no cambie.

**Visto y no tocado (EMITIR con dos)**: el maestro que arranca sin haber visto nunca al esclavo
no pasa a una lente: `PeerHealth` empieza en `down` y solo avisa de los cambios, así que
`peerDown` sigue en false, el director encuadra las dos lentes y lo que cae en la otra sale en
negro y cuenta como retroceso. Es lo que pasaba con «el 17 emite con una lente» de la guía; con
«Una cámara» ya no. Arreglarlo en el modo de dos es otra tarea.

**La guía** (`docs/GUIA-CANCHA.md`, «Si algo falla»): si no hay forma de enlazar, en el 17
«Una cámara (sin pareja)», «Abrir cámara» y EMITIR; «Un solo móvil, sin reloj» + GRABAR queda
como último recurso para la 4K del 16 Pro. En la tabla de lo probado, «Una cámara» sin probar.

**Siguiente**: el comando de arriba con el 17 por cable; con su veredicto en verde, `preparar`
y `volver` para la cancha.

## 2026-10-15 · Mediodía con los dos iPhone: calibrar en la cancha, EMITIR con 4K y el Aware que no enlazaba tras cerrar Zero · 🚧 falta el dedo en EMITIR

Los dos en el soporte de mesa, por Wi-Fi Aware, todo lanzado desde el Mac (Alexander no
llegó a hacer la prueba con el dedo: `tools/sesion_emitir.sh` esperó de 11:05 a 11:32).

**`tools/calibrar_cancha.sh --solo-comprobar` (44986ad), en los iPhone:** fotos de los dos
en ~1-1,5 min, «❌ NO CALIBRA» con el motivo de cada pareja (en el cuarto, como debe), no toca
los `rig.json` y deja otra vez la app de EMITIR. Dos veces (11:33 y 12:11).

**`tools/limpiar_moviles.sh` (bf66979), solo listar:** Zero ocupa 68,3 GB en el 17 (bench
40,9; bench4k 18,4; nv12 6,4) y 20,9 GB en el 16 Pro (bench4k 19,0). `--borrar-pruebas`
espera el sí de Alexander.

**EMITIR automático con «Guardar vídeo» (f2f2c21), 10 min** (`bench/emitir-auto-20261015-1157`):
enlazó a los ~10 s, **dos lentes 98 %**, 17 975 fotogramas, la copia .mov entera,
latencia p95 145 ms, memoria plana. 198 desgarros (el cruce de fase del ADR 0024). La 4K
del 17 se grabó (−4 GB); **la del 16 Pro no** (10,5 GB libres: la reserva no la deja
arrancar). El 16 Pro, a batería, llegó al 20 %.

**El Aware que no enlaza.** 11:36: EMITIR automático lanzado ~1,5 min después de que
`calibrar_cancha.sh` matara Zero con el enlace vivo → **5 min los dos en «searching»**, sin
EMITIR (`bench/emitir-auto-20261015-1135`). Cerrando Zero y esperando 1 min, a la siguiente
enlazó en <1 min. Arreglo, 546917d (el que publica rehace su cita a los 30 s si no llega
nadie) y 526a348 (`link-diag-*.json` desde el arranque y la frase en la fila Enlace).
**Repetido el mismo escenario con el arreglo** (`bench/emitir-auto-20261015-1213`):
**enlazó a los 90 s** (una primera conexión cancelada, «Operation canceled», y se rehízo
sola), 3 min de EMITIR sin problemas, «✅ enlace del izquierdo/derecho: enlazó a los 90 s,
1 caídas». Una sola vez: no basta para decir que no vuelve a pasar.

**En los dos queda la app de EMITIR de 526a348** (`tools/plan_b_cancha.sh volver`), con
«Guardar vídeo» arreglado y el diagnóstico del enlace. `docs/GUIA-CANCHA.md`, al día.

## 2026-10-15 · Wi-Fi Aware que no enlaza: el que publica rehace su cita y el enlace dice por qué desde el arranque · 🚧 en código y tests; falta con los dos iPhone

**El caso.** EMITIR automático de las 11:36 (`bench/emitir-auto-20261015-1135`), lanzado ~1,5 min
después de que `calibrar_cancha.sh` matara Zero en los dos con el enlace Aware vivo: 5 min los dos
en «enlace searching» y nada más, porque el diagnóstico de f0df022 solo va en el latido de una
pasada del programa y EMITIR no llegó a arrancar.

**Lo que dice el código** (NWLinkTransport). El que busca rehace su suscripción a los 20 s
(4ca370b); el que publica no tenía nada simétrico: su listener de control o de medios en
`.waiting` («Network is down», «Device not configured») solo se apuntaba y no fallaba ni caducaba,
y uno publicado al que nadie llega solo se cambiaba al caducar (`publisherTimeout`, ~2 min). Los
enlaces de 124 s (AUTO_EMITIR de las 09:04) cuadran con esa caducidad. Además, un listener de
medios que no se podía crear no se reintentaba nunca. Lo que no se puede saber sin los iPhone: si
lo que queda colgado tras matar la app con el enlace vivo es el datapath del sistema (no hay API
para verlo); con 90 s entre matar y lanzar, una pausa corta en los guiones no lo habría evitado,
así que no se añade.

**Lo hecho.**
- El vigía de la publicación (`LinkRendezvous.republishAfterS`, 30 s por Wi-Fi Aware, nil por
  Bonjour): sin enlace, la cita de control o de medios a la que no llega nadie en 30 s desde que se
  abrió o desde la última caída se cambia por otra, esté publicada o en espera.
  `stats.republishes`, el suceso «control: no ha llegado nadie a la cita en 30 s (en espera: …):
  otra» y el diagnóstico lo cuenta («publicando; no ha llegado nadie en 300 s (10 citas, 9
  rehechas)»). El listener de medios que no se crea se reintenta a los 2 s.
- `RigNet/LinkDiagnosisRecorder`: desde que se abre el enlace (RigLinkNW.start, en EMITIR, en
  AUTO_EMITIR y en los bancos), `Documents/bench/link-diag-<lado>-<t>.json` cada 10 s sin sesión,
  una vez al enlazar (con `linked_after_s`) y otra vez tras una caída: la frase, el diagnóstico,
  los sucesos del transporte y los contadores. La frase va también a la fila Enlace mientras busca
  («esperando al móvil derecho… · publicando; no ha llegado nadie en 40 s (2 citas, 1 rehechas)»)
  y, por la misma vía, a `auto-emitir-*.log`.
- `tools/cancha.py`: `informes` recoge `link-diag-*` (lo traen `emitir_auto.sh`,
  `sesion_emitir.sh` y `recoger_partido.sh` sin tocarlos) y el veredicto dice de cada lado
  «enlazó a los N s» o «sin enlace a los N s: <frase>» con los últimos sucesos, aunque no haya
  informe de la pasada.

**Tests.** `PublicationWatchdogTests` (5), `LinkDiagnosisRecorderTests` (2), las frases de
`LinkDiagnosisTests`; `swift test --skip ModelBench`: 539, 4 saltados, 0 fallos. `check_layers`
limpio. ZeroKit para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED; el Runner con
`swiftc -typecheck` contra él: 0 errores, ningún aviso en lo nuevo. `test_cancha.py` 25 OK,
`test_guiones_cancha.sh` 160 bien. `flutter analyze` sin nada; `flutter test` en verde.

**Queda fuera.** Que `calibrar_cancha.sh` cierre el enlace antes de matar Zero (haría falta que el
banco suelte el enlace tras el disparo); se decide con el primer `link-diag` de un fallo.

**Para probarlo con los dos iPhone.** Compilar las apps de la cancha con este commit, luego
`tools/calibrar_cancha.sh <secreto>` y en seguida `tools/emitir_auto.sh …` (lo que falló hoy). Si
enlaza, el veredicto dice «enlace del izquierdo: enlazó a los N s». Si no, dice la frase de cada
lado y los sucesos: buscar «no ha llegado nadie a la cita» en el izquierdo (el vigía actuó) y
«suscripción … no ha dado con nadie» o «ve al otro pero no conecta» en el derecho.

---

## 2026-10-15 · Calibrar en la cancha en una orden y limpiar los iPhone · 🚧 probado con el devicectl falso y con fotos reales; falta con los dos iPhone

**`tools/calibrar_cancha.sh <secreto> [--solo-comprobar] [--sin-instalar]`** (44986ad). EMITIR
cose con `Documents/rig.json`, hoy el del trípode de casa, y no toma fotos de calibración. El
guion instala las apps de banco de `build/cancha`, lanza un split corto por Aware con
`RIG_CALIB_AT_S=10` (sin .ts ni .mov), espera a que los dos tengan `calib/<id>/summary-<lado>.json`,
cierra Zero, trae el disparo a `bench/calib-cancha-<fecha>/`, vuelve a dejar `emitir.app` y
calibra con `calibrate_bench_pairs.py --json` de football-ai (b7afc14; los umbrales del repo, sin
red). Si calibra: puntos, residuo, ángulos y la comparación con el rig.json que tenía cada móvil
(bajado antes como copia; «se parece» por debajo de 0,3°); lo instala con `devicectl copy to` y lo
baja para comprobarlo. Si no calibra, no toca nada y dice por qué y qué hacer.
- Con el devicectl falso y la calibración real: las fotos del trípode (`…-20261011-1321`) dan el
  rig.json de casa idéntico e instalado en los dos; las del cuarto (`…-20261015-1047`), «NO CALIBRA»
  con las cinco razones y los móviles sin tocar.
- `devicectl device copy to` a `Documents/rig.json` no se ha usado en este repo con un fichero (sí
  con una carpeta, en `spk53_bench.sh`): el guion lo baja otra vez y lo compara.

**`tools/limpiar_moviles.sh [--borrar-pruebas]`**. Lo que ocupa Zero por carpeta (el 17, hoy: 68
GB, 66 en `bench/`, `bench4k/` y `nv12/`). `devicectl` no sabe borrar ficheros de un contenedor
(solo listar, copiar e instalar o desinstalar la app entera), así que borra la app: con
`RIG_PURGE_BENCH=1`, al arrancar, `BenchPurge` (RigMedia) borra de esas tres carpetas lo de antes
de hoy y deja `bench/purge-<t>.json`; nunca `rig.json`, `bench-resources/`, `calib/` ni las copias
`program-*.mov`. Solo funciona con una app compilada desde este commit (las de `build/cancha` son
de 3ccd75e): con una anterior, el guion dice que no borró nada.

Pruebas: `tools/test_guiones_cancha.sh` 160 ✅ (79 nuevas), `tools/test_calib_cancha.py` 14,
`tools/test_cancha.py` 23, `swift test` de ZeroKit 533 (4 de BenchPurge; 5 saltados) y
`check_layers.sh` ✅. El AppDelegate no se compiló
entero (5,7 GB libres en el Mac): sus líneas nuevas, comprobadas con `swiftc -typecheck` contra
RigMedia.

Siguiente: con los dos iPhone, `tools/calibrar_cancha.sh <secreto> --solo-comprobar` en casa
(no calibra en un cuarto: tiene que decirlo y no tocar nada) y, en la cancha, sin la opción.

## 2026-10-15 · El plan B enlaza (4ca370b, 8ab8f86, f0df022), la escalera forzada responde y el spike de la duración de fotograma, medido · ✅ plan B · 🚧 el spike, con dos cosas que mirar

Los dos iPhone en el soporte de mesa, por Wi-Fi Aware, lanzado desde el Mac.

**1. El plan B otra vez, con el arreglo del enlace** (`tools/plan_b_cancha.sh preparar` y
`lanzar <secreto> 600`, sin 4K; `bench/partido-20261015-1022`). Justo después de la hora
de EMITIR, como la vez que falló.
- **Los dos enlazados** («enlace: arriba (aware)» en el veredicto de los dos), **dos lentes
  en el 75 %** (13 527 de 17 975), 0 desgarros, latencia p95 144 ms, `part_age` p50 75 /
  p95 80, partes 13 772 y 1 perdida.
- **El esclavo deja su informe final** (8ab8f86): 13 811 partes enviadas.
- La copia .mov del maestro con el 100 % del programa. Memoria plana en los dos. El 16 Pro,
  a batería: −33 %/h (55 → 50 %).

**2. La escalera forzada, con la tabla de 2358dcb** (L2 en el esclavo de 120 a 300 s;
`bench/dos-moviles-20261015-1035`).
- El esclavo pasa a L2 a los 121 s y **la detección para en los dos**
  (`detect_runs_by_minute`: 297, 300, 3, 0, 0, 0, 298… en el esclavo; 296, 300, 79, 0, 0,
  0, 287… en el maestro). El maestro lo recoge a los 136 s (15 s de retraso: el nivel del
  otro llega con el latido).
- Al acabar el forzado (300 s) el esclavo se queda en L2 los 60 s de la histéresis y a los
  360 s vuelven los dos a L1 (5 Hz). 93 órdenes de cadencia enviadas y recibidas.
- **El programa sigue:** 17 977 fotogramas, dos lentes 13 508, 2 desgarros, p95 144 ms.
- A mirar: `director_pairing` 1 185 completos de 1 862 ciclos (677 huérfanos del maestro),
  frente al 99,8 % de la hora de EMITIR. Parte son los 15 s de retraso; el resto, sin
  explicar.

**3. El spike de la duración de fotograma (f4ce90d, f5e0671)**, ADR 0024: el derecho a
33 367 µs durante 20 s de cada 120, 10 min, spk04 sin director, con su 4K
(`bench/dos-moviles-20261015-1023`).
- **La cámara da lo pedido:** `readback_min`/`max` 33367/1000000, formato el mismo
  (`1/30..1/1`), 0 rechazos. Medido entre PTS (en el reloj del host), el periodo pasa de
  **33 316,8 µs a 33 364,2 µs**: +47,4 µs por fotograma (+0,142 %, 1,4 veces lo pedido
  sobre el nominal: el nominal del sensor no es 33 333,3 en ese reloj).
- **Lo aplica en 4 fotogramas** (~110-120 ms) al alargar y al volver; `apply_ms` 2-5 ms.
- **No pierde nada:** `did_drop` 0, `camera_drops` 0; la exposición (9,984 ms) y el ISO
  (55,3), iguales 3 s después de cada cambio.
- **La fase se mueve lo que dice el periodo:** cada ventana de 20 s la baja **−27,5 ms**
  (se ve +5,8 porque la fase se envuelve a ±½ fotograma), igual en las tres ventanas
  medidas (600 fotogramas × 47,4 µs = 28,4 ms). La predicción del ADR (−20 ± 2) suponía el
  nominal exacto; el lazo tiene que usar la ganancia medida.
- **Dos cosas que mirar:**
  - **la parte se retrasa con el spike:** `part_age` p50 120 / p95 200 y `parts_jitter_ms`
    30,6, frente a 85/90 y 1,4 sin spike en la misma configuración (la pasada de las 08:06).
    La latencia añadida no se movió (p95 144);
  - **la 4K del esclavo**, en 2 segmentos (`clock_jump_segments` 1, 1 201 fotogramas
    esperando el reloj al arrancar): parece el arranque lento del enlace, no el spike, pero
    no está separado.
- 200 desgarros: las ventanas empujaron la fase a través de ±½ fotograma, como se esperaba.

**4. El spike en los dos lados** (`RIG_SPIKE_FRAME_SIDE=alternate`, sin 4K;
`bench/dos-moviles-20261015-1047`): **el iPhone 17 responde igual que el 16 Pro**
(33367/1000000 leído, 4 fotogramas, 0 pérdidas, exposición e ISO iguales). Cada ventana
mueve la fase ~28 ms: hacia abajo si se alarga el derecho y hacia arriba si se alarga el
izquierdo. **Aquí la parte, normal:** `part_age` 85/90 y `parts_jitter_ms` 1,3. El retraso de
la pasada anterior iba con la 4K del esclavo: falta separarlo (4K sin spike frente a 4K con
spike). Resultados en el ADR 0024 (football-ai, 9248c9c).

## 2026-10-15 · EMITIR de producción, 60 min por Wi-Fi Aware y sin destino, en los dos iPhone (AUTO_EMITIR): ✅ programa completo y estable · 🚧 falta el dedo en el botón y una escena con dos lentes

`tools/emitir_auto.sh <secreto> 3600 --link aware` (2358dcb: con la escalera actuando y la
tabla nueva). Datos en `bench/emitir-auto-20261015-0903`. Es el camino de la cancha (Zero
de producción, `purpose: production`, sin QR Soporte → `publish_source: none`), sin la
pantalla de lado ni el toque: lo hace AUTO_EMITIR.

**Lo que salió**
- **LISTA a los 124,6 s** de lanzar (el enlace por Aware tarda), EMITIR a los 144,6 y PARAR a
  los 3600 s de emitir. El esclavo arrancó y paró por la orden del maestro.
- **La copia del programa:** `program-m_f50b97dd8d1a-1792076844.mov`, **1:00:00, 2,1 GB,
  h264 1920×1080 a 30 fps y aac**; 107 830 fotogramas, el 100 % del programa. ffprobe la lee
  entera.
- Programa: `program_fps_p5` 29,2, **0 desgarros**, latencia añadida p95 **142-144 ms en
  cada uno de los 60 minutos** (el tic de fcbafad, sin deriva en una hora),
  `tick_phase_ms` p99 4,5.
- **La escalera:** el maestro estuvo en `serious` los 60 min (llevaba desde las 08:06 sin
  parar) y fue a L1. `detect_runs_by_minute` 300 en cada minuto (5 Hz) en los dos: la
  cadencia común viaja. **`director_pairing`: 17 955 de 17 997 ciclos con la pareja
  completa (99,8 %)**, `max_abs_skew_ms` 0. Antes de 91dd7bb, casi ninguno (ver la
  entrada de la escalera).
- Memoria plana: el maestro 414 → 480 MB (+4 desde el minuto 3); el esclavo 380 → 446 (+0).
- Batería: el maestro cargando, 80 %; **el esclavo, a batería, −20 %/h** (75 → 55 %: le
  quedarían ~165 min).

**Lo que hay que mirar**
- **El director no salió de la lente del 17:** 85 fotogramas de dos lentes de 107 830
  (`slave_no_parts` 107 954). En los fotogramas de los minutos 5, 30 y 58 el plano es el
  mismo, cerrado sobre el lado izquierdo del cuarto (el ventilador y una camiseta colgada:
  probablemente falsos positivos del CenterNet). Con jugadores de verdad no se sabe; la
  cosedura con dos lentes en EMITIR queda por ver en la cancha o con `RIG_SPLIT_SCRIPT`.
- `program_skipped_instants` 168 en 60 min (~3 por minuto; 74 en los 30 min de la mañana; 0
  en los 8 min de ayer): con el maestro en `serious`. A vigilar.
- 3 instantes sin fotograma propio («SIN SEÑAL»).

**Lo que no cubre:** la pantalla de lado, el toque en EMITIR y PARAR, el QR Soporte y el
segundo plano/llamada (los pasos 7a-c de `sesion_emitir.sh`): eso, con Alexander delante.

## 2026-10-15 · El plan B que no enlazó: la suscripción de Aware que no se rehacía, el esclavo sin informe y el latido mudo (IOS-14c) · 🚧 falta repetir el plan B en los iPhone

`bench/partido-20261015-0902` (apps de `build/cancha`, 6a7a052, el código de las pasadas de
08:06 y 08:39).

**Lo que dicen los datos.**
- El maestro publicó a los 0 s y, tras «Device not configured» a los 62 s, otra vez a los 65 y
  70 s, y cada ~120 s (`publisherTimeout`). No le llegó ni una conexión de control: el esclavo
  no lo vio o no montó el datapath.
- El esclavo llegó a su final: cerró la 4K a las 09:01 (600 s) y su audio siguió hasta la
  recogida (09:02:19; `last_rig_ms` 61 400 559 es su reloj de host, sin el desfase del
  maestro). Qué la cerró entre eso y las 09:03 no queda dicho (sin crash ni jetsam).
- Firma, entitlement de Wi-Fi Aware y perfil de `build/cancha/auto-*.app` correctos
  (`codesign --verify`, el mismo perfil y los dos iPhone en él). Entorno, orden y los 10 s
  entre los dos, iguales que en el banco.
- Lo que sí cambia: con APPS no se compila, así que la app nueva arranca **~10-20 s después de
  matar la anterior**, que tenía un datapath Aware vivo con el otro (la pasada de 08:39); en el
  banco normal pasa más de un minuto. La de 08:39, ~30-50 s después de matar la de 08:06,
  tardó 36 s en enlazar con tres intentos fallidos. Es la hipótesis; la línea de tiempo del
  esclavo no se guardó (abajo).

**Lo arreglado**
1. **4ca370b** `fix(ios)`: **la suscripción de Wi-Fi Aware que no da con nadie se rehace.**
   Solo se cambiaba al fallar un intento o al caducar. «Network is down» y «Device not
   configured» llegan como `.waiting`, que solo se apuntaba, y una suscripción en espera o sin
   anuncios no falla ni tiene por qué caducar. Ahora el que busca, sin enlace ni intento en
   marcha, cambia la de control a los 20 s (`WiFiAwareTimings.resubscribeAfterS`), y la de
   medios si no ve ningún anuncio. Bonjour no cambia. La línea de tiempo dice también cuándo la
   suscripción está lista.
2. **8ab8f86** `fix(ios)`: **el informe final se escribe siempre.** `SplitBench.finish` salía
   con `guard session.isMaster || slave != nil`, y el esclavo sin enlace no monta su parte. Por
   eso no había `program-split-right` y el latido seguía en `finished: false`.
   `RigMedia/Obs/ProgramRunFiles.writeFinal` escribe los dos.
3. **f0df022** `feat(ios)`: **el latido (cada 30 s) y el informe dicen por qué no hay
   enlace.** `link` trae la frase («no ve al otro en 600 s (31 citas, 30 rehechas)», «ve al otro
   pero no conecta: 3 intentos; el último: sin respuesta en 10 s», «publicando; no ha llegado
   nadie…», «control arriba, la sesión no: rechazada: …») y sus cifras. El latido lleva además
   `transport_events`. `tools/cancha.py` lo enseña en el veredicto.

**Comprobado.** `swift test --skip ModelBench`: 528, 4 saltados, 0 fallos (sin el vigía, el
test nuevo de la suscripción falla). `tools/check_layers.sh` limpio. `bash
tools/test_guiones_cancha.sh`: 81 bien. `python3 tools/test_cancha.py`: 19 OK. ZeroKit para
iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED. El Runner, con `swiftc -typecheck`
contra ese ZeroKit: 0 errores, los 32 avisos de siempre.

**Siguiente, en los iPhone** (cuando acabe el EMITIR de 60 min):
1. `tools/plan_b_cancha.sh preparar`: `build/cancha` sigue con 6a7a052, sin esto.
2. El plan B como hoy, justo después de otra pasada enlazada:
   `tools/plan_b_cancha.sh lanzar <secreto> 600`.
3. Recoger con `tools/recoger_partido.sh --desde <lo que diga lanzado.txt>`.
   - Si enlaza tarde: el `link` del esclavo y sus `transport_events` (las suscripciones
     rehechas y si estaban listas).
   - Si no enlaza: ahora hay informe y frase en los dos.
   - Ya no debe salir «SOLO EL LATIDO» en el esclavo.

## 2026-10-15 · Con los dos iPhone, sin nadie delante: la fase medida otra vez, la escalera actuando y el plan B · 🚧 el plan B no enlazó; EMITIR automático en marcha

Los dos en el soporte de mesa (17 izquierdo/maestro por cable, 16 Pro derecho/esclavo por la
red y sin cargador), sin bloqueo automático y en «No molestar». Todo lanzado desde el Mac.

**1. La fase entre las cámaras, 30 min por Wi-Fi Aware con `RIG_SPLIT_SCRIPT=spk04`**
(`bench/dos-moviles-20261015-0805`, 6a7a052).
- `halves_phase_drift_ms_per_min` **0,859** (ayer, 0,8): el 16 Pro va ~14 ppm más rápido.
  Arrancó en +9 ms (no ≤5 como quiere el ADR 0012), +16 en los minutos 7-8, **−16 en el 9**
  y vuelta a +1 en el 29. `halves_skew_ms` p50 12 / p95 16 / p99 22.
- **`torn_frames` 294, todos en los minutos 8 y 9** (el cruce); 0 el resto.
- 53 925 fotogramas (twoLens 36 274), latencia añadida p95 144 ms, `part_age` p95 90,
  partes 36 735 y 86 perdidas, `tick_phase_ms` p99 4. `program_skipped_instants` 74 (ayer,
  en 8 min, 0): a vigilar.
- Memoria plana (~495 MB el maestro, ~447 el esclavo). Térmica: `fair` desde el minuto 11
  (maestro) y 17 (esclavo).
- Con esto el ADR 0024 (football-ai, cd25549) tiene su dato; falta el spike de la duración de
  fotograma (f4ce90d, f5e0671) en los iPhone.

**2. La escalera actuando (91dd7bb, ceee4d3), 10 min con L2 forzado en el esclavo**
(`bench/dos-moviles-20261015-0837`).
- **Con la tabla provisional, la IA se apagó en los dos desde el segundo 0**: el esclavo,
  `fair` y sin cargador, fue a L2 por sí solo (`fair` → L1, más uno sin carga), y manda la
  peor de las dos. `detect_runs_by_minute` del maestro: 195 en el minuto 0 y 0 después;
  `cadence_commands_sent` 111 / `received` 111: la orden de cadencia viaja. El programa
  siguió: 17 973 fotogramas, twoLens 16 457, 0 desgarros, latencia p95 144 ms.
- **Arreglo, 2358dcb (pendiente de la revisión de Alexander):** `fair` → L0, `serious` →
  L1 (IA a 5 Hz), `critical` → L3, `shutdown` → L4; sin carga, un escalón más. El ensayo de
  90 min aguantó 71 min en `serious` con la IA a 7,5 Hz sin llegar a `critical`.
- El forzado a L2 de 120 a 300 s no se vio, porque ya estaba en L2. Queda repetirlo con la
  tabla nueva.

**3. El plan B (`tools/plan_b_cancha.sh lanzar <secreto> 600`, las apps de `build/cancha`)**
(`bench/partido-20261015-0902`).
- Lanzar y soltar: 12 s. El maestro grabó sus 10 min bien: 17 980 fotogramas, la copia .mov
  con el 100 %, 0 desgarros, p95 144 ms, memoria plana y batería 80 % → 80 % cargando.
- **❌ El esclavo no se enlazó nunca por Aware.** El maestro publicó la cita y la reabrió
  cada ~120 s (`publisherTimeout`); `peer_states` vacío en los dos. **❌ El esclavo no dejó
  informe final**: solo el latido hasta los 570 s (0 partes, 0 «sin parte») y Zero ya no
  estaba abierta a las 09:03, sin crash ni jetsam. El mismo código enlazó a las 08:06 y a
  las 08:39. Un agente lo investiga.
- El 16 Pro, a batería: −33 %/h. Le quedan 11,4 GB libres (Zero ocupa 18 GB con las 4K de
  las pasadas).

**4. EMITIR automático (79ef313, db9f677), 60 min por Aware sin destino**, en marcha desde
las 09:07. Al minuto: `purpose: production`, `publish_source: none`, la copia .mov
creciendo, enlazados (93 partes del esclavo y 85 fotogramas de dos lentes), el maestro ya
en `serious` (lleva desde las 08:06 sin parar). El resultado, en la entrada siguiente.

## 2026-10-15 · El spike de la duración de fotograma: mantener la fase entre las cámaras alargando un 0,1 % al que adelanta (ADR 0024 de football-ai, propuesta) · 🚧 hecho en código, sin medir en los iPhone

La fase entre las capturas deriva (§2 de «Las tres anomalías…», 2026-10-14). La pasada de hoy
por Wi-Fi Aware (`bench/dos-moviles-20261015-0805`, 30 min, guion spk04) lo repite:
- de +9 ms en el minuto 0 a +16 en el 8, el cruce en el 8-9 y de −16 a +1 hasta el 29: **+0,86
  ms/min**, el mismo signo que el ensayo (+0,8). El 16 Pro (derecho) va ~14 ppm más rápido;
- **294 desgarros**, todos entre los segundos 492 y 594: ~100 s en que la fase redondea a ±17
  ms y el emparejado salta de vecino;
- `halves_skew_ms` p50 12 / p95 16 / p99 22.

El arreglo que propone el ADR 0024 es alargar un ~0,1 % los fotogramas del que va adelantado.
Antes hace falta saber si el sensor lo cumple, y eso es esto: solo para bancos, y sin
RIG_SPIKE_FRAME_US no hace nada.

**Hecho**
- **RigCore, `Runtime/FrameDurationSpike.swift`:**
  - `FrameDuration`, en µs o en valor/escala de CMTime;
  - `FrameDurationSpikePlan`, el entorno: ventanas de `ON_S` cada `EVERY_S` en la rejilla del
    reloj del soporte, como Spk04Script, así que el maestro sabe cuándo se alargó el otro.
    Lado `left`, `right` o `alternate`, varias duraciones por turnos, `AFTER_S` de base, el
    retraso previsto y `measuredShiftMs`: lo que movió la fase una ventana, desenrollado
    cubo a cubo (20 ms pasan de ½ fotograma);
  - `FrameCadenceTracker`, cada 10 s: el periodo medio, p50 y p99, los huecos, didDrop, lo
    que entró a la 4K y lo pedido;
  - `FrameDurationEffect`, los fotogramas y los ms hasta que se nota.
- **`HalvesPhaseTracker`:** `gridStart` y `startRigMs(of:)`. **`MasterProgramStage`:**
  `halvesPhaseBy10s`.
- **CaptureEngine:**
  - `benchFrameDuration`: `lockForConfiguration` como `lockSettings`, con mínima ≤ máxima en
    todo momento. Antes mira el rango del formato, porque fuera de él AVFoundation lanza una
    excepción de ObjC. Después lee lo que quedó: la duración, el formato, la exposición y el
    ISO, también 3 s después;
  - la cadencia, en cada fotograma y cada didDrop.
- **SplitBench:** pide en cada tic, en los dos móviles, y vuelve a la nominal al acabar. El
  informe trae `halves_phase_by_10s` y `frame_duration_spike`.
- **Tests:** `FrameDurationSpikeTests` (14) y la fase de 10 s en `MasterProgramStageTests`.
  `swift test --skip ModelBench`: 516, 4 saltados, 0 fallos. `check_layers` en verde. ZeroKit
  para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED. El Runner, con `swiftc
  -typecheck` contra ese ZeroKit y los módulos copiados de `build/ios`: 0 errores.

**La pasada** (10 min por Aware, director apagado, guion spk04 para que haya dos lentes, el
derecho alargado a 33 367 µs 20 s de cada 120):

    BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware", "RIG_SPLIT_SCRIPT": "spk04", "RIG_SPLIT_DIRECTOR": "0", "RIG_SPLIT_RECORD_4K": "1", "RIG_SPIKE_FRAME_US": "33367", "RIG_SPIKE_FRAME_SIDE": "right", "RIG_SPIKE_FRAME_ON_S": "20", "RIG_SPIKE_FRAME_EVERY_S": "120"}' \
      tools/banco_dos_moviles.sh split <secreto> 600

Con `SIN_4K=1` la 4K se queda en el móvil, y la recogida va más rápida.

Qué mirar:
- **El derecho**, `frame_duration_spike`:
  - en `transitions`, que no haya `rejected` y que `readback_min`/`max` den lo pedido. Además,
    `apply_ms`, `frames_to_effect` y `ms_to_effect`, lo que tarda; `periods_us`, los 90
    primeros periodos; la exposición y el ISO de antes y de 3 s después; `format_kept`;
  - en `cadence_by_10s`, que `mean_us` dé ~33 367 dentro de las ventanas y ~33 333 fuera, con
    `gaps` y `did_drop` en 0 y `frames_4k` en ~300;
  - además, `camera_drops`, `rec4k` y `capture_clock_skew_ms`.
- **El izquierdo**, `frame_duration_spike.windows`: el `measured_phase_shift_ms` de cada
  ventana frente al previsto (−20,2: alargar el esclavo baja la fase). Además:
  - `halves_phase_by_10s`, ~−10 ms por cubo dentro de cada ventana y plana fuera (+0,14 ms por
    cubo de deriva);
  - `torn_frames`: con 4 o 5 ventanas la fase cruza ±½ fotograma 2 o 3 veces. Cada cruce dura
    1-2 s, no los ~100 de la deriva sola: si hay desgarros, que sean pocos y caigan en las
    ventanas;
  - `part_age_ms` y `added_latency_ms_p95`, que no se muevan.

**Siguiente:** la pasada. Con sus cifras, el ADR 0024 va a la decisión de Alexander. Si
cumple, lo mismo con el izquierdo (`alternate`) y con 1001/30000 y 33 667 (1 %, para corregir
rápido al arrancar). El lazo cerrado (la orden `frame_trim` y el controlador del maestro) no se
escribe hasta que el ADR se acepte.


## 2026-10-15 · IOS-06 — la escalera actúa en el banco split y en EMITIR (la IA, el programa y la parte) · 🚧 sin probar en los iPhone

En el ensayo de 90 min (2026-10-14) el 16 Pro, de esclavo, pasó 71 min en `serious`, y la
escalera de IOS-06 en el camino de la arquitectura B solo se enseñaba. La cancha será al sol
90-120 min. Ahora suelta lo que dice la tarjeta, en el orden del propietario: primero la IA,
después la calidad del programa, después la emisión de ese móvil; la grabación local nunca.

**Hecho** (en un worktree aparte; ZeroKit y el Runner, sin Dart)
- **`RigCore/Runtime/LadderGovernor.swift`** (lógica pura): la escalera de cada móvil con sus
  sensores, más lo que se sabe del otro. **La IA sigue la peor de las dos escaleras** (la
  cadencia más baja, IOS-25): el maestro, la suya y la que el esclavo cuenta en su latido; el
  esclavo, la suya y la que manda el maestro. Ninguno detecta por encima de lo que permite la
  suya: lo propio se aplica al momento, sin esperar a la orden. **El programa va con la
  escalera del maestro y la parte con la del esclavo.** Un otro caído no cuenta.
- **La orden `cadence`** (`RigCore/Wire/CadenceCommand.swift`): `command` por control en JSON
  (`{"ai":false,"kind":"cadence","level":2,"player_hz":0}`), el `kind` que ya lista el ADR
  0023 §1 y que pide §5 («la cadencia la fija el maestro con `command`»). El maestro la manda
  al cambiar la común y cada `cadenceResendS` (5 s). Un esclavo de antes ignora el `kind`: no
  sube `link_version`. El nivel del esclavo ya iba en el latido (IOS-81); ahora se rellena
  (`RigLinkSession.setLadderLevel`) y el maestro lo oye (`onPeerLadder`, solo los cambios).
- **La cadencia común en la rejilla del soporte** (`DetectionGate`, junto a DetectionCadence):
  la detección del banco y de EMITIR ya no toma «el último fotograma cada 4 tics», sino el más
  cercano a t_k = k/hz del soporte, igual en los dos (la regla de PlayerDetectionStage para
  quien va por tics). Las cajas llevan t_k: el director las empareja con desfase cero. Cambiar
  la cadencia empieza la rejilla nueva; 0 la apaga. Un tic que llega más de un periodo tarde va
  al instante más reciente y cuenta los saltados.
- **SplitBench** (el banco split y EMITIR, `ios/Runner/RigLinkNW.swift`): avanza la escalera
  una vez por segundo con los sensores del CaptureEngine (`ladderSensorTarget`: térmica,
  presión de la cámara y carga) y aplica lo que cambia:
  - **L1** jugadores a 5 Hz en los dos; **L2** sin detecciones en los dos y el director a
    `setAI(false)`, que va al plano abierto al ritmo del muelle (con «sin detecciones» a secas
    se quedaba en el último plano: la gramática ve la última evidencia buena);
  - **L3** el programa ×0,6: por `setCeiling` del publicador (él lleva el codificador con
    `onBitrate`); sin publicador (la cancha sin internet), el codificador directamente; un
    publicador que nace en L3 nace con el techo;
  - **L4 en el esclavo**: deja de pintar y codificar su parte (con un IDR al volver); el
    maestro lo oye en el latido y sigue con una lente sin esperarla, como con el esclavo caído
    (`peerDown` y `setSingleLens`, IOS-81). Su 4K sigue.
- **Lo que se ve**: CaptureStatus.ladderLevel enseña la escalera de la pasada mientras dura
  (sin pasada, la de CaptureEngine, que solo se enseña). ThermalMonitor guarda sus niveles
  tras un candado (se leen desde la cola del programa). `FrameRing.latestRigMs()`, sin reservar.
- **El forzado para los bancos** (`LadderForce`, solo `ProgramRunConfig.bench`; EMITIR no lo
  mira): `RIG_LADDER_FORCE=L0..L4`, `RIG_LADDER_FORCE_AT_S` (desde, 0),
  `RIG_LADDER_FORCE_UNTIL_S` (hasta; sin él, al final) y `RIG_LADDER_FORCE_SIDE=left|right`
  (sin él, los dos: BANCO_EXTRA llega igual a los dos). Es el **objetivo**, no el nivel: pasa
  por la misma histéresis, así que al acabar el tramo la escalera mejora un escalón cada 60 s.
- **El informe** (`program-split-<lado>-<t>.json`): `ladder_by_minute` (el nivel de ese
  móvil), `ladder_ai_by_minute` (el de su IA, la común), `detect_runs_by_minute` (el último,
  a medias), `director_pairing` (completas, huérfanas por lado, desfase máximo) y `ladder`:
  cada cambio con su `s` y `rig_ms` (`level`, `ai_level`, `peer_level`, `commanded_level`,
  `forced`, `detect_hz`, `program_bitrate_factor`, `part`, `single_lens`), las acciones en
  vigor al acabar, el forzado, las órdenes mandadas y recibidas, `detect_skipped_late`,
  `detect_missing_frame`, `part_frames_paused` y `program_bitrate_bps`. El latido
  (`program-live-*`) lleva el nivel, el de la IA, los dos por minuto y los últimos 20 cambios.

**Cambia también sin calor** (L0)
- La detección va en la rejilla k/7,5 Hz del soporte y no por el contador de tics. Antes los
  contadores de los dos móviles no estaban en fase (cada uno empezaba al arrancar su banco): lo
  más probable es que la mayoría de los ciclos llegaran al director como huérfanos de un lado
  (no se medía; ahora sí, `director_pairing`).
- Un esclavo promovido (IOS-85) con el enlace caído ya compone con su lente sola: antes el
  aviso de caída le llegaba siendo esclavo y se ignoraba.

**NO probado en hardware**: nada de lo de hoy. Ni el forzado, ni la orden por Wi-Fi Aware, ni
el director yendo al abierto con el programa en marcha, ni el bitrate de L3 en la copia .mov y
en el SRT, ni la parte que para y vuelve con su IDR, ni la escalera de verdad al sol.

**Pendiente de revisión de Alexander** (no se ha cambiado)
- **La tabla es la provisional de IOS-06 (M19): `serious` → L2.** Con el ensayo del 10-14
  (esclavo 71 min en `serious`), la IA de los dos habría ido apagada esos 71 min: el partido en
  el plano abierto. ¿`serious` → L1 (5 Hz) y L2 desde `critical`? Es una decisión de M19
  (SPK-54/SPK-07), no de esta tarea.
- **Sin carga se sube un escalón** (IOS-06): con la batería externa agotada, `fair` ya es L2.
- **L3 a 720p no se aplica**, solo el ×0,6. Cambiar el alto a mitad pide rehacer el pool, el
  compositor, el render y el codificador del programa, abrir otra copia .mov (el formato no
  cambia dentro de un fichero) y mandar un SPS nuevo por el SRT. No es barato ni seguro hoy.
- **L3 en el esclavo no hace nada** (la tarjeta solo habla del programa). ¿Bajar la parte?
- **L4 en el maestro**: no hay cesión (IOS-86); sigue como en L3.
- **El balón global (L1) y la vista previa (L2)** no tienen a quién mandar en este camino: no
  hay balón en el banco split ni en EMITIR, y la vista previa la gobierna IOS-07.
- La escalera de CaptureEngine (sin pasada) sigue sin actuar: fuera de EMITIR y del banco
  split no hay IA que soltar.

**Comprobado**
- `swift test --skip ModelBench`: **502 tests, 4 saltados, 0 fallos** (486 antes; los 16
  nuevos: LadderGovernorTests 9 —la peor de las dos, la común igual en los dos lados para
  todas las parejas de niveles, el esclavo nunca por encima de la suya, L2 sin detecciones con
  el programa y la grabación vivos, L3 ×0,6, L4 sin parte y el maestro con una lente, el
  forzado del entorno con su lado, solo en el banco, y su histéresis, la orden de ida y
  vuelta—, DetectionGateTests 4 —7,5 Hz en la rejilla, los dos móviles con 4,5 ms de fase dan
  los mismos instantes a 7,5 y a 5 Hz, cambiar y apagar, el tic tarde—, DirectorServiceTests 1
  —la IA de la escalera apagada ignora las cajas y va al plano abierto centrado—,
  RigLinkSessionTests 1 —el nivel en el latido, solo los cambios; la orden del maestro llega y
  la del esclavo no sale— y FrameRingTests 1).
- `tools/check_layers.sh`: limpio.
- ZeroKit para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED.
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de todos sus
  `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData (copiados
  aparte): 0 errores y los mismos 16 avisos de siempre (ninguno en lo nuevo).
- Sin Dart: `flutter test` no hace falta.

**Para probarlo en los dos iPhone** (10 min; con el director y el detector, como el ensayo):
```
# L2 en el esclavo de 120 a 300 s: la detección para en los dos y el programa sigue.
BANCO_EXTRA='{"RIG_LINK_INTERFACE":"aware","RIG_SPLIT_DIRECTOR":"1","RIG_DETECT":"players-centernet-mnv4.mlpackage","RIG_LADDER_FORCE":"L2","RIG_LADDER_FORCE_AT_S":"120","RIG_LADDER_FORCE_UNTIL_S":"300","RIG_LADDER_FORCE_SIDE":"right"}' \
  tools/banco_dos_moviles.sh split <secreto> 600
```
En los dos informes, `detect_runs_by_minute` (el minuto i va de 60·i a 60·(i+1) s de cada
móvil): ~450 en el 0 y el 1, **0 del 2 al 5**, ~300 en el 6 (L1 de 360 a 420 s, la
histéresis) y 450 desde el 7, si los sensores están en L0 (en `fair` es L1: 300). En el
izquierdo, `ladder.changes` con `peer_level` 2 y `ai_level` 2 hacia `s` 120 y
`cadence_commands_sent` > 0; en el derecho, `forced` true y `cadence_commands_received` > 0.
`program_frames` ~18 000 sin hueco, `two_lens_frames` como siempre y `ladder.single_lens`
false. El N0 del izquierdo (`n0/banco-*-left.jsonl`) lleva el `hfov` de la vista: el más
abierto de 120 a ~360 s. Y `director_pairing.max_abs_skew_ms` 0.

Variantes: L4 en el esclavo (`"RIG_LADDER_FORCE":"L4","RIG_LADDER_FORCE_AT_S":"120",
"RIG_LADDER_FORCE_SIDE":"right"`, sin UNTIL): `slave_parts` deja de crecer y
`ladder.part_frames_paused` ~14 400 en el derecho; en el izquierdo, `two_lens_frames` se para a
los 120 s, `one_lens_frames` sigue y `ladder.single_lens` true. L3 en el maestro
(`"RIG_LADDER_FORCE":"L3","RIG_LADDER_FORCE_SIDE":"left"`): `ladder.program_bitrate_bps`
3 600 000 y la copia .mov del programa ~60 % de la de siempre.

**Siguiente paso**: la pasada de arriba en los dos iPhone. Después, la decisión de la tabla
(`serious` → L1 o L2) antes de la cancha al sol.






## 2026-10-15 · EMITIR sin tocar la pantalla: `AUTO_EMITIR` y `tools/emitir_auto.sh` · 🚧 sin probar en los iPhone

Para dejar los dos iPhone emitiendo por Wi-Fi Aware sin destino (como en la cancha) sin nadie
que toque la pantalla. **No es el banco split** (sin `RIG_SPLIT` ni `RIG_LINK_*` en el
entorno): es el camino de producción de los toques, con dart-defines.

**Hecho**
- **`lib/src/auto_emitir.dart`** (`AutoEmitir`), con `AUTO_ROLE=left|right`,
  `AUTO_EMITIR=1`, `AUTO_LINK=aware|wifi` (aware por defecto; nunca Multipeer),
  `AUTO_EMITIR_S=<s>` y `AUTO_EMITIR_4K=1`. La app abre la de captura como «Abrir cámara»
  (`ZeroShell`/`CapturePage`/`CaptureSession` de siempre, con el `MasterHost`): el lado,
  «Este móvil dirige» en el izquierdo (PREFERS_MASTER manda si se da), y
  `startLink(role, prefersMaster, mode)`. En el maestro espera a LISTA (cámara lista, enlace
  conectado y rol negociado `master`), deja 20 s al esclavo para su reloj y su fase (el
  maestro no la ve) y llama a `toggleRecording()`, lo mismo que el botón EMITIR; a los
  `AUTO_EMITIR_S` s, otra vez `toggleRecording()`, lo mismo que PARAR. Sin LISTA en 5 min, no
  emite y dice por qué. El esclavo no hace nada: arranca y para por la orden del maestro.
  Sin los defines, nada cambia (la pantalla de lado).
- **El registro**: cada paso y cada cambio de fase, enlace, rol o emisión, al log del sistema
  (`flutter:`) y a `Documents/bench/auto-emitir-<lado>-<t>.log`.
- **`tools/emitir_auto.sh <secreto> <s> [--link aware|wifi] [--con-4k] [--sin-instalar]`**:
  compila cada lado con sus defines e instala (como `instala` del banco), cierra solo Zero,
  lanza los dos con solo `RIG_LINK_SECRET` (desde el fichero, temporal 600 borrado, nunca en
  pantalla), espera a que el maestro pare (s + 5 min de tope de LISTA + 20 s + 3 min) y
  recoge y da el veredicto como `sesion_emitir.sh` (informes, latido, el registro
  auto-emitir y la copia `program-*.mov`, ~2,7 GB/h, con ffprobe y `tools/cancha.py`). Las 4K
  se quedan en el móvil.

**NO probado en hardware.** Y **no sustituye a la prueba con el dedo**: no pasa por la
pantalla de lado (ni su Bonjour, ni lo guardado de «Enlace y emisión» y «Este móvil
dirige», ni el servidor tecleado) ni por el botón (`canRecord`, el doble toque).

**Pendiente de revisión de Alexander**
- **El interruptor «Guardar vídeo» pone a emitir al esclavo.** `CaptureSession.setSaveVideo`
  manda `record`/`recordAndSave` al otro móvil y, sin emitir, el esclavo lo toma como la orden
  de EMITIR (`onPeerCommand` → `toggleRecording`): en la arquitectura B, tocar «Guardar vídeo»
  en el 17 arranca la parte del 16 Pro antes de EMITIR (el paso 6 de `sesion_emitir.sh`). No se
  ha cambiado; el modo automático pone el campo `saveVideo` sin pasar por ahí.
  **Arreglado después** (`fix(captura): «Guardar vídeo» ya no pone a emitir al esclavo`): en la B (`programMode`) el interruptor
  solo cambia el ajuste y no manda nada; EMITIR lleva `record`/`recordAndSave`. Con Multipeer,
  lo de siempre. *Decidido (pendiente de revisión):* emitiendo en la B, `setSaveVideo` se
  ignora (como el interruptor de la pantalla, ya apagado), y el esclavo que vuelve recibe lo
  que se emitió. 2 tests nuevos en `capture_session_test`; `flutter test --no-pub`: 435 bien;
  `flutter analyze --no-pub`: sin avisos. Sin probar en los iPhone.

**Comprobado**
- `flutter test --no-pub`: **433, todos bien** (425 antes; 8 nuevos en `auto_emitir_test`: el
  maestro en orden `startLink` → `start("")` → `startProgram` → `record` y PARAR a los s
  segundos → `stopProgram` → `stop` → `stop` al esclavo; con 4K; sin LISTA en el tope; el
  programa que no arranca; el esclavo que solo arranca y para por la orden; la pantalla con y
  sin el modo; `autoEmitirShell`; sin defines, la pantalla de lado).
- `flutter analyze --no-pub`: sin avisos. `tools/check_layers.sh`: limpio. Sin Swift tocado.
- `tools/test_guiones_cancha.sh`: **81 bien** (59 + 22 de `emitir_auto.sh`: los defines de
  cada lado y su móvil, solo `RIG_LINK_SECRET`, el secreto nunca sale, solo Zero, la espera, la
  recogida con el registro y la copia, el veredicto, `--con-4k`/`--link wifi`, sin el 16 Pro no
  empieza, `--link multipeer` no vale).

**El comando** (60 min por Aware, sin destino):
`tools/emitir_auto.sh <fichero_secreto> 3600 --link aware`

## 2026-10-14 · La cancha sin internet: el camino de EMITIR auditado, lo frágil arreglado y los guiones de la sesión de mesa, la recogida y el plan B · 🚧 NADA de esto probado en los iPhone

La primera prueba en una cancha va sin internet (solo datos móviles lentos; el Starlink y el
VPS, después): los dos iPhone en un trípode, enlazados por Wi-Fi Aware, y EMITIR desde la
pantalla del 17 sin QR Soporte. Lo único probado en hardware hasta hoy es el banco split
lanzado desde el Mac. Aquí, el camino entero leído en el código, lo que se ha arreglado, los
guiones para la sesión de mesa y la recogida, y el plan B.

**Hecho** (4fb5bf4 la app, 913193e los guiones, y esta entrada; en un worktree aparte)
- **Copias locales en fragmentos de 10 s** (`RecordingPolicy.movieFragmentIntervalS`): la 4K
  (CaptureEngine) y la copia .mov del programa (ProgramRecorder). Sin ellos, una app que muere
  a mitad (batería, jetsam, disco lleno, un cierre a mano) dejaba ficheros sin `moov` que no
  abre nadie: hasta 30 GB de 4K perdidos enteros. Medido en el Mac: la copia de un .mov a medio
  escribir se lee hasta el último fragmento (y ffprobe la lee); sin fragmentos, no se abre. Al
  cerrar queda un .mov normal (ftyp, mdat, moov) sin mover datos (0,02 s). La 4K HEVC con
  fragmentos, la sesión en un reloj del soporte grande y AAC, igual (una prueba de usar y tirar
  en el Mac).
- **VideoToolbox tras el segundo plano.** iOS invalida las sesiones de codificar y decodificar
  (kVTInvalidSessionErr) cuando la app pasa a segundo plano: el botón lateral, contestar una
  llamada, cambiar de app. Antes, al volver, el programa y la parte no salían más hasta PARAR
  y EMITIR (y la pantalla seguía diciendo EMITIENDO, porque cuenta los fotogramas compuestos).
  Ahora VideoEncoder rehace la sesión y vuelve a codificar el mismo fotograma (el primero, IDR);
  VideoDecoder tira la suya y abre otra con el siguiente IDR. El informe dice cuántas
  (`vt_session_resets`).
- **La copia del programa no se pierde si su escritor falla**: ProgramRecorder ya no pisa un
  fichero que exista, y SplitBench sigue en `program-<id>-2.mov` desde un IDR (hasta 8
  segmentos). El informe: `files.mov_segments`, `mov_segments`, `mov_failures`.
- **El latido**: `Documents/bench/program-live-<lado>-<t de arranque>.json` cada 30 s (y uno
  final al PARAR), en EMITIR y en el banco. Lo que se sabe de la pasada aunque la app muera
  antes de PARAR (el informe de verdad solo se escribe al final): fotogramas, dos/una lente,
  desgarros, retrocesos, partes del esclavo, la huella, la térmica, la batería y el disco por
  minuto, lo grabado y por qué se cortó. El informe trae además `battery_by_minute` y
  `disk_free_gb_by_minute`.
- **La 4K se cierra con menos de 2 GB libres** (`RecordingPolicy.diskFloorBytes`; lo mira el
  estado que Dart pide cada segundo): con el disco lleno fallan a la vez la 4K, la copia del
  programa, el N0 y el informe.
- **El banco largo pedía 69,5 GB para su 4K** (el doble de la pasada) y no arrancaba: ahora
  como mucho los 40 GB del partido, o la pasada y 2 GB si no cabe en ellos (7200 s: 42,5 GB).
- **RIG_LINK_SECRET se guarda en el Keychain al arrancar.** Antes solo al abrir el enlace de
  Network: el paso 2 de la entrada IOS-58 (lanzar con el secreto y cerrar) no guardaba nada.
  En los dos está guardado igualmente: el banco split de hoy abrió el enlace con él.
- **La pantalla no se bloquea**: `isIdleTimerDisabled` otra vez al volver a primer plano y al
  EMITIR (las hojas del sistema pueden devolverlo a su valor).
- **SIN DESTINO** dice ahora «se graba en este móvil; el QR Soporte lo sube al VPS».
- **Guiones** (ver los comandos abajo): `tools/sesion_emitir.sh`, `tools/recoger_partido.sh`,
  `tools/plan_b_cancha.sh`, con `tools/cancha.py` (qué es de la pasada, ffprobe y el
  veredicto ✅/⚠️/❌) y `tools/zero_movil.sh` (cerrar solo Zero, lanzar con el secreto sin
  imprimirlo, listar y copiar). `banco_dos_moviles.sh` gana `SOLO_LANZAR=1` y `APPS=<carpeta>`
  sin cambiar lo de siempre.

**Los riesgos de la cancha, paso a paso** (arreglado / mitigado / sin arreglo)

| Paso | Riesgo | Estado |
|---|---|---|
| Icono | El secreto del enlace no está en el Keychain | Mitigado. Está en los dos (el banco lo guardó); `sesion_emitir.sh` lo vuelve a guardar y desde 4fb5bf4 basta lanzar con él. Si faltara, «Abrir cámara» con Aware falla («sin secreto del soporte») y sin Mac no hay forma: plan C, «Pod (Multipeer)» en los dos (cada uno graba su 4K, sin programa). |
| Lado | Bonjour del servidor y el permiso de red local sin red | Sin arreglo, no bloquea: la búsqueda del servidor tarda 4 s; `requestLocalNetworkAccess` espera hasta 20 s si no se ve a sí mismo y la fila puede decir NO PERMITIDA. A mirar en la sesión, en modo avión. |
| Aware | ¿Hay que emparejar cada vez? | No: el emparejado lo guarda el sistema (WAPairedDevice, IOS-14). |
| Aware | Sin emparejar (o si el enlace no sube) | **Sin arreglo en la pantalla** (pendiente): dice «esperando al móvil derecho…» y el porqué («no hay ningún iPhone emparejado») solo va al log y a `transport_events` del informe. El maestro emite con una lente, pero **el esclavo no graba nada**: espera la orden (decisión de IOS-58). Mitigado con procedimiento: si el 16 Pro no enlaza en 2 min, en él «Un solo móvil» y GRABAR (su 4K, sin reloj del soporte). |
| Aware | En modo avión con la Wi-Fi encendida | Sin probar. La sesión de mesa lo prueba así; si no sube, sin modo avión y con los datos apagados. |
| LISTA | `rig.json` | EMITIR lo usa (Geometría «calibrada · rig.json»). Es la del trípode de casa (2026-10-11): si los móviles se montan distinto, la costura del programa no casa (las 4K no cambian). EMITIR no hace fotos de calibración (solo el banco, con RIG_CALIB_AT_S). Sin arreglo. |
| LISTA | El detector | Está en los dos (`bench-resources`); se carga aparte, no bloquea el tic; sin él, el director sin detecciones y la fila en rojo. `sesion_emitir.sh` mira los dos ficheros en cada móvil. |
| EMITIR | ¿Arranca sin destino? | Sí (código): sin QR Soporte no hay publicador ni red; el programa se compone y va a `Documents/program-<partido>-<t>.mov` a 6 Mbit/s, ~2,7 GB/h con el AAC. |
| EMITIR | Un QR Soporte viejo en el Keychain (el del Mac de IOS-56) | Mitigado: el publicador reintenta cada 3 s por los datos, en su cola, sin tocar el programa; la tarjeta sale en rojo. «Olvidar» en la tarjeta VPS antes de ir. |
| EMITIR | El .mov del programa o la 4K si la app muere o se queda sin batería | **Arreglado**: fragmentos de 10 s. |
| EMITIR | El escritor de la copia falla a mitad | **Arreglado**: segmento siguiente desde un IDR. |
| 90 min | Disco | Mitigado: 4K 20,25 GB/h por móvil, más 2,7 GB/h de copia en el maestro (2 h: ~46 y ~41 GB). La reserva de 40 GB solo mira la 4K al empezar; ahora la 4K se cierra con < 2 GB. Zero ocupa 59 GB en el 17 y 15 GB en el 16 Pro de bancos viejos (listados del 14-oct): mirar «Disco libre» (≥ 50 GB) y borrar `bench/` y `bench4k/` en Archivos → En mi iPhone → Zero. |
| 90 min | La app muere y no hay informe | **Arreglado**: el latido. |
| 90 min | Memoria | Medida plana en 90 min (banco del 10-14). Los históricos del tic sin tope suman ~5 MB en 2 h. |
| 90 min | Bloqueo automático | Ya estaba (`isIdleTimerDisabled`); endurecido. |
| 90 min | Segundo plano (botón lateral, llamada contestada, otra app) | **Arreglado** lo que no volvía (VideoToolbox). La cámara ya cerraba la 4K y abría otro segmento al volver; el enlace se rehace. |
| 90 min | Llamada entrante | Ya estaba: el micro cede y el programa sigue con silencio (IOS-54). Mitigado: modo avión. |
| 90 min | Térmica serious/critical | **Sin arreglo** (decisión pendiente: la escalera solo se enseña, IOS-56). En el ensayo del 10-14 el esclavo pasó 71 min en serious. En critical iOS puede parar la cámara (interrupción por presión): segmento nuevo al volver. Sombra, sin funda, la batería externa fuera del sol. |
| 90 min | Batería | **Sin medir sin cable**: los bancos de 90 min fueron por cable. Ahora va por minuto en el informe y el latido, y el veredicto da %/h. Baterías externas en los dos. |
| PARAR | Se cierra bien | Fuera del hilo principal; espera hasta 5 s a la copia. El esclavo para con la orden; si no le llega (sin enlace), PARAR también en él. |
| Esclavo | Se reinicia o se cae a mitad | El maestro sigue con una lente (IOS-81, probado en banco) y le reenvía la orden al volver (con fakes). Su 4K nueva va en otro fichero. Sin probar desde la pantalla. |
| Maestro | Muere a mitad | El esclavo sigue con su 4K; el maestro, desde el icono y EMITIR otra vez, abre otra copia. La primera se lee (fragmentos); `recoger_partido.sh` junta las pasadas del mismo partido (3 h). |
| Plan B | ¿Sigue si se quita el cable? | La app sí (lanzada sin consola ni depurador; su entorno vive en el proceso). El guion del banco, si espera, al final no lista y no recoge nada (los ficheros se quedan en el móvil): `plan_b_cancha.sh lanzar` sale enseguida y se recoge en casa. |
| Plan B | ¿La Mac en la misma Wi-Fi? | No, por cable (`transportType: wired`). Sin cable, devicectl solo por la red local si comparten Wi-Fi (hoy el 17 sale `wired` y el 16 Pro `unavailable`). |
| Plan B | Compilar en la cancha | La firma puede pedir red: `plan_b_cancha.sh preparar` en casa guarda las tres apps. |
| Plan B | Un iPhone que se reinicia (batería a cero) | Sin comprobar: devicectl tiene que volver a montar la imagen de desarrollo, que en iOS 17+ se personaliza con Apple (red). No reiniciar entre casa y la cancha; si hace falta, compartir los datos del móvil con el Mac. |
| Plan B | La 4K no arrancaba (69,5 GB de reserva) | **Arreglado** (40 GB; 42,5 con 7200 s). |
| Recogida | **El Mac tiene 4,9 GB libres** (460 GB al 99 %) | No cabe ni una 4K de 2 h (~40 GB). `recoger_partido.sh` lo mira y trae solo lo que cabe; para todo, `SALIDA=/Volumes/<disco>/partido-…`. Compilar también pide sitio. |

**NO probado en hardware** (todo lo de hoy): los fragmentos en el iPhone (en el Mac sí), el
rehacer VideoToolbox al volver del segundo plano (en el Mac, invalidando la sesión a mano),
el latido, el suelo del disco, el secreto al arrancar, el bloqueo de pantalla, los tres
guiones contra el devicectl de verdad (solo contra el falso), el plan B lanzado y sin cable,
Aware en modo avión y la batería sin cable. Y EMITIR desde la pantalla sigue sin una sola
pasada en los iPhone.

**Pendiente de revisión de Alexander** (no se ha cambiado)
- El esclavo en la arquitectura B no graba nada sin la orden del maestro (IOS-58): si el enlace
  no sube en la cancha, el lado derecho se pierde salvo «Un solo móvil» a mano. ¿Que grabe su
  4K solo tras N min sin maestro?
- La escalera no actúa ante la térmica (IOS-56): en serious/critical no se suelta nada.
- La pantalla no dice por qué no sube Aware (sin emparejar): pide plumbing del motivo del
  transporte hasta Dart (RigNet → RigLinkNW → Pigeon).
- EMITIR no hace fotos de calibración: si el soporte se monta distinto en la cancha, el cosido
  del programa va con la calibración de casa.
- `banco_dos_moviles.sh` sigue con sus funciones propias (probadas); los guiones nuevos usan
  `tools/zero_movil.sh`. Unificarlos, cuando haya una pasada real de los nuevos.

**Comprobado**
- `swift test --skip ModelBench`: **486 tests, 4 saltados, 0 fallos** (476 antes; los 10
  nuevos: RecordingPolicyFieldTests 3, ProgramRecorderTests 5 —el .mov cortado se lee, sin
  fragmentos no, no pisa, cerrar sin fotogramas, audio cruzando fragmentos—,
  VideoEncoderInvalidSessionTests 1 y VideoDecoderInvalidSessionTests 1).
- `flutter test --no-pub`: **425, todos bien**. `flutter analyze --no-pub`: sin avisos.
- `tools/check_layers.sh`: limpio.
- ZeroKit para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED, el aviso de siempre
  (`VtConcurrencyBench`).
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de todos sus
  `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData: 0 errores
  y los mismos 16 avisos que 59510dc (comparados uno a uno).
- `python3 tools/test_cancha.py` (17), `python3 tools/test_recogida_pasada.py` (8) y
  `tools/test_guiones_cancha.sh` (59 comprobaciones, con `tools/fake_xcrun.py`): el secreto
  nunca sale por pantalla ni en el registro; solo se cierra Zero; la sesión espera, recoge y
  da el veredicto; la recogida trae la última pasada (no las viejas), las 4K con segmentos, la
  del esclavo que murió a mitad (solo latido y un .mov fragmentado cortado que ffprobe lee) y
  salta el móvil sin cable; el plan B instala las apps guardadas, lanza con el entorno de
  siempre (Aware, director, CenterNet, micro, 4K, sin .ts, 7200 s) y sale sin recoger.
- `tools/cancha.py veredicto` sobre los informes reales de `bench/dos-moviles-20261014-1235` y
  `-1010`: da lo que dicen sus entradas (471 desgarros y p95 169 ms en el de 90 min; el
  esclavo 71 min en serious).

**Los comandos**

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer && git pull --ff-only

# 1. La sesión de mesa (en casa, los dos por cable y desbloqueados; ~20 min). Compila sin
#    AUTO_ROLE, instala, guarda el secreto, dice qué tocar, espera el informe del maestro y
#    recoge en bench/emitir-<fecha>/ con el veredicto:
tools/sesion_emitir.sh <fichero_secreto>                # como en la cancha: SIN DESTINO
tools/sesion_emitir.sh <fichero_secreto> --con-mac      # además, al MediaMTX del Mac (QR Soporte)
#    opciones: --sin-instalar, --minutos N (45), --con-4k

# 2. El plan B: en casa, las apps guardadas; en la cancha, lanzar y soltar; después, volver.
tools/plan_b_cancha.sh preparar
tools/plan_b_cancha.sh lanzar <fichero_secreto> [7200]
tools/plan_b_cancha.sh volver
#    (el de siempre sigue igual, pero espera y recoge al final, con el cable puesto:)
BANCO_EXTRA='{"RIG_LINK_INTERFACE":"aware","RIG_AUDIO":"1","RIG_SPLIT_DIRECTOR":"1","RIG_DETECT":"players-centernet-mnv4.mlpackage","RIG_SPLIT_RECORD_4K":"1"}' \
  tools/banco_dos_moviles.sh split <fichero_secreto> 6000

# 3. Tras la cancha (por cable): la última pasada de cada móvil, ffprobe y el veredicto.
tools/recoger_partido.sh                                 # todo, si cabe en el Mac
tools/recoger_partido.sh --sin-4k                        # sin las 4K (se quedan en el móvil)
SALIDA=/Volumes/<disco>/partido-$(date +%Y%m%d) tools/recoger_partido.sh   # a un disco externo
tools/recoger_partido.sh --desde '2026-10-18 16:30'      # si después hubo otra pasada
```

**En la cancha** (EMITIR desde la pantalla): los dos en modo avión con la Wi-Fi encendida y
«No molestar», baterías externas, sombra y sin funda; el 17 IZQUIERDA y «Este móvil
dirige», el 16 Pro DERECHA, Aware, tarjeta VPS vacía; «Abrir cámara», LISTA en los dos (Enlace
conectado), «Disco libre» ≥ 50 GB; «Guardar vídeo» y EMITIR en el 17. Al acabar, PARAR en el
17 y comprobar que el 16 Pro paró. Si el 16 Pro no enlaza en 2 min: en él «Un solo móvil» y
GRABAR. Si EMITIR falla: el plan B desde el Mac.

**Siguiente paso**: la sesión de mesa con `tools/sesion_emitir.sh` (en modo avión, con el
lado derecho que se cierra y vuelve y el botón lateral en el 17); con su veredicto en verde,
la cancha.

## 2026-10-14 · El tic de fcbafad, probado en los dos iPhone: fase p99 4,5 ms, sin huecos y la latencia plana · 🚧 la fase entre cámaras sigue sin medir; EMITIR desde la pantalla, sin hacer

Pasada de 8 min (`bench/dos-moviles-20261014-1235`, maestro
`program-split-left-1792003470.json`) con 00a5318, por Wi-Fi con router y con toda la carga
menos la 4K y el SRT: director, CenterNet en los dos y micrófono.

**El tic (fcbafad), ✅ en el iPhone**
- `tick_phase_ms` p50 3,5 / p95 3,5 / **p99 4,5**.
- `program_skipped_instants` **0**, `missing_director_views` **0**.
- `added_latency_ms_by_minute`: p95 entre 143,0 y 143,7 en los 8 minutos (p50 ~141,7).
  Latencia añadida p50 142 / p95 143. 14 399 fotogramas, `program_fps_p5` 29,2, **0
  desgarros**.
- El arreglo no corrige la deriva: la quita de raíz. Para ver que no vuelve el escalón
  del minuto ~80 hace falta una pasada larga, la próxima de 90 min.

**La fase entre las cámaras, sin dato.** El director miró todo el rato a la izquierda
(yaw −1,1 rad, `sides` [left] en el 100 % de las vistas: había alguien sentado a ese lado).
El esclavo no mandó parte más que 24 veces (`slave_no_parts` 14 365, como debe), y
`halves_phase_by_minute` solo tiene 23 muestras del minuto 0 (`drift` −1, sin calcular). La
deriva hay que medirla con la escena repartida entre las dos lentes, o con
`RIG_SPLIT_SCRIPT=spk04` (vistas que cruzan la costura a la fuerza). Con ese dato se
escribe el ADR del arreglo de la fase, que contradice el ADR 0012 y el §5 del 0023.

**La memoria:** el maestro arranca en 358 MB y en el minuto 1 ya está en 479, plano hasta
el final (483); `app_events` vacío, `camera_drops` en 0 y el pico de VideoToolbox, 2. El
esclavo, plano en ~450. Térmica: el maestro, `fair`; el esclavo, `nominal`.

**EMITIR desde la pantalla (IOS-58), sin hacer.** A las 12:03 quedó todo listo: el Runner
sin `AUTO_ROLE` instalado en los dos, el secreto guardado en el Keychain y MediaMTX con el
QR Soporte abierto en el Mac. Zero se abrió en el 17 pero el 17 no publicó, y en el 16 Pro
no se abrió. A las 12:35, sin respuesta, se usó el tiempo para esta pasada. Para la próxima
vez basta con `emitir_prep` (los pasos 1 a 4 de la entrada IOS-58) y los pasos 5 a 9.

## 2026-10-14 · Las tres anomalías del ensayo de 90 min por Wi-Fi Aware: el tic a la deriva (arreglado), la fase entre las cámaras (medida, pide ADR) y +180 MB sin reconexión (instrumentado) · 🚧 falta la pasada con los dos iPhone

Datos: `bench/dos-moviles-20261014-1010` (maestro `program-split-left-1791999786.json`,
esclavo `…-right-1791999796.json`). `program-views-1791994386.jsonl` **sí se grabó**
(156 024 líneas, una por instante) y es lo que dio el diagnóstico. Todo con
`RIG_SPLIT_NO_MOV`/`NO_TS`, director y CenterNet en los dos.

**El enlace no se cayó en toda la pasada.** `transport_events` no tiene ningún «control
caído»: las citas caducaron a los 120 s con `keepUntilDrop` y nada más. Los
`suspect`/`down`/`up` de `peer_states` son latidos perdidos durante 100-300 ms (minutos
28,7, 46,0, 46,8, 74,2, 82,8, 87,5 y 88,4) y no rehacen nada (revisado en el código: solo cambian la espera de la parte y los límites
del director). `parts_lost` 19 de 44 684.

### 1. Latencia añadida p95 169 ms, huecos y vistas perdidas: el tic a la deriva · arreglado (fcbafad)

Lo que dicen las vistas por minuto:

| | Minutos | Pico | Total |
|---|---|---|---|
| Instantes sin vista del director (salían con el **barrido de guion**: un salto de plano de un fotograma, HFOV 60°) | 23-61 | 541-581/min en 37-41 | 5027 |
| Fotogramas de una lente con vista de dos (el esclavo tampoco tenía esa vista: «no_part») | los mismos | ~230/min | 2751 |
| **Huecos del programa** (instantes sin componer) | 63-89 | 546-571/min en 77-84: **el programa a ~20 fps** | 5973 |

Las tres cosas y la latencia son lo mismo. El tic se armaba con un temporizador de GCD que
se repetía cada `1.0 / 30`. GCD pasa el intervalo a ticks de mach (24 MHz) **truncando**:
33 333 333 ns son 799 999 ticks, 41,7 ns menos por tic (−1,25 ppm). La fase del tic frente
a la rejilla del programa se iba **0,075 ms por minuto**, 6,75 ms en un partido. Arrancó a
~2,7 ms detrás de un punto de la rejilla (el margen de e92edd0) y:
- **hacia el minuto 40** llegó a la frontera del instante del director, `rejilla(ahora +
  67)`. Con el jitter del disparo, uno de cada tres tics daba el mismo instante que el
  anterior y el siguiente se saltaba uno. El instante sin vista se pintaba con
  `scriptedView` y el esclavo, sin ella, mandaba `no_part`;
- **hacia el 80** llegó a la del instante que se compone, `rejilla(ahora − 130)`: los
  mismos saltos, ahora huecos en el programa;
- **pasada esa frontera, la espera es un fotograma más.** Antes: 133,3 + fase + composición
  ≈ 136-140 ms (p50 139,7). Después: 133,3 + ~30 + composición ≈ 165-169 ms, en los
  últimos ~10 min, más del 5 % de la pasada. **De ahí los 25 ms de más del p95**, no de
  Wi-Fi Aware: la parte llegó antes que por el router (`part_age` p50 80 / p95 85 / p99 90
  ms, frente a 90 / 115 / 125) y la espera sigue en 130.

Una simulación del temporizador de antes (90 min, mismo arranque y 0-0,8 ms de jitter) da
los picos de vistas perdidas en 36-37, los de huecos en 76-77 y el p95 en 163 + composición:
lo medido. En el banco del 2026-10-11 (80 min, p95 143) la fase de arranque debió de ser
otra y no llegó a cruzar (no hay vistas por instante de esa pasada para comprobarlo).

**Hecho**
- **RigCore:**
  - `ProgramTickPhase`: el retraso hasta el siguiente punto de la rejilla más el margen, y
    la fase de un tic. En aritmética entera de ns: en coma flotante el instante justo del
    tic caía a veces en el fotograma anterior.
  - `ProgramClock.gridIndex`, `instant(index:)` y `gridInstants(after:through:limit:)`.
  - `ViewHistory.view(atOrBefore:)`.
- **SplitBench:**
  - el temporizador se rearma en cada disparo, en el reloj del soporte. No hay intervalo
    que acumule deriva, y tras un relevo el siguiente disparo ya va con el reloj nuevo;
  - el director da vista también a los instantes que un tic tarde se saltó (como mucho 4);
  - un instante sin vista del director se pinta con la anterior, no con el barrido.
- **El informe:** `tick_phase_ms` (p50/p95/p99), `program_skipped_instants`,
  `missing_director_views` y `added_latency_ms_by_minute` ([p50, p95] de cada minuto).
- **Tests:** `ProgramTickTests` (4). Con 90 min simulados, el temporizador de antes da más
  de 100 vistas y 100 instantes perdidos y la latencia de 162 ms; rearmado, ninguno y ≤137.
  Además, la vista anterior en `ViewSyncTests`.

### 2. 471 fotogramas desgarrados: la fase entre las cámaras deriva · medida (14ed93a); el arreglo pide un ADR

Captura del maestro menos captura de la parte (mediana por minuto, en ms), de las vistas:

| Minuto | 0 | 5 | 10 | 15 | 20 | 21 | 22 | 36 | 43 | 44 | 64 | 72 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Fase | −1 | 2 | 7 | 11 | 15 | 16 | **−16** | −5 | 0 | 1 | −16 | −10 |

**+0,8 ms por minuto (~13 ppm entre los dos sensores), cruzando ½ fotograma cada ~42 min.**
Los 471 desgarros son **todos** de los minutos 21 (4) y 22 (467), el primer cruce. El
segundo (63-64) cayó sin dos lentes. En el cruce, los dos fotogramas propios vecinos de la
parte están a 17 ms (16,7 redondeado al ms) y TearCheck, con razón, lo cuenta. No es:
- el enlace, que no cayó;
- el reloj tras reconectar: no hubo reconexión, y `part_age` (llegada − captura de la
  parte, en el reloj del soporte) no se movió más de ~10 ms en 90 min. Con el RigClock
  derivando 0,8 ms/min se habría abierto 70 ms;
- la extrapolación: 0 de los 471 llevaban vista extrapolada.

El ADR 0012 (TASK A4) sortea la fase al arrancar suponiendo «un desfase constante», y el
ADR 0023 §5 dice que no hay desgarro «por construcción (la fase está a ≤5 ms)». Medido,
no se queda: con una deriva así, la fase pasa ~70 % del partido por encima de 5 ms
(`halves_skew_ms` p50 8 / p95 16) y cruza ½ fotograma unas dos veces. En 10 min no se
veía (SPK-04: 0 desgarros, desfase p99 12 ms).

**Hecho:** `HalvesPhaseTracker` (RigCore). Lo alimenta `MasterProgramStage` y lo leen los
informes, también los de EMITIR, que no graban las vistas:
- `halves_phase_by_minute`: [minuto, mediana con signo, fotogramas de dos lentes,
  desgarros];
- `halves_phase_drift_ms_per_min`: la deriva, desenrollada a través del cruce;
- `halves_phase_minutes_to_half_frame`.

Tests: `HalvesPhaseTests` (3; la deriva del ensayo con su cruce da 0,8 ms/min) y la fase
en `MasterProgramStageTests`.

**Para un ADR** (enmienda al 0012 y al 0023 §5; no se toca la arquitectura aquí). Opciones,
por orden:
1. **Mantener la fase alargando fotogramas** del móvil que va adelantado:
   `activeVideoMin/MaxFrameDuration` un ~0,1 % más largos durante unos segundos cada vez que
   la fase pase de ~3 ms.
   - A 30 fps el formato solo deja alargar. Por eso se frena siempre al que adelanta, que
     puede ser el maestro (su fase frente a la rejilla no importa: usa su fotograma más
     cercano a ≤20 ms).
   - Antes hace falta un spike en el iPhone: si el sensor cumple duraciones finas y cuánto
     tarda en aplicarlas.
2. **Volver a sortear** (`restartForPhase`) al pasar de 5 ms: corta la cámara 1-2 s y la 4K
   del esclavo. Solo valdría en el descanso, y no basta: la deriva da ~36 ms por parte.
3. **Suavizar el cruce:** histéresis en el emparejado del maestro, para no alternar entre
   los dos fotogramas vecinos cerca de ½ fotograma. Quita el tirón de la mitad del maestro;
   el desfase sigue ahí.

### 3. +180 MB en el maestro entre los minutos 44 y 45 · no fue el enlace ni una fuga; instrumentado (115062b, 87c9fca)

`footprint_mb` está plano en 305-310 MB hasta la muestra del minuto 44. En la del 45 ya
marca 487 y sigue plano hasta el final (493). El esclavo, plano en 444-452.
- **No fue una reconexión.** No hubo ninguna. El primer latido perdido (minuto 28,7) no
  movió la memoria, y el del 46,0 llegó 1-2 min **después** del salto.
- **El código de la reconexión no retiene nada grande.** Revisado:
  - `retiredListeners`, la cita guardada con `keepUntilDrop` y la conexión de medios
    sustituida (se cancela);
  - el reensamblador (4 tramas a medias, ≤4 MiB), la cola del espaciado y el `controlReader`;
  - el decodificador, que solo se rehace si cambian el SPS/PPS e invalida el viejo;
  - `setUpIfNeeded`, que monta una vez.
  
  Lo único que se rehace con un suceso del enlace es un cambio de papel, y no lo hubo.
  Confirmado de paso el aviso del 2026-10-10: la lectura pendiente de un control viejo
  puede tirar el nuevo. Es un fallo funcional, no de memoria, y aquí no saltó: no hay
  ningún «control caído».
- **Lo que coincide:** alguien junto al soporte.
  - `color_series` se dispara a los 2680-2690 s (minuto 44,7): la diferencia de luma en
    bruto baja de 0,22 a 0,11-0,13, algo delante de una lente.
  - Entre los minutos 42 y 44 el director se fue al centro (yaw −21°, dos lentes), con gente
    en la escena.
- **No es una fuga: son ~180 MB que la app suele tener desde el principio.** En todos los
  informes del maestro (`footprint_mb[0]`, a ~2 s de lanzar la app, frente a `[1]`) la
  huella sube 80-235 MB en el primer minuto y luego se queda. Lo que cambia es dónde
  arranca:

  | Pasada | A los 2 s | Minuto 1 | Después |
  |---|---|---|---|
  | Emisión de las 11:46 (`…-1792000717`, director y detector, sin .mov) | 420 | 498 | plana, 497 |
  | Banco del 2026-10-11 en el trípode (`…-1791752445`, 80 min) | 386 | 506 | 506-535 |
  | **Este ensayo** | **215** | **306** | **+181 entre el minuto 44 y el 45**, luego plana en 487-493 |

  Este ensayo arrancó ~200 MB por debajo de una pasada igual (420) y alcanzó el nivel de
  siempre (~490) entre el 44 y el 45, de una vez. A los 2 s de lanzar el banco aún no ha montado
  nada (el enlace sube a los 3,3 s): la diferencia ya estaba en la app, antes del programa.
  El 2026-10-10 hubo otro escalón igual, y sin partes ni decodificador
  (`…-1791648761`, 381 → 288 → +169 en el minuto 2 → 457). Es una reserva que suele
  ocurrir al arrancar y que esta vez llegó tarde.

Hipótesis, por orden:
1. **La UI de Flutter** (el motor, sus superficies y la vista previa), que suele estar
   pintada al lanzar y aquí no lo estaba hasta que alguien tocó o despertó el 17.
   **Pregunta para Alexander:** ¿se tocó o se miró el 17 hacia el minuto 44-45? ¿Y al
   lanzar esta pasada estaba la pantalla de la app a la vista?
   **Respuesta (Alexander, 12:50):** sí, a esa hora se movieron los móviles, que se
   caían del soporte de mesa, y se pasó el cargador de uno al otro; el 17 casi seguro. Cuadra
   con la hipótesis 1 y con `color_series` en el minuto 44,7. La pasada de las 12:36
   arrancó con la app a la vista y no tuvo salto (358 → 479 MB en el primer minuto).
2. **El pool de la cámara.** Si alguien retiene sus búferes 4K NV12 (12,4 MB cada uno), el
   pool crece ~15 (≈186 MB) y no vuelve a bajar. didDrop con «sin búferes» lo diría
   (`camera_drops`, 87c9fca).
3. **El pool del programa.** `masterPool` no tiene tope y da dos búferes por tic. Si el
   codificador del programa se atasca ~1 s, retiene ~60 búferes 1080p NV12 de 3,1 MB,
   ≈186 MB, y el pool se queda con ellos (`program_encoder_in_flight_peak`).
4. **Core ML**, que cambie de unidad o recompile el detector (el maestro estaba en `fair`
   desde el minuto 12): `infer_p50_ms_by_minute`.

**Hecho** (para que la próxima pasada lo diga):
- **`FootprintJumps` (RigCore):** la huella se mira cada 5 s, y cada subida de ≥20 MB va a
  `footprint_jumps` con:
  - el segundo, el `rig_ms`, el papel, la térmica y el último estado del esclavo;
  - lo más que tuvieron dentro los codificadores del programa y de la parte;
  - las cuentas del programa, los huecos y las vistas sin director;
  - las pasadas del detector, las subidas del gráfico y los últimos sucesos de la app.
- **`app_events`:** los avisos de memoria, deja de estar activa, activa, al fondo y vuelve
  del fondo, cada uno con su segundo y su huella.
- **`peer_states_footprint_mb`:** la huella en cada cambio del esclavo, en paralelo a
  `peer_states`.
- **`VideoEncoder.inFlight` y `takeInFlightPeak()`:** lo que tiene dentro VideoToolbox. El
  informe trae `program_encoder_in_flight_peak`.
- **`ProcessFootprint` (RigNet):** cada suceso del transporte lleva la huella,
  `12.3 [306 MB] control arriba`.
- **El detector:** `infer_p50_ms_by_minute`.
- **Los descartes de la cámara por motivo** (didDrop: sin búferes, tarde, otros):
  `camera_drops`, en el informe y en cada salto (87c9fca).
- **Tests:** `FootprintJumpsTests` (3), `ProcessFootprintTests` (1), la huella en la línea
  de tiempo del loopback y lo que queda en VideoToolbox (`VideoEncoderTests`).

**Comprobado** (en el worktree `../wt-reconexion`; el árbol principal no se tocó)
- `swift test --skip ModelBench`: **476 tests, 4 saltados, 0 fallos** (antes, 463).
- `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED.
- **El Runner, sin `flutter build`:** `swiftc -typecheck` de todos sus `.swift` contra ese
  ZeroKit y los módulos de HaishinKit y Flutter del DerivedData (copiados aparte). 0 errores
  y los mismos 32 avisos que 68d63d3, comparados uno a uno, en cada uno de los cuatro
  commits.

**La próxima pasada con los dos iPhone** (la misma orden del ensayo, con este build; si se
puede, apuntar la hora a la que alguien toque el 17):

```bash
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print("latencia p50/p95", d["added_latency_ms_p50"], d["added_latency_ms_p95"], "fase del tic", d["tick_phase_ms"])
print("huecos", d["program_skipped_instants"], "sin vista del director", d["missing_director_views"])
print("latencia por minuto", d["added_latency_ms_by_minute"])
print("fase entre cámaras", d["halves_phase_by_minute"])
print("deriva", d["halves_phase_drift_ms_per_min"], "min hasta medio fotograma", d["halves_phase_minutes_to_half_frame"])
print("saltos de huella", json.dumps(d["footprint_jumps"], indent=1, ensure_ascii=False))
print("app", d["app_events"], "pico en VideoToolbox", d["program_encoder_in_flight_peak"], "cámara", d["camera_drops"])
print("esclavo", list(zip(d["peer_states"], d["peer_states_footprint_mb"])))
print("detector por minuto", d["detect"].get("infer_p50_ms_by_minute"))
print("\n".join(d["transport_events"]))' $(ls -t bench/dos-moviles-*/izquierdo/bench/program-split-left-*.json | head -1)
```

- **El tic:**
  - `tick_phase_ms` p99 en ~3-4 ms (el margen y el despertar), igual en el minuto 1 que en
    el 90;
  - `program_skipped_instants` y `missing_director_views` en ~0;
  - `added_latency_ms_by_minute` con el p95 en ~140-145 todos los minutos, sin el escalón
    de +33 al final. El p95 global, ~144: lo que pide la espera de 130 por Wi-Fi.
- **La fase entre cámaras:**
  - `halves_phase_drift_ms_per_min` otra vez en ~±0,8; el signo puede cambiar con el papel
    o el par;
  - desgarros solo en los minutos del cruce. Con eso se decide el ADR.
- **La huella:**
  - el nivel: `footprint_mb[0]` y `[1]`. Si arranca en ~400-500 no habrá salto, y es lo
    normal;
  - si `footprint_jumps` trae un salto, su `s` y `app_events` dicen si coincidió con tocar
    el móvil (hipótesis 1);
  - `camera_drops.out_of_buffers` que sube en ese salto apunta al pool de la cámara
    (hipótesis 2);
  - `program_encoder_in_flight_peak` de más de ~10 apunta a un atasco de VideoToolbox
    (hipótesis 3);
  - un cambio en `infer_p50_ms_by_minute` en ese minuto apunta a Core ML (hipótesis 4);
  - los sucesos del transporte llevan su huella: si hay una caída y una vuelta, dicen si
    dejaron algo.

**Siguiente paso**: esa pasada (90 min, o 30 para el tic y la huella). Con la deriva
confirmada, el ADR de la fase y el spike de la duración de fotograma en el iPhone.

## 2026-10-14 · IOS-56 — la primera emisión desde los dos iPhone: 10 min por SRT al MediaMTX del Mac, sin reconexiones y con la SEI al 100 % · 🚧 faltan los 30 min al VPS

El paso 1 de la entrada IOS-56 de abajo, con los dos iPhone en el soporte de mesa (17 a la
izquierda y maestro; 16 Pro a la derecha), por Wi-Fi con router y con toda la carga: el
director, el CenterNet en los dos, el micrófono, la copia .ts y el maestro publicando el
programa por SRT (latencia 1500 ms) al MediaMTX de `tools/mediamtx-programa.yml` en el Mac
(10.10.18.101). La passphrase, de prueba, se generó y se borró sin imprimirse. Datos:
`bench/dos-moviles-20261014-1146` (maestro `program-split-left-1792000717.json`).

**Lo que llega al Mac**
- `ffprobe` del RTSP a los 6 s de lanzar: **h264 1920×1080 y aac 48 kHz estéreo**.
- `sei_probe.py`, 120 s: **3600 de 3600 fotogramas con SEI** (30 fps justos), `sei_ok`,
  `rig_ms_backwards` 0. Solo `view_ids` [0]: en el cuarto no hay jugadores y el director no
  sale del plano general. La llegada respecto al rigMs: p50 6 ms, p95 12 ms, p99 455 ms y
  máx. 1,65 s (las rachas de la Wi-Fi, que SRT recupera con su latencia).
- 20 s grabados del RTSP: 583 fotogramas y 938 de audio; la imagen sale con el marcador, la
  franja de anuncios y «CÁMARA IA AUTO». MediaMTX lo grabó también en
  `bench/programa-mediamtx/programa/` (fMP4 de 60 s).

**El informe del maestro** (`publish.sessions[0]`)
- `connects` 1, **`reconnects` 0, `congestions` 0, `connect_failures` 0,
  `program_encode_failures` 0**.
- `video_frames_sent` **17 999 de 17 999**, `video_dropped` 0; `audio_frames_sent` 28 121
  (2 descartados antes de conectar).
- `bitrate_bps` 6 000 000 sin cambios (`bitrate_min_bps` igual); `send_rate_mbps` 3,9 (la
  escena quieta no llena los 6).
- SRT: `rtt_ms` 7,9 (máx. 100), `srt_packets_lost` 342 de 266 584 (0,13 %),
  `srt_packets_retransmitted` 333, **`srt_packets_dropped` 0**, `send_buffer_ms_max` 124.

**El programa, con el SRT encima de las partes** (la misma Wi-Fi para las dos cosas)
- 17 999 fotogramas, `program_fps_p5` 29,05, `program_interval_ms_p99` 35. `masterOnly`
  13 329 y `twoLens` 4 670; `part_fallbacks` 248.
- **`torn_frames` 2**; latencia añadida p50 142 ms y **p95 144 ms**, lo mismo que sin
  publicar. `part_age_ms` p50 90 / p95 120 / p99 200.
- Partes 4 861 recibidas y 7 perdidas (0,14 %); 17 IDR pedidos. El enlace: un `down` de
  0,2 s a los 45 s y 8 `suspect` sueltos que vuelven a `up` en menos de 0,3 s.
- Detector en los dos: 4 495 pasadas, 0 saltadas, p99 30 ms.
- GPU del maestro p50 3 / p95 4,5 / p99 5 ms (la composición, p99 3).
- Memoria: el maestro, plana en ~497 MB tras el primer minuto; el esclavo, en ~450.
- Térmica: el maestro, `fair` todo el rato. **El esclavo, `serious` desde el minuto 0**:
  el 16 Pro venía caliente del ensayo de 90 min y no le dio tiempo a enfriarse.
- El esclavo: `publish.sessions` vacío (no publica), 4 908 partes y 8 descartadas.

**Aceptación del paso 1**: ✅ 0 reconexiones, ✅ SEI al 100 %, ✅ ~18 000 fotogramas
enviados, ✅ las partes y la latencia como sin publicar.

**Siguiente paso**: los 30 min al VPS cuando esté desplegado (paso 2 de abajo), y EMITIR
desde la pantalla (IOS-58).

## 2026-10-14 · IOS-58 — EMITIR en la arquitectura B, desde la pantalla y sin el banco · 🚧 falta la pasada con los dos iPhone

**Dependencias: excepción deliberada** (pendiente de la revisión de Alexander). La tarjeta
depende de IOS-80 e IOS-73 (✅) y de IOS-56 e IOS-44, que tienen el código hecho y siguen 🚧
solo por sus pruebas con hardware. Se adelanta para la primera emisión en una cancha.

**Hecho** (81d496e, cdbc999, cf04738 y el commit de esta entrada, «IOS-58d»)
- **El programa sale del banco sin romperlo.** EMITIR usa la misma orquestación que el banco
  split (`SplitBench`: parte del esclavo, programa del maestro, director, detector, copias y
  SRT), con sus ajustes en `ProgramRunConfig` (RigCore):
  - `bench(environment:)` lee el entorno como siempre: `RIG_SPLIT_*`, `RIG_DETECT` y
    `RIG_LINK_INTERFACE` no cambian, y `tools/banco_dos_moviles.sh` sigue igual;
  - `production(medium:detectorPackage:)` es EMITIR: sin fin propio, con el director
    (IOS-73), publicando al QR Soporte del Keychain (IOS-56/68), sin la 4K del banco y sin
    sus ficheros de medir (.ts y vistas por instante). La copia del programa va a
    `Documents/program-<partido>-<t>.mov` (IOS-57) y el informe, a `Documents/bench` como el
    del banco, con `purpose: production`, `elapsed_s` y `part_fallbacks`.
- **RigHostApi:** `startProgram()`, `stopProgram()` y `programStatus()` (`ProgramStatus`).
  Llegan a `CaptureHostApiImpl` por `ProgramHub`, porque la cámara y el enlace viven ahí.
  PARAR cierra fuera del hilo principal.
- **`startLink(role, prefersMaster, mode)`** con `LinkMode` (multipeer, ethernet, wifi o
  aware). El entorno de los bancos (`RIG_LINK_MULTIPEER`, `RIG_LINK_INTERFACE`) manda
  (`LinkChoice`); sin él, lo elegido en la pantalla.
- **El secreto del soporte en el Keychain** (`football-ai.enlace` / `secreto`):
  `RIG_LINK_SECRET` manda y se guarda; sin él se usa el guardado (`RigSecretSource`). Basta
  lanzar la app una vez desde el Mac con el secreto para abrirla después desde el icono.
- **Dart (`CaptureSession`):**
  - en el maestro, EMITIR llama a `CaptureHostApi.start` sin URL del pod (solo la 4K, si se
    guarda), a `startProgram` y manda `record`/`recordAndSave` al esclavo. PARAR para el
    programa, la 4K y manda `stop`;
  - si el programa no arranca, se cierra la 4K, no se ordena nada y se dice por qué;
  - el esclavo no emite solo («EMITE EL MAESTRO»): arranca con la orden (su parte, su
    detector y su 4K) y puede parar el suyo;
  - el esclavo que llega o vuelve con el programa en marcha recibe la orden otra vez;
  - el estado del programa se lee cada segundo con el de la cámara.
- **La pantalla:**
  - en la de lado, la tarjeta «Enlace y emisión»: Pod (Multipeer, lo de siempre), Wi-Fi,
    Aware o Cable. Se guarda (`zero.linkMode`) y va junto a «Emparejar sin cable» y al VPS;
  - en la de captura, el botón dice EMITIR, el chip EMITIENDO, y la tarjeta Programa
    sustituye a la de Emisión al pod. Sus filas: Programa (fps, Mbit/s y RTT del SRT), SRT
    (destino y estado), Parte (Mbit/s, retrocesos y pérdidas), Detector, Geometría
    (`rig.json` o NOMINAL), Enlace (medio y estado) y Escalera.
- **`tools/qr_soporte_mac.sh`**: el QR Soporte de un «VPS» en el Mac (el MediaMTX de
  `tools/mediamtx-programa.yml`) con el `support_payload` de football-ai, sin tocar ese
  repo. El SVG lleva la passphrase: sale con permisos 600 en `$TMPDIR`. Comprobado que la
  app lo acepta (`VpsPairing.parse`).

**Decidido aquí** (pendiente de la revisión de Alexander)
- **`startProgram()` no lleva `saveVideo`**, aunque la tarjeta lo escribe así. La 4K sigue
  por `CaptureHostApi.start` (su reserva de disco y su aviso de IOS-57, ya probados), con la
  URL vacía. La copia .mov del programa va siempre: 6 Mbit/s, ~2,7 GB/h.
- **El modo B lo decide el enlace.** Con Multipeer, EMITIR es lo de hoy (cada cámara al pod),
  y es el valor por defecto hasta el corte (REF-49). Con un enlace de Network, la
  arquitectura B. Los dos móviles tienen que elegir el mismo.
- **El secreto del enlace, del entorno al Keychain**, hasta el QR de un solo uso de IOS-97.
  `ThisDeviceOnly`, sin sincronizar y nunca en el log. Un secreto del entorno que no es
  base64 falla, no cae en el guardado.
- **Retrocesos:** en el maestro, vistas que pedían las dos lentes y salieron de una (la
  parte no llegó en `PART_MAX_WAIT_MS`); las vistas que caen enteras en la lente del maestro
  no cuentan. En el esclavo, fotogramas con la vista extrapolada.
- **El detector** se busca en `Documents/bench-resources`: `RIG_DETECT` si se lanzó con él;
  si no, `players-centernet-mnv4.mlpackage` (el nombre de su ficha) o el primer
  `*centernet*.mlpackage`. No hay modelo en el registro todavía. Sin modelo, el director
  dirige sin detecciones y la fila Detector lo dice en rojo.
- **El informe de EMITIR va a `Documents/bench`**, junto a los del banco, para recogerlo con
  lo de siempre. El N0 lleva el partido y el `clock_domain` de verdad (`RigClockDomain`).
- **Cada móvil enseña lo suyo.** El maestro no ve el estado de la parte del esclavo más que
  por lo que recibe (Mbit/s, retrocesos y pérdidas).
- **La escalera solo se enseña.** No actúa todavía sobre el programa ni llama a
  `setCeiling` del publicador (anotado en IOS-56).
- **EMITIR sube al VPS; salir en las plataformas** es `stream/start` en el VPS (NUBE-21).

**Comprobado**
- `flutter test --no-pub`: **425, todos bien** (antes, 411). Los nuevos: 8 en
  `capture_session_test` (el enlace hasta `startLink`; sin programa con un solo móvil o en el
  banco del enlace; un toque en el maestro y parar; el programa que no arranca; el esclavo
  con la orden; la orden repetida al volver el esclavo; el estado cada segundo; calibrar
  contra el pod no se ofrece), 3 en `widget_test` (la tarjeta del maestro, SIN DESTINO y
  NOMINAL en rojo, el esclavo) y 3 en `role_page_test` (elegir y guardar el enlace, lo
  guardado al abrir, un valor que ya no existe). Con `FakeRigApi`, la API falsa del pipeline.
- `flutter analyze --no-pub`: sin avisos.
- `swift test --skip ModelBench`: **463 tests, 4 saltados, 0 fallos** (antes, 452). Los
  nuevos, `ProgramRunTests` (11).
- `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED.
- **El Runner, sin `flutter build` y sin tocar `build/ios`:** `swiftc -typecheck` de todos sus
  `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData. 0
  errores y los mismos 32 avisos que el Runner de f87b5a2 (comparados uno a uno).
- Hecho en un worktree aparte: el árbol principal no se tocó mientras los iPhone estaban en
  el ensayo.

**Aceptación de la tarjeta**, hoy:

| Criterio | Con fakes | Con los dos iPhone |
|---|---|---|
| Un toque en el maestro pone los dos en marcha | ✅ | pendiente |
| Parar los para | ✅ | pendiente |
| Los estados se ven en los dos móviles | ✅ | pendiente |

**Pendiente: la pasada con los dos iPhone, desde la pantalla y sin el banco**
1. **Instalar** (con los iPhone libres; sin `AUTO_ROLE`, para que salga la pantalla de lado):

   ```bash
   cd /Users/alexander/Trabajacion/fooball_ai_capturer && git pull --ff-only
   IZQ=8FBBECC4-5239-59C4-BE22-5EEFB5958863; DER=11BE5E85-F450-5C4B-B19E-ADA3EF036831; APP=com.logicielapplab.zero
   /Users/alexander/flutter_3.44.8/bin/flutter build ios --release
   for d in $IZQ $DER; do xcrun devicectl device install app --device $d build/ios/iphoneos/Runner.app; done
   ```

2. **El secreto del soporte al Keychain, una vez:** cerrar Zero en los dos y lanzarla con
   solo el secreto (el mismo fichero del banco):

   ```bash
   for d in $IZQ $DER; do xcrun devicectl device process launch --device $d \
     --environment-variables "{\"RIG_LINK_SECRET\": \"$(cat <fichero_secreto>)\"}" $APP; done
   ```

   Después, cerrarla desde el selector de apps. A partir de aquí se abre desde el icono.
3. **Lo que tiene que haber en cada iPhone** (de los bancos): `Documents/rig.json` (la
   calibración) y el CenterNet en `Documents/bench-resources`:

   ```bash
   for d in $IZQ $DER; do xcrun devicectl device info files --device $d --domain-type appDataContainer \
     --domain-identifier $APP 2>/dev/null | awk '{print $1}' | grep -E '^Documents/rig.json$|centernet[^/]*/Manifest.json$'; done
   ```

   Si falta el modelo se emite igual, sin detecciones (la fila Detector lo dice).
4. **El MediaMTX del Mac y su QR Soporte:**

   ```bash
   ( umask 077; openssl rand -hex 16 > /tmp/frase-programa )
   # Terminal 1:
   MTX_PATHS_PROGRAMA_SRTPUBLISHPASSPHRASE=$(cat /tmp/frase-programa) mediamtx tools/mediamtx-programa.yml
   # Terminal 2:
   tools/qr_soporte_mac.sh /tmp/frase-programa && open "$TMPDIR/qr-soporte-mac.svg"
   ```

   Contra el VPS, en lugar de esto, el QR de `https://<dominio>/pair`.
5. **En los dos iPhone, desde el icono:** el lado (17 IZQUIERDA, 16 Pro DERECHA; «Este móvil
   dirige» en el 17), «Enlace y emisión» en **Wi-Fi** (o **Aware**, ya emparejados), «Escanear
   QR Soporte» contra la pantalla del Mac («Emparejado con 10.10.18.101 · rig rig1») y «Abrir
   cámara». Esperar a LISTA en los dos: Enlace conectado, Reloj y Fase. El esclavo enseña
   «EMITE EL MAESTRO», sin poder pulsarlo.
6. **EMITIR en el 17** (con «Guardar vídeo» como se quiera). En unos segundos:
   - el maestro, EMITIENDO, y la tarjeta Programa: EN EL VPS, `30 fps · 6 Mbit/s · RTT … ms`,
     `publicando a 10.10.18.101:8890`, Parte `~8 Mbit/s · … retrocesos · … perdidas`,
     Detector `… pasadas`, Geometría `calibrada · rig.json`, Enlace y Escalera L0;
   - el esclavo, EMITIENDO, y en su tarjeta PARTE: `~8 Mbit/s al maestro · … retrocesos`;
   - en el Mac, a partir del minuto 1:

     ```bash
     ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,width,height,avg_frame_rate \
       -of compact rtsp://127.0.0.1:8554/programa
     (cd ../fooball_ai_streaming && uv run python tools/nube/sei_probe.py --source rtsp://127.0.0.1:8554/programa \
       --seconds 60 --out /tmp/m20-emitir.json)
     ffplay -rtsp_transport tcp rtsp://127.0.0.1:8554/programa   # el cosido con el director, a ojo
     ```

7. **PARAR en el 17:** paran los dos (el esclavo vuelve a «EMITE EL MAESTRO») y MediaMTX
   cierra la publicación. EMITIR y PARAR otra vez, sin reiniciar la app.
8. **El esclavo que vuelve:** con el programa en marcha, cerrar Zero en el 16 Pro, abrirla y
   «Abrir cámara»: el maestro sigue con una lente mientras tanto, y el esclavo arranca solo
   al conectar.
9. **Recoger los informes** (`purpose: production`):

   ```bash
   mkdir -p bench/emitir && for p in "$IZQ:left" "$DER:right"; do d=${p%%:*}; l=${p##*:}
     f=$(xcrun devicectl device info files --device $d --domain-type appDataContainer --domain-identifier $APP \
       2>/dev/null | awk '{print $1}' | grep -E "^Documents/bench/program-split-$l-[0-9]+\.json$" | sort | tail -1)
     xcrun devicectl device copy from --device $d --domain-type appDataContainer --domain-identifier $APP \
       --source "$f" --destination bench/emitir/; done
   ```

   En el del maestro: `publish.sessions` con 0 reconexiones, `program_frames`,
   `part_fallbacks`, `detect` y `rig: rig.json`; la copia en `Documents/program-…-<t>.mov`.
   Al acabar, borrar `$TMPDIR/qr-soporte-mac.svg` y `/tmp/frase-programa`.

**Fuera de IOS-58:** el secreto por QR (IOS-97); la escalera actuando sobre el programa; el
túnel y el `anchor` (IOS-65); salir en las plataformas (NUBE-21); un modelo del registro en
lugar de `bench-resources`.

**Siguiente paso**: la pasada de arriba con los dos iPhone (unos 15 min) y, si sale, la
misma contra el VPS.

## 2026-10-14 · Wi-Fi Aware 25 min con el 16 Pro en iOS 27: sin cortes, y aguanta 30 Mbit/s (IOS-14, SPK-08)

`link90` 1500 s con `RIG_LINK_INTERFACE=aware` (`bench/dos-moviles-20261014-0940`; la primera
recogida con 51e23fd, que funcionó y dio su resumen). El emparejado sobrevivió a actualizar
el 16 Pro a iOS 27.0.1.

| | Wi-Fi Aware 2026-10-14 (25 min) | Wi-Fi con router, partes (2026-10-06 / hoy) |
|---|---|---|
| Cortes / reconexiones | 0 / 0 | — |
| Órdenes / PTS | 748 de 748 / 747 de 750 | — |
| Partes enviadas / recibidas / perdidas | 27 176 / 26 962 / 213 (**0,78 %**), con escalones 0/10/30 Mbit/s y picos de 39 | a 12 Mbit/s el 0,75 %; a 15 Mbit/s el 6,4 % |
| RTT p50 / p90 / p99 | 5,5 / 7,8 / 10,8 ms | — |

**Por Wi-Fi Aware caben 30 Mbit/s de partes con menos pérdida que 12 por la Wi-Fi del
router.** Si se confirma en 90 min, la parte puede subir de 8 a 15-25 Mbit/s sin hubs, que
es lo que SPK-05 pide para bajar el ΔVMAF (3,7 a 8 Mbit/s). Queda la medida a 25 Mbit/s con
las 4K: hoy no cabían en el disco de la Mac ni del 16 Pro (8,85 GB libres, la reserva pide
8,75).

## 2026-10-14 · IOS-56 — el publicador del programa por SRT al VPS · 🚧 falta la pasada con los dos iPhone y los 30 min al VPS

**Dependencias: excepción deliberada** (pendiente de la revisión de Alexander). La tarjeta
depende de IOS-50 e IOS-53 (✅) y de IOS-54, IOS-55 e IOS-68, que tienen el código hecho y
siguen 🚧 solo por sus pruebas con el iPhone o el VPS. Se adelanta para llegar a la primera
prueba de emisión en la cancha.

**Hecho** (4a16e8e, ab2321e, f165519 y el commit «IOS-56d», que trae el banco y
`tools/mediamtx-programa.yml`; esta entrada entró antes, con 9a3306a)
- **RigCore, la lógica pura:**
  - `ProgramSendQueue`: unidades de acceso (vídeo con la SEI, AAC), no TS. Lo que se tira
    no deja huecos en los contadores de continuidad.
    - Acotada a 1 s de espera y a 160 unidades.
    - Ante congestión tira lo que espera y todo hasta el siguiente IDR, y lo pide una vez.
    - El audio se tira con el vídeo.
    - Empieza esperando un IDR.
  - `AdaptiveRate`: el AdaptiveBitRate de StreamPublisher portado.
    - `next`, backoff 0,8, un escalón de 0,6 Mbit/s cada 15 s tranquilos y suelo de
      1 Mbit/s.
    - El techo de la escalera (`setCeiling`) se aplica al momento.
  - `ReconnectBackoff` y las constantes de `ProgramPublish`, con sus unidades.
- **`RigNet/ProgramPublisher.swift`**: VideoEncoder + AacEncoder → TsMuxer → SrtSocket.
  - Multiplexa justo al enviar, con un TsMuxer nuevo por conexión.
  - Con el búfer de envío de SRT por encima de 750 ms no le mete más: retiene en la cola,
    y la cola decide si tira.
  - Un fotograma que SRT corta a medias también tira hasta el IDR.
  - Una muestra de SRT por segundo (`mbpsSendRate`, `msSndBuf`) para el bitrate, que sale
    por `onBitrate` hacia el codificador; el IDR sale por `onIdrRequest`.
  - Reconecta a los 3 s.
  - Las estadísticas (`Stats`, Codable):
    - bitrate, envío, RTT y búfer;
    - pérdidas, retransmisiones y tirados, por SRT y por la cola;
    - conexiones, reconexiones, rechazos e IDR pedidos;
    - `lastSentRigMs`, el `anchor` de IOS-65.
- **`SrtSocket`**: `sendBufferMs()` (srt_getsndbuffer, para mirarlo antes de cada envío) y
  `SrtStats()` a cero.
- **El banco split**: `RIG_SPLIT_PUBLISH=1`.
  - El maestro publica al bloque `srt` del QR Soporte del Keychain (`VpsPairingKeychain`,
    IOS-68).
  - Con `RIG_SRT_HOST`, en cambio, al destino de `RIG_SRT_PORT` (8890), `RIG_SRT_USER`,
    `RIG_SRT_PASS` y `RIG_SRT_PASSPHRASE`.
  - Solo publica mientras es maestro. Si deja de serlo, para.
  - El log (`[srt] …`) y el informe solo llevan host y puerto, nunca usuario, clave ni
    passphrase.
  - El informe gana `publish`: el origen del destino, host y puerto, las `Stats` de cada
    tramo de maestro y `program_encode_failures`.
- **`tools/mediamtx-programa.yml`**: el MediaMTX del VPS para `programa`, en el Mac.
  - SRT por IPv4 en 0.0.0.0:8890 y RTSP en 127.0.0.1:8554.
  - Cualquier usuario desde la LAN, con la passphrase por entorno.
  - Graba fMP4 en `bench/programa-mediamtx/` para mirar la SEI después.

**Decidido aquí** (pendiente de la revisión de Alexander)
- **Dos niveles ante congestión.** La tarjeta dice «búfer por encima del umbral: descarta
  hasta el IDR». Con el búfer de SRT por encima de 750 ms (la mitad de la latencia) se
  retiene; se tira hasta el IDR cuando la cola pasa de 1 s. Por encima de la latencia,
  libsrt tira paquetes sueltos (TLPKTDROP) y rompe fotogramas a medias.
- **La reconexión:** cada 3 s, como dice el ADR 0022 §8. El encargo pedía «backoff»: solo
  tras rechazos seguidos (clave o passphrase), 3-6-12-24-30 s, porque reintentar no lo
  arregla y a MediaMTX le cuesta 2 s cada intento. Un corte de red sigue a los 3 s. Un
  streamid o una passphrase que no valen (`SrtError.invalid`) no se reintentan: `.failed`.
- **Lo bajado durante un corte se deshace al reconectar.** Medido en el Mac: MediaMTX no
  avisa al caer y SRT tarda ~5 s en dar la conexión por rota (`SRTO_PEERIDLETIMEO`).
  Mientras, no sale nada y la regla del pod («sin salida, a la mitad») bajaba de 6 a
  1 Mbit/s; luego tardaba dos minutos en volver a 6. Ahora `AdaptiveRate.reset` vuelve al
  bitrate de antes del corte. Además, lo tirado en el corte ya no cuenta como congestión
  en la primera muestra de la conexión nueva: antes bajaba de 6 a 4,9.
- **Arranca al techo (6 Mbit/s).** El pod arrancaba a 4 por RTMP; aquí baja en un segundo
  si no cabe.
- **El suelo es 1 Mbit/s**, el del pod.
- **Sin destino, no publica** (`publish.target.source: none`) y lo dice una vez en el log.
  El puerto por defecto del entorno es 8890 (ADR 0022 §1).
- **El codificador es el mismo** para el SRT y para el .ts y el .mov del banco. El bitrate
  adaptativo baja también la copia local (IOS-57 tendrá que decidir si eso vale).

**Lo que se vio en el Mac**
- **La latencia ≤1,5 s no se puede cumplir con `SRTO_LATENCY` = 1500 ms.** TSBPD entrega
  cada paquete 1500 ms después de enviarlo. Del codificador a la lectura por RTSP, la sonda
  de NUBE-20 mide una mediana de **1582-1589 ms** con la red a 0 ms. En el maestro hay que
  sumar la espera de la parte (130 ms) y la cámara: unos 1,75 s del cristal al VPS. Lo
  decide SPK-07, que fija la latencia SRT; con 1000 ms saldrían ~1,25 s.
- **En macOS, MediaMTX con `:8890` solo escucha SRT por IPv6.** Los iPhone necesitan
  `0.0.0.0:8890`, que es lo que pone `tools/mediamtx-programa.yml`. El cortafuegos del Mac
  está apagado.
- **VideoToolbox tira fotogramas si no cabe.** Con un tercio del cuadro de ruido puro a
  6 Mbit/s, el modo de baja latencia con el QP topado en 45 entregó 61 de 241 fotogramas
  (`encodeFailures` 180). No baja la calidad: tira fotogramas. En el sintético se dejó en
  1/8 del alto y ruido de 6 bits. En la cancha (césped con mucho detalle, lluvia) puede
  pasar: por eso el informe trae `program_encode_failures`. Es de IOS-50; no se toca aquí.

**Comprobado**
- `swift test --skip ModelBench`: **452 tests, 4 saltados, 0 fallos**; antes, 422. Los
  saltados son el del iPhone, los dos de MediaMTX de IOS-55 y el de MediaMTX de este. Los
  nuevos:
  - `AdaptiveRateTests` (10), con los 3 de AdaptiveBitRateTests portados;
  - `ProgramSendQueueTests` (8);
  - `ProgramPublisherTests` (10), contra un socket falso. Cubren el IDR al conectar; SRT
    congestionado (retiene, a 1 s tira y pide IDR); el bitrate y el techo; el fotograma
    cortado; la reconexión con un TS nuevo; lo tirado sin conexión; los rechazos y el
    destino inválido; parar; y ningún secreto en estadísticas ni logs. Pasaron 20 veces
    seguidas;
  - `ProgramPublisherSrtTests`, contra el eco SRT con passphrase: 8 s del programa
    sintético (VideoEncoder 1080p30 a 6 Mbit/s con SEI y AacEncoder estéreo).
    - Llegan 241 de 241 fotogramas y 375 tramas, sin nada tirado.
    - h264 y aac, y la SEI del rigMs en los 241, creciente.
    - `ffprobe -show_frames` la ve en los 241.
- **`RIG_SRT_MEDIAMTX=1 RIG_PUBLISH_S=120 swift test --filter ProgramPublisherSrtTests`**:
  2 min contra MediaMTX 1.21.0 con SRT en 0.0.0.0, el programa sintético y MediaMTX
  matado a los 40 s y relanzado a los 2 s.
  - 6,45-6,69 Mbit/s enviados, 0 perdidos, 0 retransmitidos y 0 tirados por SRT.
  - **Una sola reconexión, la del reinicio:** detectada a los ~5 s y reconectada 3 s
    después.
  - Tirados por el corte: 151 fotogramas en la cola y 90 sin conexión, unos 8 s. Al
    reconectar, otra vez a 6 Mbit/s.
  - **Leído de vuelta por RTSP** (20 s, `ffmpeg -c copy`): h264 y aac. La SEI del rigMs
    está en los 549 fotogramas y `ffprobe -show_frames` ve `User Data Unregistered` en
    549 de 549.
  - **`tools/nube/sei_probe.py` de football-ai** sobre el mismo RTSP, sin tocar ese repo:
    600 fotogramas, 600 con SEI, `sei_ok: true` y 0 hacia atrás. Desfase mediano 1582 ms;
    parte variable p50 8 ms (el p95 es la ráfaga del GOP al engancharse).
- `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData propio): BUILD SUCCEEDED.
- **El Runner, sin `flutter build` y sin tocar `build/ios`:** `swiftc -typecheck` de todos
  sus `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData. 0
  errores y los 32 avisos de antes.

**Aceptación de la tarjeta**, hoy:

| Criterio | En el Mac (sintético, MediaMTX local) | Con el iPhone y el VPS |
|---|---|---|
| 1080p30 a ~6 Mbit/s | ✅ 6,5 Mbit/s | pendiente |
| Sin reconexiones sin causa | ✅ solo la del reinicio provocado | pendiente (30 min) |
| ffprobe ve H.264 y AAC | ✅ | pendiente |
| La SEI con el rigMs (ffprobe -show_frames y NUBE-20) | ✅ 100 % | pendiente |
| Latencia del cristal al VPS ≤1,5 s | ❌ por construcción con SRT a 1500 ms (1,58 s sin red) | SPK-07 |

**Pendiente**
1. **Los dos iPhone contra el MediaMTX del Mac.** Con el build de estos commits: el banco
   instala, salvo con `SIN_INSTALAR=1`. La IP del Mac hoy es 10.10.18.101.

   ```bash
   cd /Users/alexander/Trabajacion/fooball_ai_capturer
   ( umask 077; openssl rand -hex 16 > /tmp/frase-programa )   # 32 caracteres, sin imprimirla
   # Terminal 1, MediaMTX con SRT por IPv4 en :8890 y RTSP en 127.0.0.1:8554:
   MTX_PATHS_PROGRAMA_SRTPUBLISHPASSPHRASE=$(cat /tmp/frase-programa) mediamtx tools/mediamtx-programa.yml
   # Terminal 2, el banco de 10 min con el maestro publicando al Mac:
   BANCO_EXTRA="{\"RIG_SPLIT_PUBLISH\": \"1\", \"RIG_SRT_HOST\": \"$(ipconfig getifaddr en0)\", \"RIG_SRT_USER\": \"maestro\", \"RIG_SRT_PASS\": \"banco\", \"RIG_SRT_PASSPHRASE\": \"$(cat /tmp/frase-programa)\"}" \
     tools/banco_dos_moviles.sh split <secreto> 600
   # Terminal 3, a partir del minuto 1:
   ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,width,height,avg_frame_rate,sample_rate,channels \
     -of compact rtsp://127.0.0.1:8554/programa
   (cd ../fooball_ai_streaming && uv run python tools/nube/sei_probe.py --source rtsp://127.0.0.1:8554/programa \
     --seconds 120 --out /tmp/m20-banco.json)
   # Al acabar:
   python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["publish"], indent=1))' \
     $(ls -t bench/dos-moviles-*/izquierdo/bench/program-split-left-*.json | head -1)
   for f in bench/programa-mediamtx/programa/*.mp4; do echo "$f $(ffprobe -v error -select_streams v -show_frames \
     -show_entries frame_side_data=side_data_type -of csv=p=0 "$f" | grep -c 'User Data Unregistered')"; done
   ```

   - `publish.sessions[0]`: `reconnects` 0, `congestions` 0, `bitrate_min_bps` 6000000,
     `video_frames_sent` ≈ 18 000. También `rtt_ms`, `srt_packets_lost` y
     `srt_packets_retransmitted`.
   - `program_encode_failures` 0.
   - La sonda: `sei_ok` true. Aquí el desfase no es latencia: el rigMs es el reloj del
     iPhone.
   - El programa (6 Mbit/s) va por la misma Wi-Fi que las partes (8): mirar `parts_lost` y
     la latencia añadida frente a una pasada sin publicar.
   - El esclavo no publica: `publish.sessions` vacío en su informe.
2. **Los 30 min al VPS** (cuando haya VPS; sin relé, ninguna `FBAI_*_KEY`). Primero el
   QR Soporte en los dos iPhone (IOS-68) y luego:

   ```bash
   BANCO_EXTRA='{"RIG_SPLIT_PUBLISH": "1"}' tools/banco_dos_moviles.sh split <secreto> 1800
   # en el VPS, mientras dura:
   ffprobe -v error -show_entries stream=codec_name -of csv=p=0 rtsp://127.0.0.1:8554/programa   # h264, aac
   ffprobe -v error -read_intervals %+10 -select_streams v -show_frames -show_entries frame_side_data=side_data_type \
     -of csv=p=0 rtsp://127.0.0.1:8554/programa | grep -c 'User Data Unregistered'
   uv run python tools/nube/sei_probe.py --seconds 60        # NUBE-20, en football-ai
   ```

   Sin QR, por entorno: el mismo `BANCO_EXTRA` del paso 1 con `RIG_SRT_HOST` igual a
   `FOOTBALL_VPS_DOMAIN`, y `RIG_SRT_USER`, `RIG_SRT_PASS` y `RIG_SRT_PASSPHRASE` iguales a
   `FOOTBALL_PROGRAM_USER`, `_PASSWORD` y `_PASSPHRASE`. Sin iPhone, el sintético desde el
   Mac:

   ```bash
   cd ios/ZeroKit
   RIG_SRT_HOST=… RIG_SRT_USER=… RIG_SRT_PASS=… RIG_SRT_PASSPHRASE=… RIG_PUBLISH_S=1800 \
     swift test --filter ProgramPublisherSrtTests/testPublicaElProgramaEnMediaMtx
   ```

3. **Lo que no cubre IOS-56** (de otras tarjetas):
   - el 4409 que para el publicador (IOS-86);
   - el `anchor` del túnel con `lastSentRigMs` (IOS-65);
   - las `Stats` en la telemetría (IOS-89);
   - la escalera, que llama a `setCeiling`: el banco no la corre y publica con el techo
     de fábrica.

   El publicador solo vive en el banco split, porque el programa solo se compone ahí. El
   botón «Emitir» de verdad llega cuando el programa salga del banco.

**Siguiente paso**: la pasada del paso 1 con los dos iPhone. Si da 0 reconexiones y la SEI
al 100 %, los 30 min al VPS en cuanto esté desplegado.

## 2026-10-14 · Con los dos iPhone: el 16 Pro en iOS 27, la 4K del esclavo arreglada, la parte a 15 Mbit/s no cabe por Wi-Fi y el relevo de ida con a62d4ec

**iOS 27.** El 16 Pro se actualizó a iOS 27.0.1 (el 17 sigue en 26.6.1; Xcode 26.6 con el SDK
26.5). Instala, lanza y hace de esclavo sin cambios: 858 partes enviadas y 849 recibidas en
la primera pasada corta (`bench/dos-moviles-20261014-0752`).

**SPK-04 con la parte a 15 Mbit/s** (`bench/dos-moviles-20261014-0854`; el derecho recogido a
mano: el script murió tras el izquierdo, arreglado en 51e23fd):
- **La 4K del esclavo con de62055: 3,36 GB en 600 s, un segmento, 58 fotogramas descartados
  esperando el reloj, 0 saltos** (el 2026-10-11 eran 7,3 GB y un salto de +591 898 s). La del
  maestro, 600 s a 44,9 Mbit/s.
- **La parte a 15 Mbit/s por Wi-Fi no cabe**: 722 partes perdidas de 11 261 (6,4 %) y 1018
  peticiones de IDR, a 11,9 Mbit/s efectivos. Confirma los 8 Mbit/s de la enmienda del ADR
  0023: para 15/25/35 hace falta Ethernet (SPK-02). El VMAF de SPK-05 a 15 queda para
  entonces.
- 0 desgarros; latencia añadida p95 144 ms; GPU del maestro p99 4,5 ms, del esclavo 3,25.
- Una pasada anterior (`…-0817`) salió sin esclavo: su app seguía viva de la pasada de antes y
  el lanzamiento nuevo no la reinició (tardó 25 s). Cerrar Zero en los dos y comprobar que no
  queda ninguna antes de lanzar lo evitó.

**El relevo de ida con a62d4ec** (`bench/relevo-20261014-0928`): el maestro izquierdo se cierra a
los 94 s, el derecho se fuerza maestro y el izquierdo vuelve a los 172 s. El derecho, ya
maestro, compone **9065 fotogramas de dos lentes** con las partes del que volvió (p50 100 ms),
**0 desgarros**; las 4K de los dos, un segmento sin saltos. Con el `clock_pong` en host crudo,
las partes del que volvía habrían ido a ~591 898 s de las vistas y no habría ni uno de dos
lentes (lo que pasó, probablemente, el 2026-10-06). El viaje de vuelta queda por probar: al
matar una app se pierde su informe (solo se escribe al final).

**Cosido**: en el cuarto no calibra con los umbrales del repo (6-13 puntos en el solape, pared
lisa y la cama a 2-3 m); se usa `rig-tripode-20261011.json`, del trípode.

## 2026-10-14 · banco — la recogida de `banco_dos_moviles.sh`, rápida y sin cortes · 🚧 probada con un devicectl falso; falta una pasada real

`recoge` traía todo Documents/bench y Documents/calib (~10 min) y, con `set -e`, un listado vacío la cortaba en silencio (08:54, nada del derecho). Ahora trae solo lo de la pasada (`tools/recogida_pasada.py`, con su prueba): los .json con hora ≥ arranque − 30 s, su .ts (sin el vacío del esclavo), lo de `files` y las calib/<id>/ en la ventana `bench_start_rig_ms` de los informes; reintenta el listado 3 veces, apunta lo no copiado y termina con un resumen por lado.

## 2026-10-14 · IOS-54 — audio del micrófono: captura y AAC · 🚧 falta la pasada en el iPhone (10 min, palmadas y una llamada)

**Lo que ya estaba** (entradas del 2026-10-04 al 07): AudioCapture en la misma sesión que la
cámara, AacEncoder (AAC-LC 128 kbit/s en ADTS), el AAC en el .ts y el .mov del banco, la pista
de la 4K (IOS-57) y el PTS del micro pasado al reloj del host (`hostNs`). Todo detrás de
RIG_AUDIO=1, en mono, y medido: 84 374 tramas de 84 375 en 30 min, 0 huecos. Faltaban el
formato del contrato, el desfase A/V, la interrupción y el texto del permiso.

**Tres fallos de sincronía encontrados al medir en el Mac**
- **El cebado del codificador: el audio sonaba 44 ms tarde.** El AAC de Apple sale con 2112
  muestras de cebado delante y se sellaba la trama 0 en el instante de la primera muestra.
  Un decodificador de TS no las quita (ffmpeg 9.0.1 y AVAudioConverter: el chasquido de la
  muestra 48 000 vuelve en la 50 112). Ahora cada trama se sella 2112 muestras antes.
- **La deriva del micro: 2,67 ms/min, 240 ms a los 90 min.** El AAC se sellaba contando
  muestras, que van con el reloj del dispositivo de audio, ~45 ppm frente al del host (el de
  `capture_clock_skew_ms`, 2,8 ms/min). En el programa de 30 min del 2026-10-07
  (`bench/dos-moviles-20261007-1020`), el PTS del audio frente al del vídeo, en el orden del
  fichero, pasa de 184,7 ms en el minuto 0 a 263,4 ms en el 29: 2,67 ms cada minuto.
- **La 4K deriva igual.** AVAssetWriter apila las muestras del PCM sin mirar su PTS: con el
  micro a 300 ppm, el chasquido llega 3, 18, 36 y 51 ms tarde a los 10, 60, 120 y 170 s.

**Hecho** (3f8998d, 23738f2 y el commit de esta entrada)
- **`RigCore/Media/AudioTimeline.swift`, el eje del AAC.** Compara cada búfer con su sello y
  dice cómo meterlo:
  - hasta 1 ms, tal cual;
  - hasta 10 ms, una muestra por búfer (se repite o se quita), que absorbe la deriva sin
    oírse;
  - más, silencio delante o recorte;
  - más de 1 s, se reancla.

  Da también el silencio que pide el vigilante.
- **AacEncoder:**
  - estéreo 48 kHz 128 kbit/s, el contrato (`PROGRAM_AUDIO_*` de `tools/program_contract.py`,
    escritos a mano y fijados por un test); el micro mono va igual a los dos canales;
  - acepta Int16 o Float32, intercalado o no, y 48 kHz o lanza `.format`;
  - el rigMs ya descuenta el cebado y sigue el eje;
  - `syncStats` (silencio, recortes, correcciones finas, saltos) y `onAligned`.
- **AudioCapture:**
  - el codificador existe desde el principio, haya micro o no;
  - `keepAlive(nowRigMs:)`, el vigilante: si el micro calla 200 ms, el AAC sigue con silencio
    hasta «ahora − 200 ms»; cuando vuelve, el eje rellena hasta su sello;
  - las derivaciones `onPcm` (el PCM del micro con su rigMs, para el silbato de IOS-76) y
    `onAlignedPcm` (el PCM ya en el eje, para la 4K).
- **CaptureEngine:**
  - el micro va por defecto: `configure` pide el permiso; sin él, el programa va con
    silencio. RIG_AUDIO=0 lo quita del todo (los bancos «sin micro» lo necesitan ahora);
    RIG_AUDIO=1 deja además `audio-<t>.aac` y su informe, que gana `silence_ticks`,
    `silence_samples`, `dropped_samples`, `nudges` y `reanchors`;
  - el vigilante corre cada 100 ms en la cola del audio, con la cámara en marcha;
  - `audioDeviceInUseByAnotherClient` (una llamada, una alarma) para la sesión ENTERA. Ahora
    se quita el micro para que siga el vídeo, y vuelve al acabar la llamada
    (`CXCallObserver`) o la interrupción del audio (`AVAudioSession`);
  - la 4K graba `onAlignedPcm`, en estéreo, con el silencio de los cortes incluido;
    `recordingClockReport` gana `audio_not_ready`.
- El .ts del banco declara el AAC estéreo.
- `NSMicrophoneUsageDescription`: «El sonido del partido va con la emision y con la
  grabacion.» (sin tildes, como los otros textos del Info.plist). Ya no habla de sincronizar
  los móviles.
- **`tools/av_clap.py`, el desfase A/V con palmadas.**
  - El audio da el arranque de cada palmada.
  - El vídeo da el contacto con resolución de submuestra: el último intervalo que se mueve
    tras el de más movimiento, en la parte que se movió.
  - Saca la mediana total y la de cada minuto (palmadas al principio y al final dicen si
    deriva) y, con `--hojas`, una tira de fotogramas por palmada.

**Decidido aquí** (pendiente de la revisión de Alexander)
- **Estéreo = el mono duplicado.** La captura estéreo de verdad
  (`AVCaptureDeviceInput.multichannelAudioMode = .stereo`, iOS 18) traería además
  `windNoiseRemovalEnabled`, que vendría bien con viento en el mástil. Cambia la captura y
  hay que medirla en el iPhone: queda propuesta.
- **El micro por defecto y, sin permiso, silencio.** El programa lleva siempre AAC y el relé
  puede ir en `--audio source`.
- **Los umbrales del eje** (1 ms, 10 ms, 1 s) y **los del vigilante** (200 ms y cada
  100 ms) son míos. El relleno máximo cabe en la cola de 64 tramas.
- **Sin reintento periódico del micro.** Si el micro sigue ocupado, un reintento volvería a
  parar el vídeo. Vuelve solo con el fin de la llamada o de la interrupción.
- **Sin aviso «sin micro» en la pantalla.** Pediría tocar Pigeon y Dart (IOS-68 estaba en
  `lib/`). Queda en el log (`[audio] …`) y en el informe del banco.
- `SampleRetime` ya no lo usa el Runner; sigue en RigMedia con su test.

**Visto y no arreglado**
- **El .mov de la copia del programa** (ProgramRecorder, AAC sin recodificar): AVFoundation
  lo lee en su sitio, pero ffmpeg lo lee 44 ms tarde. Probado sin las tramas de antes del
  origen, con 44 ms de más y con `TrimDurationAtStart`: siempre 44 ms entre los dos. El .ts,
  que es lo que sale al VPS, lo lee bien ffmpeg. `av_clap.py` mide el .ts o la 4K.

**Comprobado**
- `swift test --skip ModelBench`: 422 tests, 3 saltados (el del iPhone y los dos de
  MediaMTX), 0 fallos; antes, 403. Los nuevos:
  - `AudioTimelineTests` (8): 90 min a ±150 ppm sin pasar de 1,05 ms;
  - `AacEncoderTests` (9, antes 2): estéreo, el chasquido en su instante (±0,2 ms), 3 min a
    150 ppm (±1,3 ms), un hueco de 500 ms, solo silencio, el PCM alineado y el contrato;
  - `AudioCaptureTests` (4): el micro callado 2 s con el vigilante (AAC sin huecos), sin
    micro, PCM ⇄ CMSampleBuffer y la pista de la 4K con AVAssetWriter a 300 ppm (±2 ms).
- **De punta a punta en el Mac:**
  - un .ts como el del programa (VideoEncoder, AacEncoder y TsMuxer) con 10 palmadas
    sintéticas: `av_clap.py` da +3,6 ms con desfase 0 y +17,9 ms con +15;
  - un .mov con PCM: +1,6, +13,6 y −23,6 ms para 0, +12 y −25;
  - antes del arreglo, el .ts habría dado unos +47 ms.
- `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData temporal): BUILD SUCCEEDED, sin
  avisos nuevos.
- **El Runner, sin `flutter build` y sin tocar `build/ios`:** `swiftc -typecheck` de todos
  sus `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData.
  0 errores y los 32 avisos de antes.

**Pendiente: la aceptación en el iPhone** (con el build de estos commits; los dos ya
aceptaron el permiso del micro con RIG_AUDIO=1)
1. **10 min con palmadas** delante de la lente del maestro, al principio y al final: unas
   10 cada vez, a un metro.

   ```bash
   BANCO_EXTRA='{"RIG_AUDIO": "1", "RIG_SPLIT_RECORD_4K": "1"}' \
     tools/banco_dos_moviles.sh split <secreto> 600
   python3 tools/av_clap.py bench/dos-moviles-<fecha>/izquierdo/bench/program-split-<t>.ts --hojas /tmp/palmadas
   python3 tools/av_clap.py bench/dos-moviles-<fecha>/izquierdo/bench4k/<t>/left-<t>.mov
   ```

   - **A/V ±20 ms** en el .ts y en la 4K, y la misma mediana el minuto 0 y el 9 (sin deriva).
   - **AAC continuo:** en `audio-<t>.json`, `gaps`, `failures` y `reanchors` a 0; `nudges`,
     unas 1300 (2,7 ms/min); `silence_samples`, solo el arranque. En el .ts:

     ```bash
     ffprobe -v error -select_streams a -show_entries packet=pts -of csv=p=0 program-split-<t>.ts \
       | awk 'NR>1 && ($1-p>1921 || $1-p<1919) {n++} {p=$1} END {print n+0, "saltos"}'
     ```

   - **Los fps intactos:** tic p5/p50 del informe como antes (29,4/30).
2. **Una llamada al maestro** durante un banco (teléfono o FaceTime de audio), 30 s, y
   colgar. Debe salir:
   - en el log, «[audio] otro cliente tomó el micrófono» y «el micrófono vuelve»;
   - el programa sin hueco en el vídeo, y el AAC continuo con silencio mientras dure;
   - la 4K en un segmento nuevo.

   No está comprobado que AVCaptureSession siga con el vídeo al quitarle el micro durante la
   interrupción: Apple no lo promete. Si no sigue, queda lo de antes (vídeo parado hasta
   colgar), y la recomendación de poner los dos móviles en «No molestar».
3. **Un móvil sin permiso de micro** (quitarlo en Ajustes): el programa sale con AAC de
   silencio y la 4K sin pista de audio.

**Siguiente paso**: la pasada en el iPhone de arriba. IOS-56 (el publicador) depende de
IOS-54 ✅. El código del publicador ya puede usar `AudioCapture.onFrame`: tramas estéreo con
su rigMs, también sin micro.

## 2026-10-14 · IOS-68 — el soporte emparejado con el VPS por el QR Soporte · 🚧 falta escanear el QR de un VPS real con el iPhone

**La dependencia circular con NUBE-16, resuelta empezando por aquí.** La tarjeta depende de
NUBE-16, que sigue 🚧 solo porque su aceptación («un escaneo configura el SRT y el túnel») es
justo esta tarea. El lado del VPS está hecho (a1962d5 en football-ai) y fija el contrato; las
dos se cierran juntas con la prueba del iPhone contra un VPS.

**Hecho** (be07067 y el commit de esta entrada)
- **El QR Soporte leído igual en Swift y en Dart:** `RigCore/Wire/VpsPairing.swift` y
  `lib/src/vps_pairing.dart` validan `{v:1, srt, tunnel, rig_id, rig_key}` (ADR 0022 §3) en el
  mismo orden.
  - Otra `v`: «actualiza la app». Sin `v`, o algo que no es un objeto JSON (el QR Mando, el de
    Cámaras): «no es el Soporte».
  - Campo a campo, y el error dice el campo, nunca el valor:
    - `srt`: host `[A-Za-z0-9.-]+`, puerto 1-65535, ruta sin «:», usuario y clave en
      `[A-Za-z0-9._-]`, streamid ≤512 y passphrase de 10 a 79;
    - `tunnel.url`: `wss`, con host y sin usuario;
    - `rig_id`: el patrón del VPS;
    - `rig_key`: un token cuyo `r` es el `rig_id` y que lleva el ámbito `tunnel`.
  - Al escanear, un `rig_key` caducado (`e` ≤ ahora, en hora de pared) se rechaza. Leído del
    Keychain, no: el SRT sigue valiendo, y el túnel lo dirá con el 4401.
  - El token se lee sin firma: `peekClaims` en `control_token.dart` (el `peek_claims` de
    Python) y su gemelo en Swift.
- **39 casos compartidos** en `ios/ZeroKit/Tests/RigCoreTests/Fixtures/vps_pairing_cases.json`,
  que leen `VpsPairingTests` y `test/vps_pairing_test.dart`. El QR bueno salió de
  `support_payload` del VPS (a1962d5), con el entorno de sus tests.
- **Keychain por Pigeon:** `loadVpsPairing`, `saveVpsPairing` y `clearVpsPairing`. Guardar
  valida antes con `VpsPairing` de RigCore y, si no vale, falla con `vps_pairing` y el campo.
- **El formato del ítem, el que leen IOS-56 e IOS-65:**
  - genérico, servicio `football-ai.vps`, cuenta `soporte`;
  - `AfterFirstUnlockThisDeviceOnly` y sin sincronizar;
  - los datos son el JSON del QR tal cual, en UTF-8 y sin espacios alrededor.
- **Cómo se lee:**
  - en Swift (IOS-56), `VpsPairingKeychain.load()` en `CaptureHostApiImpl.swift` da
    `VpsPairing?`, y su `.srt` es el `ProgramSrtTarget`, con streamid y passphrase ya
    comprobados;
  - en Dart (IOS-65), `VpsPairing.load(api)` da `tunnel` (`wss://…/tunnel/v1`), `rigKey` (el
    Bearer) y `expiredAt(nowS)`.
- **La tarjeta «VPS» de la pantalla de lado**, debajo de «Emparejar sin cable»:
  - sin nada, «Sin emparejar» y «Escanear QR Soporte»;
  - emparejado, «Emparejado con <dominio>» y «rig <id> · caduca en 11 h 59 min», o, en
    rojo, «la llave del túnel caducó: escanea otra vez»;
  - los botones «Escanear otra vez» y «Desemparejar»;
  - un QR que no vale no toca lo guardado, y se dice por qué.
- **El QR Soporte leído desde «Escanear QR» del servidor** va al emparejado y nunca al campo
  «Servidor», que se ve en pantalla. El lector dice ahora «Apunta al QR del panel».
- **El servidor del pod sale de `UserDefaults`**, la nota pendiente del ADR 0017 §4:
  `loadServerHost` y `saveServerHost` usan el Keychain (`football-ai.servidor`, `host`) y
  mudan lo que hubiera en `UserDefaults` la primera vez que se lee.
- **Logs:** StreamPublisher ya no escribe la URL del pod con usuario, clave, streamid y
  passphrase (`redactedForLog`), y el error de una URL no válida no la repite.

**Decidido aquí** (pendiente de la revisión de Alexander)
- **El Keychain guarda el texto del QR, no un formato propio.** Los dos lados lo leen con el
  mismo código, y no hay nada que migrar si el QR crece dentro de la v1.
- **Un campo de más dentro de la v1 se ignora:** lo incompatible lo marca `v`.
- **Solo `wss`,** porque el `rig_key` va en la cabecera. Un banco con `ws://` necesitaría un
  QR propio.
- **No se comprueba la ruta del túnel**, se usa la que trae el QR, ni que el host del túnel y
  el del SRT coincidan. El dominio que se enseña es el del túnel.
- **La caducidad se mira al escanear y al pintar la pantalla.** No hay temporizador que avise.
- **Rotar en el VPS no lo ve la app hasta el 4401 del túnel** (IOS-65); entonces se escanea
  otra vez.
- **Desemparejar no pide confirmación:** se vuelve a escanear en un momento.
- **Los dos `mando_page_test` que pulsan «Solo mando»** necesitaban un `pump()` tras
  `ensureVisible`: la tarjeta nueva lo deja fuera de los 1000 px de la prueba.

**Comprobado**
- `swift test --skip ModelBench`: 403 tests, 3 saltados (los mismos) y 0 fallos; antes, 399.
  Los nuevos son `VpsPairingTests` (4): los casos compartidos, el Keychain sin caducidad,
  ningún secreto en `description`, `debugDescription` ni en los errores, y el token como en
  Python.
- `flutter test --no-pub`: 411, todos bien; antes, 361. `vps_pairing_test` (45) y 5 en
  `role_page_test`: escanear y guardar (nada en `shared_preferences` ni en pantalla), otra
  versión, caducado y QR Mando sin guardar, lo guardado al abrir y desemparejar, caducado en el
  Keychain, y el QR Soporte por «Escanear QR» del servidor.
- `flutter analyze --no-pub`: sin avisos. `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData temporal): BUILD SUCCEEDED, con el
  aviso de siempre de `VtConcurrencyBench`.
- **El Runner, sin `flutter build` y sin tocar `build/ios`:** `swiftc -typecheck` de todos sus
  `.swift` contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData
  (`Debug-iphoneos`). 0 errores y los 32 avisos de antes.

**Pendiente**
- **La prueba en el iPhone contra un VPS real.** No hay VPS desplegado. Los pasos:
  1. En el VPS, por la tubería de `deploy/vps.sh`: `FOOTBALL_VPS_DOMAIN`,
     `FOOTBALL_PROGRAM_USER`, `_PASSWORD` y `_PASSPHRASE`, `FOOTBALL_TUNNEL_SECRET`,
     `FOOTBALL_PANEL_PASSWORD` y, si se quiere, `FOOTBALL_RIG_ID`. Abrir
     `https://<dominio>/pair` con la contraseña del panel.
  2. En cada iPhone, en la pantalla de lado, «Escanear QR Soporte». Tiene que decir
     «Emparejado con <dominio>» y «rig <id> · caduca en 12 h».
  3. Cerrar la app y volver a abrirla: sigue emparejado.
  4. «Rotar» en `/pair` y escanear el QR nuevo: lo sustituye.
  5. «Desemparejar»: vuelve a «Sin emparejar».
  6. Bajar el contenedor de la app (`xcrun devicectl device copy from … Library/Preferences`)
     y comprobar que el plist no tiene la clave, la passphrase ni el `rig_key`; y la consola
     de Xcode durante los pasos 2-5, lo mismo. El barrido automático es de IOS-97.
- **«Un escaneo configura el SRT y el túnel», en sentido completo**, llega con IOS-56, que
  publica con `VpsPairingKeychain.load()`, e IOS-65, que abre `tunnel` con `rigKey`. Los dos
  tienen que leer el Keychain al arrancar y al reconectar: desemparejar hoy no corta nada,
  porque no hay nada que cortar.
- **Para la referencia** (football-ai; desde aquí no se toca): exportar un dorado del QR
  (`support_payload` con un entorno fijo, con casos buenos y malos) que sustituya a
  `vps_pairing_cases.json`, y anotar en NUBE-16 que la app ya lo lee.
- **El Runner no tiene tests del Keychain ni de `redactedForLog`:** no hay target que corra
  en el Mac. Lo cubren la prueba del iPhone y el barrido de IOS-97.

## 2026-10-14 · IOS-55 — libsrt directo y SrtSocket · 🚧 falta la pasada de 10 min contra el MediaMTX del VPS

**Hecho** (dd88e5a, 13b096e, dc80bec y el commit de esta entrada)
- **`tools/build_libsrt.sh` → `ios/ZeroKit/Frameworks/CSrt.xcframework`**:
  - libsrt 1.5.7 y mbedTLS 3.6.7 LTS (solo `libmbedcrypto`), bajados con su SHA-256
    fijado; iPhone, simulador y Mac (arm64), estático, 1,5 MB por rodaja.
  - Sale igual byte a byte compilado en dos carpetas distintas (mismo Xcode 26.6): los
    `__FILE__` van sin la ruta de trabajo. cmake del PATH o, si no hay, por `uvx`.
  - El binario se commitea (4,5 MB) para que `swift test`, `git archive` y el Runner
    funcionen sin pasos previos. Las licencias van en `Frameworks/licenses/`.
- **Convive con el libsrt de SRTHaishinKit** (que no es el mismo: 1.5.4 con OpenSSL):
  - Los dos exportan `srt_*` y `srt::*`. Con dos archivos estáticos, el primero en el
    enlazado gana y, si el nuestro iba primero, salían símbolos duplicados (`g_Sync`,
    `CHash::insert`): las piezas de uno y otro no casan.
  - Cada rodaja es un solo objeto prelinkado que exporta solo la API C renombrada a
    `csrt_*` (`csrt.h` la renombra para Swift). El C++, haicrypt y mbedTLS quedan
    ocultos; el script falla si se escapa algo.
  - Probado enlazando los dos archivos en los dos órdenes: limpio, y cada uno usa el
    suyo. Esto dura hasta IOS-91, cuando se quite HaishinKit.
- **RigCore/Wire/ProgramSrt.swift** (ADR 0022 §1-§3):
  - las constantes: `programa`, 1500 ms, 1316 B, 512 caracteres, 2-5 partes, passphrase
    de 10 a 79 y 5 s de timeout al conectar;
  - `ProgramSrtTarget`, el bloque `srt` del QR Soporte, decodificable y sin secretos al
    escribirlo en un log;
  - `ProgramSrtStreamId`: compone `publish:programa:<user>:<pass>[:<query>]` y valida
    cualquier streamid antes de salir.
- **RigNet/SrtSocket.swift**: caller y live, IPv6 e IPv4, `SRTO_LATENCY`,
  `SRTO_PASSPHRASE`, `SRTO_STREAMID`, envío sin bloquear en mensajes de 1316 B (devuelve lo
  que entró si el búfer se llena) y `stats()` con `srt_bstats`. `SrtError` nunca lleva el
  streamid ni la passphrase. `SrtLibrary` arranca libsrt una vez.
- DEPENDENCIES.md: libsrt propio (MPL-2.0) y mbedTLS (Apache-2.0).

**Decidido aquí** (pendiente de la revisión de Alexander)
- **La passphrase «sacada del Keychain»:** SrtSocket la toma de `ProgramSrtTarget`, el
  bloque `srt` del QR Soporte. Lo guarda en el Keychain IOS-68, que fija el formato del
  ítem, e IOS-56 lo lee y se lo pasa. IOS-55 no escribe código de Keychain.
- **`ProgramSrt.latencyMs` va escrito a mano** con la referencia a
  `PROGRAM_SRT_LATENCY_MS`: ningún generador de football-ai lo exporta
  (`export_overlay_spec` solo lleva el tamaño y los fps). Si SPK-07 lo cambia, hay que
  cambiarlo aquí también; `ProgramSrtTests` lo fija en 1500.
- **`SRTO_LATENCY`**, como dice la tarjeta, fija las dos latencias. Para el que envía la que
  cuenta es `SRTO_PEERLATENCY`, y es la misma.
- **El simulador solo en arm64**, sin x86_64.
- **El binario en git y la API con prefijo `csrt_`** (arriba): lo pide la convivencia con
  HaishinKit, y el prefijo se puede quitar en IOS-91 si se quiere.
- **5 s de timeout al conectar** (`ProgramSrt.connectTimeoutMs`), no los 3 de SRT: ver
  abajo lo de MediaMTX.

**Lo que se aprendió de MediaMTX 1.21**
- Contesta `SRT_REJ_PEER` (2) tanto a una passphrase mala como a un usuario o una clave
  malos. Su log sí los distingue: «invalid passphrase» y «failed to authenticate».
  libsrt en escucha (`srt-live-transmit`) da `BADSECRET` (10) y, sin passphrase,
  `UNSECURE` (11).
- **Espera 2 s antes de rechazar unas credenciales malas** (contra la fuerza bruta). Con
  los 3 s de `SRTO_CONNTIMEO` por defecto, una de cada pocas veces llegaba como timeout
  (con el Mac cargado). Por eso `ProgramSrt.connectTimeoutMs` es 5 s: el publicador
  (IOS-56) tiene que poder decir «clave mala» y no «sin red». La cadencia de reconexión
  es otra cosa.
- En el Mac, con `srtAddress: :<puerto>`, escucha solo por IPv6: la prueba conecta a `::1`
  y así cubre IPv6.
- `srt-live-transmit` solo vacía su stdout al salir: el eco se para con SIGINT antes de
  leerlo.

**Comprobado**
- `swift test --skip ModelBench`: 399 tests, 3 saltados (el del iPhone y los dos de
  MediaMTX, que piden variable), 0 fallos; antes 384. Los nuevos:
  - `ProgramSrtTests` (8): el streamid del VPS y el del banco, «:», «~» y espacios,
    vacíos, 5 partes y 512 caracteres, la passphrase, el bloque del QR y las constantes;
  - `SrtLibraryTests` (1): enlaza y es la 1.5.7;
  - `SrtSocketTests` (4), contra `srt-live-transmit` en escucha con passphrase:
    - 1 MB a ~8 Mbit/s vuelve byte a byte;
    - las estadísticas cuadran;
    - una passphrase errónea se rechaza (10), y también sin passphrase (11);
    - el streamid y la passphrase se comprueban antes de salir;
    - los errores no llevan secretos.
- `RIG_SRT_MEDIAMTX=1 swift test --filter SrtMediaMtxTests` (MediaMTX 1.21.0 local, la
  config del VPS reducida a SRT, usuario y clave y `srtPublishPassphrase`):
  - 20 s de 720p30 H.264 a 6 Mbit/s CBR con AAC: 6,53 Mbit/s, 0 perdidos, 0 tirados;
  - leído de vuelta con `read:programa:…`: ffprobe ve h264 y aac;
  - passphrase y clave malas, rechazadas.
- **Los 10 min contra el MediaMTX local** (`RIG_SRT_SOAK_S=600`, con el código y el binario
  de estos commits):
  - 600 s a 6,55 Mbit/s: 377 800 paquetes y 491 MB;
  - 0 perdidos, 0 retransmitidos y 0 tirados;
  - conectado y con `stats()` legible en cada segundo, y ningún `send` se quedó corto;
  - leído de vuelta, h264 y aac;
  - las dos credenciales malas, rechazadas.

  Una primera pasada igual dio lo mismo en el envío, pero la clave mala llegó como
  timeout con 3 s (el Mac compilaba a la vez). De ahí los 5 s.
- `tools/check_layers.sh`: limpio.
- RigNet compilado para iOS, en el iPhone y en el simulador, con xcodebuild (derivedData
  temporal). Sin avisos.
- **El Runner enlaza con los dos libsrt** sin `flutter build` y sin tocar `build/ios`:
  - sobre una copia de `ios/` con las dos fases de Flutter anuladas, xcodebuild Release
    para iOS con derivedData y paquetes propios: BUILD SUCCEEDED;
  - sin avisos nuevos;
  - el binario lleva los 13 `csrt_*` que usa RigNet y los 21 `srt_*` de HaishinKit.
- El commit dc80bec, sacado con `git archive`, compila solo, con el xcframework
  commiteado.

**Pendiente**
- **La aceptación contra el MediaMTX del VPS: 10 min.** Desde el Mac, con un MediaMTX y un
  VPS de verdad:

  ```bash
  cd ios/ZeroKit
  RIG_SRT_HOST=<FOOTBALL_VPS_DOMAIN> RIG_SRT_USER=<FOOTBALL_PROGRAM_USER> \
  RIG_SRT_PASS=<FOOTBALL_PROGRAM_PASSWORD> RIG_SRT_PASSPHRASE=<FOOTBALL_PROGRAM_PASSPHRASE> \
  RIG_SRT_SOAK_S=600 swift test --filter SrtMediaMtxTests
  # en el VPS, mientras dura:
  ffprobe -v error -show_streams rtsp://127.0.0.1:8554/programa
  ```

  - Allí `programa` no se lee de vuelta desde fuera: lo mira ffprobe en el VPS.
  - Que sea sin relé (ninguna `FBAI_*_KEY`), o la carta de ajuste sale al aire.
  - MediaMTX lo graba 48 h en `recordings/programa`.
- El SrtSocket en el iPhone llega con IOS-56: el publicador, la cola, el IDR ante
  congestión y la reconexión.

**Siguiente paso**: IOS-56 (el publicador del programa). De sus dependencias faltan IOS-68
(el QR Soporte en el Keychain) e IOS-54 en ✅.

## 2026-10-11 · SPK-04 y SPK-05 medidos en el Mac sobre la pasada del trípode: PSNR ✅, ΔVMAF intermedio

Sobre `bench/dos-moviles-20261011-1506` (10 min del guion de SPK-04 por Wi-Fi, las dos 4K),
con las herramientas de football-ai:

- **PSNR en la rampa de la costura (SPK-04, `tools/spk04_psnr.py`, `--every 10`): p5 40,8 ·
  p50 42,0 · media 42,1 dB; el 100 % ≥38 dB** (404 fotogramas; peor 40,2 dB). El primer
  cálculo dio p50 19,9 dB por un fallo de la medida (la máscara de la rampa cruzaba el
  marcador y la franja, que la referencia de Python no pinta); arreglado en e6ac376 midiendo
  solo las filas sin gráfico (194-956). Lo que queda (~2 niveles rms) es códec y redondeo:
  el tramo del esclavo da 39,8-41,1 dB y el del maestro 41,5-43,0.
- **VMAF por mitades (SPK-05, `tools/vmaf_halves.sh`, `--every 3`, parte a 8 Mbit/s por
  Wi-Fi): maestro 97,2 (p5 95,0) · esclavo 93,5 (p5 89,0) · ΔVMAF 3,7 → intermedio** (éxito
  ≤2, abandono >5). Es la doble compresión de la mitad del esclavo (la parte H.264 a 8
  Mbit/s y luego el programa); la tarjeta pide repetir con la parte a 15/25/35 Mbit/s:
  por Wi-Fi solo cabe 15 (12 ya perdía el 0,75 %); 25/35 esperan a Ethernet (SPK-02).

Con esto, de SPK-04 se cumplen 0 desgarros, la GPU del esclavo y el PSNR; quedan la GPU del
maestro (p99 5 ms frente a 3: su mitad y la composición van en el mismo command buffer) y
la latencia ≤120 ms, que supone Ethernet.

## 2026-10-11 · El maestro contesta la hora en el reloj del soporte: el que vuelve tras un relevo ya no se va 591 898 s (IOS-12, IOS-13, IOS-85; ADR 0023 §4, enmienda) · 🚧 falta el relevo de ida y vuelta con los dos iPhone

**El fallo**, apuntado en la entrada de abajo («la 4K del esclavo») y confirmado en el código:
- `RigLinkSession.handle(.clockPing)` contestaba `t2 = llegada` y `t3 = hostNowNs()`, en el
  host crudo.
- El promovido (`forceMaster`, IOS-85) conserva su `clock`. Los `clock_pong` solo los coge
  el esclavo (`guard !isMaster`), así que al promoverse deja de recibir muestras: la recta
  queda congelada y `offsetAt` sigue extrapolándola.
- Todo lo demás del promovido va en host + recta: su cámara (`CaptureEngine`), el anillo,
  las vistas (`SplitBench.rigNowMs`), la calibración (`CalibrationPairs.nowRigMs`) y el
  `rigClockSnapshot` de Dart. El pong era lo único en host crudo.
- El maestro de antes, al volver de esclavo, despejaba el host del promovido menos el suyo:
  ~+591 898 s, en vez de ~0.

**Arreglo**
- **`RigLinkSession`:** `t2` y `t3` salen con `clock.toRigTimeNs(…)`. Sin muestras el
  desfase es 0, así que un maestro que nunca fue esclavo contesta byte a byte lo mismo.
- **`AdHub.nowRigMs`** (la franja, IOS-48) suponía lo mismo: «el soporte, en el maestro, es
  su host».
  - La lista y los overrides se fechaban en el host crudo, y la franja se pide con el
    instante del programa, que va en el soporte.
  - En un promovido se habría quedado sin anuncios o en un punto cualquiera de la lista.
  - Ahora suma el desfase del reloj del enlace: `AdHub.clock`, que ponen `startLink` y
    `stopLink`.
- **El contrato** se enmienda en football-ai: ADR 0023 §4 y la fila de `clock_pong` de la
  decisión 1, pendiente de la revisión del propietario.

**Revisado y sin cambios.** Lo que cruza al otro móvil ya iba en el soporte o no lleva hora:
- **El latido** no lleva sellos (rol, term, escalera, estado y el último seq). La salud usa
  el host, pero solo dentro del móvil.
- **Las vistas** (`targetRigMs`), **las partes y `no_part`** (`frameRigMs`) y **las
  detecciones** van en el soporte.
- **`pts_reply`** (`recentFramePtsNs`): los PTS ya llevan el desfase.
- **La calibración** (`calibration_capture`): los destinos salen del anillo o de
  `nowRigMs()`, con desfase, y el esclavo espera con el suyo.
- **La réplica:** el cronómetro sale de `rigClockSnapshot` (host + desfase).
- **La llegada de `onPart`** va en host, pero el banco split no la usa (usa `rigNowMs()`), y
  el link-bench mide en uptime de punta a punta.
- **El Multipeer** (`RigLink.swift`) también contesta en host crudo, pero allí no hay
  relevo (el rol es el lado) ni RigClock nativo. Se queda como está.

**Los casos compartidos del reloj** (`rig_clock_cases.json`, `lib/src/rig_clock.dart`) no
cambian. Prueban la cuenta a partir de los cuatro sellos, y el dominio de `t2`/`t3` no
entra. Dart recibe por `onClockStamps` los mismos sellos, ya en el soporte.

**Comprobado**
- `swift test --skip ModelBench`: 384 tests, 1 saltado, 0 fallos. Los 2 nuevos de
  `RigLinkSessionTests` separan los dos relojes de host 591 898 s:
  - **sin relevo:** el pong sale en el host del maestro (t1 − Δ < t2 ≤ t3 < t4 − Δ), el
    esclavo despeja −591 898 s y el maestro no tiene muestras;
  - **relevo:** A maestro y B esclavo sincronizado. Cae A y B hace `forceMaster`. Vuelve el
    enlace, B manda por term 2 y A, ya de esclavo, cae en el soporte de B: diferencia
    < 1 ms y desfase de A ≈ 0. La recta de B no recibe muestras. Sin el arreglo falla con
    591 898 000 000 000 ns.
- `tools/check_layers.sh`: limpio.
- `flutter build ios --release --no-pub --dart-define=AUTO_ROLE=left
  --dart-define=PREFERS_MASTER=true`: compila (Runner.app de 28,1 MB), sin instalar.

**Qué mirar con los dos iPhone: el relevo de ida y vuelta.**
- **La pasada.** Los dos con
  `BANCO_EXTRA='{"RIG_SPLIT_SCRIPT": "spk04", "RIG_SPLIT_RECORD_4K": "1", "RIG_SPLIT_FORCE_AT_S": "100"}'`
  y `tools/banco_dos_moviles.sh split <secreto> 600`.
  1. A los ~90 s se mata la app del izquierdo (`xcrun devicectl device process terminate`).
     El derecho se promueve a los 100 s.
  2. A los ~170 s se relanza el izquierdo con el mismo entorno. Hacen falta ≥150 s tras la
     vuelta: con 67 s, en la pasada del 6-oct, no llegó a conectar.
  3. **La vuelta**, si da tiempo: se mata el derecho a los ~90 s del izquierdo relanzado. El
     izquierdo se fuerza a sus 100 s y luego se relanza el derecho.
- **El derecho, promovido:**
  - `two_lens_frames` > 0 después de la vuelta, porque el guion de SPK-04 cruza la costura
    cada 20 s;
  - `torn_frames` 0;
  - `part_age_ms` p50 ~90-150 ms. Con el fallo, la parte del que vuelve llegaba fechada
    ~591 898 s lejos y no casaba con ninguna vista.
- **El izquierdo, de vuelta como esclavo:**
  - `rec4k.clock.clock_jump_segments` 0 y un solo segmento: arranca de maestro provisional
    con desfase 0 y la primera muestra da ~0. Con el fallo, 1 segmento más por el salto;
  - `ffprobe` de su 4K y de su programa da la duración real.
- **Los `bench_start_rig_ms` de los dos informes** se separan lo que se tardó en relanzar
  (~170 s), no ~591 898 s.
- **Si se hace la vuelta,** lo mismo con los papeles cambiados. El derecho, al volver,
  tiene que caer otra vez en ~−Δ, el desfase de su primera sincronización.

## 2026-10-11 · La 4K del esclavo decía durar 592 497 s: el reloj del soporte cambiaba a mitad de fichero (IOS-57, IOS-13, SPK-04) · 🚧 falta la pasada con los dos iPhone

**Qué pasaba.** En la pasada de SPK-04 (`bench/dos-moviles-20261011-1506`), la 4K del esclavo
(16 Pro, `derecho/bench4k/1791752830/right-1791752830.mov`) dice durar 592 497 s y pesa 7,3 GB:
≈97 Mbit/s reales en vez de 45. La del maestro está bien: 599,9 s y 45,1 Mbit/s. Con ffprobe,
los 70 primeros fotogramas llegan hasta 2,27 s y el siguiente está en 591 899,6 s.

**Por qué, en el código.**
- `CaptureEngine.captureOutput` sella cada fotograma con
  `hostNs + (rigClock?.offsetAt(ns:) ?? clockOffsetNs)`.
- El escritor abría su sesión con el sello del primer fotograma, tuviera reloj o no.
- En el esclavo, `RigClock.offsetAt` devuelve 0 sin muestras: es el reloj de su host. Con la
  primera muestra devuelve ya el desfase de verdad (con menos de 3 muestras, el de la última),
  ~591 898 s: la distancia entre los arranques de los dos iPhone.
- La 4K arranca con la cámara, antes que el enlace. El informe del esclavo da el control arriba
  a los 2343 ms y la primera trama por medios a los 2362: es el primer `clock_pong`, a los 70
  fotogramas.
- El codificador reparte el bitrate sobre esa duración absurda: de ahí el doble de bytes.
- En el maestro el desfase es 0 siempre: nadie le pregunta la hora a él, y no pasa.
- **El audio de la 4K** (`appendAudio`) lleva el mismo desfase: con micro, la primera trama
  después del salto también habría alargado el fichero.

**Arreglo**
- **`RigCore/Runtime/RecordingClockGate`** (lógica pura) decide qué se hace con cada fotograma:
  - **Sin reloj no se abre la sesión.** Abre con el maestro (la referencia del reloj, ADR 0023
    §4), con el móvil solo o con Multipeer. En un esclavo, solo cuando RigClock tiene
    estimación (3 muestras, ~0,5 s de ráfaga). Lo que tira mientras tanto lo cuenta.
  - **Si la espera pasa de `RecordingPolicy.clockWaitMaxNs` (30 s), graba con su host.**
    Perder la 4K entera, si el enlace no sube, es peor que un segmento sin emparejar. Cuando
    llegue la estimación, el salto abre otro segmento.
  - **Un salto del desfase cierra el segmento.** Si cambia más de
    `RecordingPolicy.clockJumpSegmentNs` (100 ms) entre dos fotogramas, el fichero se cierra
    entero y el fotograma abre el siguiente (`right-<t>-2.mov`, como tras un corte). Si el
    reloj aún no vale, el nuevo espera a la estimación: es el caso del maestro que vuelve de
    esclavo tras un relevo. Las correcciones normales son de ms y la deriva de µs por
    fotograma; el umbral es lo que las separa de un cambio de dominio.
  - **Un sello que no avanza se tira.** Una corrección de más de un fotograma hacia atrás,
    por debajo del umbral, dejaba el PTS detrás del anterior. El escritor pasa entonces a
    `.failed` y la 4K muere en silencio.
  - **El audio va con el segmento del vídeo.** Una trama con otro desfase (el reloj saltó y
    el vídeo aún no cortó) se tira y se cuenta.
- **`CaptureEngine`.**
  - Pregunta a la puerta por cada fotograma y por cada trama de audio.
  - Corta el segmento en la propia cola de captura (`rollSegmentForClockJump`).
  - El número y el fichero del segmento van bajo un cerrojo, porque ahora cambian también en
    esa cola.
  - `setClockReference`: `CaptureHostApiImpl` le pasa el rol de cada `onRigRole`. Al abrir
    el enlace empieza de esclavo.
- **El estado y el informe.**
  - `CaptureStatus` (Pigeon) gana `recordingClockWaitFrames` y `recordingClockJumpSegments`,
    y el panel local, `rec_clock_wait_frames` y `rec_clock_jump_segments`.
  - El informe del banco split gana `rec4k.clock`: `clock_wait_frames`,
    `clock_jump_segments`, `sessions_without_clock`, `out_of_order_frames` y
    `audio_dropped_on_jump`.

**¿Lo tienen otras grabaciones?**
- **El programa (.ts y .mov del banco), en esta pasada no.** Lo compone el maestro, con
  desfase 0: ffprobe da 599,9 s en los dos.
- **El programa sí podría tenerlo con un relevo y vuelta** (A maestro → B promovido → A
  vuelve de esclavo → A promovido otra vez). El .ts y el .mov se abren una vez por pasada.
- **Eso, y la 4K del que vuelve, vienen de un fallo del enlace, no de la grabación:**
  - el `clock_pong` contesta con el reloj de host crudo (`RigLinkSession.handle`, `t2` y `t3`);
  - el promovido sella con su host más la recta que congeló (ADR 0023 §4: «pasa a ser la
    referencia sin salto»);
  - el maestro de antes, al volver de esclavo, se sincroniza al host crudo del promovido, a
    ~591 898 s del dominio del soporte. Sus partes no casarían con las vistas.
  - **El arreglo es de una línea:** contestar `t2` y `t3` en el reloj del soporte
    (`+ clock.offsetAt`). Para un maestro sin muestras no cambia nada.
  - Toca el contrato de `clock_pong` del ADR 0023 («en ns del reloj de host»): queda para su
    propia tarea. Con este commit, la 4K de ese móvil al menos sale en dos segmentos limpios.
- `audio-<t>.aac` es ADTS sin sellos, y las vistas y el N0 los escribe el maestro: no les pasa.
- Suelto: el esclavo deja un `program-split-<t>.ts` de 0 bytes al acabar.

**Comprobado**
- `swift test --skip ModelBench`: 382 tests, 1 saltado, 0 fallos. Los nuevos son los 10 de
  `RecordingClockGateTests`:
  - el caso medido (70 sin reloj y luego +591 898 s): la sesión empieza con la estimación y
    el fichero dura lo grabado;
  - el maestro y el móvil solo graban desde el primer fotograma;
  - con la sesión abierta, el reloj no se vuelve a mirar;
  - el umbral, en los dos sentidos (5 ms y 100 ms no cortan; 100 ms + 1 ns sí);
  - 90 min con 60 ppm de deriva, sin ningún corte;
  - una corrección de 50 ms hacia atrás tira un fotograma;
  - la espera vence a los 30 s y la estimación abre otro segmento;
  - el relevo: corta, y el segmento nuevo espera a la estimación;
  - el audio entre el salto y el corte del vídeo;
  - el segmento abierto desde fuera.
- `tools/check_layers.sh`: limpio.
- `flutter analyze`: limpio. `flutter test`: 361, todos verdes.
- `flutter build ios --release --no-pub --dart-define=AUTO_ROLE=left
  --dart-define=PREFERS_MASTER=true`: compila (Runner.app de 28,1 MB), sin instalar.

**Qué mirar en la próxima pasada** (vale la de SPK-04 con `RIG_SPLIT_RECORD_4K=1`)

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
D=$(ls -td bench/dos-moviles-* | head -1)
for p in $(ls -t $D/izquierdo/bench/program-split-left-*.json | head -1) $(ls -t $D/derecho/bench/program-split-right-*.json | head -1); do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["rec4k"]
print(d["role"], "segmentos", r["segments"], "bytes", r["bytes"], "fotogramas", r["frames"]); print("  reloj", r.get("clock"))' "$p"
done
for f in $D/*/bench4k/*/*.mov; do echo "$f $(ffprobe -v error -show_entries format=duration,bit_rate -of csv=p=0 "$f")"; done
```

- **Maestro:** `clock_wait_frames` 0 y un segmento de ~600 s a ~45 Mbit/s, como hoy.
- **Esclavo:**
  - `clock_wait_frames` ≈ 70-90: el enlace a ~2,3 s y la ráfaga hasta la 3.ª muestra;
  - `clock_jump_segments` 0 y un segmento;
  - ~597 s a ~45 Mbit/s y ~3,4 GB, no 7,3.
- **`out_of_order_frames`:** 0 o muy pocos.
- **`sessions_without_clock` 1:** el enlace tardó más de 30 s. Saldrá un segundo segmento
  (`clock_jump_segments` 1), y eso es lo esperado.
- La 4K del esclavo empieza ahora ~3 s después del banco, con el primer fotograma con reloj.
  Los 70 primeros de la 4K de hoy son los que hay que saltarse para el PSNR y el VMAF.

## 2026-10-11 · SPK-04, la pasada en el trípode por Wi-Fi: 0 desgarros; la GPU del maestro y la latencia, por encima · 🚧

Los dos iPhone en el trípode con `rig-tripode-20261011.json` (yaw ±40,7°), 10 min con el
guion de SPK-04 (`RIG_SPLIT_SCRIPT=spk04`: barrido que cruza la costura cada 20 s y zoom
40°→83°) y las dos 4K locales (`RIG_SPLIT_RECORD_4K=1`). Por Wi-Fi: no hay Ethernet.
Datos en `bench/dos-moviles-20261011-1506` (programa .ts/.mov, `program-views-*.jsonl`, las
dos 4K —izquierda 3,4 GB, derecha 7,3 GB— y los informes).

| Criterio de SPK-04 | Objetivo | Medido | |
|---|---|---|---|
| Fotogramas desgarrados | 0 | **0** (desfase entre mitades p50 8 / p99 12 ms) | ✅ |
| GPU por fotograma, esclavo (render de la parte) | ≤3 ms | p50 1,5 / p95 2,5 / p99 2,75 ms | ✅ |
| GPU por fotograma, maestro (render de su mitad + composición) | ≤3 ms | p50 3 / p95 4,5 / p99 5 ms; la composición sola p99 3 ms | ❌ |
| Latencia añadida p95 | ≤120 ms | 144 ms | ❌ por Wi-Fi |
| PSNR en la rampa | ≥38 dB | pendiente: `tools/spk04_psnr.py` en football-ai | — |

Lectura: el cosido no desgarra (lo que la tarjeta pone como condición de ABANDONO), y el
esclavo cabe en su presupuesto de GPU. El maestro hace dos cosas en el mismo command buffer
(su mitad y la composición) y pasa de 3 ms: o el presupuesto de la tarjeta es por pase, o
hay que juntar los dos pases en un kernel. La latencia de 144 ms es la de la espera de 130
ms por Wi-Fi (ADR 0023, enmienda del 2026-10-07); el ≤120 supone Ethernet (SPK-02 con hubs).
El arranque, ya con la línea de tiempo de 8056f00: control a los 2,1 s, primera parte a los
8,5 s. 10 410 de 18 000 fotogramas de una lente: con HFOV < 68° el guion cae entero en una
lente, que es lo que quiere SPK-05.

Siguiente, sin iPhone: el PSNR (`tools/spk04_psnr.py`) y el VMAF por mitades
(`tools/vmaf_halves.sh`, SPK-05) sobre estas grabaciones; luego decidir lo de la GPU del
maestro. La 4K del 16 Pro sale al doble de bytes (7,3 GB en 600 s): mirar su bitrate real.

## 2026-10-11 · 80 min con toda la carga en el trípode: la memoria del maestro plana (SPK-54)

Los dos iPhone en el trípode, calibrados con los umbrales del repo en esa posición
(`bench/dos-moviles-20261011-1321`: 75-100 inliers, residuo 0,06°, **yaw ±40,7°, roll del
derecho −6,2°**; `docs/img/rig-tripode-20261011.json`, par en
`docs/img/par-calibracion-tripode-20261011.jpg`). 80 min con director, CenterNet en los dos,
micro, partes y esa geometría (`bench/dos-moviles-20261011-1340/manual`; los informes se
trajeron a mano para no esperar a copiar 2,8 GB de .ts):

| | 2026-10-08 (antes de c5a5506) | **2026-10-11** |
|---|---|---|
| Memoria del maestro | 389 → 629 MB, +1,25 MB/min | **506-545 MB, +0,27 MB/min** |
| Esclavo | plano ~442 | plano ~452 |
| Programa | 161 877 fot. (90 min) | 143704 fot. en 4800 s, sin el propio 0 |
| Dos lentes / una | 135 561 / 26 316 | 116186 / 27518 |
| Latencia añadida p95 | 144 ms | 143 ms |
| Térmica | maestro fair, esclavo serious | ['fair', 'nominal'] los dos |

La memoria se queda en 506-523 MB hasta el minuto 69, sube una vez a ~543 y no vuelve a
crecer: la fuga queda cerrada en una pasada de partido. Con el trípode los dos se
quedaron en fair (el 2026-10-08 el esclavo llegó a serious).

## 2026-10-11 · El arranque lento del 10-oct no fue el canal de medios: el esclavo abrió su enlace 100 s tarde · 🚧 falta una pasada con los tiempos nuevos

**Diagnóstico.** Se cruzan los informes de las 18 pasadas split con los dos lados del 7 al
10-oct, entre ellas `…-20261010-1035` (900 s, build recién instalada), y la de calibración
de hoy, `…-20261011-1321` (60 s):

| Pasada | El informe del esclavo, después del del maestro | El maestro ve al esclavo (`peer_states`) | Pareja de calibración |
|---|---|---|---|
| Las otras 16 | +9-12 s | a los 1,0-3,4 s (la de 90 min del 8-oct, a los 24 s) | — |
| `…-20261010-1035` | +10 s | a los 2,0 s | a los 30 s |
| **`…-20261010-1106`** | **+112 s** | **a los 102,5 s** | **ninguna** |
| `…-20261011-1321` | +10 s | a los 1,3 s | a los 30,4 s |

- **Cómo se leen los tiempos.**
  - El nombre del informe es la hora Unix en que acaba, con el reloj de cada móvil.
  - Cada banco dura su `RIG_SPLIT_S` desde que se crea, y se crea en `startLink`, justo
    antes de `link.start()`.
  - Los +10 s de siempre son los relojes de pared: el del 16 Pro va ~9-10 s por delante.
    No puede ser un retraso, porque el maestro ve al esclavo a los ~2 s.
- **En `…-1106` el esclavo abrió su enlace ~101 s más tarde de lo normal**, y el maestro
  lo vio 100,5 s más tarde de lo normal.
  - Desde que el esclavo abrió el enlace, el control, el apretón de manos y los latidos
    por medios tardaron lo de siempre (1-2 s).
  - **El transporte no tardó.** Los ~100 s se fueron antes del `startLink` del derecho, de
    una de dos maneras:
    1. El lanzamiento: el script lanza el derecho cuando `devicectl` vuelve del izquierdo.
    2. La app antes de abrir el enlace. `prepare` de Dart pide la cámara (al instante), la
       red local (≤ 20 s) y `configure` (≤ 3 s de medición). Nada de eso espera 100 s salvo
       que la app estuviera suspendida, por ejemplo con la pantalla apagada.

    Los informes no los distinguen; desde hoy, sí.
- **Encaja con lo demás.**
  - El esclavo mandó 4434 partes, sus 150 s enteros. El banco del maestro acabó 112 s antes
    que el suyo, y el esclavo siguió mandando partes con la última vista.
  - Las 1389 recibidas son los ~47 s en que los dos bancos corrieron a la vez. `parts_lost`
    da 0 porque las demás llegaron después del informe del maestro.
  - Los negros a los 40 y 75 s y el cosido bien a los 110 y 140 s caen igual.
- **Sin pareja de calibración en `…-1106`.** `RIG_CALIB_AT_S` contaba desde que el maestro
  toma su rol, y lo toma solo al arrancar. A los 30 s no había esclavo, `start` respondió
  «solo el maestro con enlace calibra» y no volvió a intentarlo. Arreglado (abajo).
- **El transporte, revisado** (0d10448 y c5a5506).
  - Por Bonjour no hay vigía de silencio (`silenceTimeoutS` nil).
  - El plazo para conectar sigue en 4 s.
  - `keepUntilDrop` y el relevo de medios solo cambian algo con la conexión arriba o por
    Wi-Fi Aware.
  - El navegador prefiere el anuncio recién aparecido al de la caché, y su vigía de medios
    prueba otro a los 3 s.
  - Nada de esto puede tener los medios 100 s abajo con el control arriba, y los datos dicen
    que no pasó.

**Hecho**
- **RigNet.**
  - `LinkTransportStats.firstControlUpNs` y `firstPeerMediaNs`.
  - `NWLinkTransport.createdNs` es público: es el cero de `events`.
  - La línea de tiempo ya cuenta el canal de medios: la cita de medios publicada, cada
    intento de conexión de control y de medios, `medios: conexión lista`,
    `medios: llega una conexión` y `medios mudos: se prueba el anuncio i de n`.
  - `medios: primera trama del otro` sale una vez por cada subida del control.
  - Cuenta los anuncios que ve cada browser (`control: 2 anuncios (+1 −0)`): el viejo de la
    caché se ve.
  - Guarda los 40 primeros sucesos y los 80 últimos (`LinkEventLog`): en una pasada de
    90 min el arranque ya no se pierde.
- **`LinkStartupTimeline`.** La primera vez de cada hito, en ms desde que arranca el banco,
  y `processStartUnixMs()` (sysctl).
- **El informe de `program-split`** trae:
  - `link_timeline_ms`, en ms desde que arranca el banco (−1 si nunca):
    - `control_up` y `media_rx` (la primera trama del otro), de los dos lados;
    - `session_up` (cada tic, unos 33 ms de resolución);
    - en el maestro, `peer_up` y `first_part`;
    - en el esclavo, `first_view` y `first_part_sent`.
  - `transport_events`, con sus segundos desde `transport_t0_ms`.
  - `launch_to_bench_ms`: del lanzamiento del proceso a `startLink`.
  - `bench_start_unix_ms` y `bench_start_rig_ms`. Este último, en el reloj del soporte, se
    resta entre los dos informes y da el desfase de arranque sin el de los relojes de pared.
    Solo vale en el esclavo si el reloj llegó a sincronizarse.
- **`tools/banco_dos_moviles.sh`** dice la hora de cada lanzamiento y lo que tardó
  `devicectl`.
- **La calibración automática** espera al enlace: dispara a los `RIG_CALIB_AT_S` segundos
  de que haya enlace, como decía su comentario. Hasta entonces mira una vez por segundo.

**Comprobado**
- `swift test --skip ModelBench`: 372 tests, 1 saltado, 0 fallos. Es la ZeroKit de
  fd5e88d (con SPK-04) más esto; sobre 7f17138, 363.
- Los 7 de `LinkStartupTimelineTests`:
  - el registro con su arranque y su final;
  - los hitos, solo la primera vez;
  - los del transporte, desde sus contadores;
  - el arranque del proceso;
  - por el loopback, los dos lados apuntan cuándo subieron el control y los medios, y la
    línea de tiempo lo dice.
- `tools/check_layers.sh`: limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData temporal). Sin avisos nuevos;
  queda el de `VtConcurrencyBench`.
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de todos sus
  `.swift`, en dos estados. 0 errores en los dos, con los 32 avisos de antes:
  - 7f17138 con esto;
  - fd5e88d (SPK-04) con esto, que es lo que se sube.

**Qué mirar en la próxima pasada** (vale cualquiera, `split` o con `SIN_INSTALAR=1`)

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
d=$(ls -td bench/dos-moviles-* | head -1)
for f in $(ls -t $d/izquierdo/bench/program-split-left-*.json | head -1) $(ls -t $d/derecho/bench/program-split-right-*.json | head -1); do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
print(sys.argv[1], d["role"], "arranque (reloj del soporte)", d.get("bench_start_rig_ms"), "ms; lanzado→enlace", d.get("launch_to_bench_ms"), "ms")
print("  hitos (ms desde el arranque):", d.get("link_timeline_ms"))
print("  " + "\n  ".join(d.get("transport_events", [])[:30]))' "$f"
done
```

- **Lo normal.** En la salida del script, los dos `… lanzado (N s)` a pocos segundos uno
  del otro.
  - `launch_to_bench_ms`: unos segundos.
  - `control_up` y `media_rx`: 1-2 s. `peer_up` y `first_part` del maestro, poco después.
  - La resta de los `bench_start_rig_ms`: unos segundos.
- **Si vuelve a pasar,** la resta de los `bench_start_rig_ms` da ~100 s, y la causa sale así:

  | Lo que se ve | Dónde está |
  |---|---|
  | `derecho lanzado (≈100 s)` | El lanzamiento (`devicectl`): mirar el bloqueo y la pantalla del derecho antes de lanzar. |
  | `launch_to_bench_ms` ≈ 100 000 en el esclavo | La app antes del enlace: la pantalla, los permisos o la cámara. |
  | Los arranques juntos, pero `control_up` o `media_rx` tarde | El transporte. `transport_events` dice qué anuncio probó y cuándo llegó lo primero por medios. |

- **La pareja de calibración** sale en `calib/` aunque el esclavo llegue tarde, a los
  `RIG_CALIB_AT_S` s del enlace.

## 2026-10-11 · SPK-04 — el banco del render repartido: guion, GPU, desgarros y las 4K · 🚧 falta la pasada con los dos iPhone

Lo que hace falta para que la pasada de 10 min deje medida la aceptación: la latencia
añadida, la GPU y los desgarros en el informe del iPhone, y grabado todo lo que piden el
PSNR (REF-41) y el VMAF (SPK-05) en el Mac.

**Hecho**
- **El director de guion** (`RIG_SPLIT_SCRIPT=spk04`, `Spk04Script` en RigCore).
  - Barrido: `yaw = costura + 35° · sin(2π · (t mod 40 s) / 40 s)`, que cruza la costura
    cada 20 s.
  - Zoom: HFOV en triángulo de 40° a 83° y vuelta en 60 s.
  - Depende solo del rigMs, sin instante de arranque: se repite cada 120 s y la
    referencia lo recalcula con el rig.json.
  - La costura y el pitch son la media de las dos cámaras del rig.json. Hoy, yaw ±42°:
    costura en 0°.
  - Con HFOV < 68° el encuadre cae entero en una lente en los extremos, a cada lado: son
    los planos de una lente que pide SPK-05.
  - Manda sobre `RIG_SPLIT_DIRECTOR`. El N0 apunta `shot: "spk04"`.
- **La GPU por fotograma**, `gpuEndTime − gpuStartTime` del command buffer (`GpuTiming`,
  cubos de 0,25 ms hasta 5 ms).
  - En el esclavo, el render de la parte.
  - En el maestro, el render de su mitad más la composición, y la composición sola.
- **Los desgarros.** No había contador: el ADR 0023 §5 dice que no hay desgarro por
  construcción.
  - `TearCheck` (ViewSync) llama desgarrado a un fotograma de dos lentes con las mitades
    de vistas distintas, o con las capturas de los dos móviles a más de medio fotograma.
  - `MasterProgramStage` lo cuenta (`torn_frames`) con el instante real del fotograma
    propio. Para eso, `masterFrame` devuelve ahora también su rigMs.
  - Además, `halves_skew_ms` (la fase entre las cámaras; el ADR 0012 la quiere ≤5 ms) y
    `extrapolated_view_frames` (partes pintadas con una vista extrapolada por el esclavo).
- **Las vistas de cada instante:** `Documents/bench/program-views-<t>.jsonl`, una línea por
  fotograma del programa.
  - Lleva la vista de verdad (la de la parte en dos lentes), la costura, la rampa, las
    ganancias, la fuente, los dos instantes de captura, el desgarro y la GPU.
  - El N0 solo trae `view` a 7,5 Hz, y con un barrido que se mueve en cada fotograma eso
    no da para un PSNR. Son ~2-3 MB en 10 min.
- **La 4K local de los dos** (`RIG_SPLIT_RECORD_4K=1`): la de siempre de IOS-57, en
  `Documents/bench4k/<t>/<lado>-<t>.mov`.
  - Pide libre solo lo de la pasada (`RecordingPolicy.benchReserveBytes`: el doble de lo
    que ocupa más 2 GB). Para 600 s son 8,75 GB; el partido sigue pidiendo 40 GB.
  - Ocupa ~3,4 GB por móvil a 45 Mbit/s. El bitrate pasa a `RecordingPolicy.localBitrateBps`.
- **El informe** `program-split-<lado>-<t>.json` gana estos campos:
  - `script` y `spk04_script` (los parámetros, la costura y el pitch).
  - `gpu_ms_per_frame` (p50/p95/p99/n), y en el maestro `compose_gpu_ms`.
  - `torn_frames`, `halves_skew_ms` y `extrapolated_view_frames`.
  - `rec4k`: si arrancó, los segmentos, los bytes, los fotogramas y el disco libre al
    empezar y al acabar.
  - `files`: las rutas, relativas a Documents, de todo lo grabado en la pasada.
  - `spk04_acceptance`. En el maestro: `added_latency_ms_p95` (ya se medía, del instante
    del programa al programa compuesto) con `≤120`, la GPU p99 con `≤3 ms` y los
    desgarros con `0`. En el esclavo: su GPU.
- **`tools/banco_dos_moviles.sh`** recoge, además de lo de siempre, lo que dice `files` del
  informe de ESTA pasada (`tools/ficheros_pasada.py`, con epoch no anterior al arranque
  del banco): el .mov del programa, las vistas, el N0 y las 4K. Con `SIN_4K=1` las 4K se
  quedan en el móvil.

**La pasada** (por Wi-Fi: no hay Ethernet; los dos con el rig.json de 2026-10-10)

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
BANCO_EXTRA='{"RIG_SPLIT_SCRIPT": "spk04", "RIG_SPLIT_RECORD_4K": "1"}' \
  tools/banco_dos_moviles.sh split <secreto> 600
# Si ya están instalados con este build: SIN_INSTALAR=1 delante.
```

Lo que sale en `bench/dos-moviles-<fecha>/`:
- **`izquierdo/`** (el maestro):
  - `bench/program-split-left-<t>.json`
  - `bench/program-split-<t>.ts` y su `.mov`
  - `bench/program-views-<t>.jsonl`
  - `n0/banco-<t>-left.jsonl`
  - `bench4k/<t>/left-<t>.mov`
  - `calib/…`
- **`derecho/`** (el esclavo):
  - `bench/program-split-right-<t>.json`
  - `bench4k/<t>/right-<t>.mov`

Qué mirar:

```bash
D=$(ls -td bench/dos-moviles-* | head -1)
python3 -c 'import json,sys
for p in sys.argv[1:]:
    d=json.load(open(p)); print(p); print(" rig", d["rig"], "script", d["script"], "rec4k", d["rec4k"])
    print(" gpu", d["gpu_ms_per_frame"], "\n acept", d["spk04_acceptance"])
    print(" dos/una lente", d["two_lens_frames"], d["one_lens_frames"], "fase", d["halves_skew_ms"], "extrap", d["extrapolated_view_frames"])' \
  $D/izquierdo/bench/program-split-left-*.json $D/derecho/bench/program-split-right-*.json
```

- `rig` tiene que ser `rig.json`: con `nominal` la costura no es la calibrada.
- `rec4k.started` true en los dos: si no, no había 8,75 GB libres.
- **La latencia, por Wi-Fi, no va a dar ≤120.** Con la espera de la parte en 130 ms, el
  2026-10-07 dio un p95 de 144 ms. El ≤120 de la tarjeta es por Ethernet. Con
  `RIG_SPLIT_PART_WAIT_MS=100` bajaría a ~110, pero el 19 % de los fotogramas sale de una
  lente.

**Comprobado**
- `swift test --skip ModelBench`: 372 tests, 1 saltado, 0 fallos. Los nuevos:
  `Spk04ScriptTests` (4), `TearCheckTests` (2), `RecordingPolicyBenchTests` (1), la GPU
  del esclavo (1) y la GPU, el desgarro y `onComposed` del maestro (1).
- Una primera vuelta con xcodebuild compilando a la vez dio 1 fallo que no se repitió.
- `tools/check_layers.sh` limpio.
- ZeroKit de lo commiteado (`git archive`, sin el trabajo a medias de otros en RigNet)
  compilado para iOS con xcodebuild, en Release y con derivedData temporal.
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de sus `.swift`
  commiteados contra ese ZeroKit y los módulos de HaishinKit y Flutter del DerivedData
  (`Debug-iphoneos`). 0 errores; 32 avisos, los de antes.
- `tools/ficheros_pasada.py` probado con informes falsos: el de una pasada vieja no se
  recoge, y `SIN_4K=1` deja fuera las 4K.

**Pendiente**
- La pasada con los dos iPhone (Alexander, hoy hacia las 15:05).
- El PSNR en la rampa frente a REF-41, con las vistas por instante, en football-ai.
- El VMAF por mitades (SPK-05, `tools/vmaf_halves.sh`) con las mismas grabaciones.








## 2026-10-10 · IOS-14 — Wi-Fi Aware: 10 min sin un corte, con el vigía de silencio · ✅

Con 0d10448 (el vigía de 3 s, la cita que se guarda con la conexión arriba, 10 s para
conectar), los dos iPhone emparejados y `RIG_LINK_INTERFACE=aware`, `link90` 600 s
(`bench/dos-moviles-20261010-1125`):

| | 2026-10-08 (95f756e) | **2026-10-10 (0d10448)** |
|---|---|---|
| Cortes / reconexión | 2 / 20-90 s | **0** |
| Órdenes recibidas / enviadas | 165 / 185 | **298 / 298** |
| PTS respondidos | 166 / 240 | **297 / 300** |
| Partes enviadas / recibidas / perdidas | 2946 / 2629 / — | **9064 / 9039 / 24 (0,27 %)**, pico 34 Mbit/s (escalón de 30) |
| RTT p50 / p90 / p99 | 4,5 / 6,6 / 17,7 ms | 5,1 / 8,1 / 23,6 ms |

La cita caduca a los 120 s como siempre (`publisherTimeout`/`subscriberTimeout`,
`keepUntilDrop`) y **la conexión sigue viva hasta el final** (el `control caído` a los
602 s es el cierre del banco). `silence_drops` 0. Es lo que dice Apple: la cita solo sirve
para encontrarse y el datapath vive con las conexiones.

Aceptación de IOS-14 («dos iPhone enlazan por Wi-Fi Aware sin router, y el banco da RTT y
pérdidas»): cumplida. Siguiente: SPK-08 (90 min por Wi-Fi Aware) e IOS-17 (la política
automática y el cambio en caliente).

## 2026-10-10 · El cosido calibrado con director, y un arranque lento del canal de medios

Con los dos iPhone en su posición (17 a la izquierda boca abajo, 16 Pro a la derecha)
mirando a la oficina, calibró con los umbrales del repo los cinco pares de
`bench/dos-moviles-20261010-1035`: 88-114 inliers, residuo 0,05-0,06°, **yaw ±42,0°** y el
derecho con **roll −13,7°** (`docs/img/rig-20261010.json`, par en
`docs/img/par-calibracion-20261010.jpg`). Con ese `rig.json` en los dos, 150 s de programa
con director y CenterNet (`bench/dos-moviles-20261010-1106`,
`docs/img/cosido-calibrado-director-20261010.jpg`): donde salen las dos lentes la costura
es continua (pared de neopreno del maestro, puerta y escoba del esclavo), sin fotogramas
propios perdidos.

**Pero el 70 % salió de una lente (3138 de 4499), con negro donde va el esclavo.** No es
la geometría: el esclavo mandó 4434 partes y el maestro recibió 1389, sin contar ninguna
perdida; los fotogramas negros son los del principio (40 y 75 s) y los de 110 y 140 s salen
bien. Parece que **el canal de medios tardó ~100 s en subir** al arrancar. En la pasada
anterior de 15 min (`…-1035`, misma build salvo `rig.json`) salieron dos lentes en el 95 %.
Pendiente: mirar los `transport_events`/tiempos de subida del canal de medios al arrancar
(¿los cambios de IOS-14c en la cita o el vigía afectan a Bonjour?) y repetir una pasada
corta midiendo cuándo llega la primera parte.

## 2026-10-10 · La fuga de memoria del maestro, resuelta y confirmada con los dos iPhone ✅

La bisección con los iPhone reales (`footprint_mb` por minuto, recta desde el minuto 3):

| Pasada | Maestro |
|---|---|
| 90 min con toda la carga (2026-10-08, `bench/dos-moviles-20261008-0808`) | +1,25 MB/min (389 → 629 MB) |
| Base sin director, detector, micro, .mov ni .ts, los dos (`…-1138`) | +1,94 MB/min |
| Un solo iPhone, sin enlace (`bench/un-movil-20261008-1106`) | plana |
| Los dos, el esclavo manda «sin parte» (sin partes ni decodificador, `…-20261010-0951`) | +2,05 MB/min |
| **Con c5a5506, toda la carga y partes, 15 min (`…-20261010-1035`)** | **plana: 526-560 MB, −0,35 MB/min** |

La causa (c5a5506): el búfer del canal de control se recortaba con `Data.removeFirst`,
que no libera lo leído, y guardaba todo lo recibido desde que subió la conexión. Por
control llega al maestro la miniatura del esclavo, una por segundo (17-35 KB): 1-2 MB/min.
En la pasada de confirmación pasaron por ese canal **26,7 MB** (`control_rx_bytes`) y el
búfer no pasó de **31 KB** (`control_buffer_peak_bytes`). El esclavo, plano en las dos.

La caché de texturas de Metal (53e8661) no era la fuga, pero su vaciado se queda.

**Siguiente**: unos 90 min con toda la carga para cerrar SPK-54 en memoria (la latencia y
el programa ya aguantaron el 2026-10-08).

## 2026-10-10 · La fuga de memoria del maestro: el búfer de control del enlace se quedaba con todo · 🚧 falta el banco con los dos iPhone

**Dónde estaba la bisección.** El maestro crece solo con enlace. Sin enlace queda plano
(`bench/un-movil-20261008-1106`). Con enlace crece aunque falten la copia .mov, el .ts, el
director, el detector, el micro y, hoy, las partes y el decodificador (`RIG_SPLIT_SLAVE_NO_PARTS=1`,
`bench/dos-moviles-20261010-0951`). En esa pasada el maestro va de 454,2 MB en el minuto 3 a
494,7 en el 19: la recta da 2,05 MB/min. El esclavo se queda plano entre 401 y 404 MB (−0,07).

**La causa.** `NWLinkTransport.drainBuffer` juntaba el stream TCP de control en un `Data` y lo
recortaba con `buffer.removeFirst(consumed)`.
- `Data` es su propio SubSequence: `removeFirst` solo corre el `startIndex`. Los bytes leídos
  siguen en el almacenamiento y el `append` siguiente escribe detrás.
- El búfer guardaba todo lo recibido por control desde que subió la conexión. En el Mac,
  143 MB por ese camino dejan 145 MB más de huella; con la copia que se hace ahora, 0,2 MB.
- **Lo que el maestro recibe por control** es casi todo la miniatura del esclavo: ThumbHub,
  JPEG de 640×360 a q 0,6, una por segundo.
  - Los fotogramas de calibración del esclavo, recodificados como Thumbnailer, dan 23 KB
    (oficina, 08-oct 10:30), 34-35 KB (otros del 08-oct) y 17 KB (hoy a los 30 s; según
    `color_series`, la escena cambió a los ~31 s).
  - 60 × 17-35 KB son **1,0-2,1 MB/min**, entre 90 y 190 MB por partido.
  - Lo medido: 1,94-2,05 MB/min en la oficina, 1,25 MB/min en los 90 min. Unos 120 MB por
    partido.
- **El esclavo** solo recibe por control la pizarra cada 5 s, el look y las respuestas de
  PTS: decenas de KB por minuto. Por eso se queda plano.
- **Encaja con toda la bisección.** Con un iPhone solo no hay miniaturas que recibir. Sin
  partes, las miniaturas siguen llegando por control.

**Revisado y descartado** (a 30 fps, latidos a 10 Hz)

| Qué | Lado | Cuánto crece | Veredicto |
|---|---|---|---|
| `PeerHealth.sentAt` / `sentOrder` | los dos | tope 256 seq | acotado |
| `ViewHistory` 64, `SlaveViewResolver` 64, `ProgramSync` 16, `RigClock` 240, `ReplayWindow` fija | los dos | 0 | acotados |
| `Reassembler` (4 a medias), cola del espaciado (2048 datagramas), `events` (80) | los dos | 0 | acotados |
| `pendingPts` (caduca a 1,5 s), `retiredListeners` (se vacía al caer) | — | 0 | acotados |
| `pingT1BySeq` de RigLinkSession | esclavo | 12 entradas/min, <1 KB/min | sin poda y nadie lo leía: **quitado** |
| Envíos UDP con completion vacía | los dos | 40/s cada lado | simétrico, no retiene nada |
| `receive`/`receiveMessage` encadenados | los dos | uno pendiente por conexión | se re-registra al completar |
| Temporizadores (latido, vigías, miniatura) | los dos | uno de cada | se cancelan en `stop` |
| Arrays por tic del banco (`tickIntervalsMs`, `composeLatencyMs`, `programIntervalsMs`) | maestro | 3 × 30/s × 8 B ≈ 43 KB/min, 4-8 MB por partido | también con un iPhone solo; del banco, no explica 2 MB/min |
| `adCues` (1/s), `colorSeries` (0,5 Hz), `peerStates` | maestro | unos KB | del banco |

**Hecho** (c5a5506)
- **`LinkStreamReader` (RigCore/Wire).** Saca las tramas enteras del stream y copia lo que
  queda a medias a un `Data` nuevo. Entre dos lecturas guarda como mucho una trama sin
  terminar. NWLinkTransport lo usa en vez del `Data` recortado. La lectura máxima pasa a
  `LinkConstants.controlReadChunkB` (64 KB, la de antes).
- **`LinkTransportStats`** cuenta `controlBytesReceived` y `controlBufferPeakBytes`.
  - Salen en los informes de `link-bench` y `program-split` como `control_rx_bytes` y
    `control_buffer_peak_bytes`.
  - `statsSnapshot` los lee en la cola del transporte.
- **Interruptores nuevos del banco split**, por si quedara algo:
  - `RIG_SPLIT_NO_THUMBS=1`: el esclavo no manda su miniatura.
  - `RIG_SPLIT_NO_VIEWS=1`: el maestro no manda `view`, así que el esclavo no pinta ni manda
    partes.
  - `link_switches` en el informe dice cuáles estaban puestos.
  - `RIG_SPLIT_SLAVE_NO_PARTS` sigue sin commitear, en el árbol de trabajo de Alexander.
- **Tests (8).**
  - `LinkStreamReaderTests` (6): tramas cortadas por cualquier sitio, un partido de 5400
    miniaturas a trozos de 64 KB que deja como mucho una trama a medias, el testigo de
    `removeFirst`, la basura, la longitud disparatada y el reinicio.
  - Por el loopback: 300 miniaturas con el búfer por debajo de una trama y los bytes
    contados.
  - La huella del proceso: 100 MB por el lector, y crece menos de 25 MB.
  - Con el `removeFirst` de antes fallan los de la cota: 162 MB retenidos y +102 MB de huella.

**Aparte, sin tocar** (no es memoria). El callback de `receive` del control no comprueba que
su conexión siga siendo la actual. Al sustituir o soltar una conexión, su lectura pendiente
puede volver con error y llamar a `dropConnection`, que tiraría la conexión **nueva** y
contaría una caída de más. No está comprobado en el iPhone. Para IOS-14c/IOS-17: mirar si en
`transport_events` salen dos `control caído` seguidos.

**Comprobado**
- `swift test --skip ModelBench`: 356 tests, 1 saltado, 0 fallos.
- `tools/check_layers.sh` limpio.
- ZeroKit compilado para iOS con xcodebuild (derivedData temporal): sin avisos nuevos (queda
  el de siempre de `VtConcurrencyBench`).
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de todos sus
  `.swift` contra el ZeroKit nuevo y los módulos de HaishinKit y Flutter del DerivedData.
  0 errores; los 32 avisos son los de antes. Se comprobó igual la versión commiteada, sin el
  trozo de `RIG_SPLIT_SLAVE_NO_PARTS`.

**Para la próxima prueba** (los dos iPhone, con el build que lleve c5a5506)

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
# 1. La misma base de hoy. Esperado: el maestro plano.
BANCO_EXTRA='{"RIG_SPLIT_NO_MOV": "1", "RIG_SPLIT_SLAVE_NO_PARTS": "1"}' tools/banco_dos_moviles.sh split <secreto> 1200
# 2. Si queda plano, con la carga de verdad (partes y .mov) y luego los 90 min.
tools/banco_dos_moviles.sh split <secreto> 1200
# Lo que mirar del maestro:
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); f=d["footprint_mb"]; xs=range(3,len(f)); ys=f[3:]
m=lambda v: sum(v)/len(v)
r=sum((x-m(xs))*(y-m(ys)) for x,y in zip(xs,ys))/sum((x-m(xs))**2 for x in xs) if len(ys)>2 else None
print(sys.argv[1], "recta desde el minuto 3:", r and round(r,2), "MB/min; control_rx_bytes", d.get("control_rx_bytes"),
      "pico", d.get("control_buffer_peak_bytes"), d.get("link_switches"))' \
  $(ls -t bench/dos-moviles-*/izquierdo/bench/program-split-left-*.json | head -1)
```

Qué mirar en el maestro:
- La recta de `footprint_mb` desde el minuto 3, por debajo de ~0,3 MB/min. Antes, 2,05.
- `control_rx_bytes` de 20 a 42 MB en 1200 s: lo que antes se quedaba en memoria.
- `control_buffer_peak_bytes` por debajo de ~40 KB, una miniatura.

Si aun así crece, por orden de probabilidad:
1. Algo más en el camino de la miniatura. Se añade `"RIG_SPLIT_NO_THUMBS": "1"` a la pasada 1:
   si queda plano, es eso.
2. El tráfico de medios a 30 Hz. Se añade además `"RIG_SPLIT_NO_VIEWS": "1"`: si queda plano,
   son las vistas y los «sin parte». Si sigue creciendo, es la base del enlace: latidos,
   reloj y color.

## 2026-10-10 · IOS-14c — lo que dice Apple de una conexión Wi-Fi Aware larga, y el enlace que vuelve en segundos · 🚧 falta la prueba con los dos iPhone

**Lo que dice la documentación.** Fuentes: el SDK iPhoneOS 26.5 de Xcode 26.6 (los
`.swiftinterface` y `.swiftdoc` de WiFiAware y Network), la sesión WWDC25 228 «Supercharge
device connectivity with Wi-Fi Aware», y el artículo y el código de ejemplo «Building
peer-to-peer apps».
- **La cita solo sirve para encontrarse.**
  - WWDC25: «To conserve wireless resources and power, stop the listener and browser once
    all the required connections have been made.»
  - El ejemplo de Apple para el browser con el primer punto que ve (`.finish`) y conecta
    después. Su listener sigue hasta que caduca; ante `publisherTimeout` solo dice «Timed
    out. Tap Advertise to restart.», sin tocar las conexiones.
- **El datapath vive con las conexiones, no con la cita.**
  - `addingConnections`: «Make additional network connections over a preexisting Wi-Fi
    Aware datapath, without publishing or advertising any services».
  - Y «Your app must have at least one pre-existing NetworkConnection to a remote device».
  - No hay que mantener vivo ningún otro objeto: `WAConnection` solo da `deriveSharedSecret`.
- **`requestedDuration` es una petición, sin máximo documentado.** «Optional duration
  requested to keep the NetworkListener publishing. The default value of nil instructs the
  system to stay active for long enough to guarantee the action completes with all nearby
  target devices.» Medido el 2026-10-08: con 7200 s caduca igual a los ~2 min.
- **Errores de una conexión:** `connectionIdleTimeout` («when a connection is unused for an
  excessive duration»), `connectionTerminated` y `deviceNoLongerAvailable`. Ninguno pone
  tiempo de vida a una conexión en uso.
- **API nueva o puente.** El puente a la clásica (`service`, `configureParameters`,
  `makeDescriptor`, `makeEndpoint(from:)`) es API pública documentada. La nueva
  (`NetworkListener.run`, `NetworkBrowser.run`) tiene el mismo ciclo: el listener y el
  browser fallan al caducar (`run` lanza) y las conexiones siguen. Nada dice que gestione
  mejor la caducidad. Lo único que solo da la nueva es `.addingConnections`: el canal de
  medios sobre el datapath del control, sin una segunda cita. Pide `NetworkConnection` hacia
  un `WAEndpoint`; queda anotado para IOS-17/SPK-08.
- **Rendimiento:** lo que ya llevamos.
  - `.realtime` «prioritizes latency at the expense of throughput, power, and other
    concurrent Wi-Fi use cases».
  - WWDC25: «real time is used with interactive voice or video service class».
  - El ejemplo de Apple usa justo `.realtime` con `.interactiveVideo`.
  - «Each service must have the same WAPerformanceMode on both … sides».
  - `.interactiveVideo` da «low-latency for moderate throughput flows» y «doesn't support
    high throughput».
- **Del daemon, no de la documentación.** Las cadenas de `/usr/libexec/wifip2pd` (el del Mac
  trae el código de Wi-Fi Aware) son un indicio:
  - mantiene el datapath con keep-alives propios: «%@ will be terminated because no keep
    alive was received for %s»;
  - no monta uno nuevo si la publicación asociada ya caducó: «cannot retry response because
    the associated publisher is no longer active».

**Diagnóstico** (`bench/dos-moviles-20261008-1122` y `…-1204`)
- **Lo lento es volver, no caer.**
  - En la caída de 11:22 el derecho hace 10 intentos en 54 s, unos 5,4 s cada uno: los 4 s
    de `controlConnectTimeoutS`, la espera y otra suscripción.
  - Por Wi-Fi Aware, montar el datapath y el TCP tarda 2,4-6,3 s, así que cada intento se
    abortaba a medio montar.
- **Nadie se entera de que el datapath murió.**
  - El TCP, sin keepalive, sigue «arriba». En 11:22 el izquierdo cayó 36 s antes que el
    derecho: 90 s fuera frente a 54.
  - Mientras tanto, el derecho no volvía a suscribirse.
  - Y al soltar el control, el derecho dejaba viva la conexión de medios sobre el mismo
    datapath.
- **En 12:04 hubo una tercera caída que no llegó a cerrarse.** Entre los 300 y los 480 s:
  - el derecho suma 15 intentos más y recibe 42 órdenes de 90;
  - el izquierdo recibe 2629 partes de unas 5400, y su informe final ya no trae `aware_*`.

  `outages` no la cuenta: solo cuenta las caídas que vuelven.
- **95f756e volvía a publicar cada ~2 min con la conexión arriba**, al revés de lo que pide
  Apple. Si el derecho aún estaba suscrito a los medios, veía el anuncio nuevo y cambiaba de
  conexión de medios a mitad. No hay prueba de que eso tumbe el datapath, pero sobra.
- **Por qué cae, los informes no lo dicen:** no guardaban ni el motivo ni la hora. Desde
  ahora, sí.

**Hecho** (RigNet y el banco)
- **Vigía de silencio**, `silenceTimeoutS` de la cita: 3 s por Wi-Fi Aware (`WiFiAwareTimings`);
  por Bonjour no hay.
  - Si el control está arriba, han llegado medios del otro desde que subió y luego callan
    3 s (30 latidos), se tira el enlace entero y se vuelve a buscar. Se mira 4 veces por
    plazo.
  - Sin medios desde que subió el control (el apretón de manos, un conflicto de roles) no
    se arma.
- **Por Wi-Fi Aware el enlace es uno.**
  - Si cae el control que estaba arriba, el derecho suelta también los medios y se vuelve a
    suscribir a ellos, en vez de seguir hablando a un anuncio de un datapath muerto.
  - El izquierdo no cancela su conexión de medios: la sustituye la nueva al llegar.
    Cancelarla podría tirar la nueva, que puede llegar antes que el control y no trae
    latidos hasta que sube la sesión.
  - Si el control nuevo del derecho llega con el viejo aún arriba, el izquierdo cambia ya
    sus citas caducadas por otras, para que la suscripción nueva a los medios lo encuentre.
- **La cita que caduca con la conexión arriba se guarda hasta que la conexión cae**, en los
  dos lados (`rendezvousEndAction` da `.keepUntilDrop`).
  - Ya no se vuelve a publicar cada ~2 min.
  - Al caer la conexión se abren citas nuevas en el acto.
  - Un listener de Bonjour que falla de verdad sigue en `.renewLater`.
- **Plazo para conectar por cita** (`connectTimeoutS`): 10 s por Wi-Fi Aware y los 4 s de
  siempre por Bonjour.
- **Línea de tiempo del transporte** (`events`): los últimos 80 sucesos, con su segundo.
  - Recoge las citas publicadas y acabadas, el control arriba y cada caída con su motivo:
    `falló: Wi-Fi Aware: connectionTerminated`, `silencio de 3.2 s`, `sin respuesta en 10 s`…
  - Los errores de Wi-Fi Aware salen sin sus detalles vacíos.
- **El informe de `link-bench`** añade `transport_events`, `silence_timeout_s` y
  `silence_drops`.
- **Tests:** `LinkSilenceTests` (4) y la tabla nueva de `RendezvousEndTests`.
  - La decisión del vigía.
  - Que solo Wi-Fi Aware tiene vigía y que sus plazos cubren lo medido.
  - Por el loopback, un enlace que calla se tira y se rehace, con los medios otra vez.
  - Sin medios desde que subió el control, no se tira nada.

**No hecho, a propósito**
- **Pasar a la API nueva:** no da nada mejor para la caducidad y cambia el transporte
  entero. `.addingConnections` para los medios sí la pediría.
- **Conectar con los parámetros de `configureParameters` del browser** (Apple: «the
  parameters to use to configure the Wi-Fi Aware subscriber and the subsequent connection»).
  Hoy conecta sin ellos, y no sé si atarían la conexión a la suscripción, que caduca. Si la
  próxima pasada sigue cayendo justo tras cada caducidad, es lo siguiente que se prueba.
- **Una conexión a medio montar que pasa a `.waiting` se sigue soltando en el acto.** La
  línea de tiempo dirá si eso ocurre por Wi-Fi Aware.

**Comprobado**
- `swift test --skip ModelBench`: 348 tests, 1 saltado, 0 fallos.
- `tools/check_layers.sh` limpio.
- RigNet compilado para iOS con xcodebuild (derivedData temporal), sin avisos.
- El Runner, sin `flutter build` y sin tocar `build/ios`: `swiftc -typecheck` de todos sus
  `.swift` contra el RigNet nuevo y los módulos de HaishinKit y Flutter del DerivedData. 0
  errores; los avisos son los de antes.

**Para la próxima prueba** (los dos desbloqueados, emparejados como el 2026-10-08)

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
# 1. 10 min por Wi-Fi Aware.
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware"}' tools/banco_dos_moviles.sh link90 <secreto> 600
# 2. La vuelta tras un corte con la cita ya caducada: el izquierdo se para 1 s a los 200 s.
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware", "RIG_LINK_CUT_AT_S": "200"}' tools/banco_dos_moviles.sh link90 <secreto> 600
# 3. Si las dos van bien, los 90 min (SPK-08).
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware"}' tools/banco_dos_moviles.sh link90 <secreto> 5400
# La línea de tiempo de cada lado:
for f in $(ls -t bench/dos-moviles-*/{izquierdo,derecho}/bench/link-bench-*-1*.json | head -2); do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["counters"]; p=d["params"]
print(sys.argv[1], "outages", c["outages"], "reconnect_ms", c["reconnect_ms"], "silence_drops", c.get("silence_drops"), "rendezvous_ends", c["rendezvous_ends"])
print("\n".join(p.get("transport_events", "").split(" | ")))' "$f"
done
```

Qué mirar en los informes:
- `silence_timeout_s` es `3.0`: el build lleva el arreglo.
- **La 1:** `connected=1` y `commands_received` ≈ 299 en el derecho. `rendezvous_ends` baja
  a ~2 por lado (una caducidad por canal) desde los 4-6 de antes.
- **Si hay caídas:** `reconnect_ms` de unos 3-10 s, y no de 20-90.
  - `transport_events` dice el motivo de cada `control caído (…)`.
  - Si cada caída llega justo después de una `cita … acabada (Wi-Fi Aware: publisherTimeout
    | subscriberTimeout)`, la caducidad sí se lleva el datapath. Entonces lo siguiente es
    probar `configureParameters` y, si no basta, la API nueva con `.addingConnections`
    (ADR).
- **La 2:** `outages` 1 y `reconnect_ms` de pocos segundos.
- **Una caída sin cerrar al final** no sale en `outages`: se ve como un último `control caído`
  sin `control arriba` detrás.

## 2026-10-08 · Wi-Fi Aware con los dos iPhone (IOS-14) y la fuga de memoria acotada al enlace con el esclavo

**Wi-Fi Aware** (emparejados a mano con «Emparejar sin cable»; el emparejado sobrevive a
reinstalar). Tres pasadas de `link90` con `RIG_LINK_INTERFACE=aware`:

| Pasada | Conecta | Órdenes (recibidas/enviadas) | Partes | Cortes / reconexión | RTT p50 / p99 |
|---|---|---|---|---|---|
| 10:47, sin arreglo (`bench/dos-moviles-20261008-1047`) | 2,5 s | 58 / 299 | 0 (la sesión cayó a los ~116 s) | el esclavo sin poder volver | 3,9 / 13,6 ms |
| 11:22, con 95f756e (`…-1122`) | 6,3 s | 183 / 203 | 6619 enviadas, 5472 recibidas, 8,9 % perdidas, hasta 12,3 Mbit/s | 2 / 54-90 s | 4,6 / 21 ms |
| 12:04, con `RIG_LINK_AWARE_ACTIVE_S=7200` (`…-1204`) | 6,5 s | 165 / 185 | 2946 enviadas, 2629 recibidas, 0 perdidas en conexión, hasta 11,3 Mbit/s | 2 / 20-30 s | 4,5 / 17,7 ms |

Lectura: el enlace por Wi-Fi Aware ya conecta solo entre los dos iPhone, sin router, con
un RTT parecido al de la Wi-Fi, y tras 95f756e la caducidad de la cita ya no lo tumba
para siempre. Pero iOS **sigue caducando la cita aunque se pidan 7200 s** (6 y 4
caducidades en 8 min) y, cuando caduca, a veces se lleva la conexión: 2 cortes en 8-10
min, que vuelven solos en 20-90 s. Así no sirve para un partido. IOS-14 sigue 🚧.
Siguiente: averiguar en la documentación de WiFiAware si la conexión ya establecida puede
sobrevivir a la caducidad de la cita (o pasar la cita a la API nueva de Network, el plan B
que anotó 95f756e) y un vigía del control que tire y rehaga la conexión en segundos, no en
decenas (IOS-17).

**La fuga de memoria del maestro, acotada.** Con la base (sin director, detector, micro,
.mov ni .ts):
- con los dos iPhone, crece ~2 MB/min (`bench/dos-moviles-20261008-0941`, y 1,94 MB/min en
  `…-1138`);
- con el iPhone 17 solo (`tools/banco_un_movil.sh`, sin esclavo, sin partes ni
  decodificador), **plana**: 468-480 MB en 15 min (`bench/un-movil-20261008-1106`).

La fuga necesita el enlace con el esclavo. **No es la caché de texturas de Metal**: se
añadió `MetalContext.flushTextureCache()` tras cada composición (lo que recomienda Apple, y
se queda) y la pasada `…-1138` siguió en 1,94 MB/min. Revisado y acotado: el reensamblador
de fragmentos, la ventana de bitrate del receptor, `decoded` y `viewsByRigMs`. Sospechosos
que quedan: el decodificador de VideoToolbox de las partes y la recepción de
`RigLinkSession`. Siguiente: con los dos, una pasada con el esclavo mandando `no_part` en
todos los fotogramas (sin partes ni decodificador, pero con el enlace vivo).

## 2026-10-08 · IOS-14c — la cita de Wi-Fi Aware caduca a los ~2 min y el enlace se quedaba mudo · 🚧 falta repetir la prueba

**La prueba** (`bench/dos-moviles-20261008-1047`, link90 de 600 s por Wi-Fi Aware, los dos
emparejados a mano). Conecta: rendezvous=aware, connect_ms 2528/2408, RTT p50 3,9 / p90 6,6 /
p99 13,6 ms, y el emparejado sobrevivió a reinstalar. Pero los dos dan un fallo del
transporte: `publisherTimeout` el izquierdo (publica) y `subscriberTimeout` el derecho (se
suscribe). A partir de ahí no pasa nada más:
- Todo se para a los ~116 s de conectar. Los `no_part` del maestro son 3468, que a 30 fps son
  115,6 s. El esclavo recibe 58 órdenes y 58 PTS, una cada 2 s: otros 116 s.
- El informe parcial de los 300 s ya tiene los mismos contadores que el final de los 600 s
  (tramas 1299/4715 y 4807/1299). Solo suben `commands_sent` y `pts_requests`, que el banco
  cuenta aunque no salgan.
- `media_stalls_over_100ms` 569 no es síntoma: los medios del maestro llegan así siempre
  (~4,9 por segundo, igual que en la pasada de 90 min por Wi-Fi).

**Qué es la caducidad** (SDK iPhoneOS 26.5 y la documentación de `wifiAware(_:active:)`).
`WAPublisherListener.wifiAware(_:active:)` y `WASubscriberBrowser.wifiAware(_:active:)`
tienen un `active requestedDuration: Duration? = nil`. Con nil, el sistema publica o se
suscribe «long enough to guarantee the action completes with all nearby target devices».
Después, el listener y el browser fallan con `WAError.publisherTimeout` y
`.subscriberTimeout`. Es el fin de la cita, no del enlace. El maestro pasó 480 s sin ver caer
su conexión (`reconnects` 0).

**El fallo era nuestro.** NWLinkTransport trataba el `.failed` del listener o del browser
como fallo del transporte:
- Ponía `state = .failed` con la conexión viva. RigLinkSession, ante `.failed`, hace
  `resetSession()`: tira la clave sin cambiar de estado. Desde ahí ningún lado manda ni
  acepta nada, pero el banco sigue viéndolo «conectado» (`outages` 0).
- Y no se curaba. `scheduleReopen` solo actúa sin conexión, y el listener muerto no se
  soltaba nunca, así que el maestro no volvía a publicar.
- El esclavo sí perdió después su conexión (`reconnects` 2). Volvió a suscribirse, pero ya no
  había nadie publicando.

**Por qué no salió ninguna parte.**
- Los primeros 300 s del perfil son 0 Mbit/s: el esclavo manda `no_part`, que van a
  `no_parts` (3468) y no a `parts_sent`.
- A los 300 s empieza el escalón de 10 Mbit/s, pero `LinkPartsLoad.tick` solo manda con la
  sesión en `.connected`. `parts_sent` 0 dice que la sesión del esclavo ya no lo estaba: su
  conexión había caído y no podía volver.
- Es el mismo fallo, no otro.

**Hecho** (RigNet y el banco)
- `LinkRendezvous.isExpiry(_:)`: false por defecto (Bonjour no caduca). En
  `WiFiAwareRendezvous`, true para `publisherTimeout` y `subscriberTimeout`.
- NWLinkTransport, el fin de una cita (`rendezvousEndAction`, una función pura con test):
  - Con la conexión arriba nunca es un fallo. No toca `state`, la cuenta en
    `stats.rendezvousEnds` y apunta el motivo en `lastRendezvousEnd`.
    - El que busca guarda su browser sin cancelarlo hasta que caiga la conexión.
    - El que anuncia vuelve a publicar a los `rendezvousRenewS` (5 s). Si el otro pierde la
      conexión y este no se entera, lo puede volver a encontrar. El listener viejo se guarda
      sin cancelar mientras siga la conexión: no se sabe si cancelarlo la arrastra.
  - Sin conexión, si caducó, abre otra cita a los 0,5 s sin pasar por `.failed`. Si es un
    error de verdad, `.failed` y se reintenta como antes.
  - Al caer la conexión, las citas acabadas se cambian por otras nuevas, las de control y
    las de medios, que antes no se vigilaban.
  - Un listener que falla se suelta. Antes `scheduleReopen` no lo sustituía nunca, también
    por Bonjour.
  - Una conexión nueva que sustituye a otra viva pasa el estado por `.listening`. Así la
    sesión vuelve a darse la mano; antes se quedaba con la clave de la vieja y el esclavo
    daba «auth antes del hello».
- `WiFiAwareRendezvous(activeDuration:)` y `RIG_LINK_AWARE_ACTIVE_S` en la app y en el banco,
  por si la caducidad arrastrara la conexión del que busca. Sin ella, nil, como hoy.
- El informe de `link-bench` añade `rendezvous_ends`, `rendezvous_end` y
  `aware_requested_active_s`. La caducidad ya no sale en `transport_failures`.
- Tests (4, `RendezvousEndTests`):
  - La tabla de decisiones.
  - Que Bonjour no caduca.
  - Un listener que falla (puerto ocupado) se cambia por otro y el otro conecta. Sin el
    arreglo, falla por tiempo.
  - Una cita caducada se reabre sin `.failed` y queda contada.

**Comprobado**
- `swift test --skip ModelBench`: 344 tests, 1 saltado, 0 fallos.
- `tools/check_layers.sh` limpio.
- RigNet compilado para iOS con xcodebuild, sin avisos.
- El Runner no se ha compilado (Alexander tenía `build/ios` en uso). Son tres líneas del
  informe y `awareActiveDuration()`.

**Pendiente**
- Si la próxima pasada da `outages` y `reconnects` de uno cada ~2 min, la caducidad sí se
  lleva la conexión del que busca. Entonces se pasa `RIG_LINK_AWARE_ACTIVE_S` y, si eso lo
  arregla, se fija la duración en el código.
- Un plazo de silencio del control que tire la conexión. Hoy, si el datapath muere sin avisar,
  el TCP puede tardar minutos en darse cuenta. Es de IOS-17.
- Los medios sin control vivo no tienen vigía propio en el que anuncia.

**Para la próxima prueba**

```bash
# 1. La misma pasada. Esperado: connected=1, transport_failures vacío,
#    rendezvous_ends ≥ 2 (la cita caduca y se renueva), frames y no_parts creciendo hasta el
#    final, parts_sent > 0 desde los 300 s, commands_received ≈ 299, pts_answered ≈ 300.
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware"}' tools/banco_dos_moviles.sh link90 <secreto> 600
# 2. Si va bien, la vuelta tras un corte con la cita ya caducada (el izquierdo se para 1 s
#    a los 200 s). Esperado: outages 1, reconnect_ms de unos 3 s y partes después.
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware", "RIG_LINK_CUT_AT_S": "200"}' tools/banco_dos_moviles.sh link90 <secreto> 600
# 3. Si la 1 da outages cada ~2 min, la misma con la cita larga:
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware", "RIG_LINK_AWARE_ACTIVE_S": "7200"}' tools/banco_dos_moviles.sh link90 <secreto> 600
```

## 2026-10-08 · SPK-53 e IOS-23 medidos en el iPhone 17 · ✅

**SPK-53, el spotter N4 en modo paso** (`tools/spk53_bench.sh iphone`,
`bench/spk53-20261008-1104`; iPhone 17, iOS 26.6.1, térmica nominal):

| Variante | ANE (coste) | Paso p50 / p90 / p99 | Dorado (100 pasos) | Reinicio / intercalado | Carga |
|---|---|---|---|---|---|
| E/S explícita | 100 % | 0,295 / 0,327 / 0,352 ms | 0 fuera, peor Δ 0,0124 | 0 / 0 | compile 61 ms, load 393 ms |
| MLState | 100 % | 0,287 / 0,313 / 0,349 ms | 0 fuera, peor Δ 0,0124 | 0 / 0 | compile 47 ms, load 285 ms |

Las dos cumplen los cuatro criterios (≥95 % ANE, p50 ≤1,7 ms, el dorado, sin fugas), con
el p50 a 6× del objetivo. Empatan (0,008 ms): por la regla anotada al preparar el banco
(empate ≤0,1 ms → la explícita), **se elige la E/S explícita**, que además no ata al
`MLState` de iOS 18+. Pendiente de la revisión del propietario.

**IOS-23, el decodificador en el iPhone** (`tools/bench_iphone.sh decoder-bench`,
`bench/decoder-bench-20261008-1104`, 2000 llamadas): `detr300` (300 queries) p50 0,012 /
p99 0,018 ms — **la aceptación pide <0,2 ms**; `heatmap` (CenterNet) p50 0,073 / p99 0,097 ms;
`heatmap_saturated` (mapa lleno de picos, el peor caso artificial) p50 1,42 / p99 1,53 ms.
Con esto IOS-23 queda entera (los dorados ya pasaban el 2026-10-07).

`tools/spk53_bench.sh`: la comprobación de los recursos fallaba con ellos en su sitio
(`echo | grep -q` con pipefail sale con SIGPIPE justo al encontrar); ahora lee sin tubería.

## 2026-10-08 · El cosido calibrado con los umbrales del repo (IOS-71, SPK-04)

Con los dos iPhone a mano en la posición del soporte (iPhone 17 a la izquierda boca abajo,
16 Pro a la derecha), mirando a una oficina de ~10 m de fondo, se calibró con los 5 pares
que saca el banco al empezar (`bench/dos-moviles-20261008-1030`) y la `calibrate_upright` del
servicio NUBE-09, **con los umbrales del repo** (RANSAC 3 px, ≥30 inliers):

| Par | Inliers | Residuo | Yaw izq / der | Roll der |
|---|---|---|---|---|
| 1 | 164 / 265 | 0,065° | −35,65° / +35,65° | −11,24° |
| 2 | 152 / 238 | 0,069° | −35,64° / +35,64° | −11,19° |
| 3 | 151 / 248 | 0,071° | −35,65° / +35,65° | −11,21° |
| 4 | 149 / 244 | 0,066° | −35,65° / +35,65° | −11,20° |
| 5 | 143 / 231 | 0,061° | −35,64° / +35,64° | −11,34° |

Los cinco coinciden a 0,01° en yaw y 0,15° en roll. El derecho estaba ladeado 11°: el
trípode lo corregirá, pero la calibración ya lo compensa. Con ese `rig.json` en Documents de
los dos (`docs/img/rig-agencia-20261008.json`), 150 s de programa
(`bench/dos-moviles-20261008-1035`): el logo de la pared, que cae en el solape, sale una sola
vez y entero; pared, ventana, sofá y garrafón continuos a través de la costura
(`docs/img/cosido-calibrado-agencia-20261008.jpg`; el par crudo en
`docs/img/par-calibracion-agencia-20261008.jpg`). 0 fotogramas propios perdidos, latencia p95
144 ms. Ayer, en un cuarto a 2-4 m, solo calibraba aflojando los umbrales: con algo más de
fondo ya no hace falta.

Falta para cerrar IOS-71/SPK-04: el trípode (mañana) y la prueba en la cancha, más
SPK-05 (ΔVMAF) sobre una grabación.

## 2026-10-08 · 90 min con los dos iPhone y todos los arreglos: aguanta un partido (SPK-54, IOS-44)

Maestro iPhone 17 y esclavo iPhone 16 Pro por Wi-Fi, apuntando a un cuarto con luz de día,
sin soporte ni hubs. Toda la carga: director, CenterNet en los dos por la cadena de
producción, micro, N0 y franja; espera de la parte 130 ms y anillo de 6 (9468324), los
sellos en el reloj del host (cc2a98e). Datos en `bench/dos-moviles-20261008-0808/manual`
(recogidos a mano: el script del banco cambió en disco mientras corría).

| | 2026-10-07 (antes de los arreglos) | 2026-10-08 |
|---|---|---|
| Programa | 156 079 fotogramas; 37 714 SIN SEÑAL | **161 877; 0 SIN SEÑAL, 0 fallos de composición** |
| Sin el fotograma propio | 123 235 (79 %) | **0** |
| Dos lentes / una lente | 31 338 / 1 506 (+79 466 solo esclavo) | 135 561 / 26 316 |
| Latencia añadida p50 / p95 | 107 / 136 ms | 140 / 144 ms |
| Partes | 161 735 recibidas, 139 perdidas | 139 707 recibidas, 1 292 perdidas, 531 IDR |
| Térmica | maestro serious desde el minuto 2 | maestro nominal → fair; esclavo serious desde el ~40 |
| Memoria del maestro | 326 → 610 MB | 389 → 629 MB (**+1,25 MB/min**); esclavo plano en ~442 |

**Lectura.** Los dos arreglos de ayer se sostienen 90 min: nunca falta el fotograma propio
y no hay ni un SIN SEÑAL. De los 26 316 fotogramas de una lente, 20 197 son vistas del
director que caen enteras del lado del maestro (el esclavo manda `no_part`, lo correcto);
las partes que faltaron de verdad son ~6 100 (3,8 %), la mitad en los primeros 20 min, con
83 caídas cortas del enlace por Wi-Fi (106 s fuera de `up`); después, estable hasta el
final. La geometría era el `rig.json` de interior de ayer, con los móviles ya movidos: no
cambia el coste, sí qué vistas cruzan la costura.

**Sigue abierto**: la memoria del maestro (+1,25 MB/min, ~120 MB por partido). No es la
escritura de ficheros (2026-10-07); esta tarde se separa con `tools/banco_un_movil.sh`
(maestro solo, sin partes ni decodificador) apagando director, detector y micro por turnos.

**Base sin director, detector ni micro** (12 min con los dos, `bench/dos-moviles-20261008-0941`):
la memoria del maestro **sigue creciendo** (474 → 500 MB del minuto 2 al 11, ~2 MB/min; la
pasada es corta y ruidosa). La fuga no está en el director, el detector ni el micro: queda
la base (cámara y anillo, compositor y gráfico, codificador del programa, decodificador de
las partes). Siguiente: la misma base con un solo iPhone (`tools/banco_un_movil.sh`, sin
partes ni decodificador); si crece igual, el decodificador queda fuera.

## 2026-10-08 · IOS-14 — Wi-Fi Aware como plan B del enlace · 🚧 falta la prueba con los dos iPhone

Hecho en el Mac, sin tocar los iPhone (estaba corriendo la pasada de 90 min). La
aceptación («dos iPhone enlazan por Wi-Fi Aware sin router, y el banco da RTT y
pérdidas») queda para la próxima ventana con los dos móviles. Los comandos van abajo.

**La API que hay de verdad** (Xcode 26.6, SDK iPhoneOS 26.5):
- `WiFiAware.framework`, solo en iOS.
- `WAPublisherListener` y `WASubscriberBrowser` son los proveedores de la API nueva de
  Network (`NetworkListener`/`NetworkBrowser`). También traen puentes a la clásica:
  `service` y `configureParameters` para NWListener; `makeDescriptor` y
  `configureParameters` para NWBrowser.
- `NWParameters.wifiAware.performanceMode` (`.bulk`/`.realtime`); la categoría de acceso
  la da `serviceClass`.
- `DeviceDiscoveryUI` en UIKit: `DDDevicePairingViewController(listenerProvider:access:)`
  para quien publica, y `DDDevicePickerViewController(browseDescriptor:parameters:access:)`
  con `endpoint` async para quien busca.
- `NWEndpoint.wifiAware`, `WAConnection` y `.addingConnections` son de iOS 26.4.

**Entitlement: no falta nada.** `Runner.entitlements` ya traía
`com.apple.developer.wifi-aware` con Publish y Subscribe (la rama sale de
`bundle-id-zero`, IOS-01). El perfil del equipo 5AKXUHD733 lo incluye. Lo he comprobado
en el `embedded.mobileprovision` del build de hoy: Publish y Subscribe, los dos iPhone,
caduca el 2027-10-04. El binario enlaza WiFiAware y DeviceDiscoveryUI.

**Hecho**
- IOS-14a, en RigNet:
  - `LinkRendezvous.swift`: la cita. Da el listener y el browser de cada canal y los
    parámetros de la conexión. Con ella, NWLinkTransport deja de saber de Bonjour.
    `BonjourRendezvous` es lo de siempre (Ethernet, Wi-Fi o loopback).
    `NWLinkTransport(mode:interfaceType:)` sigue igual por fuera.
  - `WiFiAwareLink.swift`:
    - `WiFiAwareRendezvous`: el izquierdo publica los dos canales y el derecho se
      suscribe, solo entre emparejados (`.allPairedDevices`). Modo realtime en los dos
      lados (tienen que coincidir) y categoría `.interactiveVideo`. Los errores de la
      radio salen con palabras: falta el entitlement, no hay nadie emparejado…
    - `report(of:)`: señal, capacidad, techo, latencia de emisión de vídeo y tiempo
      activo del datapath, para el banco (SPK-08).
    - `WiFiAwarePairing.pair(side:from:)`: el emparejado único. El izquierdo enseña la
      hoja con el código; el derecho, el selector. Las dos con acceso `.permanent`.
      Termina al aparecer un emparejado nuevo, al elegir en el selector o al cerrarse
      la hoja.
  - `RigCore/Wire/TransportPolicy.swift`: `LinkMedium` (ethernet, wifi, aware) desde
    `RIG_LINK_INTERFACE`, con su tasa de parte. Un valor que no se entiende es error. Antes,
    cualquier cosa que no fuera `wifi` iba por Ethernet sin decirlo.
  - `Info.plist`: `WiFiAwareServices` con los dos servicios, publicables y suscribibles.
  - Tests:
    - `TransportPolicyTests` (5).
    - `WiFiAwareLinkTests` (6): nombres válidos según RFC 6335; Info.plist y entitlement
      del Runner leídos desde el test; la cita de Bonjour; y que `.advertise` pide a la
      cita un listener por canal, con el loopback de verdad.
- IOS-14b, la app:
  - `RIG_LINK_INTERFACE=aware` en la app y en `link-bench`. `RigLinkNW.makeTransport` es
    la única fábrica del transporte (antes, dos copias).
  - El informe de `link-bench` añade `interface`, `rendezvous`, `transport_failures`,
    `transport_waiting` y, por Aware, `aware_signal`, `aware_capacity_mbps`,
    `aware_ceiling_mbps`, `aware_tx_latency_video_ms` y `aware_active_s`.
  - `transport_waiting` existe porque por Wi-Fi Aware, sin emparejado o sin
    entitlement, el listener no falla: se queda esperando. NWLinkTransport lo expone en
    `waitingReason`.
  - Pigeon `pairWithoutCable(role)` y el botón «Emparejar sin cable» en
    `role_page.dart`. Usa el lado elegido arriba y dice debajo con quién quedó
    emparejado o por qué no. `role_page_test.dart` (4).
  - `tools/banco_dos_moviles.sh emparejar`: la app normal en los dos, para el botón.

**Decidido (pendiente de revisión del propietario)**
- **Los medios por Wi-Fi Aware se llaman `_footballai-av._udp`**. `_footballai-media`
  tiene 16 caracteres y RFC 6335 admite 15. Apple avisa de que con un nombre inválido
  en el Info.plist la app se cierra al arrancar, y un test lo vigila. El control
  conserva `_footballai-rig._tcp`.
- **Dos servicios**, control y medios, como por Bonjour. No uso un servicio más
  `.addingConnections`, que pide iOS 26.4 y cambiar el transporte.
- **Sin TXT por Wi-Fi Aware**: la huella del secreto no viaja. Al otro soporte lo
  paran el emparejado y el hello autenticado.
- **`.interactiveVideo` también para el control**: la tarjeta pide la categoría de
  vídeo, y el control es poco tráfico.
- **La parte por Wi-Fi Aware va a 8 Mbit/s**, la misma que por Wi-Fi, hasta que SPK-08
  mida (`LinkMedium.partBitrateAwareBps`).
- **El «link-echo» de la tarjeta es `link-bench`**: un banco `link-echo` no existe.
  `link-bench` da el RTT del reloj (`link/rtt`), las pérdidas de medios
  (`media_loss_gaps`) y las de partes con `RIG_LINK_PARTS=1`.
- La política automática y el cambio en caliente son de IOS-17, que ya encuentra
  `TransportPolicy.swift` con `LinkMedium`.

**Lo que solo dirá el iPhone** (riesgos, por si no enlaza)
- El puente a la API clásica: `NWListener(service:using:)` con el `service` de
  `WAPublisherListener`, y NWBrowser con `makeDescriptor()`. Apple documenta ese puente
  pero enseña los ejemplos con la API nueva. Si no conecta, el plan B es pasar
  `WiFiAwareRendezvous` a `NetworkListener`/`NetworkBrowser` sin tocar las tramas.
- No sé qué hace la hoja de emparejado al terminar. Se cubren las tres salidas.
- Que el emparejado sobreviva a reinstalar con `BENCH=link-bench`. Es una
  actualización, no un borrado. Si se perdiera, el informe lo diría en
  `transport_waiting`.

**Fuera**
- IOS-63: por Wi-Fi Aware, `peerHost` es una IPv6 de enlace local de la interfaz NAN, y
  el mando por la LAN no la alcanza. El QR Mando solo sirve por Ethernet o Wi-Fi.
- La pantalla no enseña si ya hay emparejado al abrir; solo tras pulsar el botón.
- SPK-08 (90 min, vatios) e IOS-17.

**Comprobado**
- `swift test --skip ModelBench`: 340 tests, 1 saltado, 0 fallos.
- `tools/check_layers.sh` limpio.
- RigNet compilado para iOS con xcodebuild, sin avisos.
- `flutter analyze` sin avisos; `flutter test`: 361.
- `flutter build ios --release` ✓. El build lleva el entitlement y `WiFiAwareServices`.

**Para la próxima ventana con los dos iPhone** (desbloqueados, con el Bloqueo
automático en Nunca y el Wi-Fi encendido; el router no hace falta):

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
# 1. Una vez: la app normal en los dos. A mano, en cada uno su lado y «Emparejar sin
#    cable». El derecho (16 Pro) elige al iPhone 17 y teclea el código que enseña.
tools/banco_dos_moviles.sh emparejar <fichero_secreto>
# 2. El banco del enlace por Wi-Fi Aware: 10 min, partes a 0/10/30 Mbit/s cada 5 min.
#    Para probar sin router, el router apagado o lejos.
BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware"}' tools/banco_dos_moviles.sh link90 <fichero_secreto> 600
# 3. El informe: connected=1, interface=aware, rendezvous=aware, transport_waiting
#    vacío, link/rtt, media_loss_gaps, pérdidas de partes y los aware_*.
ls bench/dos-moviles-*/izquierdo/bench/link-bench-*.json bench/dos-moviles-*/derecho/bench/link-bench-*.json
```

**Siguiente paso**: la pasada de arriba para dar la aceptación, y luego IOS-17 (política
y cambio en caliente) y SPK-08 (90 min por Wi-Fi Aware).

## 2026-10-08 · IOS-28 — el Kalman del balón y el planificador de ROIs (RigCore) · ✅

Réplica en RigCore (solo Foundation) de `libs/vision/ball_kalman.py` (REF-28), contra
los 15 casos de `ball.json` (football-ai `a14ae4d`, sincronizado desde `5e4c4d5`). Va en
dos commits porque pasa de las 400 líneas con los tests.

**Hecho**
- `Detection/BallKalman.swift` (IOS-28a): `BallAxisFilter` y `BallKalman`. Es el modelo
  de velocidad constante en píxeles nativos, con un filtro por eje, `predict(dtS:)`,
  `mahalanobis2` y `update`. Las cuentas van en el mismo orden que la referencia y las
  constantes salen de `DetectionSpec` (`ballKf*`).
- `Detection/BallRoiPlanner.swift` (IOS-28a): `BallRoi` (`clamped`, `contains`),
  `BallRoiSource` y `BallRoiPlanner`:
  - `heatmapSide`: el lado con export más cercano; a empate, el mayor.
  - `roi(centeredAt:)`: ⌊c − lado/2 + 0,5⌋ y después se desplaza dentro del frame.
  - `plan(prediction:groups:…)`: la ROI de la predicción, con el lado que pide 6σ + 64,
    y la del grupo más cercano que no cae en ella. Sin filtro, los primeros grupos con
    el lado mayor.
- `Detection/BallTracker.swift` (IOS-28b):
  - `BallTracker` con TRACKING/COASTING/LOST, la candidata que pide una segunda
    detección, la puerta χ² 9,21 con el desempate por d²/score, la caducidad a 0,5 s con
    la edad en Double, la confianza con τ = 0,5 s, `globalSearchHz` (3 o 10) y
    `rois(groups:)`.
  - `BallEstimate`, `BallDetection`, `BallKalmanState` y `RigModel.fuseBall`
    (`fuse_estimates`).
- Tests:
  - `BallKalmanTests` replica el evaluador y pasa los 15 casos: 1 del filtro, 10
    secuencias y 4 fusiones. Además cubre la edad que caduca en el fotograma 16, la
    candidata, COASTING sin tocar el filtro, la puerta al nacer y lo que se rechaza.
  - `RoiPlannerTests` compara aparte las ROIs de las 10 secuencias doradas y fija los
    desempates: el lado, el centrado que no redondea al par, el desplazamiento, la
    segunda hipótesis y el caso sin filtro.

**Aceptación** («secuencias doradas idénticas, 1e-6»): **se cumple**. La tolerancia del
dorado es 1e-6 absoluta o 1e-9 relativa. La desviación máxima medida en los 15 casos es
de 2,8e-17 absoluta y 1,4e-16 relativa, prácticamente bit a bit. La tarjeta no pide
ninguna medida en el iPhone; lo que corre en el móvil es IOS-74.

**Decidido (pendiente de revisión del propietario)**
- `update` devuelve el **índice** de la detección que tomó el filtro, en vez de la
  detección. Python devuelve el objeto y el evaluador lo busca por identidad.
- `BallDetection` lleva x, y, score, `roiId` y `source`. No lleva `w`/`h`, porque el
  heatmap no mide la caja, ni `frame_seq`, que decidirá IOS-74.
- El planificador es una función pura (`BallRoiPlanner.plan`) a la que llama
  `BallTracker.rois`. Así RoiPlannerTests la prueba sin filtro.
- Un dt negativo y unas desviaciones inválidas lanzan `RigError`, como el `ValueError`
  de la referencia. `heatmapSide` sin lados devuelve nil.

**Pendiente para la referencia (football-ai, no tocado)**
- **La frase del Float no es exacta.** El ADR 0020 (REF-28c) y el docstring de
  `evaluate_ball_kalman.py` dicen que en float32 la pista caducaría en el fotograma 15 y
  que el dorado lo detecta. En float32, quince sumas de 1/30 dan **0,5 justos**: con `>`
  también caduca en el 16, y el dorado no lo ve. Probado aquí con una edad en Float:
  - con `>`, ball.json pasa entero;
  - con `>=`, fallan `oclusion_larga_lost_y_reentrada` y `salto_de_puerta_balon_desviado`.

  El dorado solo atrapa la combinación Float con `>=`. La réplica usa Double con `>`,
  como la referencia. Si se quiere blindar, hace falta un caso con un dt en el que Double
  y Float caigan a lados distintos de 0,5.
- **`BALL_ROI_SIDES` no está en `DetectionSpec`.** Swift usa `[ballRoiSide]` por defecto
  (`BallRoiPlanner.defaultSides`). Cuando SPK-52 apruebe 320, hay que exportarla.

**Fuera**: el recorte [2, 3, S, S], el carril y la decodificación (IOS-74). El balón en
la fusión del director (IOS-29). Las listas de ROIs y detecciones son arrays pequeños
(2 ROIs) que se crean en cada ciclo; si el banco de IOS-74 lo ve en el p99, se
preasignan.

**Siguiente paso**: IOS-74, que pasa a `BallTracker` las detecciones del lote y del
mosaico, y pasa las ROIs de `rois(groups:)` al recorte.

## 2026-10-07 · SPK-53 — la secuencia del spotter N4 en la app: MLState frente a E/S explícita · 🚧 falta la pasada del iPhone 17

El export de las dos variantes y su secuencia dorada están en el repo de entrenamiento
(`8b0b9a7`). Esta entrada es el arnés que las mide en la app.

**Hecho**
- `RigMedia/Obs/SequenceBench.swift`:
  - `SequenceManifest` lee el `sequence.json` (versión 1) que acompaña al bundle de ML-12.
  - `SequenceStepper` lleva un recorrido con su propio estado y deduce del modelo cuál de
    las dos maneras usa:
    - MLState: `makeState()` y `prediction(from:using:)`.
    - Explícita: dos juegos de MLMultiArray fp16 sobre IOSurface, en doble búfer. Con
      `outputBackings`, la salida `X_out` del paso k se escribe en el juego que lee el
      paso k+1, sin copias ni reservas de memoria dentro del bucle.
  - `SequenceBench.run` hace cuatro cosas: recorre la secuencia contra el dorado desde
    cero; la repite tras reiniciar; corre dos recorridos intercalados sobre el mismo
    MLModel, con 7 pasos de desfase; y mide la latencia por paso con el estado vivo, con
    percentiles exactos.
- `ModelBench`:
  - Un modelo con `"sequence"` en bench.json va a SequenceBench. Deja `state_mode`, la
    etapa `<nombre>/step`, `sequence_steps`, `golden_violations`, `golden_max_delta_x1e6`,
    `repeat_violations` e `interleave_violations`.
  - El fichero de modelos se elige con `MODEL_BENCH_SPEC` (bench.json por defecto).
    BenchRunner lo lee del entorno del lanzamiento.
  - Un modelo que no carga o que falla se apunta en el informe (`<nombre>/failed`, con el
    error en params) y el banco sigue con el siguiente: el -14 de MLState en el ANE
    también es una medida.
  - ModelBenchTests falla si algún modelo tiene `/failed` o si hay fugas.
- `SequenceBenchTests` (8 tests). Usan el gemelo diminuto: los paquetes
  `Fixtures/n4-tiny-{mlstate,explicit}.mlpackage` (25 KB cada uno) y el bundle
  `Fixtures/n4-tiny-v1` (12 pasos, 86 KB). Los genera el repo de entrenamiento y son
  idénticos a sus `runs/spk53/fixtures`. Comprueban:
  - que las dos variantes recorren el dorado sin fugas;
  - el contraejemplo: sin reiniciar, el dorado sí ve la fuga;
  - que las dos variantes dan lo mismo;
  - que un modelo sin estado no se acepta como modo paso;
  - los strides de un IOSurface;
  - el banco entero por un bench.json que incluye un modelo inexistente.
- `tools/spk53_bench.sh` tiene tres modos:
  - `recursos <runs/spk53>` monta `build/spk53/bench-resources/`: los dos paquetes
    (2,8 MB cada uno) y la secuencia de 100 pasos (34 MB). No van a git.
  - `mac` corre ModelBenchTests con esos recursos.
  - `iphone [dispositivo]` compila con `BENCH=model-bench`, instala la app, sube los
    recursos y comprueba que han quedado donde ModelBench los busca. Luego lanza cada
    variante por separado con `tools/bench_iphone.sh`, que solo cierra la Zero, y acaba
    con la aceptación de la tarjeta criterio a criterio. Se ha probado contra un `xcrun`
    falso.
- `BenchResources/README.md`: `sequence`, `function` y `MODEL_BENCH_SPEC`.

**El error de compilación** de `SequenceBenchTests.swift:124` ya no estaba en el stash.
Los strides que recibe el cierre de `withUnsafeMutableBytes` son `[Int]`, y la línea ya
usa `pasos[1]` sin `intValue`. Compila y pasa.

**Medido en el Mac** (M4, macOS 26.3, carril `mac`, `cpu_and_ne`, compilación debug):

| variante | ANE | paso p50 / p99 | dorado, 100 pasos | reinicio · intercalado |
|---|---|---|---|---|
| explícita | 100 % | 0,27 / 0,30 ms | 0 fuera (peor Δ 0,0135) | 0 · 0 |
| MLState | 100 % | 0,26 / 0,29 ms | 0 fuera (peor Δ 0,0135) | 0 · 0 |

Los 12 ms que dio la explícita en este mismo carril, según el repo de entrenamiento, no se
repiten con el Mac menos cargado. La cifra que vale es la del iPhone.

**Para la pasada del iPhone 17** (desbloqueado y con el Bloqueo automático en Nunca; los
recursos ya están montados en `build/spk53/bench-resources`):

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
# solo si cambió el export:
tools/spk53_bench.sh recursos /Users/alexander/Trabajacion/fooball_ai_training/runs/spk53
tools/spk53_bench.sh iphone 8FBBECC4-5239-59C4-BE22-5EEFB5958863
```

En el iPhone queda un `Documents/bench/model-bench-<epoch>.json` por variante, en el
contenedor de `com.logicielapplab.zero`. En el Mac bajan a
`bench/spk53-<fecha>/n4-step-explicit.json` y `n4-step-mlstate.json`.

**Decidido (pendiente de revisión del propietario)**: si las dos variantes pasan los cuatro
criterios, se elige la de menor p50 por paso. Si empatan (diferencia ≤0,1 ms), gana la E/S
explícita, por dos razones: no depende de MLState, que ya dio el -14 en el ANE con la forma
nativa, y su estado se puede leer o guardar sin API nueva.

**Siguiente paso**: la pasada en el iPhone. Con ella se elige la variante y se cierra
SPK-53, también en el PROGRESS del repo de entrenamiento.

## 2026-10-07 · IOS-23 (cont.) — el banco del decodificador (`decoder-bench`) · 🚧 falta la cifra del iPhone

**Hecho**
- `RigMedia/Obs/DecoderBench.swift`, en BenchRunner como `decoder-bench`: lo que cuesta
  pasar las salidas del modelo a cajas con `PlayerDecoder`, sin el modelo y sin la copia
  desde MLMultiArray (`planes`, que es de CoreMLPlayerDetector). Las salidas se siembran
  (SplitMix64) antes de medir y las muestras se guardan en crudo, con percentiles
  exactos, como en director-bench. Tres etapas:
  - `decoder/detr300`: 300 queries × 3 clases, 25 personas sobre el umbral. Es la
    aceptación.
  - `decoder/heatmap`: el CenterNet del plan B (ADR 0020), 3×144×480 con 25 picos.
  - `decoder/heatmap_saturated`: ruido uniforme, como los pesos sembrados; llega al tope
    de detecciones.
  `calls` por `BENCH_PARAMS` (2000 por defecto).
- `DecoderBenchTests`: con 3 llamadas por BenchRunner, el informe sale con las tres
  etapas (p50 ≤ p99) y las detecciones del guion (25, 25 y `playerMaxDetections`).
- `tools/bench_iphone.sh <banco> [dispositivo]`: un banco de BenchRunner en el iPhone sin
  tocarlo. Compila con `BENCH`, instala, cierra solo la Zero (`procesos_zero.py`), lanza,
  espera el informe nuevo de `Documents/bench/`, lo baja a `bench/<banco>-<fecha>/` y
  vuelve a cerrar la Zero. Admite `ENTORNO` (variables del lanzamiento), `SIN_COMPILAR`,
  `BENCH_PARAMS`, `SALIDA` y `NOMBRE`. Se ha probado contra un `xcrun` falso: el informe
  baja, una Zero muerta se detecta (dos miradas seguidas sin proceso) y nunca se cierra
  el Runner de otra app. En el iPhone no se ha probado, porque estaba ocupado.

**Medido en el Mac** (M4, release, 2000 llamadas): `detr300` p50 **0,021 ms** (p99 0,036);
`heatmap` 0,092 ms; `heatmap_saturated` 1,63 ms.

**Para medir en el iPhone 17** (desbloqueado y con el Bloqueo automático en Nunca):

```bash
cd /Users/alexander/Trabajacion/fooball_ai_capturer
tools/bench_iphone.sh decoder-bench 8FBBECC4-5239-59C4-BE22-5EEFB5958863
```

En el iPhone, el informe queda en `Documents/bench/decoder-bench-<epoch>.json`, dentro del
contenedor de `com.logicielapplab.zero`. En el Mac baja a `bench/decoder-bench-<fecha>/`.
Pasa si `stages_ms["decoder/detr300"].p50_ms` < 0,2.

**Decisión mínima (pendiente de revisión del propietario)**: el «<0,2 ms» de la tarjeta se
lee sobre el p50. El p99 se apunta al lado.

**Siguiente paso**: la pasada en el iPhone. Cuando pitch.json llegue al móvil, pasar
`FootMask(pitch:)` a CoreMLPlayerDetector.

## 2026-10-07 · IOS-23 (cont.) — umbrales en float32, picos más baratos y la máscara del campo desde PitchModel · 🚧 falta medir en el iPhone

El postproceso ya estaba (2026-10-04, `Postprocess.swift` + `PlayerDecoder`, con los
dorados). Faltaba de la tarjeta el filtro de pies por PitchModel, los tests que nombra y
la cifra en el iPhone.

**Hecho**
- **Divergencia con la referencia, arreglada**: numpy compara un tensor float32 con un
  `float` de Python en float32 (NEP 50) y la réplica comparaba en Double. Justo en el
  umbral daban distinto: un pico igual a `Float(0.3)` pasaba `> 0.3` en Swift y no en
  numpy; un score igual a `Float(0.7)` no pasaba `>= 0.7`. Ahora el umbral de confianza,
  el de los picos (también el del balón) y el margen de la junta se comparan en Float.
- `heatmapPeaks` más barato sin cambiar el resultado: ventana recortada al mapa (equivale
  al borde replicado), sale con el primer vecino mayor y solo ordena los
  k·(2·kernel − 1)² mejores candidatos (cada pico descarta como mucho
  (2·kernel − 1)² − 1 vecinos por la meseta). Mapa saturado 3×144×480 (pesos sembrados)
  en el Mac en release: 5,8 → ~1,8 ms; mapa de partido: ~0,08 ms.
- `RigCore/Detection/FootMask.swift`: la `pitch_mask[y, x]` sin mapa de bits. El pie se
  recorta y se trunca como `np.clip(...).astype(np.intp)`, y con
  `FootMask(pitch:width:height:)` el píxel se pregunta a `PitchModel.isInsidePlayable`
  (la rasterización de IOS-36). `decode`/`decodeHeatmap` toman `footMask:` en lugar del
  par `onPitch`/`pitchSize`.
- Tests (+12): HeatmapPeaksTests (contra la versión directa en 300 mapas al azar, con
  mesetas, empates y Float(0.3) justo en el umbral; un mutante que no mira más allá de
  los primeros candidatos cae), NmsTests (el desplazamiento = NMS por clase, con
  coordenadas negativas), DetrDecodeTests (los dos casos de detectors.json con
  `pitch_mask` salen iguales con un PitchModel cuya área jugable es ese rectángulo;
  recorte y truncado del pie; umbral en float32; recorte a la región; errores de ficha).

**Decisiones mínimas (pendientes de revisión del propietario)**
- La tarjeta pide `DetrDecode.swift`, `Nms.swift` y `HeatmapPeaks.swift`; el código sigue
  en `Postprocess.swift` (decisión del 2026-10-04) y solo los tests llevan los nombres de
  la tarjeta: mover ficheros ahora chocaría con quien toca la parte de ML.
- Un pie NaN (salida rota del modelo) no pisa el campo: truncarlo abortaría la app. En
  la referencia es indefinido.

**Pendiente para la referencia (football-ai)**
- Un dorado con un valor exactamente en `Float(umbral)` (picos y DETR) que fije la
  comparación en float32.
- `_finish` ordena con `np.argsort(-scores)`, que no es estable: con scores empatados el
  orden depende de la plataforma. La réplica desempata por índice; `kind="stable"` lo
  fijaría.
- No hay rasterizador de `pitch_mask` desde un PitchModel: los dorados solo traen
  rectángulos.

**Queda fuera (sin commitear por la pausa)**: `RigMedia/Obs/DecoderBench.swift`,
`DecoderBenchTests.swift` y su entrada `decoder-bench` en BenchRunner (que ahora también
lleva cambios de SPK-53 de otro agente). Mide `decoder/detr300`, `decoder/heatmap` y
`decoder/heatmap_saturated`; en el Mac en release, 300 queries p50 0,021 ms. La cifra de
la aceptación (300 queries <0,2 ms **en el iPhone**) sigue sin medir. Tampoco se ha
compilado la app (`flutter build ios`): no se tocó nada del Runner ni de Dart.

**Siguiente paso**: commitear el banco cuando SPK-53 suelte BenchRunner, lanzarlo en el
iPhone (`--dart-define=BENCH=decoder-bench`) y, cuando pitch.json llegue al móvil, pasar
`FootMask(pitch:)` a CoreMLPlayerDetector.

## 2026-10-07 · IOS-62 — el `command` del túnel y la aceptación con PanelControl · 🚧 falta el tercer iPhone en la LAN

La API ya estaba (2026-10-04). Faltaba lo que el VPS de NUBE-07 (`tools/nube/control.py` y
el maestro falso) espera del maestro por el túnel, y la aceptación con el cliente de verdad.

**Hecho**
- `MasterApi.command(ApiRequest)`: los `command` del túnel (IOS-65) con los mismos
  manejadores que la LAN. Devuelve `CommandReply`: el `state` (el DTO sin `scopes`) si la
  orden subió `rev`, que el túnel tiene que mandar **antes** que la `response` (ADR 0022,
  anotado al implementar NUBE-07), y `responseData`, la `response` v1
  `{status, headers: {content-type}, body}`.
- `ApiRequest.fromCommand(data)`: la query cruda sin `since` (un `command` nunca espera),
  las cabeceras, el cuerpo ya JSON (sin exigir `content-type`) y `principal`.
- `principal: operator` (el panel remoto, NUBE-08) entra sin `Authorization` con `match`,
  `stream` y `rig`. Por la LAN no hay principal: siempre el Bearer.
- Tests (+10, 23 en api_server_test):
  - la aceptación con PanelControl contra el servidor real en el mismo proceso: dos
    mandos apuntan el mismo gol a la vez (uno se aplica y el otro recibe 409 con el
    marcador bueno); un proxy TCP corta la vuelta de una orden ya aplicada y el reintento
    con la misma clave no suma otro gol; la espera larga despierta en ≤100 ms; el noveno
    mando recibe 503 y sigue con el partido sin `since`;
  - el `command` con los dorados de `tunnel.json` (`valido_command_del_panel`,
    `valido_command_del_mando` y la forma de `valido_state` y `valido_response_del_maestro`):
    el `state` antes de la respuesta, el reintento por el túnel y por la LAN con la misma
    clave, el 409 sin `state` y el `since` que no hace esperar.

**Decisiones mínimas (pendientes de revisión del propietario)**
- Por el túnel, `stream/*` da 404 y no se reenvía como `relay_command`: el hub nunca la
  manda (la atiende él, que tiene el relé), y atenderla haría esperar a un `command`.
  También dan 404 los GET que no son `match` (miniaturas y estado del soporte: los sirve
  el hub, ADR 0022 §12).
- Un `command` de `principal: operator` sin `x-zero-device` no entra en la lista de mandos
  del maestro: el hub lleva la suya.
- Basta con que un `state` con ese `rev` vaya por delante de la respuesta en la cola del
  túnel: IOS-65 puede fusionarlo con el que mande por `MatchEngine.changes`.

**Queda fuera**: conectar `command` al túnel (IOS-65) y la prueba de la tarjeta en la LAN
con un tercer iPhone que lleve el marcador del maestro (solo hay un iPhone y está en el
banco). Con el Mac de tercer dispositivo ya se hizo (2026-10-04 y 2026-10-05: gol 200, el
repetido 409 y la réplica en el esclavo).

**Siguiente paso**: IOS-65 llama a `MasterApi.command` con cada `command` y manda
`reply.state`, si lo hay, antes de la `response`.

## 2026-10-07 · Primer programa con la geometría calibrada (IOS-71, SPK-04) y la memoria sin ficheros

**El cosido, con geometría medida.** Hasta hoy todas las pasadas usaban la geometría
nominal (±45° de yaw, roll 0), y de ahí la imagen doblada en la costura. Con los dos
móviles abiertos como en el soporte (a mano, sin soporte ni hubs) y una escena de
interior, se calibró con los 5 pares que saca el banco al empezar
(`bench/dos-moviles-20261007-1222`) y la misma `calibrate_upright` del servicio NUBE-09:

- Con los umbrales del repo **no calibra**: 6-12 de 30 puntos coherentes, porque todo
  está a 2-4 m y el paralaje entre lentes rompe el modelo de rotación pura.
- Con un umbral tolerante **solo para esta prueba** (RANSAC 12 px y 12 puntos, en un
  script aparte; el repo no cambia) los cinco pares coinciden: **yaw ±32,7°** entre
  cámaras y **roll −7° en el derecho** (estaba ladeado), residuo 0,13-0,18°.
  `docs/img/rig-interior-20261007.json`.
- Copiado como `Documents/rig.json` a los dos iPhone (la app lo carga si existe; el
  informe dice `rig: rig.json`), 150 s de programa (`bench/dos-moviles-20261007-1229`):
  pared, esquina, cama y cable salen continuos a través de la costura; solo se dobla la
  gorra junto a la camiseta, a ~2 m (paralaje). `docs/img/cosido-calibrado-20261007.jpg`.

Para cerrar IOS-71 / SPK-04 falta lo de siempre: el soporte y una pareja de cancha (todo a
más de 20 m) con los umbrales del repo. **Ojo:** los dos iPhone se quedan con ese
`rig.json` de interior en Documents; bórrese o recalíbrese antes de otra pasada.

**Memoria del maestro sin ficheros.** Sin la copia .mov ni el .ts
(`RIG_SPLIT_NO_MOV=1 RIG_SPLIT_NO_TS=1`, `bench/dos-moviles-20261007-1153`) sigue creciendo
1,44 MB/min (1,61-1,64 con ellos). No es la escritura: queda la composición, el
codificador del programa, el decodificador de las partes o el director. Lo siguiente es
bisecar con el director y el detector apagados.

## 2026-10-07 · IOS-49 — director de anuncios y descarga de paquetes (Dart) · 🚧 falta el túnel (IOS-65) y probarlo en el iPhone

**Hecho**
- `lib/src/ads/ad_director.dart`: porte de tools/ad_director.py: `AdTrigger` (gol,
  medio-tiempo, arranque), `MatchSignals` (del MatchEngine: goles, reloj en marcha y
  `streaming` como «al aire»), `triggerBetween` y `adEventLoops` = 2 (`EVENT_LOOPS`).
  `AdDirector.load` manda `setAdPlaylist` (todos los anuncios; en `slots` solo la
  rotación, por orden alfabético) y `observe`, en un flanco con anuncio vendido,
  `setAdOverride(nombre, 2)`. La vuelta a la rotación la hace el nativo (AdRotation);
  Dart solo lleva `eventOnAir` con un Timer para enseñarlo.
- `lib/src/ads/ad_pack_downloader.dart`: atiende `ads_changed {manifest_sha256, url}`,
  baja el manifiesto v1 de NUBE-17 (comprueba su sha256 y `v`) y cada PNG a
  `Documents/ads/blobs/<sha>.png` con `Authorization: Bearer` y `Range` sobre el
  `.part` (206 sigue, 200 empieza de cero), comprueba tamaño y sha256 y renombra.
  `current` se escribe el último; `loadCurrent()` lo recupera sin red. Los avisos se
  atienden en orden y uno que repite el vigente no baja nada.
- MasterHost (`adSink`, `adPacks`): al dirigir carga el paquete vigente, cada uno nuevo
  y observa el partido con cada cambio. capture_page crea el downloader en los dos
  móviles (el esclavo lo tiene si se promueve).
- Nativo: `setAdPlaylist` acepta `frames` (un PNG por fotograma, relativo a
  `Documents/ads/`) en lugar de `dir`; `AdStore.loadFiles` decodifica cada PNG distinto
  una vez y los repetidos comparten búfer (600 fotogramas de 40 PNG ocupan 40).
- Tests: ad_director_test (fake_async: gol → `gol` 2 vueltas y vuelta a la rotación;
  primer corte, evento sin anuncio, gol sobre gol; el gol por `match/goal` en un
  MasterHost), ad_pack_downloader_test (VPS falso: token, corte a mitad de PNG y
  reanudación con `Range: bytes=2500-`, servidor sin Range, PNG corrupto, 401, manifiesto
  ajeno, mensajes mal formados); AdStoreTests amplía el de PNG con `loadFiles`.

**Decisiones mínimas (pendientes de revisión del propietario)**
- Los fotogramas van al nativo como lista de rutas (`frames`) y no como directorios con
  copias o enlaces: no hay que duplicar en disco los PNG repetidos ni decodificarlos 600
  veces.
- Sin reintento propio: una descarga que falla lanza, deja el `.part` y sigue con el
  siguiente `ads_changed` (el VPS lo manda tras cada `welcome`). Tiempo de espera de red
  `adDownloadTimeout` = 30 s.
- Cargar un paquete nuevo reinicia la rotación y quita el evento en curso (es lo que hace
  `setAdPlaylist` del nativo); la referencia `add` no reinicia.
- No se borran paquetes ni PNG viejos de `Documents/ads` (como el catálogo del VPS).

**Queda fuera**: conectar `AdPackDownloader.onAdsChanged(mensaje, base:, token:)` al
túnel (IOS-65, con la base del VPS y el token del soporte); enseñar `eventOnAir` y
`error` en el panel; la prueba en el iPhone con un paquete real.

**Siguiente paso**: IOS-65 llama a `onAdsChanged` con cada `ads_changed`.

## 2026-10-07 · La espera de la parte a 130 ms y el anillo propio a 6 huecos (SPK-04, IOS-44)

Con los sellos ya en el reloj del host, la parte llega por Wi-Fi con p50 90 / p95 115 /
p99 125 ms, y con `PART_MAX_WAIT_MS` = 100 el 19 % del programa salía de una lente.
Medido con los dos iPhone, imagen real y toda la carga (director, CenterNet en los dos,
micro):

| | Espera 100, anillo 4 (1020, 30 min) | Espera 130, anillo 4 (1058, 20 min) | Espera 130, anillo 6 (1126, 20 min) |
|---|---|---|---|
| Una lente | 10 267 (19 %) | 852 (2,4 %) | **721 (2,0 %)** |
| Sin el fotograma propio | 0 | 175 | **0** |
| Latencia añadida p95 | 110 ms | 145 ms | 144 ms |

Con 4 huecos (133 ms), el fotograma de hace 130 ms a veces ya había salido del anillo:
`PipelineConstants.frameRingSlots` pasa a 6 (+25 MB) y `LinkConstants.partMaxWaitMs` a
130. El objetivo de IOS-44 (≤120 ms) deja de cumplirse por ~25 ms: enmienda en el ADR
0023 de football-ai (f3d1542), pendiente de la revisión del propietario. Los tests que
llevaban los 100 ms escritos los toman ahora de la constante.

**Memoria del maestro**: sin la copia .mov (`RIG_SPLIT_NO_MOV=1`) crece igual, 1,64 MB/min
(1,55 y 1,61 con ella). No es la .mov; se prueba sin el .ts.

Swift 297 tests (1 saltado) ✅.

## 2026-10-07 · El fotograma propio del maestro se perdía: el reloj del micro (IOS-13, IOS-54, SPK-54)

**Qué pasaba.** La pasada de 90 min con imagen real (`bench/dos-moviles-20261007-0837`) dio
el programa sin el fotograma propio del maestro en 123 235 de 156 079 fotogramas (79 %):
la mitad del maestro en negro hacia el minuto 20 y SIN SEÑAL desde el 66, aunque las
partes del esclavo llegaron todas (161 569 decodificadas). Las pasadas de 30 min ya lo
tenían y no se vio: 8 102 (hoy) y 12 717 (ayer) fotogramas sin el propio, pero ningún
SIN SEÑAL, que es lo que se miraba.

**Por qué.** Desde IOS-54 el micro está en la misma `AVCaptureSession` que la cámara, y
entonces AVFoundation sella vídeo y audio con el reloj del dispositivo de audio
(`synchronizationClock`), no con el del host. El PTS se usaba tal cual, mientras el tic del
programa, el enlace y el reloj del soporte van en el del host. Medido: el reloj de la
sesión se separa del host **2,8 ms/min en el iPhone 17 (46 ppm) y 3,7 ms/min en el 16 Pro
(61 ppm)**. Al pasar de ~17 ms el maestro ya no encuentra su fotograma del instante de la
parte; al pasar de la espera de la parte, ni las partes.

**Arreglo.** `CaptureEngine.hostNs` convierte cada PTS con `CMSyncConvertTime` del reloj de
la sesión al del host antes de sumar el desfase del soporte: el vídeo, el audio del
programa (AudioCapture) y el audio de la 4K. El informe del banco gana
`capture_clock_skew_ms` (la separación minuto a minuto) y `part_wait_ms`; el banco,
`RIG_SPLIT_PART_WAIT_MS`, `RIG_SPLIT_NO_MOV` y `RIG_SPLIT_NO_TS` para las mediciones que
siguen.

**Medido después** (30 min, la misma carga: director, CenterNet en los dos, micro):

| | Antes (0802) | Después (1020) |
|---|---|---|
| Sin el fotograma propio | 8 102 | **0** |
| SIN SEÑAL / retenidos | 0 / 199 | 0 / 0 |
| Dos lentes / una lente | 52 087 / 1 912 | 43 724 / **10 267** |
| Edad de la parte p50 / p95 / p99 | 45 / 90 / 105 ms | **90 / 115 / 125 ms** |
| Latencia añadida p95 | 109 ms | 110 ms |

**Lo que destapa.** Con los sellos bien, la edad real de la parte es p50 90 / p99 125 ms:
la de antes salía baja porque los sellos del esclavo derivaban. Con `PART_MAX_WAIT_MS` =
100 (ADR 0023, «objetivo» que fija SPK-04), el 19 % de los fotogramas sale de una lente
porque la parte aún no llegó. Se mide 130 ms con `RIG_SPLIT_PART_WAIT_MS` antes de
proponer el cambio.

**Sigue abierto**: la memoria del maestro crece ~1,4 MB/min (610 MB a los 90 min; el
esclavo, plano en ~427 MB). No está en las colas del banco ni del compositor, que están
acotadas; se separa con `RIG_SPLIT_NO_MOV` y `RIG_SPLIT_NO_TS`.

## 2026-10-07 · IOS-50 — la SEI del soporte, atada a los dorados de la sonda del VPS (NUBE-20)

`sei.json` llega sincronizado desde football-ai (2c5018d) y `H264SeiTests` lo consume:
`H264Sei.build` da los mismos bytes que `tools/nube/sei_probe.py` en los 4 casos de
construcción (con emulación, rigMs 0 y 2^53 - 1) y `parse` lee igual los 5 de lectura
(otro UUID, una SPS y una NAL cortada no son nuestras). La sonda midió en la Mac que la
SEI sobrevive a SRT → MediaMTX → RTSP en el 100 % de los fotogramas.

Swift 297 tests (1 saltado) ✅ · Flutter 333 ✅.

## 2026-10-05 · PlayerDecoder con el camino heatmap del plan B (ADR 0020) · ✅

Aditivo: `detr` y `nms` no cambian. `PlayerDecoder` gana `postprocess: .heatmap` con
`boxFormat: .heatmapStride` y `heatmapStride` (obligatorio con heatmap y solo con él), y
`decodeHeatmap(heatmap:offset:size:…)` para las tres salidas de CenterNet-MNv4: picos con
`Postprocess.heatmapPeaks`, centros con `refineOffset`, tamaño en celdas × paso, y desde
ahí lo mismo que `xyxy_input_px` (vuelta a nativo, junta, máscara por los pies, orden).
Los tres casos `heatmap_*` nuevos de detectors.json (football-ai 7000268) cuadran con la
tolerancia del dorado; los 18 de antes siguen igual.

Fuera: `CoreMLPlayerDetector` sigue pidiendo logits y cajas; cablear el camino heatmap
llega con la ficha de CenterNet en el registro. La decisión formal de REF-33 (ADR 0020
PROPUESTO) sigue siendo del propietario.

**Siguiente paso**: la ficha de CenterNet-MNv4 con pesos propios y su cableado en
`CoreMLPlayerDetector`.

## 2026-10-07 · IOS-38 — el igualado de color con los móviles colocados como en el soporte · ✅ (objetivo)

Móviles lado a lado en V, mirando una habitación con luz; 150 s; +1/3 EV en el esclavo a
los 60 s. El desajuste del banco usa el ISO y, si llega a su tope, la obturación, y apunta
lo aplicado (`exposure_bias`). Esta vez fue +0,333 EV: ISO de 1089 a 1372 con la misma
obturación de 10 ms. Datos en `bench/dos-moviles-20261007-0755`.

| Tramo | Solape en bruto | Solape con las ganancias |
|---|---|---|
| Antes del golpe (40-60 s) | ~20-21 % | 0,06-0,8 % |
| Tras +1/3 EV (60-150 s) | ~21-23 % | pico de 1,86 % a los 2 s, luego 0,01-0,9 % |

**La diferencia con las ganancias nunca pasa del 2 %** (la aceptación pide bajar de 2 %
en ≤10 s). Ganancias finales cerca de 1: izquierda 0,86/0,99/1,03, derecha 1,16/1,01/0,97.

**Salvedad**: el +1/3 EV solo movió el bruto unos 2 puntos, no el ~25 % esperado. El
procesado de imagen del iPhone (mapeo de tonos del vídeo) parece compensar parte del
cambio de ISO, así que el golpe real fue menor. En una pasada anterior el ISO estaba en su
tope y el desajuste no se aplicaba: de ahí el registro de lo aplicado.

**A ojo** (fotogramas del programa): el color es continuo a los dos lados de la costura.
Lo que se ve es geometría: una banda con doble imagen (la esquina de la pared y un objeto
colgado), porque el banco usa la geometría nominal del soporte sin calibrar y los móviles
están a mano. Lo arregla la calibración (IOS-71, con el VPS).

## 2026-10-06 · Con imagen real: las partes a 12 Mbit/s saturan la Wi-Fi; a 8, no (IOS-43, IOS-52, SPK-02)

Los dos iPhone boca arriba, viendo el techo, con micro, director y detección en los dos.
Datos en `bench/dos-moviles-20261006-1147` y `-1159`.

| | 10 min, partes a 12 Mbit/s | 5 min, partes a 8 Mbit/s |
|---|---|---|
| Caudal de partes | 11,4 Mbit/s | 7,7 Mbit/s |
| Pérdidas | 133 (**0,75 %**) | 8 (**0,09 %**) |
| Peticiones de IDR | 137 (una cada ~4 s) | 10 |
| Cierre de un hueco | p50 80 / p99 115 ms | p50 75 / p99 85 ms |
| Programa | 17 999 fotogramas, 0 fallos, latencia p95 111 ms | 8999, 0 fallos, p95 110 ms |
| SIN SEÑAL | 65 fotogramas | 63 fotogramas |
| Descartes del esclavo | 128 | 8 |

**Lectura**:
- Con la escena negra, las partes pesaban 1-2 Mbit/s y no apretaban. Con imagen real, 12
  Mbit/s pasan de lo que da la Wi-Fi entre los dos móviles (~10, SPK-02): pierden el
  0,75 % y piden un IDR cada 4 s. A 8 Mbit/s la pérdida baja ocho veces.
- **Recomendación**: 8 Mbit/s por defecto para las partes por Wi-Fi, y 12 solo por
  Ethernet. La decisión va en el ADR 0023 cuando se mida Ethernet.
- Los ~2 s de SIN SEÑAL salen igual con las dos cifras: no son pérdidas, son el arranque.
  El maestro compone una vista en la mitad del esclavo antes de que llegue la primera
  parte.
- Térmica: el esclavo pasa a serious en el primer minuto y el maestro a los 8 min.
- En el esclavo, cámara → app p50 25 ms, y la parte sale con p50 60 ms.

## 2026-10-06 · IOS-38 — el igualado de color con luz, medido con los dos iPhone · 🚧

El banco gana `RIG_SPLIT_EV` / `RIG_SPLIT_EV_AT_S`: el esclavo sube el ISO ×2^EV (con la
misma obturación, sin parpadeo; `CaptureEngine.benchExposureBias`). El maestro apunta en
`color_series`, por cada observación (cada 2 s), la diferencia relativa de luma (BT.601)
del solape en bruto y con las ganancias.

**Medido** (150 s; +1/3 EV en el esclavo a los 60 s; móviles boca arriba sobre una mesa,
viendo el techo; `bench/dos-moviles-20261006-1137`):
- **en bruto, el solape difiere un 40-50 % ya antes del desajuste**: sin el soporte
  montado, las dos zonas de solape no ven lo mismo. La cifra de la aceptación pide el
  soporte de verdad;
- **al arrancar**, las ganancias llevan la diferencia del 30 % a menos del 2 % en unos
  20 s, y la sostienen en ~0,3-2 %. Ganancias finales: izquierda 0,73/0,82/0,82, derecha
  1,37/1,21/1,22 (BGR);
- **tras +1/3 EV a los 60 s**, la diferencia con ganancias sube al 3,5 % y vuelve por
  debajo del 2 % a los 76 s, unos **16 s** (la tarjeta pide ≤10 s). Es el suavizado de
  PANORAMA_COLOR_MATCH_SMOOTHING con una observación cada 2 s.

**Falta**: repetirlo montado en el soporte, mirando la misma escena. Si sigue en ~16 s,
subir el suavizado o la cadencia de observación (0,5 Hz hoy), cambiando el dorado de
color.

**Nota**: una primera pasada salió entera SIN SEÑAL y sin partes, con el enlace cayendo
cada 10 s, justo tras reinstalar los dos. La pasada siguiente, sin reinstalar, fue bien;
apunta a un arranque fallido. El banco gana `SIN_INSTALAR=1` para no recompilar entre
pasadas.

## 2026-10-06 · IOS-85 (la parte local) — el maestro cae y el esclavo NO se promueve, como dice el ADR

Banco de 240 s con los dos iPhone: el maestro (izquierdo) muere a los 93 s y vuelve a los
171 s.

| Móvil | Resultado |
|---|---|
| Esclavo (derecho) | Sigue de esclavo los 240 s; 3513 partes enviadas, ninguna mientras el maestro estuvo muerto |
| Maestro, al volver | Retoma el mando: 2100 fotogramas en 70 s, 0 fallos; el esclavo le manda partes otra vez |
| Programa | **Ninguno durante los 78 s de caída** |

**Lectura**: es lo que pide el ADR 0023 §8. Sin VPS no hay promoción automática: un esclavo
aislado no sabe si cayó el maestro o si es él quien está solo. La promoción automática
exige el `welcome` del túnel y `master_status: lost` del hub durante ≥5 s; sin ellos, solo
la fuerza el operador («Este móvil dirige»).

**El relevo del operador, conectado (sin VPS)**: `RigLinkSession.forceMaster()`
(«Este móvil dirige», con su test) hace que el esclavo tome el mando con `term + 1` y lo
avise. Cuando vuelve el maestro de antes, con un term menor, la negociación lo deja de
esclavo. El banco lo prueba con `RIG_SPLIT_FORCE_AT_S` (el esclavo fuerza el relevo si el
enlace está caído). Con los dos iPhone (maestro muerto a los 90 s, relevo a los 100,
vuelta a los 170):
- el promovido compone **con su propia cámara**: 4199 fotogramas `masterOnly`, 0 fallos;
- en una pasada, el maestro de antes volvió y quedó de esclavo: 2 s provisional y luego
  1529 partes enviadas; en otra no llegó a conectarse en los 67 s que tenía;
- **con 150 s tras la vuelta, el ciclo sale entero**:
  - el derecho, promovido, compone 5999 fotogramas en 200 s con 0 fallos;
  - el izquierdo vuelve de esclavo y le manda 3464 partes; llegan 3401, con 1 perdida.

  Las partes no entran al programa (todo `masterOnly`): el barrido de prueba del banco gira
  en torno a la cámara del maestro y, con el derecho dirigiendo, no cruza a la mitad
  izquierda. Es una rareza del banco, no del producto.

**Tres fallos encontrados por el camino, arreglados**:
1. El promovido salía todo SIN SEÑAL. El banco tomaba la hora del host mientras el anillo
   está sellado en el reloj del soporte, y el promovido tiene desfase. Ahora el instante
   del programa y la llegada de las partes usan `rigNowMs()`.
2. **La app del maestro se caía** al escribir en el .ts ya cerrado (10:13 y 10:25): lo que
   quedaba en la cola de escritura tras `finish()`. Ahora usa `write(contentsOf:)`, que no
   aborta, y `tsFile` se deja a nil al cerrar.
3. **El promovido se caía al escribir el informe**: un percentil desbordado daba infinito
   y `JSONSerialization` aborta. Ahora `jsonSafe` lo pasa a -1.

`RoleElection` (IOS-83) está hecha y probada, pero aún **no está conectada** a
RigLinkSession ni a la app. Eso es IOS-85, que depende del VPS (IOS-56, IOS-65, NUBE-14).
Mientras tanto, en la cancha, si cae el maestro no hay programa hasta que vuelve o hasta
que el operador fuerce el relevo, y ese camino del operador tampoco está conectado
todavía.

## 2026-10-06 · IOS-43 e IOS-52 — la edad de las partes y el cierre de un hueco, medidos con los dos iPhone

MasterProgramStage gana dos histogramas, con su test (`testLaEdadDeLasPartesYLoQueTardaElIdr`):
- `partAge`: la llegada de cada parte menos la captura del esclavo, en el reloj del
  soporte, con cubos de 5 ms hasta 150;
- `idrRecovery`: de la primera petición de IDR por un hueco a la llegada de la clave que
  lo cierra.

El informe del banco los da como `part_age_ms` e `idr_recovery_ms`.

**Medido** (10 min, Wi-Fi, con micro, director y detección en los dos):

| Qué | Resultado | Objetivo de la tarjeta |
|---|---|---|
| Edad de la parte | p50 70 / p95 90 / p99 105 ms | IOS-43: p95 ≤60 ms por Ethernet |
| Cierre de un hueco | 1 hueco en 10 min, cerrado en 70 ms (unos 2 fotogramas) | IOS-52: ≤2 fotogramas tras la petición |
| Partes | 17 933 recibidas, 1 perdida, jitter 6,2 ms | — |
| Programa | 17 999 fotogramas: 17 147 con las dos lentes; latencia p95 111 ms | — |

Por Wi-Fi la parte llega con 90 ms de p95, por encima de los 60 que IOS-43 pide por
Ethernet. Aun así cabe en la espera de 100 ms del programa: solo se perdió 1 parte.
Hay seis `suspect` momentáneos del par en los 10 min.

**Desglose** (5 min más; el esclavo apunta `slave_send_age_ms`, la edad de la parte al
salir, pasando su hora al reloj del soporte con `RigClock.offsetAt`):

| Tramo | p50 | p95 |
|---|---|---|
| Captura → la parte sale del esclavo | 70 ms | 75 ms |
| Captura → la parte llega al maestro | 75 ms | 100 ms |

**La red pone ~5 ms de mediana** (más en la cola, por la Wi-Fi). Los 70 ms están dentro
del esclavo: la cámara entrega el fotograma a la app decenas de ms después de su PTS, y
luego vienen el render y la codificación. Para bajar de 60 ms por Ethernet el trabajo
está en el esclavo, no en el enlace. En esta pasada hubo 8 partes perdidas y 6 huecos
cerrados en p50 65 ms (p99 300 ms).

**Dentro del esclavo** (3 min más; `camera_age_*` y `render_*` en `slave_send_age_ms`):
- cámara → app: p50 35 / p95 40 ms;
- render en Metal: p50 5 / p95 8 ms;
- codificación y su vuelta: el resto, unos 30 ms. El codificador ya va en baja latencia
  (`EnableLowLatencyRateControl`, `RealTime`, sin reordenar fotogramas).

Bajar de 60 ms exige recortar la codificación (por ejemplo, partes más pequeñas o un
códec con menos retardo) o asumir los ~35 ms de la cámara. La red no es el cuello.

**Siguiente paso**: la pasada por Ethernet con los hubs y, con ella, decidir el objetivo
de IOS-43 sabiendo que la cámara ya pone 35 ms.

## 2026-10-06 · SPK-54 (parcial) — 30 min con los dos iPhone y todo encendido

Maestro iPhone 17 y esclavo iPhone 16 Pro por Wi-Fi, con las cámaras tapadas y sin
refrigeración ni hubs. A la vez: programa compuesto y codificado, micro, director,
CenterNet-MNv4 en los dos por la cadena de producción, N0 y par de calibración. El
informe gana `thermal_by_minute` y `battery`. Datos en `bench/dos-moviles-20261006-0903`.

| Qué | Maestro | Esclavo |
|---|---|---|
| Programa | 53 999 fotogramas en 1800 s: 40 207 con las dos lentes, 12 697 solo del esclavo, 1075 solo del maestro y 20 retenidos; 0 fallos; latencia añadida p50 108 / p95 111 ms; tic p5 29,38 | — |
| Partes | 53 942 recibidas, 10 perdidas, 22 IDR | 53 952 enviadas, 8 descartadas, 0 fallos de render |
| Enlace | Dos `suspect` y un `down` de 89 ms a los ~21 min, que vuelve solo | — |
| Detector | 13 495 pasadas, 0 saltadas, p50 33 ms (inferencia 16,3) | 13 496 pasadas, 0 saltadas, p50 34 ms |
| Térmica | nominal 6 min → **fair** el resto, sin pasar de ahí | **serious de principio a fin** |
| CPU / memoria | 45,5 % de un núcleo / 486-509 MB, plana | 37,7 % / 223-226 MB, plana |
| Audio / N0 | 84 374 tramas de 84 375; 13 499 vistas, 0 descartes | — |
| Batería al acabar | 80 % | 80 % |

**Lectura**: aguanta 30 min sin degradarse: ni fallos de composición ni saltos del detector,
con la latencia estable y la memoria plana en los dos. El 16 Pro empezó ya en serious
tras dos horas de bancos seguidos y no empeoró a critical.

**Falta para cerrar SPK-54**: el modelo entrenado, los hubs con carga y refrigeración, y la
cancha (el sol).

## 2026-10-06 · IOS-44 — la latencia añadida, estable bajo 120 ms con todo a la vez

Con los dos iPhone, el director y CenterNet en los dos móviles por la cadena de
PRODUCCIÓN (`MetalDetectLoad`: franja en Metal con DetectorInputBuilder, CoreMLRunner y
PlayerDecoder; `RIG_DETECT_CHAIN=vision` vuelve a la carga de Vision), se encontraron y
arreglaron tres cosas:
1. **El decodificado tardaba 17,8 ms** por copiar el heatmap elemento a elemento a arrays
   anidados. `planes` copia ahora fila a fila desde el puntero: 0,1 ms en el Mac, frente a
   3,3 ms del propio `decodeHeatmap`.
2. **La detección del maestro iba antes de componer** y retrasaba el programa. Ahora va
   después, y su trabajo de Metal sale de la cola del tic.
3. **La fase del temporizador era aleatoria**: el tic compone `rejilla(ahora − 100 ms)`, y
   según dónde caía el primer disparo la latencia añadida iba de 107 a 137 ms entre
   pasadas iguales. El primer disparo se alinea ahora a 2 ms detrás de un punto de la
   rejilla. Además, el temporizador estricto de ayer había caído por error en
   `LinkPartsLoad`: se devuelve y va en `SplitBench`.

**Medido** (dos iPhone; 300 s; micro, director y detección en los dos):

| Pasada | Latencia p50 / p95 | tic p5 | Partes perdidas | Detector (maestro) |
|---|---|---|---|---|
| Vision, antes | 131 / 135 ms | 29,38 | 0 | p50 22 ms |
| Producción, detección antes de componer | 135 / 139 ms | 29,35 | 0 | p50 34 ms (inferencia 16,5) |
| Detección después de componer | 107 / 109 ms | 29,40 | 7 de 8925 | p50 33 ms |
| **+ fase alineada** | **109 / 111 ms** ✅ | 29,41 | 0 | 2245 pasadas, 0 saltadas |

El tic p5 se queda en 29,4 (pide ≥29,5): es el temporizador de 30 Hz con toda la carga.
El compositor espera a la GPU de forma síncrona (`waitUntilCompleted`) dentro del tic.

**La cadencia que de verdad sale** (`program_fps_p5`: intervalos entre fotogramas del
programa al entrar al codificador; 5 min con los dos y todo encendido): p5 28,95 fps,
intervalo p99 35,6 ms, y 8999 fotogramas en 300 s sin perder ni duplicar ninguno. El
vaivén es de ±2 ms en la entrega, y los PTS van sellados con la rejilla exacta: el stream
sale a 30 fps justos. Para que el p5 instantáneo pase de 29,5 haría falta componer fuera
del tic (asíncrono), que queda como mejora.
La CPU del maestro está en el 46 % de un núcleo y la del esclavo en el 37 %.

**Pendiente**: un fallo del iPhone 16 Pro (08:17, SIGSEGV en un callback de NetService de
CFNetwork, `objc_loadWeak`) que no se reprodujo en las cuatro pasadas siguientes. El banco
no usa NetService (ni Multipeer ni ServerDiscovery): queda anotado por si vuelve.

## 2026-10-06 · IOS-73 — el director con los dos iPhone y detección en los dos · ✅

10 min con `RIG_SPLIT_DIRECTOR=1`: el DirectorService dirige con las cajas de los dos
móviles. El esclavo manda las suyas por el enlace y el maestro usa las propias. Las cajas
salen de CenterNet-MNv4 con pesos sembrados por Vision; con pesos al azar llegan al tope
de 64 por fotograma, lo peor para el decodificador. Informes en
`bench/dos-moviles-20261006-0759`.

| Qué | Resultado |
|---|---|
| N0 | **4496 vistas a 7,5 Hz, 0 descartes** (la aceptación) |
| Programa | 17 987 fotogramas: 17 662 con las dos lentes y 325 solo del maestro; 0 fallos; tic p5 29,41; latencia p95 120,4 ms |
| Partes | 17 929 recibidas, 2 perdidas, 2 IDR |
| Detector | 4497 pasadas en el maestro y 4496 en el esclavo, 0 saltadas; total p50 40 ms (decodificado p50 17,8 ms) |
| CPU | Maestro 51 % de un núcleo, esclavo 42 % |

La aceptación decía «con el modelo COCO»; ese era D-FINE-N, que no entra al ANE (SPK-51).
Corre con el candidato del plan B (ADR 0020), a falta de que REF-33 lo firme.

**Arreglo que sale de aquí**: el decodificado se llevaba 17,8 ms, casi la mitad del ciclo
del detector, por copiar elemento a elemento a arrays anidados. `planes` copia ahora fila
a fila desde el puntero. Medido en la pasada siguiente.

## 2026-10-06 · Dos iPhone, 10 min con todo a la vez (IOS-44, IOS-70, SPK-54 parcial)

iPhone 17 (maestro) e iPhone 16 Pro (esclavo) por Wi-Fi, con las cámaras tapadas. A la
vez: programa, micro, franja, N0, el par de calibración a los 30 s y CenterNet-MNv4 en el
maestro a 7,5 Hz (`BANCO_EXTRA` en `tools/banco_dos_moviles.sh`). Informes en
`bench/dos-moviles-20261006-0745`.

| Qué | Resultado |
|---|---|
| Programa | 17 962 fotogramas: 13 436 con las dos lentes, 4410 solo del maestro, 115 solo del esclavo; 0 fallos de composición |
| Tic | p5 29,38 / p50 30,00 fps |
| Latencia añadida | p50 131 / p95 135 ms (sin detector, el 5-oct: 111/114) |
| Partes | 13 790 recibidas, **0 perdidas**, jitter 4,5 ms, 0 IDR, el par siempre `up` |
| Detector | 4490 pasadas, 0 saltadas, p50 22 ms |
| CPU | Maestro 40,8 % de un núcleo, esclavo 18,3 % |
| Memoria | Plana: maestro ~543 MB, esclavo ~381 MB |
| Audio y N0 | 28 108 tramas de audio; N0 con 4490 vistas y 0 descartes |
| Par de calibración (IOS-70) | **2 ms entre móviles en las 5 parejas** (objetivo ≤5 ✅); JPEG ≤0,9 MB; con intrínsecas |

**Lectura**:
- **IOS-70** cumple también su objetivo.
- **IOS-44**, con el detector encima, se pasa: p5 29,38 (pide ≥29,5) y p95 135 ms (pide
  ≤120). El detector compite con la composición: Vision escala en la GPU que usa Metal.
  Hay que llevar el recorte de la franja a Metal (IOS-21 ya lo hace en la cadena de
  verdad) y volver a medir.
- **IOS-38** no se puede: la imagen está negra (brillo <1 en las fotos de calibración).

**Hecho además**: `DetectLoad` corre en los dos papeles. Recorta la franja central a
escala ×0,5 con `regionOfInterest`, decodifica el heatmap a cajas nativas con
PlayerDecoder y las entrega: el esclavo, al maestro por el enlace; el maestro, a su
director (IOS-73). `CoreMLPlayerDetector.planes` pasa a ser público.

## 2026-10-05 · Carga combinada con el detector del plan B en el iPhone 17 (SPK-54, parcial)

El banco split gana `RIG_DETECT=<paquete>` (`DetectLoad`). Compila el modelo de
`Documents/bench-resources` y, cada 4 tics (7,5 Hz), lo pasa por Vision sobre el último
fotograma de la cámara del maestro, escalado a 1920x576 con scaleFill. No es la franja de
Metal, pero el coste del escalado es del mismo orden. Una petición a la vez: si sigue
ocupado, se salta y se cuenta.

**Medido** (iPhone 17 solo; 300 s; cámara 4K, programa, micro, franja de anuncios, N0 y
CenterNet-MNv4 con pesos sembrados, todo a la vez):

| Qué | Resultado |
|---|---|
| Programa | 8980 fotogramas, 0 fallos de composición, tic p5 29,61 / p50 30,00, latencia añadida p95 119 ms |
| Detector | 2245 pasadas (7,48 Hz), 0 saltadas, 0 fallos; p50 22,6 ms, p90 24,7, p99 26,4 (escalado de Vision incluido; el modelo solo, 8 ms); compilar y cargar 0,4 s |
| CPU | 34,8 % de un núcleo, frente al 17 % sin detector |
| Memoria | Plana en ~515 MB del minuto 1 al 5 |
| Audio y N0 | 14 046 tramas de audio continuas; N0 con 0 descartes |

**Lectura**: el detector del plan B cabe junto a todo lo demás sin tocar el programa. La
térmica de 30 min con refrigeración (SPK-54 entera) y con el modelo entrenado sigue
pendiente.

**Nota**: un primer intento de 10 min se quedó parado a los 2 min, sin informe de fallo:
iOS suspendió la app (pantalla bloqueada o el teléfono en uso). La pasada de 5 min se
repitió entera.

## 2026-10-05 · IOS-64 — el coste de CPU del panel local, medido · ✅

El informe del banco gana `cpu_pct_one_core`: los segundos de CPU del proceso entero
(getrusage, usuario + sistema, todos los hilos) entre el tiempo de pared, en % de un
núcleo. Dos pasadas de 120 s en el iPhone 17 como maestro, solo:

| Pasada | CPU de la app | Fotogramas | tic p5 |
|---|---|---|---|
| Sin panel | 17,1 % de un núcleo | 3599 | 29,64 |
| Panel a 1 Hz desde el Mac (miniaturas izquierda y programa, y estado: 304 peticiones, 2 fallos al arrancar) | 19,1 % de un núcleo | 3599 | 29,56 |

El panel cuesta ~2,1 % de un núcleo, que con 6 núcleos son un **0,35 % de la CPU del
maestro** (objetivo ≤2 % ✅). Antes ya estaban la página en 26 ms y las miniaturas en
22-36 ms, con la del derecho llegando por el enlace. Es una sola pasada por caso, así que
el ruido entre pasadas es del orden de la diferencia; el orden de magnitud está claro.

## 2026-10-05 · IOS-75 — los 10 min del N0 validados · 🚧 faltan las detecciones (modelo)

El N0 del maestro en la pasada split de 10 min con los dos iPhone
(`Documents/n0/banco-1791220803-left.jsonl`) pasa `read_match_log` de la referencia sin
un error:
- 4499 registros `view` en 599,7 s, con un paso medio de 133,3 ms (7,5 Hz) y 0 huecos de
  más de 200 ms;
- el informe del banco da `e0_written` 4499 y `e0_dropped` 0.

Cumple la aceptación (10 min, 0 errores, 0 descartes) para lo que hoy se escribe. Las
cajas `det` llegan con el detector: el plan B, CenterNet-MNv4, está medido a 8 ms en el ANE
(ADR 0020) y espera la decisión de REF-33.

## 2026-10-05 · IOS-44 — el tic del programa sin el disco · medido

El .ts se escribía en la cola del temporizador de 30 Hz; ahora va a una cola de escritura
en serie, y el temporizador es `.strict`. En el iPhone 17 (180 s, solo): tic p5 29,77 fps
y p50 30,00, con 5399 fotogramas y 0 fallos. Antes daba 29,43-29,47. La aceptación pide
p5 ≥29,5 ✅. Falta repetirlo con los dos iPhone y un barrido que cruce la costura, mirando
los fotogramas desgarrados.

## 2026-10-05 · SPK-02 — 90 min de enlace entre los dos iPhone por la Wi-Fi del router · 🚧 falta Ethernet

Banco link-90: partes sintéticas a 30 fps con el perfil 0, 10 y 30 Mbit/s cada 5 min, por
UDP con espaciado (16 datagramas cada 2 ms). El control va por TCP con latidos a 10 Hz y
reloj. El banco deja ahora un informe parcial cada 5 min (`link-bench-<lado>-parcial.json`).

| Qué | Resultado |
|---|---|
| Conexión | 1 en 90 min, 0 cortes, 0 tramas inválidas |
| Órdenes del maestro | 2698 de 2698 |
| PTS al esclavo | 2628 de 2700 (97 %), ida y vuelta p50 16 ms |
| Reloj | Incertidumbre de 2,2 ms |
| RTT del control | p50 14 ms · p90 125 · p99 330 (con los tramos saturados) |
| Partes a 10 Mbit/s | 2,4-3,9 % perdidas por escalón |
| Partes a 30 Mbit/s | ~50 % perdidas por escalón (en total, 30 552 de 108 001) |

**Lectura**: por la Wi-Fi del router, entre dos iPhone, caben ~10 Mbit/s de partes y aun así
con pérdidas. Las partes pasan dos veces por el aire, así que la capacidad útil es la
mitad que entre el iPhone y el Mac, donde se medía un 0,22 % a 15 Mbit/s. No cumple ni el
éxito por Ethernet ni el de punto de acceso.

El criterio de abandono habla de «ningún medio», y falta Ethernet, así que no se aplica.
La decisión UDP/TCP del ADR 0023 §5 se toma con los hubs. El control, en cambio, aguanta
la saturación sin un corte.

**Siguiente paso**
- el mismo banco con los hubs USB-C+Ethernet (IOS-11);
- Wi-Fi Aware va en SPK-08.

## 2026-10-05 · Primera sesión con los dos iPhone: IOS-80 e IOS-81 ✅, y lo medido para IOS-44/62/64/70/82

iPhone 17 (izquierdo) e iPhone 16 Pro (derecho) por Wi-Fi, con las cámaras tapadas (la
imagen sale negra: el cosido y el color no se pueden juzgar a ojo).

**Tres fallos que solo salían con dos móviles, arreglados**
- IOS-81: con el esclavo caído, el banco componía el instante «ahora», que aún no tenía
  fotograma propio, y salía SIN SEÑAL a ratos. Además, el programa saltaba 100 ms al
  caer y volver el par. Ahora va siempre al mismo retraso.
- IOS-82: un maestro que reinicia la app vuelve a `seq` 1 con el mismo term, y el
  esclavo rechazaba sus réplicas (se quedaba en rev 0). Entre arranques ordena ahora el
  `rig_ms` de la réplica, que sale del reloj del soporte; el term es al menos 1.
- IOS-80: dos móviles que prefieren dirigir arrancaban cada uno como maestro con su
  partido y quedaban en conflicto. Un maestro con term 0 es provisional y no cuenta como
  maestro de un partido: se resuelve por preferencia (empate: el izquierdo).

**Medido**

| Prueba | Resultado |
|---|---|
| Split 10 min (IOS-44) | 17 999 fotogramas, 0 fallos de composición; tic p5 29,43 fps (pide ≥29,5); latencia añadida p50 111 / p95 114 ms (≤120 ✅); partes 13 761 recibidas y 4 perdidas (0,03 %), jitter 7 ms, 4 IDR; un solo `suspect` momentáneo; memoria plana (~460 MB el maestro, ~380 MB el esclavo); 602 subidas del marcador y 600 cues de la franja |
| Caída del esclavo 60 s (IOS-81) ✅ | 7199 fotogramas en 240 s, 0 SIN SEÑAL, 0 sin fotograma propio; `down` 27 ms después del `suspect`; las partes vuelven ~1-2 s después de relanzar el esclavo |
| Rol (IOS-80) ✅ | El derecho dirige y compone 4500 fotogramas en 150 s con 3418 partes y 0 perdidas; con los dos prefiriendo dirigir, manda el izquierdo (2082 partes, 0 fallos) |
| Par de calibración (IOS-70) | 5 de 5 pares a 7-8 ms entre móviles (≤16 ✅; el objetivo ≤5 pide el sorteo de fase), JPEG de 0,9 MB e intrínsecas |
| API desde el Mac (IOS-62) | Gol 200 y el mismo gol repetido 409; la réplica llega al esclavo con el marcador nuevo (term 1, seq 9) |
| Panel (IOS-64) | Página en 26 ms; miniaturas: izquierda 23 ms, derecha (por el enlace) 36 ms, programa 22 ms; estado con `link connected`. Falta el coste de CPU |

**Fuera**
- IOS-38: necesita una escena iluminada y +1/3 EV en el esclavo.
- IOS-43 e IOS-52: necesitan Ethernet.
- IOS-44: el p5 del tic se queda en 29,43.
- El esclavo provisional compone 1-3 s antes de negociar.

**Siguiente paso**
- con luz: IOS-38 y el cosido a ojo;
- SPK-02: el enlace de 90 min.

## 2026-10-04 · IOS-47 e IOS-48 — la pasada de 10 min del gráfico y la franja · ✅ · IOS-54 sigue 🚧

**Hecho**
- Banco program-split: el cue de la franja una vez por segundo (`ad_cues`), la lista y
  su arranque (`ad_playlist`, de `AdRotation.started`), overrides programados con
  RIG_ADS_OVERRIDES="gol:2@60,…" (`ad_overrides`), la memoria de la franja
  (`ad_bytes`) y la huella del proceso cada minuto (`footprint_mb`).
- IOS-54: el AAC del micro entra también en el programa .ts del banco (el PMT lo declara
  si RIG_AUDIO=1), en el eje rigMs × 90 del vídeo; hasta conocer el primer fotograma, las
  tramas esperan en una cola acotada de 64.
- Comparación de los cues con la referencia: un guion de banco recalcula cada cue con
  `tools/ad_strip.ad_at` (football-ai) desde la lista y los overrides del informe.

**Medido en el iPhone 17, solo, 10 min** (reloj del partido en marcha, RIG_AUDIO=1, 3
anuncios de prueba y 3 overrides):
- programa: 17 990 fotogramas, 0 fallos de composición, tic p5 29,47 / p50 30,0 fps;
- marcador: 601 subidas (una por segundo), la última de 0,012 ms (objetivo ≤1 ms); la
  huella se queda en ~490 MB del minuto 1 al 10 (sin crecer: no hay reservas por
  fotograma);
- franja: 600 cues, **0 distintos de la referencia de Python**, 10 de ellos en override;
  57 MB de 192 MB de presupuesto;
- micro: 0 huecos y 0 fallos en ~54 min seguidos (siguió tras el banco).

**Medido, 30 s con el AAC en el .ts**: 899 fotogramas y 1407 tramas (30,0 s frente a
29,97 s: no derivan); ffprobe sin errores y PTS monótonos. El audio empieza 66 ms
después del primer fotograma del programa (el micro arranca después que el
compositor), así que `ts_validate.sh` lo marca por su regla de arranque <20 ms.

**Fuera (IOS-54)**: el desfase A/V real (±20 ms) necesita una palmada delante de la
cámara, con Alexander; y la interrupción audioDeviceInUseByAnotherClient.

**Siguiente paso**: los bancos de dos iPhone, mañana.

## 2026-10-04 · IOS-87 — un solo partido en el maestro: el MasterBoard · ✅

**Hecho** (cierra lo que quedó fuera en la entrada 🚧 de abajo)
- `lib/src/master_board.dart`: MasterBoard implementa MatchBoard sobre el MatchEngine
  del mismo proceso. Cada botón es la misma orden que la API del mando (`apply` con su
  `expect`), sin red ni token; lo que el motor rechaza queda en `message` y la pantalla
  lo enseña con `MatchBanner` (el aviso del mando, ahora público). La alineación se ve
  con el puesto por línea (`lineupSlots`: POR, DEF, MED, DEL), se recoloca y sale al aire.
- CapturePage avisa de su MasterHost (`onMasterHost`) y ZeroShell enseña el MasterBoard
  mientras el motor exista; si el móvil deja de dirigir, vuelve el MatchState local (que
  queda para el móvil sin soporte, como se decidió).
- Tests (3): goles, reloj y marcador como órdenes del motor, y un gol de un mando se ve
  aquí; los rechazos (sin alineación, sin túnel) con sus palabras; la alineación
  guardada, recolocada a 4-3-3, al aire y fuera.

**Medido en el iPhone 17, solo**: con el rol al arrancar (IOS-84), el maestro sirve el
partido sin esperar al esclavo: panel 200 en 125 ms y `/api/v1/match` sin token 401.

**Siguiente paso**: los bancos de dos iPhone, mañana.

## 2026-10-04 · IOS-57 — copias locales: la 4K con audio y la política de disco · ✅

**Hecho** (cierra lo que quedó fuera en la entrada 🚧 de abajo)
- La grabación HEVC 4K gana una pista AAC (48 kHz, mono, 128 kbit/s): AudioCapture
  pasa el PCM del micro (`onSampleBuffer`), y CaptureEngine lo mete en el escritor en su
  cola, con el mismo desfase al soporte que el vídeo (`RigMedia/Video/SampleRetime`, que
  desplaza todas las entradas de tiempos). Antes del primer fotograma, o si la pista va
  por detrás, se tira: nunca se encola. Sin micro, la 4K sale como antes.
- `RigCore/Runtime/RecordingPolicy`: PHONE_DISK_RESERVE_GB = 40. Por debajo, la 4K no
  arranca (`startRecording` devuelve "") y la emisión sigue; Dart lo avisa
  (`noLocalRecordingProblem`). Ya no se borran las grabaciones anteriores al empezar
  (`removeRecordings` queda para el borrado a mano; la ingesta, ML-08, borrará al
  confirmar).
- Dart: `saveVideo` va encendida por defecto si quedan ≥40 GB (`defaultSaveVideo`,
  `phoneDiskReserveBytes`), siguiendo al disco que dice el nativo hasta que el operador
  o la orden del maestro la eligen.
- La escalera nunca cierra el escritor: solo PARAR, una interrupción o un segmento nuevo.
- Tests: RecordingPolicyTests, SampleRetimeTests, dos de CaptureSession (por defecto
  según el disco; sin reserva, emite y avisa); RecordingCleanupTests renombrado al
  borrado a mano.

**Medido en el iPhone 17** (STANDALONE, AUTO_RECORD_S=20, RIG_AUDIO=1): .mov con HEVC
3840×2160, 20,0 s y 598 fotogramas, más AAC 48 kHz mono de 19,97 s (936 tramas,
empieza 76 ms después del primer fotograma); se decodifica sin errores; volumen medio
−22 dB y pico −0,6 dB. La grabación anterior del móvil sigue ahí.

**Fuera**: el micro sigue detrás de RIG_AUDIO=1 hasta aceptar el permiso en los dos
móviles (IOS-54). RunnerTests no enlaza en simulador por la librería SRT (anterior a
esto); el código compila.

**Siguiente paso**: el MasterBoard de IOS-87.

## 2026-10-04 · IOS-84 — compás propio del programa y SIN SEÑAL · ✅

**Hecho**
- `RigCore/Runtime/ProgramClock.swift`: la rejilla de 30 fps del programa (con épsilon
  en los bordes) y la elección de fuente por tic: dos lentes, solo maestro, solo
  esclavo, `hold` del último programa durante PROGRAM_HOLD_MS (500 ms) y SIN SEÑAL.
  ProgramClockTests.
- MasterProgramStage elige la fuente con ProgramClock, cuenta `sources` y avisa con
  `onSourceChange`. El programa no depende de la cámara ni del enlace.
- OverlayStore: capas ocultas (`setVisible`); SIN SEÑAL se sube una vez desde Dart
  (ProgramGraphics) y queda oculta en nativo hasta que no queda ninguna cámara.
  Orden de apilado propio (`OverlayLayer.stackOrder`): SIN SEÑAL debajo del marcador
  y la alineación encima de todo.
- RigLinkSession: sin par todavía, el móvil actúa ya con su rol (ADR 0023 §7: sin
  partido, decide la preferencia) y lo avisa a Dart. Antes, el maestro que arrancaba
  solo componía, pero sin gráfico ni mando hasta que llegaba el esclavo.
- Banco: RIG_SPLIT_CAM_OFF_S / RIG_SPLIT_CAM_ON_S paran y reanudan la cámara del
  maestro; el informe trae `program_sources`.

**Medido en el iPhone 17, solo** (30 s, cámara parada a 10 s y reanudada a 18 s):
899 fotogramas, 0 fallos de composición, tic p5 29,6 fps; masterOnly 653, hold 15,
noSignal 231. SIN SEÑAL con marcador a 10,5 s y vuelta a la cámara ≈0,2 s después de
reanudarla; el cronómetro sigue. Con el Mac de esclavo (40 s): igual, 1199 fotogramas.

**Fuera**: el corte con los dos iPhone (cámara del esclavo caída) va con el banco de
mañana (`tools/banco_dos_moviles.sh split`).

**Siguiente paso**: lo que se pueda con un iPhone; los bancos de dos, mañana.

## 2026-10-04 · IOS-53 — multiplexor MPEG-TS propio (H.264 con SEI y AAC en ADTS) · ✅

**Hecho**
- `RigCore/Media/TsMuxer.swift`, puro y determinista: PAT y PMT (0x1B y 0x0F) con
  CRC32 de MPEG-2, PES (vídeo sin longitud, audio con ella), PCR en el PID de vídeo
  en el primer paquete de cada fotograma, contadores de continuidad, relleno por el
  campo de adaptación, AUD en cada fotograma y SPS/PPS + tablas delante de cada IDR.
  El SEI entra con la unidad de acceso en AVCC, dentro de su PES (ADR 0022).
- `RigCore/Media/Adts.swift`: la cabecera ADTS de 7 B.
- `tools/ts_validate.sh`: ffprobe sin errores, PTS monótonos y A/V < 20 ms.
- TsMuxerTests (6): CRC de la PAT conocida (2AB104B2, la de ffmpeg), PAT/PMT
  escritas, paquetes y contadores, ADTS, bytes dorados de una entrada pequeña y
  10 s de H.264 + AAC de ffmpeg muxados que ffprobe lee sin errores (A/V 0 ms).

**Siguiente paso**: tareas con los dos iPhone (Alexander ya tiene dos).

## 2026-10-04 · IOS-72 — intrínsecas por fotograma y vigilancia de la calibración · ✅

**Hecho**
- `RigCore/Direction/SeamWatch.swift`: mediana de `separationRad` de las parejas
  del solape en una ventana preasignada; por encima de
  RIG_SEAM_WATCH_MAX_MEDIAN_RAD sugiere recalibrar. No cambia nada solo.
- `RigMedia/Capture/IntrinsicsReader.swift` + `RigCore/Geometry/IntrinsicsDrift`:
  la matriz que el iPhone entrega por fotograma (FrameMeta.intrinsics) frente a la
  de rig.json reescalada al búfer: Δfocal relativo y Δcentro en píxeles nativos,
  con los umbrales RIG_INTRINSICS_MAX_*. Cierra la M2.
- TelemetrySnapshot gana `intrinsics` y `seam_median_rad`, opcionales (campos
  pasantes de la telemetría v1: sin dato no aparecen).
- Los umbrales los decidí yo, con su razonamiento en libs/vision/constants.py y una
  anotación en el ADR 0012; ninguna medición los fija todavía.
- Tests (9): con la pose derecha movida 0,5° el aviso sale en ≤60 s (sale en ~2 s);
  sin mover no sale y hay mediana; ventana y parejas; deriva de focal y de centro;
  la telemetría.

**Siguiente paso**: IOS-60 (estado del partido en Dart) o IOS-53 (MPEG-TS).

## 2026-10-04 · IOS-21 — kernel Metal de preproceso NV12 → entrada del detector · ✅

**Cierre (2026-10-04)**: metal-bench (RigMedia/Obs/MetalBench.swift), 300 pasadas tras 20 de calentado, tiempo
de GPU por command buffer (gpuEnd − gpuStart), térmica nominal. iPhone 17 (iPhone18,3):
reproyección 4K→1080p p50 0,33 / p90 0,39 / p99 2,13 ms; composición p50 0,38 /
p90 0,44 / p99 2,10 ms; total del maestro (reproyección + composición) p50 0,70 /
p90 0,85 / p99 2,66 ms; preproceso 4K→1920×576 p50 0,33 / p90 0,39 / p99 2,17 ms.
iPhone 16 Pro: más o menos el doble (maestro p50 1,83 ms). Los p99 de ~2 ms son el
arranque de la GPU tras cada espera: el banco serializa con waitUntilCompleted y la GPU
baja de reloj entre pasadas; en el directo el trabajo es continuo.
Objetivo ≤0,5 ms de GPU: p50 y p90 dentro; p99 por encima por el arranque de la GPU.

### Lo que se entregó antes

**Hecho**
- `RigMedia/Metal/Kernels/Preprocess.metal`: compose_band_input en una pasada. Por
  píxel de la entrada, su región de band.json, el recorte redondeado como la
  referencia y la media por ÁREA (INTER_AREA: caja 2×2 a ×0,5, la escala que toque
  en el mosaico), con cada píxel de fuente pasado antes a BGR redondeado con los
  coeficientes de convert.py. El móvil cabeza abajo lee su crudo girado 180°.
  Escribe 32BGRA sin normalizar (la escala 1/255 va en el modelo, ML-35).
  Dos lectores con el mismo núcleo: NV12 (producción) y BGRA (el dorado de REF-14).
- `RigMedia/ML/DetectorInputBuilder.swift`: pool BGRA precalentado y
  `addCompletedHandler`; sin hueco en el pool, el fotograma de IA se descarta y se
  cuenta (`dropped`), nunca se encola.
- BandGeometry.fromDictionary acepta `checkDetectorInput: false` para los dorados
  sintéticos de REF-14 (entrada de 192×64).
- PreprocessKernelTests (3): el lienzo dorado de REF-14 a ≤1 nivel en sus 3 casos;
  la ruta NV12 contra la cuenta de Python (con y sin giro) a ≤1; el descarte.

**Falta para ✅**: los ≤0,5 ms de GPU por fotograma en el iPhone 17.

**Siguiente paso**: IOS-22.

## 2026-10-04 · IOS-20 — geometría de la franja jugable (InputRegion) · ✅

**Hecho**
- `RigCore/Geometry/BandGeometry.swift`: InputRegion (sin deformar, sx = sy a 1e-9
  relativo; toNative/toInput/containsInput), InputLayout (regionIndex: la primera
  que contiene el punto o la más cercana, como `min` de Python), BandGeometry con
  scaleAtRow, `toRaw` con el giro de 180° del móvil cabeza abajo, y el códec de
  band.json v1 que además comprueba que la entrada es la del detector (1920×576) y
  que ninguna región se sale.
- band.json va en píxeles ENDEREZADOS, como rig.json y pitch.json (la calibración
  trabaja sobre la imagen enderezada): el crudo del móvil invertido pasa por
  CameraMount.
- football-ai añade a band.json los casos `band_from_pitch` a 6 m (mosaico) y a
  10 m (una región a ×0,5) de retranqueo, con la cámara nominal de test_band.py.
- BandGeometryTests (5): la ida y vuelta de InputLayout.map, las franjas a 6 y
  10 m (códec y escala por fila), la ida y vuelta con el giro y los rechazos.

**Siguiente paso**: IOS-21 (kernel Metal NV12 → tensor del detector).

## 2026-10-04 · IOS-41 — composición del programa en el maestro · ✅

**Cierre (2026-10-04)**: football-ai añade a compose.json dos programas representables
en NV12 (color constante por bloque 2×2, sin primarios saturados), uno con gráfico y
otro con gráfico y anuncio; el kernel los compone a **≥45 dB** de PSNR frente al dorado
(ComposeProgramTests). GPU del maestro en el iPhone 17 (metal-bench): reproyección +
composición p50 0,70 / p90 0,85 / p99 2,66 ms, dentro del objetivo de 3 ms.

### Lo que se entregó antes

**Hecho**
- `RigMedia/Metal/Kernels/ComposeProgram.metal` (compose_program): en una pasada,
  la parte propia y la del esclavo con el peso de la costura recalculado por píxel
  desde la vista, el gráfico RGBA SIN premultiplicar (alpha_composite), el anuncio
  premultiplicado con su alfa inversa en la franja (StripBlender) y NV12 BT.709 de
  rango limitado con los coeficientes exactos de compose_reference. Caminos de una
  lente: solo la parte propia o solo la del esclavo, más el gráfico.
- `ComposeProgramKernel.swift` y `UploadTexture` (el gráfico y el anuncio se suben
  solo cuando cambia su generación).
- OverlayRaster (IOS-45) pasa a entregar RGBA sin premultiplicar
  (`rawStraightRgba`), que es el contrato de la composición.
- Los helpers de cada .metal van en su espacio de nombres: sin metallib, todas las
  fuentes se compilan juntas.
- ComposeProgramTests (5): compose_reference sobre la entrada tal como el kernel la
  ve da los mismos Y/U/V a ±1 en los 9 casos dorados y en los 3 de la franja; la
  costura; una lente con el gráfico; la subida por generación.

**Falta para ✅**
- El PSNR ≥45 dB frente a los dorados de REF no se puede medir: las entradas de
  compose.json son colores al azar píxel a píxel y ninguna sobrevive al NV12 de
  entrada a 45 dB. Hace falta que REF añada casos con entrada representable en
  4:2:0 (o en NV12 directamente). La matemática ya casa a ±1.
- Los ≤3 ms de GPU del maestro por fotograma, en el iPhone.

**Siguiente paso**: lo que queda de Mac es poco; las IOS-20/21/22 necesitan el iPhone.

## 2026-10-04 · IOS-40 — kernel Metal de la parte: reproyección por homografía · ✅

**Cierre (2026-10-04)**: metal-bench (RigMedia/Obs/MetalBench.swift), 300 pasadas tras 20 de calentado, tiempo
de GPU por command buffer (gpuEnd − gpuStart), térmica nominal. iPhone 17 (iPhone18,3):
reproyección 4K→1080p p50 0,33 / p90 0,39 / p99 2,13 ms; composición p50 0,38 /
p90 0,44 / p99 2,10 ms; total del maestro (reproyección + composición) p50 0,70 /
p90 0,85 / p99 2,66 ms; preproceso 4K→1920×576 p50 0,33 / p90 0,39 / p99 2,17 ms.
iPhone 16 Pro: más o menos el doble (maestro p50 1,83 ms). Los p99 de ~2 ms son el
arranque de la GPU tras cada espera: el banco serializa con waitUntilCompleted y la GPU
baja de reloj entre pasadas; en el directo el trabajo es continuo.
Objetivo ≤1,5 ms de GPU: p50 y p90 dentro; p99 2,1 ms por el arranque de la GPU.

### Lo que se entregó antes

**Hecho**
- `RigMedia/Metal/Kernels/Reproject.metal` (reproject_part): render_view de un
  lado sobre NV12 BT.709 de rango limitado. H·(x,y,1) con w ≤ 0 = no visible,
  zona ciega del código de tiempo ensanchada PANORAMA_BLIND_MARGIN_PX (mask_blind),
  bilineal en RGB toma a toma con lo de fuera a negro (el INTER_LINEAR con
  BORDER_CONSTANT de la referencia; en NV12 el negro no es cero), ganancia por
  canal en el orden BGR de la referencia y NV12 de salida por bloques 2×2.
- `ReprojectKernel.swift`: codifica el kernel entre CVPixelBuffer con IOSurface
  (la cámara y el pool del codificador), sin copias.
- MetalContext compila en tiempo de ejecución las fuentes .metal del bundle
  cuando no hay default.metallib: `swift test` por CLI no lo genera, y sin esto
  los kernels no existían en los tests.
- ReprojectKernelTests (4, macOS): los programas dorados de ViewRenderer.render
  (con costura mezclada en la CPU como la ruta GPU de la referencia), la franja
  tapada, w ≤ 0 y el color con ganancia en un parche uniforme.

**Decisión**: el PSNR se mide en LUMA. Los fotogramas dorados (tablero
magenta/verde de 8 px y un degradado saturado con bordes duros) no sobreviven al
4:2:0: solo la ida y vuelta BGR→NV12→BGR del fotograma ya da 33,6 dB. En luma el
kernel da 55,9 dB (costura con ganancia) y 46,5 dB (w ≤ 0), por encima de 45; el
color se valida aparte. Si REF quiere el criterio en BGR, necesita dorados con
contenido que el NV12 pueda representar.

**Falta para ✅**: los ≤1,5 ms de GPU por fotograma 1080p en el iPhone (la tarjeta
es Mac + iPhone).

**Siguiente paso**: IOS-41 (composición del programa en el maestro).

## 2026-10-04 · IOS-46 — tarjeta de alineación y SIN SEÑAL en Dart · ✅

**Cierre (2026-10-04)**: la referencia de Python se pinta ahora con Archivo Bold, la
fuente de la app (football-ai la lleva en tools/fonts con su licencia OFL). Frente a
ese PNG, la tarjeta de Dart da **2,64 %** de píxeles distintos (diferencia >64 niveles
en algún canal, la que se ve; con >24 serían 3,4 %, todo bordes de glifo que FreeType y
Skia suavizan distinto). Aceptación ≤3 %: cumplida. El ancho del marcador de IOS-45
(833 px con Archivo frente a 704 de la maqueta) sigue siendo la consecuencia de usar
una fuente no condensada; si se quiere 704, hace falta una condensada con licencia.

### Lo que se entregó antes

**Hecho**
- `lib/src/graphics/lineup_card_painter.dart`: build_lineup_card y slot_positions
  portados (degradado fila a fila, lista con píldoras y dorsal, suplentes en
  renglones, campo en perspectiva con rayas recortadas al césped, camisetas,
  cabecera con escudo y DT). Formas sin antialiasing, como ImageDraw.
- `lib/src/graphics/slate_painter.dart`: la tarjeta SIN SEÑAL de live_panel.py.
- `CardRaster` (overlay_raster.dart): rasteriza bajo demanda y guarda la última
  alineación de cada lado y la tarjeta SIN SEÑAL.
- Todas las medidas, colores, textos y la silueta de la camiseta llegan generados
  en OverlaySpec: football-ai exporta ahora la geometría completa de la alineación
  y la tarjeta SIN SEÑAL, y `--sync` copia sus renders a test/graphics/reference.
- El texto deja de forzar `height: 1.0`: así el centrado coincide con los anclajes
  `mm`/`lt` de PIL (afecta también a los dorados del marcador de IOS-45).
- Tests (9): slotPositions contra Python, dorados propios (local, visitante sin
  suplentes ni DT, SIN SEÑAL), comparación con los PNG de Python, render ≤50 ms
  en el Mac y el raster bajo demanda.

**Falta para ✅: el ≤3 % frente al PNG de Python.** Sale 5,5 % de píxeles distintos,
y es todo texto: la referencia usa Arial Narrow y la app, Archivo. Pintada en
Python con Archivo Bold, la misma tarjeta da 3,4 % (umbral 24) y 2,6 % (umbral 64),
lo que queda son bordes de glifo que FreeType y Skia suavizan distinto. Decide el
propietario, y es la misma decisión del ancho del marcador de IOS-45:
- una condensada de emisión en la app, con licencia que permita empaquetarla, o
- la referencia de Python pintada con la fuente de la app (habría que añadir
  Archivo con su licencia OFL al repo football-ai).
Mientras tanto, el test vigila ≤6 %, que es lo que ya cuesta la tipografía.

**Siguiente paso**: IOS-40 → IOS-41 (Mac); las IOS-20/21/22 esperan al iPhone.

## 2026-10-04 · IOS-45 — el marcador en Dart rasterizado a RGBA · ✅

**Hecho**
- `lib/src/graphics/scoreboard_painter.dart`: ScoreboardState (valor, decide el
  re-raster), ScoreboardLayout (la medición de `_measure_layout`, con el `round()`
  bancario de Python y las cajas de boxes.json) y ScoreboardPainter (marcador con
  chaflán, tortuga, EN VIVO, indicador de cámara, franja con claim, ranuras con
  montaña/olas/sol y la marca). Medidas y paleta de OverlaySpec (REF-32).
- `lib/src/graphics/overlay_raster.dart`: PictureRecorder → ui.Image →
  toByteData(rawStraightRgba, alfa sin premultiplicar; IOS-41 lo corrigió), solo cuando cambia el estado; con el
  reloj en marcha, un raster por segundo.
- test/graphics/scoreboard_painter_test.dart (9): dorados de imagen de 4 estados
  (inicio, directo, final_largo y con_anuncios sin ranuras), la geometría de la
  maqueta y el ritmo del raster.

**Decisiones**
- Tipografía Zero: Archivo 700 donde la maqueta usaba Arial Narrow Bold, IBM Plex
  Sans 400 donde usaba Arial Narrow. Archivo no es condensada: en «directo» el
  marcador se estira a 833 px (704 en la maqueta), por el mismo camino que la
  maqueta usa con nombres largos. Si se quiere el ancho de 704, hace falta una
  condensada en assets/fonts.
- Los dorados se generaron en macOS, no en Windows como decía la tarjeta: el
  rasterizado de texto depende de la plataforma, y se regeneran con
  `flutter test --update-goldens` en la máquina de referencia que se elija.

**Pendiente**: medir el raster en el iPhone (objetivo ≤8 ms) cuando IOS-47 lo
monte en la app.

**Siguiente paso**: IOS-46 (alineación y SIN SEÑAL).

## 2026-10-04 · IOS-11/16/12 — el enlace entre dos iPhone reales, banco por Wi-Fi · ✅ por Wi-Fi

**Decisión del propietario (2026-10-04)**: por ahora se sigue solo por Wi-Fi. Las tres
quedan aceptadas con las medidas de abajo; la pasada por Ethernet (conectar <2 s,
reconectar <3 s al reenchufar, RTT p50 <2 ms) queda pendiente para cuando haya hubs, y
la hará SPK-02.

Primera vez con los dos móviles: iPhone 17 (iPhone18,3) a la izquierda, escuchando,
y iPhone 16 Pro (iPhone17,1) a la derecha, buscando; iOS 26.6.1; RIG_LINK_INTERFACE=wifi
(el modo banco que prevé IOS-11). Sin hubs todavía: el ✅ sigue pidiendo Ethernet.

**Hecho**
- `link-bench` (Runner/RigLinkNW.swift, `LinkBench`): RigLinkSession + NWLinkTransport
  reales con lado, secreto e interfaz por variables de entorno (`devicectl … launch
  --environment-variables`), y un informe en Documents/bench como los demás bancos.
  RigHostApiImpl lo engancha; `BenchRunner.machine()` pasa a público.
- `RIG_LINK_INTERFACE=wifi` también para la app (RigLinkNW).
- **Fallo encontrado y corregido**: Info.plist no declaraba `_footballai-media._udp`
  (el canal de medios de IOS-16) en NSBonjourServices, e iOS bloquea el
  descubrimiento de lo que no se declara.
- El iPhone 16 Pro, registrado en el perfil del equipo (xcodebuild
  -allowProvisioningDeviceRegistration).

**Medido** (informes en bench/link-bench-*.json)
- Derecho primero, izquierdo 5 s después: el izquierdo autentica a los 2,24 s de
  arrancar su sesión; el derecho, en cuanto aparece el anuncio.
- Izquierdo primero: el derecho autentica a los **130 ms**.
- Hello y auth: 0 tramas inválidas; con secretos distintos los dos rechazan
  («secreto distinto: empareja de nuevo») y ninguno conecta.
- Reloj por medios UDP: 12–13 estimaciones en 45 s, incertidumbre 2,2 ms; 0 huecos
  de medios.
- RTT del reloj por Wi-Fi: p50 9–48 ms, p90 ~170–186 ms, p99 ~210 ms. Es el ahorro
  de energía de la radio Wi-Fi (los pings van cada 5 s tras la ráfaga); el objetivo
  de <2 ms es para Ethernet.
- La ruta a internet la lleva `en0` (Wi-Fi) en los dos, y el informe lo dice.
- `media_stalls_over_100ms` sale alto porque sin vídeo los medios son solo los pings
  del reloj, espaciados: no es un parón.

**Segunda ronda** (link-bench con corte, órdenes y PTS; bench/link-bench-*-17911530*.json)
- Corte simulado: a los 20 s el izquierdo baja la sesión 1 s (el cable fuera) y la
  vuelve a levantar. Los dos vuelven a autenticar 3,1 s después del corte, que con el
  segundo de corte son **~2,1 s de reconexión** desde que el enlace vuelve (<3 s).
- Órdenes del maestro (IOS-12): 16 enviadas, **16 recibidas**.
- PTS del maestro al esclavo: 22 pedidos, **16 respondidos** (los 6 restantes caen
  antes de conectar y dentro del corte, y vencen a vacío como deben); ida y vuelta
  p50 6 ms, p99 111 ms por Wi-Fi.
- Reloj vivo: 8 estimaciones del esclavo, incertidumbre 2,3 ms; 0 tramas inválidas.

**Tercera ronda: de dónde salen los ~2 s del orden «derecho primero»** (el banco
desglosa la conexión: listener listo, TCP arriba, hello y auth). Seis repeticiones:
el izquierdo escucha a 1 ms, el TCP llega a 1,97–2,14 s y hello+auth cuestan
**~8 ms**. Los ~2 s son lo que tarda el anuncio Bonjour en publicarse (mDNS sondea el
nombre antes de anunciarlo) y en llegar por multicast Wi-Fi; no es código nuestro. Por
Ethernet se mide con los hubs.
- De paso, `NWLinkTransport` deja de hacer caso a una conexión ya sustituida: antes, al
  cambiar de conexión, el `.cancelled` de la vieja llamaba a `dropConnection` y podía
  tumbar la nueva. Y un anuncio que aparece manda sobre una conexión a medias a un
  anuncio viejo de la caché de Bonjour. RigNetTests 18/18.

**Falta para ✅**: lo mismo por Ethernet con los hubs (conectar <2 s en cualquier
orden, reconectar <3 s al reenchufar de verdad, RTT p50 <2 ms). Por Wi-Fi ya pasa
todo lo funcional; lo que el Wi-Fi no puede dar es la latencia.

## 2026-10-04 · IOS-37 — bucle del director (lógica pura) · ✅

**Cierre (2026-10-04)**: las dos cosas que faltaban.
- Repetición de dos minutos: football-ai añade a shot.json el caso
  `director_dos_minutos_de_partido` (3600 fotogramas, detecciones a 7,5 Hz por
  fases: grupo, transición, bimodal, porteros y árbitro, parón del detector de 2 s,
  ataque en un extremo). DirectorLoopTests lo repite y da las mismas vistas que
  tools/program_director.py a ±1e-6 rad, fotograma a fotograma, y el mismo plano.
- Coste en el iPhone 17 (iPhone18,3, iOS 26.6.1, release, térmica nominal), banco
  `director-bench` (RigMedia/Obs/DirectorBench.swift), 36 000 fotogramas:
  p50 0,0012 ms, p90 0,0084 ms, p99 0,0127 ms por fotograma; la ingesta del ciclo
  de detección (fusión de las dos cámaras + acción) p50 0,007 ms, p99 0,023 ms.
  Objetivo <0,2 ms: cumplido con más de 15× de margen.

### Lo que se entregó antes

**Hecho**
- `Direction/DirectorLoop.swift`: `ingest` por ciclo de detección (fusión de las
  dos cámaras y acción) y `tick(targetRigMs:)` a la rejilla del programa, con dt de
  los rigMs y los huecos integrados en pasos de rejilla; sale `ViewCommand`
  {targetRigMs, viewId, yaw, pitch, hfov, sides, seamYaw, featherRad, gains}.
  Modos: auto, vista manual, abierta fija, IA apagada de la escalera (vuelve al
  abierto al ritmo normal del muelle), markSituation y una lente (límites
  recalculados con la cobertura de un lado y `sides` a ese lado). Los límites se
  calculan como ProgramDirector, con su `upscaling`.
- `Detection/RigDetection.swift`: PlayerDetection, RigPlayerDetection (cumple
  ActionSighting) y `RigModel.fusePlayers` por los pies, con la caja de quien
  mejor la vio (a igualdad, la izquierda, como `max` de Python). Adelantado de
  IOS-23 porque la fusión del bucle lo necesita; IOS-23 lo reutiliza.
- PANORAMA_FEATHER_RAD exportada desde football-ai; VirtualCameraEngine.limits
  pasa a ser mutable para el cambio a una lente.
- DirectorLoopTests (9): ProgramDirector.steps de shot.json (120 pasos) a 1e-9
  con los mismos planos; tick por rigMs igual a la referencia; huecos; contrato
  del ViewCommand; IA apagada, manual, una lente, gol y la fusión de cajas.

**Falta para ✅**
- La repetición de ≥2 min de partido contra tools/program_director.py: REF todavía
  no produce ese registro de detecciones.
- El coste por fotograma en el iPhone (<0,2 ms objetivo): se mide con IOS-73,
  cuando el bucle corra en la app.

**Siguiente paso**: IOS-20 → IOS-21 → IOS-22 (necesitan el iPhone).

## 2026-10-04 · IOS-35 — gramática de planos (shot.py) · ✅

**Hecho**
- `Direction/ShotGrammar.swift`: ShotSize, angularWidthRad, ShotPlan (validado;
  `at` recorta cada plano a lo que la lente sirve), ShotDecision y ShotGrammar
  con permanencia, insistencia, asimetría (abrir antes que cerrar), reglas
  urgentes y markSituation.
- ShotGrammarTests (4): la secuencia dorada de 320 ciclos da los mismos planos,
  razones, hfov y cambios; recorte por la lente; abrir más rápido que cerrar;
  sin jugadores abre sin esperar la permanencia.

**Fuera**: el caso ProgramDirector.steps de shot.json es el director entero y
llega con IOS-37.

**Siguiente paso**: IOS-37 (bucle del director).

## 2026-10-04 · IOS-34 — muelle de 3 ejes y límites de la cámara virtual · ✅

**Hecho**
- `Direction/AxisSpring.swift`: AxisParams (validados; yaw/pitch/hfov desde las
  constantes generadas), AxisState, zona muerta con histéresis, muro blando que
  solo frena hacia fuera e `integrateAxis` en el orden de §18.3.
- `Direction/VirtualCamera.swift`: la cobertura de CylindricalCanvas.fit (sin
  remapeo) con variante de UNA lente para el modo degradado,
  `tightestServableHfovRad`, CameraLimits.fromCanvas con el rango que colapsa al
  centro, y VirtualCameraEngine.step: zoom primero, luego yaw y pitch.
- AxisSpringTests + VirtualCameraEngineTests (9): las 3 secuencias doradas de 300
  pasos y los 300 pasos del motor (con objetivos ausentes) a 1e-9, mismos
  engaged/settled; fit, from_canvas y el tope de la lente; rechazos.
- PANORAMA_FIT_* exportadas desde football-ai.

**Siguiente paso**: IOS-35 (gramática de planos) → IOS-37.

## 2026-10-04 · IOS-33 — punto de acción desde los jugadores (action.py) · ✅

**Hecho**
- `Direction/Action.swift`: PlayerEvidence (con sigmaRad), ActionEstimator con
  búferes de trabajo reservados al crear (jugadores por parámetro, rejilla para
  el yaw entero) y reutilizados sin asignar en el bucle; yawDensity replica
  np.arange tal cual lo rellena numpy (delta = (start+step)−start), argmax con
  el primero a igualdad, bimodalidad por otra moda separada y la confianza con
  tope 0.80 sin convergencia.
- `Detection/PlayerClass.swift` (player/goalkeeper/referee) y el protocolo
  `ActionSighting` (dirección, clase, score): RigPlayerDetection de IOS-23 lo
  cumplirá sin que la acción sepa qué es una caja.
- ActionTests: los 5 casos de action.json a 1e-9 (incluido el nil de pocos
  jugadores), sin evidencia con solo árbitros/porteros/score 0, y que reutilizar
  los búferes no arrastra estado entre ciclos.

**Siguiente paso**: IOS-34 (muelle de 3 ejes y límites) → IOS-35 → IOS-37.

## 2026-10-04 · IOS-36 — homografía del campo (PitchModel) en el móvil · ✅

**Hecho**
- `Geometry/PitchModel.swift`: PitchModel (validación de invertibilidad sobre la
  H normalizada, guarda del horizonte con PITCH_MIN_PROJECTIVE_W, códec de
  pitch.json v1 que rechaza otra versión) y RigPitchModel (dos lados, misma
  cancha o error, puntos compartidos con su error cruzado recalculado).
- Filtro de pies `isInsidePlayable`: pie a metros contra el rectángulo del campo
  con PITCH_PLAYABLE_MARGIN_M (3 m, §11.1), que sustituye a la máscara de mapa de
  bits. La familia PITCH_ entera llega generada en RigConstants.
- `Mat3` gana determinante, norma de Frobenius e inversa por adjugada.
- PitchModelTests (8): metros y píxeles dorados a 1e-9 aplicando la `h` dorada,
  errores cruzados del soporte, códec ida y vuelta, rechazos, y el filtro contra
  la máscara rasterizada (miles de pies, la frontera de cuantización < 5%).

**Fuera**: el ajuste (RANSAC) se queda en Python, en el VPS, por diseño. No hay
dorado de PlayerDetector con pitch_mask: la equivalencia se prueba contra la
máscara rasterizada desde la misma homografía; cuando IOS-23 porte el detector,
su dorado podrá llevar la máscara.

**Siguiente paso**: IOS-33 → IOS-34 → IOS-35 → IOS-37.

## 2026-10-04 · IOS-32 — fusión angular y emparejado por rigMs · ✅

**Hecho**
- `Detection/Fusion.swift`: Observation/FusedObservation y `RigModel.fuse` —
  voraz por score con ORDEN ESTABLE (list.sort de Python es estable y Swift
  no: desempate por orden de inserción, o los dorados no cuadran), `<=` en el
  más próximo (a igual ángulo gana el último, como Python), punto medio por
  VECTORES unitarios y salida descendente. Los 3 casos `RigModel.fuse` del
  dorado pasan y el runner de rig.json ya no salta NADA (34 casos).
- `Detection/DetectionPairer.swift`: el FramePairer aplicado a metadatos,
  genérico en la carga — misma semántica congelada por sync.json: tolerancia,
  hueco acotado con descarte de lo más viejo SIN encolar, el antiguo que ya no
  puede emparejar sale huérfano, force para el cierre, y PairingStats con
  completeness/meanAbsSkew/synchronized (RIG_MIN_PAIR_COMPLETENESS generado).
- `DetectionPairerTests` REPRODUCE las 3 secuencias doradas de FramePairer.run
  (resultados Y estadísticas idénticos); FusionTests cubre lo que el dorado no
  nombra: misma cámara no funde, claves y score del mejor, orden de salida.
- `RigPlayerDetection` (la caja de la cámara que mejor la vio) queda para
  IOS-23: es donde nace PlayerDetection en Swift, y definirla sin caja sería
  inventarse el tipo dos veces.

## 2026-10-04 · IOS-31 — vista rectilínea y homografía programa→cámara · ✅

**Hecho**
- `RectilinearView.swift`: focalPx, vfov derivado, pose sin roll, withHfov,
  lookingAt, directionAt con el medio píxel, contains(margin) y las
  validaciones con el mismo texto que Python.
- `ViewHomography.swift`: `viewHomography` = K_cam · R_camᵀ · R_vista ·
  K_vista⁻¹ con el convenio del medio píxel; `viewHomographyToRaw` la compone
  con la F de la montura para el búfer crudo del móvil invertido; `sidesFor`
  con las cuatro esquinas (casi siempre UNA cámara: donde no hay costura no
  hay fantasma).
- Tests: los dorados de reprojection.json recalculados (se saltan solo
  ViewRenderer.render —es IOS-40, Metal— y view_outline —del panel—, y el
  meta-test lo exige); la aceptación de las 20 vistas: H·(x,y,1) coincide con
  project(directionAt(x,y)) en una rejilla entera por lado (>400 puntos,
  1e-6); la homografía cruda pasa por la montura exacta. Verde a la primera.

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

## 2026-10-04 · El cronómetro en el reloj del soporte y su dominio (ADR 0023 §4; IOS-13/60/82)

- Nativo: RigClockDomain — el `clock_domain` se crea al azar ([a-z0-9]{16}) y se guarda
  con la hora de arranque del sistema (kern.boottime): sobrevive a reiniciar la app y
  cambia si se reinicia el móvil. El esclavo adopta el del maestro al aceptar su pizarra.
  Pigeon `rigClockSnapshot()` ({rig_ns, domain}: el host del maestro, o el host más el
  desfase estimado en el esclavo) y `adoptClockDomain`.
- Dart: `RigTimeSource` — una instantánea del nativo y un Stopwatch, rehecha cada 30 s
  sin retroceder nunca; MasterHost la refresca antes de abrir el partido.
- **Medido en el iPhone 17**: con el reloj arrancado desde el Mac por la API, tras
  REINICIAR LA APP el cronómetro sigue en marcha (52,6 s, `clock_restored: false`, otro
  `boot`). Con el Stopwatch de antes volvía parado.
- Tests: rig_time_test (avanza, no retrocede al rehacer la instantánea).

## 2026-10-04 · IOS-82 — la pizarra replicada en el esclavo · 🚧 falta el VPS (IOS-65) y la prueba con dos iPhone

**Hecho**
- `lib/src/server/replica.dart`: StateReplica según el ADR 0023 §7 —match_id, term, seq,
  instante y `clock_domain`, boot/rev, el MatchRecord, las alineaciones y las claves de
  idempotencia de los últimos 30 s (64 como mucho, con su status y rev)—, ≤64 KiB y SIN
  secretos (el ADR manda sobre la tarjeta, que aún hablaba de mandar el secreto del
  token). ReplicaStore en el esclavo: se queda la más fresca por (term, seq), en memoria
  y en disco (atómico).
- MasterHost la manda con cada cambio del partido y cada REPLICA_INTERVAL_S (5 s), con
  el term de la negociación y un seq que sube; el esclavo la guarda en
  Documents/partido/replica.json. IdempotencyCache gana `recent`.
- Enlace: `replica` por control del maestro al esclavo (RigLinkSession), Pigeon
  `sendReplica` y `onReplica`.
- Tests: ida y vuelta con la idempotencia y sin el PIN; la más fresca (también un term
  mayor con seq nuevo) y el disco tras reiniciar; el maestro la manda al cambiar; **en el
  mismo dominio de reloj, el partido abierto desde la réplica sigue en marcha, sin
  clock_restored, y el reloj al aire no retrocede (≤ lo transcurrido + 1 s)**.

**Queda fuera**: la réplica al VPS (IOS-65), la del esclavo al conectar el enlace y
REPLICA_ADOPT_S (IOS-85). El reloj del partido en Dart sigue siendo un Stopwatch: hasta
que el reloj del soporte (IOS-13) llegue a Dart con su dominio, la promoción abriría el
reloj parado con clock_restored en vez de seguir en marcha.

## 2026-10-04 · IOS-83 — elección de roles con terms (lógica pura) · ✅ en lo puro; la prueba con VPS va con IOS-85

**Hecho**
- `RigCore/Runtime/RoleElection.swift`: el esclavo se promueve (term + 1) solo con las
  tres condiciones del ADR 0023 §8 —enlace caído ≥PROMOTE_AFTER_MS (2 s), `welcome` en su
  túnel y el hub diciendo `master_status: lost` ≥MASTER_LOST_PROMOTE_MS (5 s)— o si lo
  fuerza el operador; sin VPS no hay promoción automática. Quien ve un term mayor del
  maestro (enlace) o recibe 4409 pasa a esclavo. `mayPublish`: el cercado del SRT (con el
  enlace caído >LINK_FENCE_MS en un partido con esclavo, solo tras un `welcome`
  posterior a la caída). Constantes nuevas en LinkConstants, con las del ADR.
- Tests: RoleElectionTests (las tres condiciones una a una, el operador sin VPS, el
  antiguo maestro que se degrada, el cercado) y **200 partidas de 10 min con particiones
  al azar entre maestro, esclavo y hub: nunca dos publicadores con el mismo term, y si
  hay dos, el hub se queda con el de term mayor** (más de 20 promociones de verdad).

**Queda fuera**: guardar el term en disco antes de anunciarlo y el arranque del
promovido (IOS-85, con VPS).

## 2026-10-04 · IOS-81 — latido, detección de caída y una lente · 🚧 falta SPK-06 con dos iPhone

**Hecho**
- `RigCore/Runtime/PeerHealth.swift`: up/suspect/down por el latido; el enlace está
  arriba solo si se oye en los dos sentidos (el latido trae el último seq de medios que
  el otro oyó de mí, y el plazo corre desde CUÁNDO mandé ese seq). Caído tras
  HEARTBEAT_LOSS_MS (500 ms), dudoso a la mitad, y al cerrarse el control. Heartbeat:
  rol, term, escalera, estado (cámara, grabación, parte) y el seq, en 11 B.
- RigLinkSession: latido a LINK_HEARTBEAT_HZ (10 Hz) por medios, `health` y
  `onPeerState`; apunta cada seq de medios enviado y el último oído.
- En el maestro con el esclavo caído: DirectorService.setSingleLens (los límites de la
  lente que queda), MasterProgramStage.peerDown (ProgramSync deja de esperar la parte)
  y el banco compone sin enlace. Al volver, las dos lentes.
- Tests: PeerHealthTests (caída y vuelta en los tiempos del ADR, un solo sentido no está
  arriba, el latido va y vuelve) y en la sesión: **un corte en un solo sentido lo ven
  los dos en <1 s**.

**Medido en el iPhone 17** (maestro; el Mac de esclavo se va a mitad): el maestro lo ve
caído y **el programa no se para**: 1048 fotogramas, 0 fallos, tic p5 29,5 fps.
Antes de este arreglo, el programa se paraba al caer el esclavo (el tic exigía el enlace).

**Queda fuera**: la vuelta relajando los límites en 2 s, el temporizador de promoción
del esclavo (IOS-83) y SPK-06 con los dos iPhone.

## 2026-10-04 · IOS-57 — copias locales: el programa con audio · 🚧 falta el audio en la 4K y la política de disco

**Hecho**
- `RigMedia/Video/ProgramRecorder.swift`: AVAssetWriter en passthrough (outputSettings
  nil y la descripción de formato como pista) con el H.264 y el AAC del programa, en
  .mov; los instantes cuentan desde el primer fotograma; el AAC entra crudo (sin ADTS)
  con su ESDS. AacEncoder expone la `formatDescription` con la magic cookie del
  convertidor; AudioCapture, la suya.
- Banco program-split: el programa también en `program-split-<t>.mov`, con el audio del
  micro si RIG_AUDIO=1 (CaptureEngine `onAacFrame`).
- Tests: ProgramRecorderTests (2 s de H.264 y AAC de verdad → .mov que AVFoundation lee
  con sus dos pistas y 2,0 s).

**Medido en el iPhone 17** (maestro con el banco y RIG_AUDIO=1, 40 s): .mov con H.264
1920×1080 y AAC 48 kHz, 33,6 s, 1000 fotogramas y 1564 tramas de audio (las que tocan a
46,9 por segundo).

**Queda fuera**: la pista de audio en la grabación HEVC 4K de CaptureEngine, la 4K
encendida por defecto con PHONE_DISK_RESERVE_GB y el borrado tras la ingesta (ML-08).

## 2026-10-04 · IOS-87 — un solo partido en el maestro: migración y plantillas · 🚧 falta el MasterBoard de la pantalla

**Hecho**
- `lib/src/server/match_migration.dart`: la migración única de «zero.match» al partido
  del maestro: marcador y nombres; el cronómetro parado (lo acumulado más lo que corría
  por la hora de pared que guardaba el MatchState local, con un tope de 3 h) y, si
  corría, con `clock_restored` (dominio `migrado0`); las plantillas Player{número,
  nombre, puesto} a la lista de tools/lineup.py: el once en el orden de la formación
  local (portero y líneas de atrás adelante, Formation.lineUp) y el resto de suplentes.
  Una plantilla que no cumple las reglas no tumba la migración. Solo si el maestro aún
  no tiene partido; MasterHost la lanza al abrir (`legacyMatch` lee la clave).
- **Decisión**: el MatchState local se queda para el móvil que lleva el marcador sin
  soporte; la migración solo lo lee.
- `POST /api/v1/match/roster` {team, name, coach, formation, roster} con el ámbito `rig`
  (el QR Mando no edita plantillas, ADR 0017 enmienda §2), con parse_roster (texto o
  CSV); el nombre pasa al marcador. `MatchEngine.importLineups` y `readPodLineups`: el
  alineaciones.json del pod (`--lineups`) se importa tal cual (mismo formato).
- Tests (5): 2-1 en el 44:00 con dos plantillas de 14 → abre con ese marcador, el reloj
  parado en 44:00, el portero primero y 3 suplentes; un reloj en marcha migra parado con
  lo que corrió y clock_restored; basura no migra; MasterHost migra al abrir; roster con
  token → 403, con PIN → 200 (CSV, nombre al marcador, DT), una lista corta → 400, y el
  importador del pod.

**Queda fuera**: el MasterBoard (MatchBoard sobre el motor en el mismo proceso) para la
pantalla del maestro.

## 2026-10-04 · IOS-75 — registro N0 (JSONL) en el dispositivo · 🚧 faltan las detecciones (modelo) y la pasada de 10 min

**Hecho**
- `RigCore/Runtime/MatchLogRecord.swift`: los registros de match-log-v1 (EV-02) —
  cabecera, det, view, mark, score, clock, audio y clip— escritos byte a byte como
  `json.dumps(sort_keys=True, ensure_ascii=False)` de Python (PyJSON: claves ordenadas,
  ", " y ": ", el repr más corto de los decimales). **Los 9 tipos reproducen las líneas
  de match_log_sample.jsonl.** El esquema v1 es estricto: la vista lleva yaw, pitch,
  hfov y plano; la escalera y el enlace que pedía la tarjeta no están en la v1 y no se
  escriben (irían con una v2 del esquema). `fused` y `ball` llegan con la fusión y el
  balón.
- `RigMedia/Obs/E0Logger.swift`: un JSONL por partido y móvil; cabecera una vez (al
  reabrir no se repite), cola acotada a MATCH_LOG_QUEUE_MAX con vaciados cada
  MATCH_LOG_FLUSH_LINES en una cola propia, descartes contados; rechaza un
  `clock_domain` que el validador no aceptaría.
- Banco program-split: el maestro escribe las vistas a 7,5 Hz en Documents/n0/.
- Tests: E0RecordTests (la muestra, los decimales de Python), E0LoggerTests (cabecera,
  orden, descartes, dominio de reloj).

**Medido en el iPhone 17**: `read_match_log` de la referencia valida el N0 del banco:
172 registros en ~25 s, 0 inválidos, sin truncar. Antes cazó un fallo real: el banco
escribía `clock_domain: host-left`, que no cumple [a-z0-9]{8,32} (ADR 0023 §4).

**Arreglo del enlace (IOS-11)**: el control tampoco conectaba a veces tras reiniciar la
app: la conexión TCP al anuncio viejo se quedaba en `.waiting` (rechazada) y Network la
reintentaba para siempre. Ahora `.waiting` cuenta como caída, hay un plazo de 4 s para
quedar listo y al reintentar se prueba el siguiente anuncio. **6 de 6 pasadas seguidas
conectan, matando la app vieja cada vez (antes fallaban 1 de cada 3).**

## 2026-10-04 · IOS-73 — DirectorService, y el canal de medios que se quedaba mudo · 🚧 falta con dos iPhone y el modelo

**Hecho**
- `RigMedia/Pipeline/DirectorService.swift`: las detecciones propias y las del esclavo
  se emparejan por su instante de la rejilla (DetectionPairer; los dos usan los mismos
  t_k, así que el desfase es cero) → DirectorLoop → en cada tic el ViewCommand y las
  últimas vistas para el mensaje `view`. Órdenes del operador: modo, IA, ganancias y
  plano de situación.
- `detections` por el enlace: RigLinkSession `send(detections:targetRigMs:inferMs:)` en
  el esclavo y `onDetections` en el maestro (WireDetection ↔ PlayerDetection, clase por
  el índice de PlayerClass y score a 1/255).
- Banco program-split: con RIG_SPLIT_DIRECTOR=1 dirige el DirectorService (las
  ganancias del color entran en sus vistas); el soporte nominal usa DEFAULT_RIG_* de la
  referencia.
- Tests: DirectorServiceTests (15 s de un grupo que solo ve la cámara derecha: la
  cámara virtual va hacia él; todas las parejas con desfase 0; en plano abierto no
  persigue y salen huérfanos de un lado), las detecciones por la sesión.

**Arreglo del enlace (IOS-16)**: con el Mac de esclavo, unas pasadas recibían 600–2600
vistas y otras NINGUNA. Por UDP, el que escucha solo conoce al otro cuando le llega un
datagrama, y el que busca tomaba el primer anuncio de medios de Bonjour, que tras
reiniciar la app es el viejo de la caché: los dos quedaban sordos sin saberlo.
NWLinkTransport, en el lado que busca: lo recién anunciado va primero, al abrir manda
un sondeo y un vigilante cambia de anuncio si con el control conectado no llega nada
por medios en 3 s (`mediaRotations`). **Medido: 4 de 4 pasadas con vistas (583–690 en
25 s), con 1-2 cambios cada una.**

## 2026-10-04 · IOS-25 — etapa de detección con cadencia anclada al reloj del soporte · 🚧 falta el modelo y el banco players-30min

**Hecho**
- `RigCore/Runtime/DetectionCadence.swift`: la rejilla t_k = k / hz en ms del soporte.
- `RigMedia/Pipeline/PlayerDetectionStage.swift`: por fotograma que entra al anillo, al
  pasar t_k toma el fotograma más cercano (≤½ fotograma) y lanza la cadena; una sola
  detección en vuelo (la siguiente se descarta y se cuenta); `setCadence` para la
  cadencia común del maestro; `onDetections` → CameraDetections {lado, t_k, instante
  del fotograma, cajas, ms de inferencia}.
- CoreMLPlayerDetector: la cadena de verdad — DetectorInputBuilder (IOS-21) →
  CoreMLRunner por el carril de jugadores (IOS-22) → PlayerDecoder con el layout de
  band.json (IOS-23); toma nombres de salidas, clases y postproceso del manifiesto.
- IOS-23 (cont.): `person` → `player` para el modelo COCO provisional (ADR 0020), en la
  referencia y en la réplica a la vez, con un caso dorado nuevo (18 en detectors.json).
- Tests: la rejilla, **diez segundos de dos cámaras con fases a 5 ms: los mismos t_k sin
  hablarse, fotogramas a ≤17 ms del instante y a ≤6 ms entre ellos, 7,5 Hz**, y el
  descarte con una detección en vuelo.

**Queda fuera**: el modelo de ML-16 (bloqueado por el dueño) y las cifras de 30 min en
el iPhone; mandar las detecciones del esclavo por el enlace va con IOS-73.

## 2026-10-04 · IOS-22 — ejecutor Core ML con salidas preasignadas y manifiesto · 🚧 falta el modelo de ML-16 y medirlo en el iPhone

**Hecho**
- `RigMedia/ML/ModelManifest.swift`: el manifiesto de los modelos del móvil (espejo del
  bloque coreml de la ficha): fichero, SHA-256, min_ios ≥18, entrada (nombre, forma,
  color, normalización), salidas con su significado, clases, postproceso y formato de
  caja. Rechaza con el campo que falla (p. ej., logits con 3 clases y `classes` con 1);
  `check(against:)` compara con la descripción del modelo cargado (entrada, tamaño,
  formas de salida).
- `RigMedia/ML/CoreMLRunner.swift`: .cpuAndNeuralEngine con la pista de forma fija,
  comprobación contra el manifiesto, calentado, `outputBackings` preasignados por
  carril, cola serie con carriles de prioridad (balón antes que jugadores; una petición
  por carril, la nueva sustituye a la vieja y se cuenta), signposts e histograma por
  carril.
- `tools/make_test_model.py`: el modelo mínimo de los tests (MIL de coremltools, sin
  torch; 12 KB), con forma de DETR y salidas deterministas. `tools/fetch_models.sh`: baja
  los .mlpackage.zip del manifiesto y comprueba el SHA-256.
- Tests: CoreMLRunnerTests (el manifiesto que no cuadra, por clases y por tamaño, se
  rechaza con un error legible; la predicción en sus búferes con los valores esperados;
  los carriles).

**Queda fuera**: el modelo de verdad llega con ML-16 (bloqueado por el dueño); el
registro de ios/Runner/Models en el proyecto del Runner y las cifras en el iPhone
(calentado <10 s, p50/p99, Allocations plano) van con él.

## 2026-10-05 · Plan para los dos iPhone (H3)

`tools/banco_dos_moviles.sh` lo hace desatendido: compila con el rol de cada móvil
(AUTO_ROLE), instala, mata procesos viejos de la app, lanza los dos con el secreto
desde un fichero (no se imprime) y recoge Documents/bench y Documents/calib de cada uno
en `bench/dos-moviles-<fecha>/`.

1. `tools/banco_dos_moviles.sh split <secreto> 600`: el cosido de 10 min (IOS-43/44:
   dos lentes, fps, latencia, IDR), el color (IOS-38: ganancias en el informe), la
   pareja de calibración a los 30 s (IOS-70: Δ izquierda-derecha), el marcador y la
   franja en el programa (IOS-47/48) y, con el panel, la miniatura del esclavo (IOS-64).
2. `tools/banco_dos_moviles.sh link90 <secreto> 5400`: SPK-02 por Wi-Fi, 90 min de
   partes a 0/10/30 Mbit/s cada 5 min (decide UDP o TCP; ya se sabe que por Wi-Fi de
   punto de acceso caben ~15 Mbit/s).
3. Con los dos en marcha, desde el Mac: la API del mando (IOS-62) y el panel (IOS-64)
   por la LAN, con un token derivado del partido.

## 2026-10-04 · IOS-64 — panel local en la LAN con miniaturas · 🚧 falta con dos iPhone y el coste de CPU

**Hecho**
- `RigMedia/Graphics/Thumbnailer.swift`: NV12 (4K o 1080p) → 640×360 BGRA por
  VTPixelTransferSession (en la GPU, con bandas si no es 16:9) → JPEG por ImageIO, con
  pool preasignado.
- RigLinkSession `send(thumb:)`/`onThumb` (control, del esclavo al maestro); ThumbHub
  en el Runner guarda la última de cada cámara (la propia del anillo a 1 Hz; la del
  otro por el enlace) y la del programa (una de cada 30 fotogramas). Pigeon
  `thumbnail(name)`.
- API del maestro: `/` sirve `assets/panel/index.html` sin puerta (la página toma el
  token del fragmento `#mando=` del QR, que el navegador no manda al servidor);
  `/api/v1/rig/thumb/{left,right,program}` y `/api/v1/rig/status` con token.
- La página: marcador y reloj por la espera larga, goles con `expect`, reloj, ±1 min,
  alineaciones al aire, marcar jugada, las tres miniaturas a 1 Hz y el estado.
- Tests: ThumbnailTests (4K → JPEG 640×360 de pocos KB), la miniatura por la sesión,
  el panel en la API (página sin puerta, miniaturas y estado con token, 404) y el asset.

**Medido en el iPhone 17** (maestro con el banco, el Mac de esclavo y de portátil):
la página carga en 48 ms; miniatura de la cámara 6 KB en 25 ms y la del programa
12 KB en 20 ms (con marcador y franja); el estado dice maestro, enlace conectado,
30 fps, térmica fair, escalera 1, 0 fotogramas perdidos.

**Ojo**: en el iPhone quedaron dos procesos de la app de dos instalaciones y el viejo
tenía el puerto; `devicectl … process terminate` de los dos lo arregló. Mañana,
terminar procesos viejos antes de cada banco.

**Queda fuera**: la miniatura del esclavo de verdad y el coste de CPU (≤2 %) con los
dos iPhone.

## 2026-10-04 · IOS-54 — audio del micrófono: captura y AAC · 🚧 falta la pasada de 10 min y meterlo en el programa

**Hecho**
- `RigMedia/Audio/AacEncoder.swift`: PCM de 48 kHz → AVAudioConverter → AAC-LC a
  128 kbit/s en tasa CONSTANTE (el relé espera caudal estable) → tramas con su cabecera
  ADTS (Adts de IOS-53) en una BoundedQueue; cada trama lleva el rigMs de la primera
  muestra más las ya codificadas.
- `RigMedia/Audio/AudioCapture.swift`: el delegado del micro, aparte del de vídeo (los
  dos protocolos comparten selector); el PTS pasa al reloj del soporte con el mismo
  desfase que los fotogramas; cuenta búferes, huecos de más de una trama y fallos.
- CaptureEngine: con RIG_AUDIO=1, el micro entra en la misma sesión y las tramas van a
  Documents/bench/audio-<t>.aac con un resumen cada ~10 s. Apagado por defecto hasta
  que el programa lo use (y para no pedir permiso a nadie en banco).
- Tests: AacEncoderTests (10 s de un tono de 1 kHz: tramas ADTS seguidas sin huecos, su
  instante cada 21,33 ms, ~128 kbit/s, y decodificado vuelve un 1 kHz).

**Medido en el iPhone 17** (RIG_AUDIO=1, ~69 s): 2820 tramas, 0 huecos, 0 fallos;
ffprobe: AAC-LC, 48 kHz, mono, 130 kbit/s; nivel medio −35 dB y pico −1,9 dB (el
sonido de la sala).

**Queda fuera**: los 10 min con el desfase A/V frente al rigMs del vídeo, la pista en
el TS del programa (en vez del silencio del relé) y la interrupción
audioDeviceInUseByAnotherClient.

## 2026-10-04 · IOS-23 — postproceso de detecciones en RigCore · 🚧 falta medir 300 queries en el iPhone

**Hecho**
- `RigCore/Detection/Postprocess.swift`: réplica de libs/vision/postprocess.py —
  sigmoid por tanh en Float, cajas a esquinas, cxcywh y xyxy por layout (región del
  centro, recorte y a nativo; cuentas en Double y salida en Float como la referencia),
  NMS por clase con el truco del desplazamiento y desempate por índice, picos del
  heatmap (ventana con borde replicado, umbral, una meseta = un pico, desempate por
  clase, fila y columna) y el refinado subpíxel.
- PlayerDecoder: réplica de PlayerDetector.detect sin el backend — argmax con umbral
  sin rescatar la segunda clase, clases por la ficha (lo que no se emite, fuera), la
  junta del mosaico (`mergeSeam`: misma clase, lados opuestos, solape en X; la unión con
  los pies de abajo), la máscara de campo por los pies y DETR (orden por score, tope) o
  NMS.
- REF exporta PLAYER_MAX_DETECTIONS y PLAYER_SEAM_* a DetectionSpec.
- Tests: PostprocessTests — los 7 tipos de postprocess.json (sigmoid, esquinas, cxcywh,
  xyxy, nms, picos, refinado) y los 17 casos de detectors.json (REF-39) de punta a punta,
  más una pasada de 300 queries.

**Queda fuera**: la cifra de la aceptación (300 queries en <0,2 ms en el iPhone) va con
el banco del detector (SPK-01/IOS-25).

## 2026-10-04 · IOS-48 — franja de anuncios en el maestro · 🚧 falta la pasada de 10 min con overrides

**Hecho**
- `RigCore/Ads/AdPlaylist.swift`: réplica de cycle_ns, ad_at y _frame_at de
  tools/ad_strip.py (AdClip, AdSlot, AdOverride, AdCue, AdPlaylist), en tiempo y en
  enteros. Cuadra con los 12 dorados de ad_strip.json (rotación, bucles, 25 y 30 fps
  mezclados, tiempo negativo y los cinco casos de override).
- `RigMedia/Graphics/AdStore.swift`: carga como load_ad (fotogramas RGBA deduplicados
  por SHA-256, premultiplicado con el redondeo de la referencia y alfa inversa, en
  texturas del alto de la franja, 1920×108), rechaza opacos, cadencias que no son 25 o
  30 y lo que no cabe. **Decisión mínima**: AD_MEMORY_BUDGET no existía; queda en
  192 MiB (~115 fotogramas distintos), con un error que dice cuánto ocupa y cuánto queda.
  Carga directorios de PNG (el master de Remotion). AdRotation elige la franja por el
  reloj del soporte, con override.
- ProgramComposing recibe el instante del programa; MetalProgramComposer pasa la franja
  al kernel. Pigeon `setAdPlaylist(json)` y `setAdOverride(name, loops)`; AdHub en el
  Runner; el banco carga una lista con RIG_ADS.
- Tests: AdPlaylistTests (dorados), AdStoreTests (4: deduplicado y premultiplicado,
  rechazos y presupuesto, PNG, rotación con override).

**Medido en el iPhone 17**: un anuncio de prueba con alfa sale compuesto sobre la barra
de la franja en el .ts del programa, sin un fallo de composición.

## 2026-10-04 · IOS-47 (cont.) y IOS-62: parches y la API desde un tercer dispositivo

- La subida del gráfico tardaba 22 ms: la capa del marcador lleva arriba el marcador y
  abajo la barra, y su caja era el fotograma entero (8 MB por Pigeon y 2 M píxeles en
  coma flotante cada segundo). Ahora Dart manda solo el rectángulo que cambió respecto
  a lo último enviado (un parche, transparentes incluidos) y el nativo pega el parche en
  su copia de la capa y recompone en enteros. **Medido: 0,019 ms la última subida, 71 en
  ~75 s, una por segundo con el reloj en marcha.**
- El maestro guardaba el partido fuera de Documents (HOME no es el contenedor en iOS):
  `appDocumentsPath()` lo toma del padre del temporal de la app.
- **IOS-62 por la LAN, con el Mac de tercer dispositivo**: un token firmado en Python
  (tools/control_token.py) con el secreto derivado del soporte abre la API Dart del
  iPhone: GET del partido, `match/clock start`, un gol (200) y el mismo gol con el
  marcador viejo (409 «home tiene 1 goles, no 0»). El gol sale en el marcador del
  programa a los 2 s.

## 2026-10-04 · IOS-47 — puente del gráfico a Metal · 🚧 falta el banco de 10 min

**Hecho**
- Pigeon rig_api: `setOverlay(rgba, width, height, x, y, layer, generation)` y
  `clearOverlay(layer)`.
- `RigMedia/Graphics/OverlayStore.swift`: las capas (marcador, alineación, SIN SEÑAL)
  en CPU con su caja; un búfer RGBA a tamaño de programa preasignado con las capas
  apiladas («over» sin premultiplicar), recompuesto solo en el rectángulo sucio; dos
  texturas preasignadas: se sube a la de atrás lo sucio más lo que le faltaba y se
  cambia de golpe. La composición toma la activa con `beginFrame`/`endFrame` y mientras
  la lee nadie la escribe. Una generación vieja se ignora. Nada se reserva por fotograma.
- MetalProgramComposer lee el gráfico del OverlayStore; el Runner tiene uno
  (OverlayHub) que llena Dart y lee el banco program-split.
- Dart: `overlay_bridge.dart` (recorte a la caja con contenido antes de cruzar Pigeon,
  generación por capa, vacía = quitar), `program_graphics.dart` (del MatchEngine al
  marcador y a la tarjeta de alineación al aire) y `rig_overlay_sink.dart`. MasterHost
  lo arranca al dirigir: con cada cambio del partido y una vez por segundo.
- Tests: OverlayStoreTests (2: apilado, generaciones, borrado, las dos texturas
  coherentes; la textura en uso no se cambia hasta soltarla), overlay_bridge_test (2),
  program_graphics_test (marcador por cambio y por segundo, la alineación al aire y
  fuera).

**Medido en el iPhone 17** (maestro con RIG_SPLIT, el Mac de esclavo): el marcador de
Dart sale compuesto en el .ts del programa («LOCAL 0-0 VISITANTE», «CÁMARA IA AUTO» y
la franja de patrocinio), 1135 fotogramas sin un fallo de composición.

**Queda fuera**: las cifras de la aceptación (10 min, subida ≤1 ms) salen del informe
del banco (`overlay_uploads`, `overlay_last_upload_ms`) en la pasada larga.

## 2026-10-04 · IOS-38 — igualado de color en el solape · 🚧 falta la prueba de +1/3 EV en dos iPhone

**Hecho**
- REF: se exporta la familia PANORAMA_COLOR_MATCH_ a RigConstants.
- `RigCore/Direction/ColorMatcher.swift`: réplica de PanoramaStitcher.observe_color
  (raíz del cociente BGR, tope PANORAMA_COLOR_MATCH_MAX_GAIN, nivel mínimo, suavizado
  0,25). Cuadra con los 5 dorados `observe_color` de color.json.
- `RigMedia/Capture/OverlapMeans.swift`: la media BGR de la cámara propia dentro del
  solape. Las muestras (paso 8) se eligen una vez con RigModel (los píxeles que la otra
  cámara también ve, con el giro de la montura); la medida lee el NV12 y pasa a BGR
  BT.709. **Desviación de la tarjeta:** en CPU y no en Metal, porque a 0,5 Hz son
  ~130 000 lecturas en 4K y un kernel no compensa; se anota aquí.
- `color_means` por medios (ColorMeansWire, 3 × f32) del esclavo al maestro.
- Banco program-split: cada 2 s el esclavo manda su media y el maestro iguala con la
  suya; las ganancias viajan en cada vista y salen en el informe.
- Tests: ColorMatcherTests (dorados y el tope), OverlapMeansTests (dónde cae el solape
  en cada cámara, girada o no, y la media de un NV12 liso), la sesión.

**Queda fuera**: la medida de los dorados `color_match` (el camino por el lienzo
entero de la referencia) no se replica: aquí se mide en el búfer de cada cámara. La
aceptación (+1/3 EV en el esclavo, la costura baja de 2 % en ≤10 s) va con los dos iPhone.

## 2026-10-04 · IOS-70 — pareja de fotogramas sincronizados para calibrar · 🚧 falta la pareja con dos iPhone

**Hecho**
- REF: RIG_CALIB_PAIR_COUNT (5, el DEFAULT_INSTANTS de calibrate_from_recordings, que
  ahora lo usa), RIG_CALIB_PAIR_SPACING_MS (1000), RIG_CALIB_LEAD_MS (500),
  RIG_CALIB_JPEG_QUALITY (0,95) y RIG_CALIB_JPEG_MAX_BYTES (6 MiB) en
  libs/vision/constants.py; se exportan a RigConstants, y también DEFAULT_RIG_*.
- `RigCore/Runtime/CalibrationPlan.swift`: los destinos y la elección del fotograma
  (el más cercano a ≤16 ms; si no, el primero de después).
- `RigMedia/Capture/CalibrationStillCapture.swift`: espera a que el anillo llegue al
  destino, fija el fotograma, lo guarda en JPEG q95 4K (CoreImage + ImageIO) con el
  tope de tamaño, y un JSON con lado, instante, destino, intrínsecas de ESE fotograma
  (RigPipeline las guarda por rigMs), tamaño, mount_flip y lo que añada el llamante.
  FrameRing gana `availableRigMs()`.
- RigLinkSession: `send(calibrationCapture:)` (command JSON por control,
  `kind: calibration_capture`) y `onCalibrationCapture` en el esclavo.
- Runner: CalibrationPairs captura en los dos con el reloj del soporte en
  Documents/calib/<id>/ (id = primer destino, el mismo en los dos) con un resumen; los
  destinos parten del último fotograma del maestro, así caen en su rejilla. Pigeon
  `captureCalibrationPairs()` y disparo automático con RIG_CALIB_AT_S.
- Tests: CalibrationPlanTests (2), StillCaptureTests (2: el fotograma elegido, JPEG 4K
  y su JSON; el plazo agotado), la orden por la sesión.

**Medido en el iPhone 17 (maestro, el Mac de esclavo):** 5 de 5 fotogramas 4K con
intrínsecas, exposición y balance; Δ al destino 0, −1, −1, −2 y −2 ms; el mayor JPEG,
0,71 MB (escena oscura). Antes de alinear los destinos a la rejilla, ±15–17 ms.

**Queda fuera**: la pareja de verdad (|ΔrigMs| izquierda-derecha ≤16 ms, objetivo
≤5 ms) con los dos iPhone; el botón de la app y la subida van con IOS-71.

## 2026-10-04 · Banco program-split (IOS-43/44) listo para los dos iPhone · 🚧

**Hecho**
- SplitBench (Runner, RigLinkNW.swift): con RIG_SPLIT=1 y el enlace de Network
  (RIG_LINK_MULTIPEER=0), la pantalla de captura normal monta el render repartido. El
  esclavo pinta, codifica y manda su parte por fotograma del pipeline; el maestro genera
  a 30 Hz un barrido de guion que cruza la costura (no hay director todavía), lo manda
  como `view` con 67 ms de adelanto, compone en T + 100 ms, codifica el programa a
  6 Mbit/s y lo graba en Documents/bench/program-split-<t>.ts, con informe JSON (dos y
  una lente, partes, IDR, tic p5/p50, latencia añadida p50/p95). Usa Documents/rig.json
  si existe; si no, un soporte nominal (±35°, HFOV 106°, pitch −8°, todo por entorno).
  Bitrate de la parte por RIG_SPLIT_PART_MBPS (12 por defecto, por lo medido en SPK-02).
- FrameRing expone su tamaño; CaptureEngine, el pipeline; RigLinkNW, la sesión.
- LinkPeerTests: el Mac puede hacer de derecho (RIG_LINK_PEER_SIDE=right).

**Medido hoy con un iPhone (iPhone 17 de maestro izquierdo con su cámara 4K, el Mac de
esclavo sin cámara, Wi-Fi), 90 s:** 2667 fotogramas de programa, todos de una lente
(el Mac no manda partes), tic p5 29,65 / p50 30,0 fps, 0 fallos de composición,
latencia añadida p50 132 / p95 133 ms (los 100 de espera fija más la rejilla), .ts
válido (ffprobe: H.264 1920×1080, 2667 fotogramas). El Mac recibió 2667 vistas. La
imagen salió negra porque la cámara veía negro (luma media 17,7 en el volcado NV12
crudo del mismo minuto): el móvil estaba boca abajo.

**Mañana con los dos iPhone**: AUTO_ROLE=left en uno y right en el otro, RIG_SPLIT=1,
RIG_SPLIT_S=600, mirando a algo iluminado; de ahí salen las cifras de IOS-43/44.

## 2026-10-04 · SPK-02 — primeras medidas de partes por Wi-Fi (un iPhone y el Mac) · 🚧

**Hecho**
- link-bench gana la carga de SPK-02: con RIG_LINK_PARTS=1 el esclavo manda partes
  sintéticas a 30 fps por el camino de las de verdad (PartPacket → medios → espaciado →
  reensamblado), con un perfil de Mbit/s por escalones (RIG_LINK_PARTS_PROFILE,
  RIG_LINK_PARTS_STEP_S; por defecto 0, 10 y 30 cada 5 min) y un IDR ×4 cada 2 s o a
  petición; con 0 Mbit/s manda `no_part`. El maestro pasa las partes por PartReceiver,
  pide IDR y cuenta pérdidas (ppm), parones de más de 100 y 150 ms, el peor hueco,
  jitter, Mbit/s y la batería. RIG_LINK_PACING_BURST / RIG_LINK_PACING_US cambian el
  espaciado sin recompilar.
- `Tests/RigNetTests/Device/LinkPeerTests.swift`: el Mac hace de móvil izquierdo y
  maestro por Wi-Fi (se salta sin RIG_LINK_PEER_S), para probar con un solo iPhone.
- Arreglo de IOS-43: MetalPartRenderer aplicaba el giro de la montura a los dos lados;
  solo va girado el izquierdo (`--flip left`), ahora con `mountedUpsideDown` explícito.

**Medidas (iPhone 17 de esclavo → Mac de maestro, los dos por la Wi-Fi de la oficina,
doble salto por el punto de acceso; 60 s por pasada):**

| Mbit/s | Espaciado | Pérdidas | Parones >100 / >150 ms | Peor hueco |
|---|---|---|---|---|
| 10 | 16 / 2 ms | 0 | 2 / 1 | 171 ms |
| 15 | 16 / 2 ms | 0,22 % | 2 / 0 | 140 ms |
| 20 | 16 / 2 ms | 2,4 % | 44 / 5 | 276 ms |
| 30 | 16 / 2 ms | 33 % | 165 / 52 | 541 ms |
| 30 | 4 / 1 ms, 2 / 0,5 ms, sin espaciar | 37–45 % | 75–157 / 52–85 | 374–502 ms |

La puerta de huecos funciona: con un 40 % de pérdidas el decodificador nunca recibió
una cadena rota. El espaciado no cambia nada a 30 Mbit/s: no son ráfagas, es la
capacidad de este camino (~18–20 Mbit/s útiles). TCP no lo arreglaría.

**Lectura para decidir (del dueño, no bloquea):** por Wi-Fi de punto de acceso, las
partes caben hasta ~15 Mbit/s. O el soporte va por Ethernet (lo que dice el ADR 0023),
o la parte del esclavo baja su bitrate cuando el enlace es Wi-Fi (la escalera de
degradación ya tiene dónde engancharlo). Falta repetir entre los dos iPhone (mañana) y
la pasada de 90 min.

## 2026-10-04 · IOS-44 — el programa del maestro: recepción, decodificación y composición · 🚧 falta el banco program-split en dos iPhone

**Hecho**
- `RigMedia/Pipeline/MasterProgramStage.swift`: las partes pasan por PartReceiver (solo
  cadenas enteras al decodificador; ante un hueco, `onIdrRequest` con el part_seq), se
  decodifican (VideoDecoder, IOS-51) y se apuntan en ProgramSync con la vista que traen.
  En cada tic, dos lentes —la mitad del maestro pintada con la vista DE LA PARTE y con
  su fotograma más cercano al instante de la parte (`masterFrame`, del FrameRing)— o una
  lente con la vista del maestro si la parte no llegó. Un encuadre que cae entero en el
  esclavo no pinta la mitad del maestro. Contadores de dos y una lente, partes, IDR y
  fallos; Mbit/s, jitter y pérdidas de las partes.
- MetalProgramComposer: ComposeProgramKernel (IOS-41) con la costura y el fundido de
  la vista; sin gráfico ni franja hasta IOS-47/48.
- Tests (4) con partes de verdad (SlavePartStage + VideoToolbox) y render y composición
  falsos: dos lentes con la vista de la parte y el fotograma de su instante, una lente
  sin parte, hueco → IDR pedido y nada decodificado hasta él, y el encuadre solo del
  esclavo.

**Queda fuera**: el banco program-split (barrido que cruza la costura 10 min, fps,
latencia añadida y desgarros) en los dos iPhone.

## 2026-10-04 · IOS-43 — la parte del esclavo: render, codificación y envío · 🚧 falta medirla en dos iPhone

**Hecho**
- `RigMedia/Pipeline/SlavePartStage.swift`: por fotograma del esclavo resuelve la vista
  (SlaveViewResolver), manda `no_part` si la vista no pide su lado, y si la pide pinta la
  parte en un búfer del pool del codificador, la codifica (VideoEncoder, IOS-50) y la
  saca por `onPart` con la vista que usó de verdad y el bit de extrapolada. Al IDR le
  pega los SPS/PPS en banda. Pasa por PartSendQueue (IOS-52): una parte tirada no
  consume part_seq, y `requestIdr` fuerza el IDR del siguiente fotograma.
- MetalPartRenderer: la vista → RectilinearView → viewHomographyToRaw del lado →
  ReprojectKernel con las ganancias de su lado (BGR, el orden de la referencia).
- RigMedia no ve el enlace: el Runner conectará `onPart`/`onNoPart` a RigLinkSession.
- Tests (5) con el codificador de verdad y un render falso: sin vista no sale nada;
  vista de otro lado → `no_part` sin pintar; 10 partes con part_seq seguido, la vista de
  cada una y el primer IDR con SPS/PPS; IDR en el fotograma siguiente a la petición;
  extrapolada marcada; un render que falla se cuenta.

**Queda fuera**: el banco part-slave y las medidas de la aceptación (p95 ≤60 ms, GPU
≤2 ms) en dos iPhone; el enganche al pipeline de captura va con IOS-44.

## 2026-10-04 · IOS-52 — transporte de las partes por el enlace · 🚧 falta la pasada de 30 min con dos iPhone

**Hecho**
- `RigCore/Wire/PartPacket.swift`: el binario de medios del ADR 0023 §5. ViewWire (la
  vista con los ángulos y las ganancias en f32, `sides` en un byte; `quantized` da la
  vista tal y como la ve el otro móvil, para que las dos mitades pinten con los mismos
  f32), el mensaje `view` con las VIEW_HISTORY últimas, PartPacket (part_seq ‖ vista ‖
  AVCC; captura en `rig_ms`, IDR y extrapolada en `flags`), NoPartPacket e
  IdrRequestWire.
- `RigCore/Wire/PartFlow.swift`: PartSendQueue (2 partes; si tira una, tira las P hasta
  el IDR que fuerza el codificador al ver `needsIdr`; la petición del maestro vacía las P
  en cola y respeta un IDR ya encolado) y PartReceiver (orden, huecos de part_seq, nada
  al decodificador hasta un IDR y `idr_request` con cada parte tirada; Mbit/s de la
  última ventana y jitter RFC 3550).
- RigLinkSession: `send(views:)` (maestro, medios), `send(part:)` y `send(noPart:)`
  (esclavo, medios), `requestIdr(partSeq:)` (maestro, control) y sus `on…`; cada uno
  solo en su sentido.
- NWLinkTransport: las tramas de más de un datagrama salen espaciadas, 16 datagramas
  cada 2 ms (~77 Mbit/s de pico), con la cola acotada a 2048 datagramas y lo que no cabe
  contado (`mediaPacerDrops`). Las de un datagrama (latidos, reloj, vistas) no esperan
  detrás de un IDR.
- Tests (13): PartPacketTests (5), PartFlowTests (6, entre ellos **diez minutos
  simulados con 1 % de pérdidas y 0–50 ms de jitter: ninguna P llega al decodificador
  sin su anterior y cada petición se atiende con un IDR en ≤2 fotogramas**), la sesión
  con los cuatro mensajes y tres IDR de 300 KB por el loopback UDP, enteros y espaciados.

**Queda fuera**: la segunda aceptación (0 pérdidas a 30 Mbit/s durante 30 min entre
dos iPhone) va con el banco de SPK-02 por Wi-Fi mañana; el criterio UDP/TCP lo decide
SPK-02.

## 2026-10-04 · IOS-62 — API /api/v1 del mando servida por el maestro · 🚧 falta la prueba en la LAN con dos iPhone

**Hecho**
- `lib/src/server/api_server.dart`: MasterApi, sin sockets (ApiRequest → ApiResponse,
  para que IOS-65 atienda con lo mismo los `command` del túnel), y MasterApiServer, el
  HttpServer de dart:io en masterApiPort. GET /api/v1/match con `since=<boot>:<rev>` y
  espera larga ≤25 s (despierta con `MatchEngine.changes`), 8 esperas como mucho y 503
  a la novena; los POST de ORDERS con Idempotency-Key; errores RFC 7807 (409 con el
  partido y sus scopes); 415/400/404/413; X-Zero-Device para la lista de mandos (16, el
  último minuto).
- La puerta: Bearer con el token de mando (verificado con el secreto derivado del
  partido; da `match` y `stream` como mucho, nunca `rig`, ADR 0017 enmienda §3) o con el
  PIN del operador (los tres ámbitos), comparado en tiempo constante.
- `stream/*` va al relé del VPS (ADR 0022): `relay` manda el `relay_command` y se espera
  apiCommandTimeout (5 s, si vence 504); sin túnel, 503.
- `lib/src/server/idempotency.dart`: porte de tools/idempotency.py (256 claves, 600 s,
  el patrón de clave); guarda el Future, así que un reintento que llega mientras la
  primera se aplica espera a esa respuesta.
- Tests (13), de integración con PanelControl contra el servidor real: gol y el de otro
  mando por la espera larga, 409 con el partido bueno, 403 sin `stream`, la misma clave
  aplicada una vez, la espera larga despierta en ≤100 ms, 503 a la novena, 401/410,
  `rig` que no se gana con token, 404/415/400, stream sin túnel 503 y 504 sin respuesta.

**Cableado en la app (mismo día)**
- `lib/src/server/master_host.dart`: MasterHost abre el partido en Documents/partido y
  sirve la API cuando el enlace dice que este móvil dirige (`onRigRole` trae ahora el
  `match_id`); si el enlace no traía partido, empieza uno y lo anuncia al enlace
  (`setMatchId`, va en el hello siguiente). Otro partido del enlace aparta el guardado a
  `match-<id>.json`. Al pasar a esclavo o cerrar la pantalla, cierra.
- Pigeon: `controlSecret(matchId)` (lo deriva el nativo con LinkAuth.controlSecret; S
  no pasa a Dart), `setMatchId`, `linkPeerAddress` (la IP del otro por la conexión de
  control, NWLinkTransport.peerHost) y el PIN del operador en el Keychain
  (`loadOperatorPin`/`saveOperatorPin`; KeychainText generaliza el del emparejamiento).
- Pantalla de captura: botón «QR MANDO» solo en el que sirve el mando, con el QR (este
  móvil, el otro y el VPS si lo hay), «puede emitir» y el PIN (6 cifras o más).
- Tests (5) de MasterHost: arranque y anuncio del partido, QR verificable con el
  secreto derivado, partido nuevo que aparta el viejo, sin S sirve solo con PIN, y
  CaptureSession que arranca y para el servidor con el rol.

**Queda fuera**: la prueba con dos iPhone (el Mac hace de tercer dispositivo con curl y
la app Zero como mando). El cronómetro del maestro usa un Stopwatch hasta que el reloj
del soporte de IOS-13 se exponga a Dart con su `clock_domain`.

## 2026-10-04 · IOS-61 — alineaciones en el maestro · ✅

**Hecho**
- `lib/src/server/lineups.dart`: porte de tools/lineup.py en lo que usa la API
  (parseFormation, parseRoster con BOM, CRLF, cabecera de CSV y columnas sobrantes,
  buildTeam, rosterText, `relineup` para recolocar por formación, Team validado al
  construirlo y LineupBook con set/toggle/setOnAir/summary y guardado atómico). Los
  límites, con su nombre de Python; los nombres se cuentan por caracteres como en Python.
  RosterPlayer, para no chocar con el Player de la pantalla local.
- MatchEngine: la orden `match/lineup` como `_order_lineup` (400/409, recolocar, sacar al
  aire, ocultar la propia sin tocar la del rival), `saveLineup` (el editor; el nombre
  pasa al marcador) y el DTO con formation, players y lineup_on_air. Las alineaciones
  van en `lineups.json` junto al partido; un fichero roto se aparta a `.roto`, el maestro
  arranca sin ellas y lo dice en `lineupsError`.
- Tests (17): los 6 dorados de lineups.json (5 build_team y la traza on_air con su
  summary), la lista, las formaciones, el disco y la orden en el motor.

**Queda fuera**: la ruta del editor (`/api/lineup`) la sirve la API del mando (IOS-62).

## 2026-10-04 · IOS-63 — token de mando y QR en el maestro · ✅

**Hecho**
- `lib/src/server/control_token.dart`: porte de tools/control_token.py, byte a byte
  (claims m/r/s/e/g, JSON compacto con lo no ASCII escapado como `json.dumps`,
  base64url sin relleno, HMAC-SHA256, comparación en tiempo constante, los mismos
  401/410 y mensajes). `deriveControlSecret`: el secreto del mando por partido,
  HMAC-SHA256(S, "zero-control-v1 " ‖ match_id) en base64url (ADR 0023 §3); no se guarda
  ni viaja, así que la tarjeta («se guarda en el Keychain») queda superada por el ADR.
- `lib/src/server/control_pairing.dart`: el texto del QR Mando con el token y las
  direcciones del maestro, del otro móvil y del VPS (punto abierto aceptado del ADR
  0023). PanelPairing gana `alternates` (fragmento `alt`, separadas por espacios) y
  `compose`; PanelControl pasa a la siguiente ante un corte o un 5xx.
- `lib/src/widgets/qr_view.dart`: el QR pintado con un CustomPainter (paquete qr).
- Decisión mínima: `masterApiPort` = 8090, el mismo del panel del Mac, porque un mando
  no distingue a quién habla. Paquetes crypto y qr (BSD-3) en DEPENDENCIES.md.
- Tests (21): los 11 dorados de control_token.json (emitir y verificar), el secreto
  derivado contra un vector de Python, tildes, token del soporte con generación, el QR
  con tres direcciones y el relevo del mando a la alternativa con la primera caída.

**Queda fuera**: enseñar el QR en la pantalla del maestro llega con la API del mando
(IOS-62), que es la que lo atiende. El secreto del soporte S sigue viniendo de
RIG_LINK_SECRET hasta IOS-97; la derivación en nativo (para que S no pase a Dart) se
hará allí por Pigeon.

## 2026-10-04 · IOS-80 — rol maestro/esclavo desacoplado del lado · 🚧 falta la prueba con dos iPhone

**Hecho**
- `RigCore/Wire/RoleNegotiation.swift`, lógica pura (ADR 0023 §7): el term menor
  adopta el mayor y deja de mandar; mismo term y dos maestros, manda el izquierdo (y se
  registra); sin maestro, la preferencia toma max + 1 y el partido es el del que pasa
  a dirigir; dos maestros de partidos distintos, conflicto. RoleNegotiationTests (8)
  recorre más de 4000 combinaciones: o conflicto en los dos, o UN maestro con el mismo
  term y partido. Encontró un fallo (cada lado se quedaba con su propio partido al
  empezar sin maestro), corregido.
- `RigLinkSession`: el hello lleva rol, term, partido y `prefers_master` (opcional, un
  hello viejo sigue valiendo); tras el auth cada lado negocia. Reloj, órdenes, color y
  PTS siguen al rol negociado, no al lado; estado `.conflict`. RigLinkSessionTests: el
  derecho de maestro (el izquierdo pregunta la hora y recibe las órdenes), dos
  maestros del mismo term y el conflicto.
- Pigeon: `RigRole`, `LinkState.conflict`, `startLink(role, prefersMaster)` y
  `onRigRole(role, term)`. RigLinkNW entra sin partido y decide la preferencia.
- Dart: `CaptureSession.isRigMaster` (el maestro del reloj es el del soporte; sin
  negociar, el izquierdo, como con Multipeer), RolePage «Este móvil dirige» guardado en
  el móvil (por defecto, el izquierdo), y la etiqueta del conflicto. 255 tests.
- link-bench ya sigue al rol negociado (RIG_LINK_PREFERS_MASTER) y lo informa.

**Falta para ✅**: en dos iPhone, con el derecho de maestro todo funciona sin
reiniciar, y dos que se declaran maestro se resuelven (con link-bench).

## 2026-10-04 · IOS-60 — estado del partido con autoridad en el maestro (Dart) · ✅

**Hecho**
- `lib/src/server/match_record.dart`: el JSON v1 de tools/match_record.py (los mismos
  `clock_ms`/`clock_running`) más `started_rig_ms` y `clock_domain` del ADR 0023;
  lectura entera o nada, escritura atómica (temporal + renombrado).
- `lib/src/server/match_engine.dart`: las órdenes de ORDERS de live_panel —gol con
  expect/409 (y el partido de verdad en el error), marcador, cronómetro
  start/pause/reset/nudge ≤3600 s, clips/mark (404 sin búfer) y stream start/stop
  (409 sin túnel, ADR 0022)— con boot/rev, guardado en cada cambio y cada 10 s en
  marcha, y el DTO que lee PanelMatch. El cronómetro solo lee una fuente monótona
  (MatchTimeSource: el reloj del soporte o un Stopwatch); en el mismo `clock_domain`
  sigue en marcha tras reiniciar, en otro vuelve parado con `clock_restored`.
- Las alineaciones del DTO (formation, players, lineup_on_air) llegan con IOS-61; los
  `scopes`, con la API del mando (IOS-62).
- Tests (19): las órdenes de live_panel (409, 400, idempotencia, límites del nudge),
  reinicio en el mismo dominio y en otro, PanelMatch.fromJson, el fichero, y que el
  motor no use DateTime.now.

## 2026-10-04 · IOS-42 — sincronía de vistas y partes sin desgarros · ✅

**Hecho**
- `RigCore/Direction/ViewSync.swift`, lógica pura (ADR 0023 §5): ViewHistory (el
  anillo acotado del maestro; cada mensaje `view` lleva las VIEW_HISTORY=3 últimas),
  SlaveViewResolver (la vista del fotograma a ≤½ fotograma, o extrapolada lineal de
  las dos últimas y marcada; acepta desorden y duplicados), PartInfo (la parte lleva
  la vista que usó de verdad) y ProgramSync (compone el instante T SIEMPRE en el tic
  T + PART_MAX_WAIT_MS: con la parte, las dos mitades con su vista y el fotograma del
  maestro más cercano al de la parte; sin ella, una lente y contada).
- LinkConstants gana `viewHistory` y `partMaxWaitMs` (los del ADR); ViewCommand y
  ResolvedView, init públicos.
- ViewSyncTests (4): dos minutos simulados con 10 % de vistas y 5 % de partes perdidas,
  jitter 0–80 ms y reordenado: **0 fotogramas con vistas distintas**, las caídas a una
  lente son exactamente las pérdidas inyectadas, retardo 100 ms ±1 fotograma; la
  extrapolación sigue la trayectoria; el maestro no compone antes de su tic; el
  mensaje view lleva las tres últimas.

## 2026-10-03 · IOS-15 — volcado NV12 crudo para el salto de dominio · ✅

**Cierre (2026-10-04)**: grabación de prueba de 180 s en el iPhone 17 con
NV12_DUMP_S=10, lanzada sin tocar la pantalla (AUTO_ROLE=left, STANDALONE=true,
AUTO_RECORD_S=180, nuevos en main.dart; la grabación arranca al quedar lista la cámara
y para sola). Informe nativo (CaptureEngine, bench/nv12-dump-run-*.json): **0
fotogramas perdidos**, **29,99 fps** (5398 en 180 s), 19 volcados sin fallos, 0 fallos
del código de tiempo. Los volcados se leen con el formato de ML-18
(`tools/nv12_check.py`): 4K `420v`, color BT.709 en la cabecera, uno cada 10 s exactos
de rig_ms. El móvil estaba boca abajo (imagen oscura): para medir el salto de dominio
de verdad, ML-58 los tomará en un partido.

### Lo que se entregó antes

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
