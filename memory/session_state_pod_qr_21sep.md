---
name: session-state-pod-qr-21sep
description: "Snapshot del 21 Sep 2026 (noche): pull del rediseño «Zero» del socio, QR del servidor en el panel y en la app, pod desplegado con tools/pod.sh y probado con un iPhone por RTMP, y bitrate adaptativo escrito e instalado pero SIN probar. Qué probar el 22 Sep."
metadata:
  node_type: memory
  type: project
---

# 21 Sep 2026: QR, pod probado y bitrate adaptativo (sin probar)

## Hecho y probado

- **Pull de los dos repos.** App: rediseño «Zero» del socio (pestañas Captura y Partido,
  118 tests). Servidor: 50 commits (cámara virtual `--director`, repeticiones, panel
  nuevo, `deploy/runpod.sh` propio del socio que usa canales `/left` `/right` y sin
  `--flip`: no encaja con la app; se sigue usando `tools/pod.sh`).
- **QR con la dirección del servidor.** Panel: tarjeta «Cámaras» abajo, lee
  `FOOTBALL_CAMERA_URL` (commit `32c4479` en streaming). App: botón «Escanear QR» junto a
  «Servidor» (commit `53f58b7`). Probado en local con el iPhone: rellena y guarda.
- **Pod con `tools/pod.sh up`**: probado dos veces. Con `--no-preview` en
  `tools/pod/servicios.sh` (si no, la página del panel intenta WebRTC por el 8889, que
  no sale a internet, y se ve el icono roto). Claves de nginx en `/etc/nginx` (los
  workers no leen `/root`). Ambos arreglos en el árbol de trabajo SIN commit.
- **RTMP desde el iPhone al pod funciona**, pero por la WiFi de casa de Alexander la
  subida es **~1,5 Mbit/s** (medido con scp) y el móvil codifica 15: el vídeo se acumula
  en el móvil y llega con minutos de retraso («+N de cola» en rojo en el panel). No es el
  pod (acepta 6 Gbit/s); es la subida del sitio.

## Escrito e instalado en el iPhone de Alexander, SIN probar

**Bitrate adaptativo** (`AdaptiveBitRate` en `ios/Runner/StreamPublisher.swift`): usa el
`NetworkMonitor` de HaishinKit; con la cola del socket creciendo tres segundos baja al 80 %
de lo que salió (mínimo 1 Mbit/s); sube un décimo del techo cada 15 s sin cola; el calor
sigue mandando el techo. `CaptureStatus.streamBitrateBps` nuevo (Pigeon regenerado); la
fila Emisión enseña el bitrate real y «bajado: la red no traga más». Tests Dart y Swift
pasan. Sin commit.

**Prueba pendiente (22 Sep):** `tools/pod.sh up` (unos 20 min por la subida del modelo),
en el iPhone escanear el QR del panel del pod, GRABAR, y ver que Emisión baja de 15 a
~1-2 Mbit/s y que «de cola» en el panel deja de crecer. Después IPA (build 2 ya existe
como `build/ios/ipa/Zero.ipa` pero SIN el escáner ni el adaptativo: regenerar).

## Pendientes

- Commit de: `tools/pod/servicios.sh` + `nginx-panel.conf`, bitrate adaptativo (app).
- Reunión con socios: crear el pod 1-2 h antes y dejarlo encendido; el Mac local de respaldo.
- Investigado RunPod: disco de red ($0,07/GB/mes) evita reinstalar; RunPod no da IP fija
  ni UDP → para dirección fija: puente con IP fija (~$5/mes, SRT) o «dirección de
  encuentro». Alexander quiere primero el QR (hecho); lo demás por decidir.
- El izquierdo aún no le pasa el servidor al derecho por el enlace (idea pendiente).
- El Mac salta a otra WiFi con más señal; hay que «olvidar» esa red en Ajustes.
