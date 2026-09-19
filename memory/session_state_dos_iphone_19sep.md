---
name: session-state-dos-iphone-19sep
description: "Snapshot del 19 Sep 2026: primera prueba con dos iPhone reales contra el servidor en el Mac. Reloj común, emparejado, cámara invertida, panorámica completa y color igualado funcionan; la app copia exposición y balance del maestro pero eso aún no se probó en los móviles."
metadata:
  node_type: memory
  type: project
---

# Dos iPhone reales, de punta a punta (19 Sep 2026)

## Qué se probó y vale

- **Reloj común entre los dos iPhone** (Multipeer): frames vecinos a 5-6 ms. Segundo
  iPhone sin modo desarrollador, instalado por **TestFlight** (equipo `5AKXUHD733` =
  LOGICIELAPPLAB S.A.S., de pago; IPA 1.0.0 build 1).
- **Servidor en el Mac con dos cámaras**: `PITCH_LIMITS="-45 35" tools/local.sh start dos`.
  Calibración desde el panel (`POST /api/action {"action":"rig_calibrate"}`): 85/127
  puntos, residuo 0,068°, guardada en `~/Movies/football-ai/soporte.json`.
- **El móvil izquierdo va montado cabeza abajo por diseño del soporte.** El panel lo
  endereza (`--flip left`, por defecto en `local.sh`; `FLIP=right` o `FLIP=` si cambia).
- **Emparejado 94-96 %**: por red el derecho llegaba ~570 ms antes; el panel guarda 30
  frames por cámara (con 3 daba 14 %).
- **Color**: cada móvil mide la luz por su cuenta y las mitades salían distintas. El
  servidor iguala en el solape cada 2 s (`rig.color_gains` en `/api/state`). También tapa
  el código de tiempo, que se veía en mitad de la costura.
- **Desfase con objetos cerca = paralaje** entre lentes. Es físico; a distancia de cancha
  no se nota. No perseguirlo.

## Repo del servidor (socio nos dio libertad para modificarlo)

Subido a **`main`** de `jhquihuiri7/fooball_ai_streaming` el 19 Sep: `26891ef` (hilos
lectores) y `2b46bfa` (color, flip, zonas ciegas, pitch limits). Rama
`alexander/dos-camaras-y-camara-virtual` = `main`.

## Escrito y SIN probar en los móviles

- **El derecho copia exposición y balance del izquierdo por el enlace** (`CameraLook`,
  mensajes `lookRequest`/`look` en `RigLink`, ISO corregido por apertura). Tests nativos
  pasan en simulador. Hace falta instalarlo en **los dos** iPhone: el de Alexander por
  cable y el otro con IPA nuevo (`--build-number 2`). Una app vieja ignora el mensaje.

## Qué falta

- **IA**: `models/onnx/` está vacío en este Mac. Pedir al socio `rfdetr-small.onnx` (5
  clases: balón, arquero, jugador, árbitro, sin usar; un modelo público no sirve, el
  detector valida las 5). `local.sh` lo pasa solo con `--model` si el archivo está.
- Zoom automático / cámara virtual y seguimiento de pelota: no existen en ningún repo
  (el «AUTO» del panel es una etiqueta).
- App: grabar ya derecho el vídeo del móvil invertido (hoy solo lo endereza el panel).
- RTMP sin probar en el móvil; pod de RunPod sin arrancar (no crear pods).

## Lección de la sesión

Alexander estaba probando en vivo y **paró** una corrida larga de comprobaciones y
papeleo en mitad de la prueba. Mientras prueba: cambios cortos, reiniciar solo el Python
del panel (`kill <pid>`; el bucle de `local.sh` lo relanza) y dejar commits y suites
completas para cuando los pida. Un fallo mío tumbó el panel un minuto: construir el
cosedor antes de `start()` no puede leer `feed.spec` (usar las intrínsecas del soporte).
