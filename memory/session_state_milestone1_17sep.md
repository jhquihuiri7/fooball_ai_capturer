---
name: session-state-milestone1-17sep
description: "Snapshot del 17 Sep 2026: milestone 1 de la app de captura probado en un iPhone real (cámara sola, vista previa, grabación local con luz y foco medidos). Commits, qué queda y siguiente paso."
metadata:
  node_type: memory
  type: project
---

# Estado al 17 Sep 2026 — Milestone 1 en el iPhone

## Commits de hoy (rama `main`)

| Commit | Qué |
|---|---|
| `aaf0098` | Paso 0. Los cuatro Swift de la TASK A2 no estaban en el target de Xcode (se escribieron en Windows) y dos nombres no coincidían con Flutter 3.44 / Pigeon 29. Primera compilación en Xcode 26.6. |
| `23738d5` | Paso 1. La cámara arranca sola, se ve en pantalla, graba en local con luz y foco medidos. Probado por Alexander en su iPhone. 54 tests, `flutter analyze` limpio. |

Sin commit: `.vscode/settings.json` (apunta al SDK 3.44.8; Alexander no decidió si se versiona) y esta carpeta `memory/`.

## Qué hace la app hoy, probado en el móvil

- Pantalla de lado con interruptor **"Un solo móvil, sin reloj"**. Encendido, la sesión salta reloj y fase y habilita GRABAR; la cabecera y la fila Modo lo marcan en naranja. Es solo para probar: lo grabado así no parea con el otro móvil.
- Al entrar: pide permiso de cámara (`requestCameraAccess`, asíncrono en el contrato Pigeon), abre la ultra gran angular a 3840×2160 a 30 fps, mide luz y balance en automático (0,7 a 3 s) y los congela. `configure` es asíncrono por eso.
- Vista previa nativa (`CapturePreview.swift`, vista de plataforma `capture-preview` sobre la misma sesión) arriba; debajo el cartel GRABANDO con cronómetro y nombre de archivo; debajo el botón; debajo la información.
- Graba HEVC a 45 Mbit/s en `Documents` (visible en Archivos → En mi iPhone → Football Ai Capture, y en Finder). `start` devuelve la ruta.
- Los avisos del nativo (interrupción, reanudación, térmico) llegan a Dart; el estado se refresca cada segundo.
- **No emite nada.** La fila "Emisión" lo dice. Eso es el paso 3.

## Qué queda (ver `project_plan_app_captura.md`)

1. **Paso 2**: pintar el código de tiempo del soporte en cada frame (formato del servidor, `timecode.py`). Sin esto el servidor no empareja.
2. **Paso 3**: emitir a MediaMTX con HaishinKit.
3. **Paso 4+**: Multipeer y reloj (hacen falta dos iPhone), fase, robustez.

## Siguiente paso concreto

Paso 2. Escribir las 64 celdas en el plano de luma del `CVPixelBuffer` antes de que el frame vaya al escritor, fijando el formato de píxel 4:2:0 biplanar en `AVCaptureVideoDataOutput`. XCTest del CRC en `RunnerTests` (hoy vacío). Verificar con el lector del servidor sobre un `.mov` grabado.
