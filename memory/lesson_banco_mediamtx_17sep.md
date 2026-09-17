---
name: lesson-banco-mediamtx-17sep
description: "Tres trampas encontradas el 17 Sep 2026 al montar el banco de pruebas de emisión en el Mac: MediaMTX SRT solo IPv6 en macOS, flutter install borra los datos de la app, y la API de HaishinKit en main no es la de 2.2.5."
metadata:
  node_type: memory
  type: project
---

# Trampas del banco de pruebas en el Mac (17 Sep 2026)

## 1. MediaMTX en macOS: `srtAddress: :8890` no recibe IPv4

Con `srtAddress: :8890`, `lsof` enseña el socket UDP como IPv6 y **ningún cliente SRT
conecta**, ni por loopback: `srt-live-transmit` se queda en "Connecting" y MediaMTX no
registra nada. Con `srtAddress: 0.0.0.0:8890` conecta al instante. RTSP y RTMP (TCP)
no tienen el problema. Costó una hora y la paciencia de Alexander: **probar siempre el
banco desde el propio Mac antes de que lo pruebe el móvil**:

```bash
srt-live-transmit -v udp://127.0.0.1:5001 "srt://10.10.18.100:8890?streamid=publish:izquierda" &
uv run python tools/ingest_probe.py send udp://127.0.0.1:5001 --seconds 6   # en el repo del servidor
```

## 2. `flutter install` desinstala antes de instalar: borra Documents y UserDefaults

Por eso Alexander tenía que reteclear la IP y desaparecían las grabaciones. Instalar
así, que conserva el contenedor:

```bash
xcrun devicectl device install app --device 00008150-001619460278401C build/ios/iphoneos/Runner.app
```

## 3. HaishinKit: la API de `main` en GitHub no es la de la versión instalada

Con `exactVersion 2.2.5`, los tipos son `SessionBuilderFactory`, `Session`,
`SessionReadyState`, `SRTSessionFactory`; en `main` ya se llaman `StreamSession…`.
Leer siempre el checkout local:
`~/Library/Developer/Xcode/DerivedData/Runner-*/SourcePackages/checkouts/HaishinKit.swift`.
Los binarios `libsrt.xcframework` van a `SourcePackages/artifacts`.

## Y una más: el permiso de red local de iOS no se puede "pedir"

Se provoca con un NWListener + NWBrowser sobre un tipo declarado en `NSBonjourServices`
(`LocalNetworkAccess.swift`). Si el aviso no sale es porque **ya está concedido** (la
búsqueda se encuentra a sí misma) o porque el tipo no está declarado (falla con
`PolicyDenied` sin preguntar). La app solo aparece en Ajustes → Red local después del
primer uso.
