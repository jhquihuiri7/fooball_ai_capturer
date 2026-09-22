# football-ai-capture — Memoria del proyecto

> **Cómo usarme con esto.** Alexander dice "revisa la memoria" (o "lee memory/"). Entonces
> leo este índice y los `.md` que referencie, y los trato como reglas del proyecto. Si no
> lo dice, esta carpeta se ignora. Se escribe aquí cuando termina un milestone, cuando
> se descubre algo que no se deduce del código, o cuando Alexander corrige la forma de
> trabajar. Lo más reciente va arriba.

## ⚡ ÓRDENES CORTAS
- [feedback_prendelo_apagalo.md](feedback_prendelo_apagalo.md) — **"préndelo"** = `tools/local.sh start` · **"apágalo"** = `tools/local.sh stop`. Sin preguntar, respuesta de una línea.

## 🔴 ACTIVO HOY (22 Sep 2026) — Bitrate adaptativo probado y commiteado; el cuello es el panel del pod (~14 fps)
- [session_state_pod_bitrate_22sep.md](session_state_pod_bitrate_22sep.md) — **Empezar aquí.** Commits `d2ee580` y `dd30fd6` en la app. Móvil → pod a 30 fps; el panel del pod compone a ~14 fps en CPU; lag ~2 s estable. Opciones dadas, Alexander no ha decidido. Build con arranque a 4 Mbit/s compilado, sin instalar. **Pod `6lcnlfmmm5osqp` encendido** al cerrar: borrar con `tools/pod.sh down` si sigue.

## (21 Sep 2026, noche) — QR del servidor, pod probado, bitrate adaptativo sin probar
- [session_state_pod_qr_21sep.md](session_state_pod_qr_21sep.md) — **Empezar aquí el 22 Sep.** Pull del rediseño «Zero»; QR en panel y app (commiteado); `tools/pod.sh up` probado (arreglos `--no-preview` y nginx sin commit); por RTMP el vídeo llegaba con minutos de retraso por la subida de 1,5 Mbit/s de la WiFi → bitrate adaptativo escrito e instalado en el iPhone, **sin probar y sin commit**. Pods borrados, saldo $18,59.

## 🔴 (19 Sep 2026) — Dos iPhone reales funcionando contra el Mac
- [project_pod_runpod_19sep.md](project_pod_runpod_19sep.md) — **`tools/pod.sh up | down`** despliega el servidor en un pod RunPod con GPU desde cero (sin volumen no se conserva nada). IA 10 ms en la 4090; RTMP desde los iPhone funciona pero dos a 15 Mbit/s no caben por la WiFi: falta bajar el bitrate de emisión.
- [session_state_dos_iphone_19sep.md](session_state_dos_iphone_19sep.md) — **Empezar aquí.** Reloj común (5-6 ms), emparejado 94-96 %, móvil izquierdo invertido por diseño (`--flip left`), panorámica completa (`PITCH_LIMITS="-45 35" tools/local.sh start dos`) y color igualado en el servidor. Servidor subido al `main` del socio. Sin probar en los móviles: el derecho copia exposición y balance del izquierdo. Falta el `.onnx` del socio para la IA.

## 🔴 (18 Sep 2026, tarde) — Paso 4 escrito: enlace entre móviles y reloj común
- [session_state_paso4_18sep.md](session_state_paso4_18sep.md) — **Empezar aquí el 19 Sep.** Multipeer + reloj verificado entre dos simuladores (ida y vuelta 1 ms, desfase 0,2 ms). Sin commit. Falta la prueba con dos iPhone reales: uno IZQUIERDA, otro DERECHA, y mirar en el derecho Enlace, Reloj y Fase.

## 🔴 ACTIVO HOY (18 Sep 2026) — El servidor corre en el Mac; el pod no arrancó
- [project_servidor_local_18sep.md](project_servidor_local_18sep.md) — **`tools/local.sh start | start clip | stop`** enciende y apaga MediaMTX + panel en el Mac. Qué aguanta el Air M4, qué falta (el `.onnx` lo tiene el socio), por qué RunPod obliga a RTMP y por qué el pod no arrancó, y qué hace falta para TestFlight. RTMP en la app sin commit hasta que Alexander lo pruebe.

## 🔴 ACTIVO HOY (17 Sep 2026, noche) — Pasos 1, 2, 3 y 6 (segmentos y calor) hechos con un iPhone
- [session_state_paso3_17sep.md](session_state_paso3_17sep.md) — **Empezar aquí si retomamos.** Con un solo iPhone ya está todo: cámara, código de tiempo, emisión SRT (29,3 fps, 300/300 legibles por RTSP) y robustez (segmentos tras corte, bitrate por calor). Queda con un iPhone: recorte vertical (A6), README, PROGRESS del servidor y B1c (SRT en el MediaMTX del pod). Con dos iPhone: paso 4 (reloj Multipeer) y 5 (fase).
- Visor en vivo en el Mac para que Alexander vea lo que llega: `uv run python tools/ingest_probe.py view rtsp://127.0.0.1:8554/izquierda --port 8090` en el repo del servidor, con MediaMTX (`tools/banco.sh`) corriendo. Arrancarlo **después** de que el móvil emita, o se queda colgado sin imagen.
- [lesson_banco_mediamtx_17sep.md](lesson_banco_mediamtx_17sep.md) — Tres trampas del banco en el Mac: `srtAddress` tiene que ser `0.0.0.0:8890`; `flutter install` borra los datos de la app (usar `devicectl install`); la API de HaishinKit en `main` no es la de 2.2.5 (leer el checkout local).

## 🎯 REGLA (17 Sep 2026, tarde) — No más "pruebitas" con Alexander
- [feedback_workflow_alexander.md](feedback_workflow_alexander.md) — Se enfadó, con razón: le pedí varias pruebas cortas seguidas y teclear IPs. **Diagnosticar solo desde el Mac todo lo que se pueda, y darle una prueba única cuando esté completa.** Actualizado con lo que quiere ver en pantalla.

## 🔴 (17 Sep 2026, mañana) — Milestone 1 probado en el iPhone, commit `23738d5`
- [session_state_milestone1_17sep.md](session_state_milestone1_17sep.md) — **Empezar aquí si retomamos.** Qué está hecho y probado en el móvil, qué commits hay, qué queda del plan y cuál es el siguiente paso (paso 2: código de tiempo pintado en la imagen).
- [lesson_camera_on_device_17sep.md](lesson_camera_on_device_17sep.md) — Lo que enseñó el iPhone y no se veía en el código: foco al infinito, medir luz y balance antes de congelar, BT.709 sin HDR, y el `markAsFinished` que tira la app. **No revertir ninguno de los cuatro.**

## 🗺️ PLAN — pasos de la app de captura y contrato con el servidor
- [project_plan_app_captura.md](project_plan_app_captura.md) — Los 7 pasos acordados con su criterio de "vale cuando", qué necesita un iPhone y qué necesita dos, y lo que el servidor `football-ai` exige de la app: código de tiempo pintado (formato exacto), MediaMTX solo recibe RTMP hoy, PyAV sin SRT. Un Android no sirve como segunda cámara.

## 🛠️ ENTORNO — este Mac
- [project_environment_mac_17sep.md](project_environment_mac_17sep.md) — Flutter 3.44.8 en `~/flutter_3.44.8` (no está en el PATH; `~/flutter` es de cardiocare y no se toca), comandos para compilar e instalar en el iPhone por WiFi, UDID, cómo añadir un Swift al target con la gema `xcodeproj`, y por qué cmdline-tools es la 22.0.

## 🎯 REGLAS — cómo trabaja Alexander en este repo
- [feedback_workflow_alexander.md](feedback_workflow_alexander.md) — Un milestone cada vez, él prueba en el iPhone, y **solo se hace commit cuando él confirma**. Respuestas cortas. Los logs `FigCaptureSourceRemote err=-17281` son ruido. Las grabaciones van a Archivos → En mi iPhone, no a Fotos.
