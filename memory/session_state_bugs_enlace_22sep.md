---
name: session-state-bugs-enlace-22sep
description: "Snapshot del 22 Sep 2026 (noche): 4 bugs reportados por Alexander sobre el enlace entre los dos iPhone y el boton Calibrar, ya diagnosticados pero SIN corregir; arreglos del despliegue del socio (canales, QR, video de prueba) ya en main. Empezar aqui el 23 Sep."
metadata:
  node_type: memory
  type: project
---

# 22 Sep 2026 (noche): 4 bugs del enlace, diagnosticados y sin tocar

**Alexander pidió expresamente identificarlos antes de corregir nada. No se ha cambiado
una línea por ellos.** El 23 Sep se empieza proponiéndole los arreglos.

## Los 4 bugs y su causa (todo en `ios/Runner/RigLink.swift` salvo el 4)

1. **No se parean: nunca se cose la imagen.** Sin confirmar del todo. Si el enlace no
   conecta (bugs 2 y 3), el derecho se queda sin reloj común, cada móvil pinta su propia
   hora y el servidor no encuentra parejas. **Falta que Alexander diga si la fila Enlace
   llegó a decir «conectado con…» y si la fila Reloj del derecho dio un número.**
2. **Al invertir los lados se cruzan los roles; hay que reiniciar la app.** El `MCPeerID`
   se construye con el nombre del móvil **más el lado** (`iPhone A (izquierda)`), así que
   cambiar de rol fabrica una identidad nueva para el mismo teléfono y el otro conserva la
   vieja en caché. Apple pide que ese id sea estable. Se suma que `CaptureSession.dispose`
   solo llama a `stopLink()` si `linkState != off` (y ese estado llega por un aviso que
   puede no haber llegado), y que `session.disconnect()` es asíncrono mientras el enlace
   nuevo ya arrancó.
3. **Hay que prender los dos casi a la vez.** `invitePeer` se llama **una sola vez**, en
   `browser(_:foundPeer:)`, con `inviteTimeout` de 10 s. Si caduca, nadie reintenta: iOS
   no vuelve a avisar de un peer ya descubierto y `lostPeer` está vacío. Si el izquierdo
   lleva rato con la pantalla apagada, iOS le suspende el anuncio. Tampoco hay nada que
   reanude el enlace al volver del segundo plano (no hay observadores de ciclo de vida).
4. **El botón «Calibrar soporte» no da señal de nada.** No se deshabilita ni dice
   «calibrando…»; el resultado (éxito o fallo) sale solo como texto pequeño al final de la
   tarjeta Soporte. Con una sola cámara no hace nada y no avisa. Lo más probable es que en
   el pod sí se pulsara y fallara por el bug 1 («no hay todavía una pareja completa»).

## Lo que sí se arregló hoy (todo en `main` y subido)

Servidor: `583fba7` (el despliegue del socio leía `left`/`right` en vez de los canales del
contrato, no pasaba `FOOTBALL_CAMERA_URL` para el QR ni `--flip`), `bf94581` (el vídeo de
prueba seguía publicando en los canales viejos: eso rompió a Jhonatan la opción de probar
sin cámaras) y `29561d2` (la tabla del README daba los canales viejos).
App: `bd8765d` (`tools/local.sh` arranca con `--videos`, `--clips` y `--replay-buffer`).

**Con vídeo de prueba hay que apagar el enderezado**: `FOOTBALL_FLIP=` en el pod,
`FLIP=` en local. Un vídeo no viene girado y `--flip left` lo pondría del revés.

## Reglas que Alexander recordó hoy

Commits **directo a `main`** y subidos en el momento; nada de ramas (se borró la rama
vieja `alexander/dos-camaras-y-camara-virtual`, ya fusionada). Ver [[no-crear-ramas]] y
[[commit-incluye-push]].

## Estado al cerrar

Sin pods (saldo $14,30). Servidor local **encendido** con dos cámaras, IA y cámara
virtual. Excel de tickets en `~/Trabajacion/football-ai-tickets.xlsx` con 6 tickets: lo
lleva él, **no editarlo**.
