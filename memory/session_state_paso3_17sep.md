---
name: session-state-paso3-17sep
description: "Snapshot del 17 Sep 2026 por la tarde: paso 2 (código de tiempo) commiteado; paso 3 (emisión SRT con HaishinKit) escrito, instalado en el iPhone y pendiente de la prueba final contra el MediaMTX del Mac."
metadata:
  node_type: memory
  type: project
---

# Estado del paso 3 (17 Sep 2026, tarde)

## Commits

| Commit | Qué |
|---|---|
| `325b5ea` | Paso 2. Código de tiempo pintado en cada frame, verificado con el lector del servidor sobre un clip real: 422/422 frames. |

**Sin commit** (árbol de trabajo): todo el paso 3. Se commitea cuando el stream del iPhone
llegue a MediaMTX y el lector RTSP lea el código de tiempo.

## Qué hay escrito para el paso 3

- `ios/Runner/StreamPublisher.swift`: HaishinKit 2.2.5 (`SessionBuilderFactory` →
  `Session` → `stream.append`), HEVC 4K a `bitrateBps` (15 Mbit/s) con `dataRateLimits`
  por segundo, sin B-frames, cola de 2 frames que descarta, reconexión cada 3 s,
  `setExpectedMedias([.video])` para que el muxer TS no espere audio.
- HaishinKit + SRTHaishinKit como paquetes Swift en el pbxproj (añadidos con la gema
  `xcodeproj`, `exactVersion 2.2.5`). Obligó a subir el iOS mínimo a **15.0**
  (pbxproj y `AppFrameworkInfo.plist`).
- Contrato: `StreamState`, `streamDetail`, `streamDroppedFrames`; `loadServerHost` /
  `saveServerHost` (UserDefaults); `discoverServer` (Bonjour `_footballai-srt._tcp`);
  `requestLocalNetworkAccess` (NWListener + NWBrowser sobre `_footballai-rig._tcp`).
- Pantalla de lado: campo "Servidor" que se rellena solo con lo descubierto si está
  vacío, con lupa para volver a buscar. La URL es
  `srt://HOST:8890?streamid=publish:izquierda|derecha&latency=1000`.
- Pantalla de captura: filas "Red local" y "Emisión" (EMITIENDO / RECONECTANDO · motivo).
- `tools/mediamtx-banco.yml` + `tools/banco.sh`: MediaMTX en el Mac anunciado por Bonjour.

## RESULTADO (17 Sep 2026, 16:57): el paso 3 vale

Lectura del RTSP de MediaMTX con el lector del servidor mientras el iPhone emitía:
HEVC 3840×2160, 300 frames en 10,2 s (29,3 fps), **300/300 con código de tiempo legible**,
33 ms entre frames, sin retrocesos. Commit del paso 3 hecho justo después (ver `git log`).

## Lo verificado y lo que no

- ✅ Desde el Mac, `srt-live-transmit` publica en el MediaMTX del banco por loopback y
  por la IP WiFi (tras fijar `srtAddress: 0.0.0.0:8890`).
- ✅ El permiso de red local del iPhone está concedido (el log `[red local] servicios
  vistos: 1` lo demuestra). No sale aviso porque ya estaba dado.
- ✅ El iPhone intenta conectar (logs `[stream] emitiendo a srt://10.10.18.100:8890…`);
  fallaba por `timeout` **por culpa del banco (IPv6)**, no de la app.
- ⬜ **Pendiente**: la prueba con el banco corregido. Hay un vigilante que analiza el
  RTSP en cuanto MediaMTX vea al iPhone (`scratchpad/clips/rtsp_timecode.py`).
- ⬜ Confirmar en el log de MediaMTX que el track es **H265** (HaishinKit elige el
  códec por `profileLevel`; si sale H264 hay que mirar `VideoCodecSettings.format`).

## Siguiente

1. Prueba única de Alexander: abrir, IZQUIERDA, GRABAR. El Mac hace el resto.
2. Si llega: commit `feat(ios): emisión SRT al servidor con HaishinKit (TASK A5)` y
   actualizar el plan. Después, pasos 4+ (dos iPhone).
3. Registrar HaishinKit (BSD-3) en un `DEPENDENCIES.md` de la app.

## Paso 6 (17 Sep, 18:00): segmentos tras corte y bitrate por calor — hecho y probado

Commit `feat(ios): grabar en un segmento nuevo tras un corte y bajar el bitrate por calor`.
Prueba de Alexander: salir de la app dos veces grabando y emitiendo → tres archivos
(`left-…mov`, `-2.mov`, `-3.mov`) y la emisión siguió por el mismo enlace SRT (la
conexión no cayó; solo pararon los frames). La primera reanudación tarda 2–3 s: iOS
devuelve la cámara y hay que esperar al siguiente frame clave. El bitrate por calor
solo tiene test unitario (no se puede provocar en el banco).

