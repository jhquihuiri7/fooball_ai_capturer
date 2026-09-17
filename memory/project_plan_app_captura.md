---
name: project-plan-app-captura
description: "Plan de 7 pasos de la app de captura (acordado el 17 Sep 2026) con el criterio de prueba de cada uno, y lo que el servidor football-ai exige de la app: código de tiempo pintado, RTMP a MediaMTX, sin SRT en PyAV."
metadata:
  node_type: memory
  type: project
---

# Plan de la app de captura y contrato con el servidor

Cada paso es un commit y termina con una prueba que Alexander hace en el iPhone.
Pasos 1 a 3 con un iPhone y el Mac; desde el 4 hacen falta los dos iPhone.

| Paso | Qué | Vale cuando | Estado |
|---|---|---|---|
| 0 | Compilar en Xcode | `flutter build ios --no-codesign` pasa | ✅ `aaf0098` |
| 1 | Cámara sola, vista previa, grabación local | 4K 30 fps, ajustes bloqueados, archivo HEVC en Archivos | ✅ `23738d5` |
| 2 | Código de tiempo pintado en cada frame | El lector del servidor (`read_timecode_ms`) lee más del 90 % de los frames de un `.mov` | ✅ `325b5ea` (422/422) |
| 3 | Emisión a MediaMTX (HaishinKit, bitrate fijo) | Por RTSP llegan 30 fps en 4K con el código de tiempo legible; el archivo local sigue entero | ✅ 17 Sep (29,3 fps, 300/300 legibles) |
| 4 | Multipeer y reloj común (A3) | Incertidumbre < 5 ms; dos móviles filmando un cronómetro difieren < 16 ms | ⬜ **siguiente**, dos iPhone |
| 5 | Fase de exposición (A4) | Fase ≤ 5 ms con reintentos visibles | ⬜ |
| 6 | Robustez: segmento tras interrupción, bitrate térmico, recorte vertical | FaceTime en medio → segundo archivo y stream de vuelta | ⬜ |
| 7 | Campo y docs: firma para dos iPhone, Acceso Guiado, README, `DEPENDENCIES.md`, PROGRESS del servidor | — | ⬜ |

## Lo que el servidor exige (repo `fooball_ai_streaming`, léase `docs/PROGRESS.md` línea 48)

- **El tiempo del soporte viaja pintado en la imagen, no en el PTS** (enmienda B1a del ADR
  0012, 2026-09-17). MediaMTX y RTSP reescriben los PTS. Formato en
  `libs/vision/source/timecode.py`: 64 celdas cuadradas en una fila desde el píxel (0,0),
  lado `round(ancho/240)` mínimo 4 (16 px en 4K), luma 235 = 1 y 16 = 0 en el plano Y,
  bits: preámbulo `0xB2`, 48 bits de milisegundos big-endian, CRC-8/SMBUS (polinomio
  `0x07`, inicial 0). Comprobación: CRC de `"123456789"` = `0xF4`. **Va también en la
  grabación local.** Si cambia, cambia en los dos repos a la vez.
- **Transporte hoy: RTMP a MediaMTX** (`tools/mediamtx-ingest.yml`, puerto 1935, path por
  cámara, reexpuesto por RTSP en 8554). `srt: no` en esa config y la rueda de PyAV no
  lee SRT directo; SRT solo vale entrando por MediaMTX (tarea B1c del servidor, pendiente).
- El panel de dos cámaras (`tools/rig_panel.py`, tarea B1b) está sin commit y falla de
  punta a punta (2 % de parejas). No depende de la app.
- No existe el modelo del balón; el directo detecta jugadores.

## Decisiones ya tomadas

- Un **Android no sirve** como segunda cámara: la capa nativa es Swift/AVFoundation y el
  enlace es Multipeer (solo Apple). Como mucho, para probar que MediaMTX recibe dos
  streams, sin código de tiempo.
- Los ajustes de cámara **no son configurables por el usuario**: fijos e iguales en los
  dos móviles (ADR 0012). Se enseñan, no se eligen.
- El modo "un solo móvil" existe solo para probar en el banco.
