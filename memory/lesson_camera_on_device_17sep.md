---
name: lesson-camera-on-device-17sep
description: "Cuatro cosas que solo se vieron al probar la captura nativa en un iPhone real el 17 Sep 2026: foco, exposición y balance, espacio de color, y un crash del escritor. Ninguna se deduce leyendo AVFoundation."
metadata:
  node_type: memory
  type: project
---

# Lo que enseñó el iPhone (17 Sep 2026) — no revertir

Todo esto está en `ios/Runner/UltraWideCamera.swift` y `CaptureEngine.swift`, commit `23738d5`.

## 1. El foco va al infinito, no "donde esté la lente"

Síntoma: "se ve borroso, no como la cámara del iPhone a 4K".
Causa: `focusMode = .locked` congela la posición actual de la lente. En los Pro la ultra
gran angular enfoca hasta macro; si la app arranca con el móvil en la mesa, se queda a
dos centímetros. Fix: `setFocusModeLocked(lensPosition: 1.0)`. A 13 mm todo lo que está
a más de un metro es nítido en el infinito.

## 2. Exposición y balance: medir primero, congelar después

Síntoma: "se ve saturado, el color no es como la cámara del iPhone".
Causas: ISO 200 a 1/100 fijos a ciegas (negro en interior, quemado al sol) y balance
congelado antes de que llegara el primer frame (color arbitrario).
Fix: `.continuousAutoExposure` y `.continuousAutoWhiteBalance` durante la medición,
`waitForMetering` (mínimo 7 sondeos de 100 ms, máximo 30), y después
`lockExposureAndWhiteBalance`: misma luz total (ISO × tiempo) llevada a la obturación sin
parpadeo (1/100 a 50 Hz). Si sobra luz al ISO mínimo se acorta la obturación (de día no
hay parpadeo); si falta al ISO máximo se abre a 1/50. Las ganancias de balance se acotan
a `[1, maxWhiteBalanceGain]` porque fuera de rango es una excepción, no un recorte.
La pantalla enseña obturación, ISO y kelvin para comparar los dos móviles.

## 3. BT.709 forzado y HDR de sensor apagado

`session.automaticallyConfiguresCaptureDeviceForWideColor = false` y
`activeColorSpace = .sRGB`; `isVideoHDREnabled = false` cuando el formato lo admite.
Sin esto, la sesión elige P3 en unos formatos y no en otros, y el HDR aplica una curva
que cambia frame a frame y distinta en cada móvil: se vería en la costura.

## 4. `markAsFinished` sobre un escritor sin empezar tira la app

Síntoma: "se trabó la app" con `NSInternalInconsistencyException ... markAsFinished
Cannot call method when status is 0`. Pasa si PARAR llega antes del primer frame (dos
toques seguidos). No es un error capturable. Fix: `closeWriter()` termina solo si
`status == .writing` y hubo frames; si no, `cancelWriting()`. Y `toggleRecording` en
Dart ignora toques mientras hay uno en curso. Si `startWriting()` falla se suelta el
escritor y queda en el log.

## Ruido que no es error

`<<<< FigCaptureSourceRemote >>>> ... err=-17281` aparece una vez por ajuste aplicado.
`FigApplicationStateMonitor err=-19431` y `AppleProResHW ... failed` también son ruido.
