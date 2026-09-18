---
name: feedback-prendelo-apagalo
description: "Órdenes cortas de Alexander para el servidor local en su Mac: 'préndelo' y 'apágalo'."
metadata:
  node_type: memory
  type: feedback
---

# "Préndelo" y "apágalo"

- **"Préndelo"** → `tools/local.sh start` (en `~/Trabajacion/fooball_ai_capturer`). Espera al iPhone; el navegador se abre solo cuando llega la imagen.
- **"Préndelo con el clip"** → `tools/local.sh start clip` (sin móvil; gasta unos 3 núcleos).
- **"Apágalo"** → `tools/local.sh stop`. Confirmar con `tools/local.sh status`.

Hacerlo sin preguntar y contestar en una línea. Si su Mac está caliente o compilando otra
cosa, recordarle apagarlo al terminar.

**Solo el servidor local del Mac.** "Préndelo" nunca enciende el pod de RunPod (cuesta dinero): ese solo con una orden expresa de Alexander, y sin crear pods nuevos.
