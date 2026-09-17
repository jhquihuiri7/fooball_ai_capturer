# Dependencias nativas de la app de captura

Misma política que `football-ai/docs/DEPENDENCIES.md`: toda dependencia nueva se anota
aquí en el mismo commit, con su licencia y para qué está.

| Dependencia | Licencia | Para qué |
|---|---|---|
| [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) 2.2.5 (`HaishinKit`, `SRTHaishinKit`) | BSD-3 | Codificar HEVC con VideoToolbox y emitir por SRT (TASK A5). Paquete Swift en `ios/Runner.xcodeproj`. |
| libsrt 1.5.4 (binario que trae SRTHaishinKit) | MPL-2.0 | El transporte SRT. Se enlaza como `xcframework`; MPL permite enlazarlo sin abrir el resto. |
| Logboard (dependencia de HaishinKit) | BSD-3 | Su logger. |

Herramientas del banco de pruebas en el Mac, no de la app: MediaMTX (MIT) y `srt`
(MPL-2.0) por Homebrew; `uv` para el entorno Python del servidor.
