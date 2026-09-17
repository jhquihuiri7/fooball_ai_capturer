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
| Ciclo de vida de la captura y UI de campo | ✅ con tests |
| Captura nativa (AVFoundation) | ⬜ TASK A2 |
| Enlace entre móviles (Multipeer) | ⬜ TASK A3 |
| Emisión SRT y grabación local | ⬜ TASK A5, A8 |

**Nada de esto se ha compilado para iOS todavía.** Se escribió en Windows, donde Flutter
analiza y ejecuta los tests de Dart pero no puede invocar a Xcode. La parte Swift está
sin compilar por definición hasta que pase por un Mac.

## Comandos

```bash
flutter pub get
flutter analyze                                   # 0 avisos, es el listón
flutter test                                      # lógica pura: reloj, fase, sesión
dart run pigeon --input pigeons/capture_api.dart  # regenerar el contrato
```

En el Mac, además:

```bash
cd ios && pod install && cd ..
flutter build ios
```

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
