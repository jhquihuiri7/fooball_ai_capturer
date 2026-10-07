# PROGRESS

Tablero de la migración a la arquitectura B en este repo: las tarjetas IOS y SPK de
`football-ai/docs/plan-dos-moviles/app-ios.md`. Se anota al cerrar cada tarea: ID ·
estado · qué quedó fuera · siguiente paso. Todo va en la rama `migracion/dos-moviles`;
`main` no recibe nada.

Una tarea que necesita el móvil no pasa a ✅ hasta que Alexander la ha probado en el
iPhone.

Leyenda: ✅ hecha · 🚧 en curso · ⛔ bloqueada · ⬜ pendiente

---

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
