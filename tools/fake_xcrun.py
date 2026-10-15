#!/usr/bin/env python3
"""Un `xcrun devicectl` falso para probar los guiones de la cancha sin iPhone
(tools/test_guiones_cancha.sh). Se pone en el PATH como `xcrun`.

Todo vive en $FAKE_DIR:
    conectados                 los ids que «están» por cable, uno por línea
    dev/<id>/Documents/...     el contenedor de Zero de cada móvil
    dev/<id>/corriendo         Zero está abierta
    dev/<id>/entorno.json      el entorno del último lanzamiento (con el secreto: no sale)
    dev/<id>/keychain          lo que Zero guardaría del RIG_LINK_SECRET al arrancar
    guion.json                 {id: {"<n>": [[«pon», origen, ruta en Documents], …]}}: lo que
                               aparece en el móvil antes de su listado número n (Zero emitiendo)
    log                        las órdenes, sin valores del entorno

Hay siempre otra app de Flutter (otro Runner.app) corriendo en cada móvil: el guion no
puede cerrarla nunca (lo que pasó el 2026-10-07).
"""

from __future__ import annotations

import json
import os
import shutil
import sys

ZERO = "com.logicielapplab.zero"
PID_ZERO, PID_OTRA = 1000, 2000


def fake() -> str:
    return os.environ["FAKE_DIR"]


def log(texto: str) -> None:
    with open(os.path.join(fake(), "log"), "a", encoding="utf-8") as f:
        f.write(texto + "\n")


def opcion(args: list[str], nombre: str) -> str | None:
    return args[args.index(nombre) + 1] if nombre in args else None


def conectados() -> list[str]:
    try:
        with open(os.path.join(fake(), "conectados"), encoding="utf-8") as f:
            return [x.strip() for x in f if x.strip()]
    except OSError:
        return []


def raiz(dev: str) -> str:
    return os.path.join(fake(), "dev", dev)


def tam(n: int) -> str:
    """Como lo escribe devicectl: «Zero KB», «812 bytes», «22,5 MB», «1,27 GB»."""
    if n == 0:
        return "Zero KB"
    if n < 1000:
        return f"{n} bytes"
    for unidad, base, dec in (("GB", 1e9, 2), ("MB", 1e6, 1), ("KB", 1e3, 0)):
        if n >= base:
            v = round(n / base, dec)
            texto = f"{v:.{dec}f}".rstrip("0").rstrip(".") if dec else f"{v:.0f}"
            return f"{texto.replace('.', ',')} {unidad}"
    return f"{n} bytes"


def aplica_guion(dev: str, n: int) -> None:
    try:
        with open(os.path.join(fake(), "guion.json"), encoding="utf-8") as f:
            guion = json.load(f)
    except OSError:
        return
    for accion in guion.get(dev, {}).get(str(n), []):
        if accion[0] == "pon":
            destino = os.path.join(raiz(dev), "Documents", accion[2])
            os.makedirs(os.path.dirname(destino), exist_ok=True)
            shutil.copyfile(accion[1], destino)


def listado(dev: str) -> None:
    cuenta = os.path.join(raiz(dev), "listados")
    n = int(open(cuenta).read()) + 1 if os.path.exists(cuenta) else 1
    with open(cuenta, "w") as f:
        f.write(str(n))
    aplica_guion(dev, n)
    docs = os.path.join(raiz(dev), "Documents")
    filas = []
    for base, dirs, ficheros in os.walk(docs):
        rel = os.path.relpath(base, raiz(dev))
        filas.append((rel, "Writable, Readable, Directory", "128 bytes"))
        for fi in sorted(ficheros):
            filas.append((os.path.join(rel, fi), "Writable, Readable", tam(os.path.getsize(os.path.join(base, fi)))))
    print("12:45:19  Acquired tunnel connection to device.")
    print(f"{len(filas)} files:")
    print(f"{'Name':<90}   {'URL Resources':<30}   {'Size':<12}   Modification date")
    print(f"{'-' * 90}   {'-' * 30}   {'-' * 12}   {'-' * 18}")
    for ruta, recursos, t in sorted(filas):
        print(f"{ruta:<90}   {recursos:<30}   {t:<12}   14/10/26, 9:31 PM")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0] != "devicectl":
        print("fake_xcrun: solo devicectl", file=sys.stderr)
        return 2
    args = args[1:]
    salida_json = opcion(args, "--json-output")
    if args[:2] == ["list", "devices"]:
        devs = [{"identifier": d, "connectionProperties": {"tunnelState": "connected", "transportType": "wired"}}
                for d in conectados()]
        devs.append({"identifier": "RELOJ", "connectionProperties": {"tunnelState": "disconnected"}})
        if salida_json:
            json.dump({"result": {"devices": devs}}, open(salida_json, "w"))
        log("list devices")
        return 0
    dev = opcion(args, "--device") or ""
    if dev not in conectados():
        print(f"ERROR: The device {dev} is not connected", file=sys.stderr)
        log(f"{dev} SIN CONEXIÓN {' '.join(args[:3])}")
        return 1
    os.makedirs(os.path.join(raiz(dev), "Documents"), exist_ok=True)
    corriendo = os.path.join(raiz(dev), "corriendo")
    if args[:3] == ["device", "info", "apps"]:
        apps = [{"bundleIdentifier": ZERO, "url": f"file:///private/var/containers/Bundle/Application/Z-{dev}/Runner.app/"},
                {"bundleIdentifier": "com.otra.app", "url": "file:///private/var/containers/Bundle/Application/OTRA/Runner.app/"}]
        json.dump({"result": {"apps": apps}}, open(salida_json, "w"))
        return 0
    if args[:3] == ["device", "info", "processes"]:
        procs = [{"processIdentifier": PID_OTRA,
                  "executable": "file:///private/var/containers/Bundle/Application/OTRA/Runner.app/Runner"}]
        if os.path.exists(corriendo):
            procs.append({"processIdentifier": PID_ZERO,
                          "executable": f"file:///private/var/containers/Bundle/Application/Z-{dev}/Runner.app/Runner"})
        json.dump({"result": {"runningProcesses": procs}}, open(salida_json, "w"))
        return 0
    if args[:3] == ["device", "process", "terminate"]:
        pid = int(opcion(args, "--pid") or 0)
        if pid == PID_ZERO and os.path.exists(corriendo):
            os.remove(corriendo)
            log(f"{dev} cierra Zero")
        elif pid == PID_OTRA:
            log(f"{dev} CERRÓ OTRA APP")
        return 0
    if args[:3] == ["device", "process", "launch"]:
        entorno = json.loads(opcion(args, "--environment-variables") or "{}")
        json.dump(entorno, open(os.path.join(raiz(dev), "entorno.json"), "w"))
        if "RIG_LINK_SECRET" in entorno:
            open(os.path.join(raiz(dev), "keychain"), "w").write(entorno["RIG_LINK_SECRET"])
        open(corriendo, "w").close()
        log(f"{dev} lanza {args[-1]} con {sorted(entorno)}")
        print(f"Launched application with {args[-1]} bundle identifier.")
        return 0
    if args[:3] == ["device", "install", "app"]:
        log(f"{dev} instala {os.path.basename(args[-1].rstrip('/'))}")
        print(f"App installed:\n• bundleID: {ZERO}")
        return 0
    if args[:3] == ["device", "info", "files"]:
        listado(dev)
        return 0
    if args[:3] == ["device", "copy", "from"]:
        origen = os.path.join(raiz(dev), opcion(args, "--source") or "")
        destino = opcion(args, "--destination") or ""
        if not os.path.isfile(origen):
            print(f"ERROR: no existe {origen}", file=sys.stderr)
            return 1
        shutil.copyfile(origen, destino)
        log(f"{dev} copia {opcion(args, '--source')}")
        return 0
    print(f"fake_xcrun: no sé {args}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
