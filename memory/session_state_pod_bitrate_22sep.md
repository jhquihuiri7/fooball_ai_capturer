---
name: session-state-pod-bitrate-22sep
description: "Snapshot del 22 Sep 2026: bitrate adaptativo probado contra el pod y commiteado; medidas de fps y lag de punta a punta (el móvil manda 30 fps, el panel del pod compone a ~14 fps en CPU); opciones dadas a Alexander, sin decidir. Pod borrado a mediodía; se vuelve a prender por la tarde."
metadata:
  node_type: memory
  type: project
---

# 22 Sep 2026: bitrate adaptativo probado; el cuello ahora es el panel del pod

## Estado de los repos (todo en `main`, sin push desde el 21 Sep)

- App `fooball_ai_capturer`: `d2ee580` (panel del pod visible desde internet:
  `--no-preview`, claves nginx en /etc/nginx) y `dd30fd6` (bitrate adaptativo +
  arranque a 4 Mbit/s por RTMP + `streamBitrateBps` en el estado). Tests Dart (121) y
  Swift pasan.
- Servidor `fooball_ai_streaming`: `32c4479` (QR en el panel). Nada pendiente.
- **En el iPhone de Alexander está el build de anoche** (adaptativo sí, arranque a
  4 Mbit/s NO). El build con el arranque a 4 está compilado en
  `build/ios/iphoneos/Runner.app`, sin instalar (él dirá cuándo). IPA para TestFlight:
  regenerar (`flutter build ipa --release --build-number 2`), el que existe es viejo.

## Cómo se prueba contra el pod

`tools/pod.sh up` (15-20 min, casi todo subir el modelo por la WiFi) → abre
`http://<ip>:<puerto>` (usuario `panel`, clave en `~/.football-ai/pod.env`) → en la app
«Escanear QR» (tarjeta Cámaras, abajo) → IZQUIERDA → GRABAR. `tools/pod.sh down` al
terminar (pide escribir «borrar»). El pod del 22 Sep es `6lcnlfmmm5osqp`
(81.27.69.179; RTMP 46927, panel 46928): **borrado a mediodía**; Alexander pidió volver a
prenderlo 4-5 h después (`tools/pod.sh up`, dirección nueva).

## Medido el 22 Sep (WiFi de casa de Alexander, subida ~1,5 Mbit/s)

- Adaptativo: arrancó a 15 → cola de 9,6 s en 20 s → el servidor cortó por silencio →
  reconectó con el bitrate ya bajado → **estable 15 min** (cola 0,1-2,5 s, sin cortes).
  Los "2 minutos malos" del principio son eso; de ahí el arranque a 4 Mbit/s.
- **Móvil → pod: 30,7 fps, 2,9 Mbit/s, HEVC 3840x2160.** El móvil manda los 30 fps.
- **El panel del pod compone a ~14 fps** (MJPEG local 13,8 fps; python3 al 480 % de CPU:
  decodificar 4K HEVC en CPU + enderezar + remapear lienzo 2444x1224 + JPEG). La GPU va
  al 4 % (solo la IA, 14-17 ms). Lo que Alexander ve "a 15-20 fps" es esto, no el móvil.
- Vista previa por internet en el Mac: 11 fps, 174 KB/frame, 15,7 Mbit/s de bajada.
- Lag ~2 s: GOP de 2 s + RTMP/TCP (RTT 320 ms) + búfer del emparejador (1 s) + MJPEG.
  No crece (eso era el problema de ayer).

## Opciones dadas (sin decidir, no hacer nada hasta que él elija)

1. Perfilar el panel en el pod (qué etapa come los 70 ms/frame) y optimizar esa: barato.
2. Decodificar y componer en GPU (NVDEC + CuPy): es el §48 del socio, trabajo grande.
3. `--rig-scale` menor (lienzo más pequeño): más fps, menos zoom para la cámara virtual.
4. Que el pod sea de más CPU (12 vCPU hoy; Python con GIL aprovecha ~5).
5. Lag: bajar GOP a 1 s / búfer del emparejador; poco margen, el lag no es el problema.
6. Calidad en la cancha: depende de la subida (Starlink 10-40 Mbit/s); el adaptativo sube
   solo hasta 15. El puente SRT con IP fija (~$5/mes) sigue sobre la mesa.

## Preguntas que hizo y respuestas

- "¿Por qué no mantener la velocidad máxima?": la subida del sitio es el tope físico;
  el bitrate baja pero **los 30 fps se mantienen** (baja la nitidez, no los cuadros). Un
  búfer de 5 s no crea ancho de banda: el déficit se acumula.
