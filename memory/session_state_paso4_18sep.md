---
name: session-state-paso4-18sep
description: "Snapshot del 18 Sep 2026 por la tarde: paso 4 (enlace Multipeer entre los dos iPhone y reloj común) escrito y verificado entre dos simuladores; falta la prueba con dos iPhone reales, prevista para el 19 Sep."
metadata:
  node_type: memory
  type: project
---

# Paso 4: enlace entre móviles y reloj común (18 Sep 2026)

## Qué hay escrito

- `ios/Runner/RigLink.swift`: Multipeer Connectivity, servicio `footballai-rig`. El
  **izquierdo se anuncia y es el maestro**; el derecho lo busca, lo invita y le pregunta la
  hora: ráfaga de 10 preguntas cada 250 ms al conectar, luego una cada 5 s, por el canal
  no fiable. Los cuatro sellos se toman en nativo con `CMClockGetHostTimeClock` (el reloj
  de los frames). `RigMessage` es binario big-endian: ping 13 bytes, pong 29.
- Contrato: `LinkState`, `startLink`/`stopLink`, `masterRecentPtsNs` (asíncrono),
  `onLinkStateChanged`, `onClockStamps`.
- `CaptureSession`: el izquierdo pasa a `lista` sin esperar a nadie (media cancha es mejor
  que ninguna); el derecho espera reloj y, en cuanto lo tiene, **mide la fase contra el
  maestro y se reinicia solo** (`phaseSettleDelay` 1,2 s entre medidas; si el maestro no
  contesta, graba con la fase «sin medir»). Fila «Enlace entre móviles» en pantalla.
- `LocalNetworkAccess` usa ahora `_footballai-lan._tcp`: con el tipo del enlace, el
  derecho veía el anuncio de la comprobación de permiso como si fuera el izquierdo.
- Banco de pruebas sin tocar la pantalla: `--dart-define=AUTO_ROLE=left|right` y
  `--dart-define=LINK_ONLY=true` (solo el enlace, sin cámara).

## Verificado

- 75 tests de Dart y 12 nativos (incluye ida y vuelta de `RigMessage`).
- **Dos simuladores en el Mac**: se encuentran, se conectan en 0,1 s y el derecho mide
  ida y vuelta de ~1 ms y desfase de 0,1–0,3 ms (el real es 0: comparten el reloj del
  Mac). Script de la prueba: compilar con `flutter build ios --config-only --debug
  --simulator --dart-define=…` y después `xcodebuild build -sdk iphonesimulator`.
- Trampa: `flutter build ios --simulator` **no enlaza libsrt** (símbolos `_srt_*` sin
  definir); `xcodebuild` sí. No afecta al build de dispositivo. Y los `print` de Dart no
  salen por `simctl launch --console-pty`: para ver algo desde fuera, `NSLog`.

## Falta (19 Sep, con el segundo iPhone)

1. Instalar la app en el segundo iPhone (`devicectl device install app`).
2. Uno IZQUIERDA, otro DERECHA. En el derecho, sin tocar nada: Enlace «conectado con…»,
   Reloj «x ms ±y», Fase «n ms», estado `lista`. Entonces GRABAR en los dos.
3. Comprobar con el lector del servidor que los códigos de tiempo de los dos archivos
   difieren menos de 16 ms filmando lo mismo.
4. Sin commit todavía: Alexander decide si commitea ya como «verificado en simuladores» o
   tras la prueba real. La app instalada en su iPhone ya lleva este código.

Ideas apuntadas, sin hacer: emparejar por QR como Veo Go; que GRABAR en el izquierdo
arranque también el derecho; avisar si Acceso Guiado no está activo.
