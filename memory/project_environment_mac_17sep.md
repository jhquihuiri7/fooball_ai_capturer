---
name: project-environment-mac-17sep
description: "Cómo se compila, prueba e instala esta app en el Mac de Alexander (17 Sep 2026): SDK Flutter 3.44.8 fuera del PATH, comandos de instalación por WiFi al iPhone, gema xcodeproj para registrar Swift, cmdline-tools 22.0."
metadata:
  node_type: memory
  type: project
---

# Entorno en este Mac

## Flutter

- El proyecto pide Flutter **3.44.8** (Dart 3.12.2; `.metadata` y `pubspec.lock`).
- Vive en `~/flutter_3.44.8`, **no está en el PATH** a propósito: hay varias versiones
  en el home y `~/flutter` (3.38.5) es la de cardiocare y del ajuste global de VS Code.
  No actualizar `~/flutter` in situ.
- VS Code usa `.vscode/settings.json` de este workspace (`dart.flutterSdkPath`). Sin
  versionar hasta que Alexander decida.

```bash
F=/Users/alexander/flutter_3.44.8/bin/flutter
$F analyze && $F test                       # 54 tests el 17 Sep
$F build ios --no-codesign                  # solo compilar
$F build ios --release                      # firmado (equipo 5AKXUHD733, automático)
$F install --release -d 00008150-001619460278401C   # iPhone de Alexander, por WiFi
xcrun devicectl device info apps --device 00008150-001619460278401C | grep footballai
dart run pigeon --input pigeons/capture_api.dart    # regenerar el contrato (con $F/../dart)
```

- La instalación por WiFi a veces da `CoreDeviceError 4000` (tiempo de espera): el
  iPhone bloqueado o fuera de la red. Reintentar o pedir a Alexander que lo desbloquee.
- Alexander suele lanzar la app desde VS Code con `flutter run` (debug, JIT) y pega los
  logs. Para una prueba de campo, `--release`.

## Xcode

- Xcode 26.6, iOS SDK 26.5, CocoaPods 1.16.2 (sin Podfile: no hay plugins todavía).
- **Un Swift nuevo hay que registrarlo en el target Runner**; `flutter build` no lo hace.
  Con la gema `xcodeproj` que trae el CocoaPods de Homebrew (no fijar `GEM_PATH`):

```bash
GEM_HOME=/opt/homebrew/Cellar/cocoapods/1.16.2_1/libexec /opt/homebrew/opt/ruby/bin/ruby -e '
require "xcodeproj"; p = Xcodeproj::Project.open("ios/Runner.xcodeproj")
t = p.targets.find { |x| x.name == "Runner" }; g = p.main_group["Runner"]
ref = g.new_file("NuevoArchivo.swift"); t.source_build_phase.add_file_reference(ref, true); p.save'
```

- El proyecto ya tiene SwiftPM habilitado (`FlutterGeneratedPluginSwiftPackage`):
  HaishinKit puede entrar como paquete Swift.

## Android (no es objetivo, pero `flutter doctor` está en verde)

- SDK en `~/Library/Android/sdk`. `cmdline-tools/latest` es la **22.0** a propósito: la
  23.0 (guardada en `cmdline-tools/23.0`) sustituye `sdkmanager` por el CLI `android` y
  Flutter 3.44.8 ya no sabe leer el estado de las licencias.

## Servidor (`../fooball_ai_streaming`)

- Python 3.12 con uv. En este Mac **no hay** uv, Python 3.12, ffmpeg ni MediaMTX.
  Para el paso 2 y 3 hará falta `brew install uv mediamtx` y `uv sync` en ese repo.
