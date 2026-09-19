---
name: project-pod-runpod-19sep
description: "Cómo se despliega el servidor en RunPod (tools/pod.sh), por qué hay que redesplegar cada vez, qué se midió el 19 Sep 2026 (IA 10 ms en GPU; RTMP de dos iPhone a 15 Mbit/s no cabe por la WiFi) y qué bloquea el entorno de Claude."
metadata:
  node_type: memory
  type: project
---

# El servidor en RunPod (19 Sep 2026)

## Un comando

`tools/pod.sh up | status | info | ssh | down`. `up` crea **un** pod RTX 4090 (~$0,74/h),
sube el árbol de trabajo del repo del servidor + `rfdetr-small.onnx` + `soporte.json`,
instala (`uv sync --group gpu --locked`, MediaMTX, nginx) y arranca `tools/pod/servicios.sh`.
Si el pod apuntado en `~/.football-ai/pod.json` sigue existiendo lo **reutiliza**: nunca
crea un segundo. `down` lo borra (pide escribir «borrar»).

- Móviles: `rtmp://rig:<clave>@<ip>:<puerto>` en «Servidor» (RunPod no deja pasar UDP → no SRT).
- Panel público: `http://<ip>:<puerto>` con usuario `panel` (nginx con clave delante del
  panel, que sigue escuchando solo en 127.0.0.1).
- Claves estables entre despliegues en `~/.football-ai/pod.env` (fuera del repo). IP y
  puertos cambian con cada pod.
- YouTube desde el pod: `FBAI_YOUTUBE_KEY=… tools/pod.sh up`.

## Por qué no se conserva nada

Los pods se crean **sin volumen**: RunPod borra el disco del contenedor al pararlos. Además
un pod parado queda atado a su máquina y, si otro cliente alquila esa GPU, no vuelve a
arrancar («not enough free GPUs on the host»; le pasó al pod viejo `vj94apvs9wv6wx`, que solo
pudo arrancar como «transfer pod»: sin GPU, medio núcleo, 5 GB). Alternativa no montada: un
disco de red (~$0,07/GB/mes) no atado a una máquina.

## Medido

- IA en la 4090: **10-12 ms** por inferencia (en el Air M4, ~2000 ms con todo encendido).
- **RTMP desde los iPhone funciona** (HEVC por enhanced RTMP contra MediaMTX 1.21) y un
  móvil que entra desplaza solo al relleno negro del canal.
- **Pero dos móviles a 15 Mbit/s no caben** por la WiFi de la prueba hasta EE. UU.: cortes
  cada pocos minutos, la derecha a ~3 fps, 1 % de parejas. Falta un bitrate de emisión
  más bajo para RTMP en la app (hoy fijo en `capture_session.dart`, 15 Mbit/s).
- El panel no arranca si falta una cámara → `servicios.sh` publica un relleno negro por
  canal, una sola vez (relanzado desplazaría él al móvil).
- La imagen de RunPod ya trae un nginx propio que no incluye `sites-enabled`: se lanza una
  instancia aparte con `nginx -c`.

## Lo que el entorno de Claude no deja hacer

Bloqueado por el clasificador: abrir un servicio **sin clave** a la red (en el Mac o en el
pod) y parar un pod que Alexander no pidió parar. Con clave delante sí pasa. No insistir:
explicarlo y ofrecer la versión con clave.
