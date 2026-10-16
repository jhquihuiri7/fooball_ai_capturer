# Dependencias nativas de la app de captura

Misma política que `football-ai/docs/DEPENDENCIES.md`: toda dependencia nueva se anota
aquí en el mismo commit, con su licencia y para qué está.

| Dependencia | Licencia | Para qué |
|---|---|---|
| [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) 2.2.5 (`HaishinKit`, `SRTHaishinKit`) | BSD-3 | Codificar HEVC con VideoToolbox y emitir por SRT (TASK A5). Paquete Swift en `ios/Runner.xcodeproj`. |
| libsrt 1.5.4 (binario que trae SRTHaishinKit) | MPL-2.0 | El SRT del camino viejo, el de HaishinKit. Se va con él en IOS-91. |
| [libsrt](https://github.com/Haivision/srt) 1.5.7 propio (`ios/ZeroKit/Frameworks/CSrt.xcframework`) | MPL-2.0 | El SRT del programa al VPS (IOS-55, decisión 1 del plan). Lo compila `tools/build_libsrt.sh` desde la fuente sin tocar, fijada con su SHA-256, en un objeto que solo exporta la API C con el prefijo `csrt_`. MPL permite enlazarlo estático sin abrir el resto; su texto va en `Frameworks/licenses/`. |
| [mbedTLS](https://github.com/Mbed-TLS/mbedtls) 3.6.7 LTS (solo `libmbedcrypto`, dentro de CSrt) | Apache-2.0 (doble con GPL-2.0+; se toma Apache) | El AES y el PBKDF2 de la passphrase de SRT. |
| Logboard (dependencia de HaishinKit) | BSD-3 | Su logger. |
| [crypto](https://pub.dev/packages/crypto) 3.0.7 | BSD-3 | HMAC-SHA256 del token de mando y de su secreto derivado (IOS-63). |
| [qr](https://pub.dev/packages/qr) 4.0.0 | BSD-3 | La matriz del QR Mando en la pantalla del maestro (IOS-63). |
| Barlow Condensed 600/700/800 e Inter variable (`assets/fonts/`) | SIL OFL 1.1 (`assets/fonts/OFL-*.txt`) | Los grafismos del programa con la marca Gala Sports (ADR 0026, IOS-100). Son los TTF de Google Fonts que usa la referencia de Python (`football-ai/tools/fonts`). |
| `assets/brand/gala-sports-isotipo.png` | Marca de Gala Sports, del propietario | El isotipo de la franja del programa, recortado del tablero de marca (97×84 px). |

Herramientas del banco de pruebas en el Mac, no de la app: MediaMTX (MIT) y `srt`
(MPL-2.0) por Homebrew; `uv` para el entorno Python del servidor. `build_libsrt.sh` usa
el cmake del PATH o, si no hay, el de PyPI por `uvx` (BSD-3), sin instalarlo.
