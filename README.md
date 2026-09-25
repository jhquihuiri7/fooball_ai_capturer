# football-ai-capture

La app que convierte dos iPhone en la cámara del sistema `football-ai`. Cada móvil cubre
media cancha, los dos se sincronizan entre ellos, graban en local y emiten por SRT al
servidor, que los alinea y los cose.

**La decisión que gobierna este repo vive en el otro**:
`football-ai/docs/DECISIONS/0012-dos-iphone-como-camara.md`. Aquí no se decide
arquitectura; aquí se implementa la parte que corre en el móvil.

## Estado

| Parte | Estado |
|---|---|
| Contrato Flutter ↔ nativo (Pigeon) | ✅ generado y versionado |
| Reloj del soporte: filtro de RTT, deriva, extrapolación | ✅ con tests |
| Fase de exposición: medida y política de reintento | ✅ con tests |
| Ciclo de vida de la captura: arranque solo, estado en vivo, avisos del nativo | ✅ con tests |
| UI de campo con la identidad **Zero**: Lado, Captura y Partido | ✅ con tests |
| Captura nativa (AVFoundation), vista previa y grabación local | ✅ TASK A2, A8 |
| Enlace entre móviles y reloj común del soporte | ✅ TASK A3, A4 |
| **Código de tiempo pintado en cada frame** | ✅ TASK A5 — enmienda B1a |
| Emisión SRT y RTMP al canal `rig/<lado>`, servidor por Bonjour | ✅ TASK A5 |
| Segmento nuevo tras un corte · bitrate por temperatura | ✅ TASK A9, A7 |
| Recorte a la banda jugable | ⬜ TASK A6 |
| **Mando del panel**: Partido lleva el marcador del panel (ADR 0017 de football-ai) | ✅ con tests y contra el panel real; el Keychain, sin compilar |
| Marcador local publicado al overlay de la emisión | ⬜ ya no hace falta para emitir: el marcador que sale es el del panel, y el mando lo lleva |

El estado completo, con lo que queda en orden y el formato exacto del código de tiempo,
está en `football-ai/docs/PROGRESS.md`, sección «Dos iPhone como cámara (ADR 0012)».

**Nada de esto se ha compilado para iOS todavía.** Se escribió en Windows, donde Flutter
analiza y ejecuta los tests de Dart pero no puede invocar a Xcode. La parte Swift está
sin compilar por definición hasta que pase por un Mac.

## Comandos

```bash
flutter pub get
flutter analyze                                   # 0 avisos, es el listón
flutter test                                      # reloj, fase, sesión, partido y pantallas
dart run pigeon --input pigeons/capture_api.dart  # regenerar el contrato
dart run flutter_launcher_icons                   # icono desde assets/brand/
dart run flutter_native_splash:create             # splash desde assets/brand/
```

En el Mac, además:

```bash
cd ios && pod install && cd ..
flutter build ios
```

## La app: dos lugares, no uno

La identidad es **Zero**: fondo `#12181A`, acento teal `#00B8A9`, Archivo para las cifras
grandes e IBM Plex Sans/Mono para lo demás. Las fuentes viajan dentro del binario —nada de
`google_fonts`—: la app arranca en una cancha sin red, y una fuente que no descarga es una
pantalla ilegible. La marca son dos anillos que se solapan un 30 %, dibujados con un
`CustomPainter` (`lib/src/theme/zero_mark.dart`) y no con un PNG, para que se vean igual a
12 px en la barra inferior que a 22 px en la cabecera.

```
RolePage  (elegir lado)  →  ZeroShell
                              ├── Captura   el móvil del soporte
                              └── Partido   marcador, cronómetro y posiciones
          (solo mando)   →  MandoPage   Partido sobre el marcador del panel, sin cámara
```

**El mando** (ADR 0017 del repo `football-ai`) es un tercer móvil que no va en el
soporte: escanea el QR «Mando» del panel, lo guarda en el Keychain y lleva el marcador
que sale al aire. Es la misma pestaña Partido (`MatchPage` sobre `MatchBoard`), pero lo
que enseña es lo que contestó el panel y cada botón es una orden: con una en camino o
sin panel, los botones se quedan quietos; reiniciar y parar la emisión preguntan antes.

Están separados a propósito. El móvil que está en el soporte no debe ver el marcador, y
quien lleva el marcador no debe poder tocar la cámara: compartir pantalla es un toque
accidental en GRABAR a mitad de partido.

Dos reglas de la capa de presentación que conviene no romper:

- **No se rellena con guiones.** Si un dato todavía no existe, la fila no se dibuja o dice
  por qué no existe. Un `—` en la pantalla se lee como «cero» desde tres metros.
- **Lo que se enseña es lo aplicado, no lo pedido.** El ISO, la obturación, los kelvin,
  el estado de la emisión y el archivo salen de lo que devuelve el nativo
  (`CaptureStatus`), no de `defaultSettings`: AVFoundation acepta peticiones que luego no
  cumple, y enterarse por la cara del vídeo no es una opción.

La lógica de captura no la toca nada de esto. `CaptureSession` solo ganó un getter de
solo lectura (`recordingElapsed`, para el reloj del HUD); cómo se agrupa y se colorea cada
dato vive aparte, en `lib/src/capture_labels.dart`.

## Lo que no es negociable

Son decisiones del ADR 0012, no preferencias. Cambiar cualquiera invalida la calibración
del soporte y obliga a recalibrar:

- **Ultra gran angular**, descubierta con `AVCaptureDevice.DiscoverySession` y nunca con
  una lista de modelos. Veo Go rechazó el iPhone 17 Pro por tener la lista vieja.
- **Estabilización desactivada.** Con ella activa el iPhone recorta y desplaza la imagen,
  y la rotación calibrada entre las dos cámaras deja de valer.
- **Exposición, balance de blancos y foco bloqueados**, iguales en los dos móviles, con
  obturación múltiplo de la frecuencia de la red eléctrica (1/100 a 50 Hz, 1/120 a 60 Hz)
  para que los focos no produzcan bandas.
- **Matriz intrínseca por frame activada.** Sin ella la calibración cae a un HFOV
  aproximado, que sirve para dimensionar y no para cerrar una costura.
- **Bitrate fijo, nunca adaptativo.** Los dos móviles comparten el enlace de Starlink y
  dos controles adaptativos se pelean entre sí hasta oscilar.
- **Grabación local siempre**, en paralelo a la emisión. Es lo que convierte un fallo de
  red en un partido en diferido en vez de en nada.

## Operativa de campo

iOS no captura en segundo plano: la app vive en primer plano con la pantalla encendida.
Modo avión con WiFi para que una llamada no corte la sesión, Acceso Guiado para que nadie
salga de la app sin querer, batería externa, y sombra sobre el soporte.
