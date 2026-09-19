---
name: project-servidor-local-18sep
description: "Cómo encender y apagar el servidor football-ai entero en el Mac de Alexander (18 Sep 2026): script tools/local.sh, qué aguanta el MacBook Air M4, qué falta (modelo .onnx) y por qué el pod de RunPod no arrancó."
metadata:
  node_type: memory
  type: project
---

# El servidor en local, en el Mac (18 Sep 2026)

## Encender y apagar

```bash
cd ~/Trabajacion/fooball_ai_capturer
tools/local.sh start        # MediaMTX + anuncio Bonjour + panel; espera al iPhone
tools/local.sh start clip   # igual, con ~/Movies/football-ai/iphone-izquierda.mov de iPhone falso
tools/local.sh status
tools/local.sh stop         # SIEMPRE al terminar: el panel ocupa ~3 núcleos
```

Panel en `http://127.0.0.1:8090`. El clip se reenvía con `ffmpeg -c copy` (HEVC 4K con su
código de tiempo, sin recodificar) a `rig/izquierda`, el mismo canal del móvil; por eso
solo puede publicar uno a la vez. No usar `--test-video` del panel: recodifica a 4K con
x264 y en el Air es mucho trabajo inútil.

## Qué aguanta este Mac (MacBook Air M4, 10 núcleos, 16 GB)

Todo con una cámara menos la detección rápida: MediaMTX, decodificar 4K a 30 fps, panel
con marcador y vista previa WebRTC, y emitir (ya está `ffmpeg` con x264 por brew). La
detección iría por CPU (`ort.py` solo conoce CUDA y CPU, no CoreML). Alexander compila
otros proyectos a la vez y el Air se calienta: apagar el servidor cuando no se usa.

## Qué falta

- **`models/onnx/` está vacío** en la copia del servidor de este Mac. El `.onnx` de
  jugadores lo tiene el socio (lo copiaba al pod a mano). Sin él no hay detección.
- El modelo del balón no existe. El panel de dos cámaras (B1b) empareja mal.

## RunPod (pod `vj94apvs9wv6wx`, RTX 4090, 0,74 $/h, saldo 24 $)

- **No admite UDP**: SRT no entra. Por eso la app emite también por RTMP (selector en la
  pantalla de lado; canal `rig/izquierda` en los dos protocolos). Sin commit hasta que
  Alexander lo pruebe una vez.
- Tiene **0 GB de volumen**: no guarda nada entre encendidos; hay que desplegar cada vez.
- Le añadí `1935/tcp` a sus puertos (`runpodctl pod update --ports`). **No arrancó** tres
  veces: "not enough free GPUs on the host machine" (la 4090 de su máquina la tenía otro
  cliente). Alexander no quiere que se creen pods nuevos: solo encender ese, con su permiso.

## TestFlight

**Corrección (18 Sep, tarde):** el proyecto firma con `5AKXUHD733`, que es **LOGICIELAPPLAB
S.A.S.**, la empresa de Alexander: equipo de pago que ya publica las apps de miwego. No es
un equipo gratuito, como anoté antes por error. No hay que cambiar de equipo.

- `flutter build ipa --release` funciona: deja `build/ios/ipa/football_ai_capture.ipa`
  firmado para App Store Connect (firma gestionada en la nube, sin certificado de
  distribución local de ese equipo). Se sube con **Transporter** o Xcode; lo hace él.
- Añadidos para que Apple lo acepte: `ITSAppUsesNonExemptEncryption = false` en Info.plist
  y `ios/Runner/PrivacyInfo.xcprivacy` (UserDefaults y espacio en disco).
- Avisos que no bloquean: icono y pantalla de arranque son los de la plantilla de Flutter.
- Cada subida necesita un número de build nuevo: `--build-number 2`, etc.
- **Probadores internos** (usuarios del equipo en App Store Connect): disponibles a los
  minutos. **Externos**: revisión de Apple de ~1 día, no llega para el día siguiente.
- TestFlight reparte la app, pero no hace que otro iPhone llegue al servidor: para eso,
  misma WiFi que el Mac, el pod, o Tailscale.
