#!/usr/bin/env python3
"""Lo que tools/calibrar_cancha.sh necesita leer (2026-10-15): qué disparo de calibración es
el nuevo, qué ficheros traer, qué dijo la calibración de football-ai y en qué se parece el
rig.json nuevo al que tenía cada móvil.

    python3 tools/calib_cancha.py disparo <antes izq> <ahora izq> <antes der> <ahora der>
    python3 tools/calib_cancha.py ficheros <listado> <id>
    python3 tools/calib_cancha.py resultado <calibracion.json>     # sale con 1 si no calibra
    python3 tools/calib_cancha.py compara <rig nuevo> <rig viejo>
    python3 tools/calib_cancha.py latido <listado> <desde>
    python3 tools/calib_cancha.py enlace <latido.json>

<listado>: la salida de `devicectl device info files` del contenedor de Zero (tools/cancha.py
la lee). Cada disparo deja en cada móvil `Documents/calib/<id>/`: cinco parejas `<lado>-<rig
ms>.jpg` y `.json` y, al acabar, `summary-<lado>.json` (CalibrationPairs, IOS-70). El <id> es
el mismo en los dos. <calibracion.json>: lo que deja `calibrate_bench_pairs.py --json`.
"""

from __future__ import annotations

import json
import math
import re
import sys

from cancha import listado, pasadas

LADOS = ("left", "right")
NOMBRE = {"left": "izquierda", "right": "derecha"}
EJES = ("yaw", "pitch", "roll")

PARECIDO_MAX_DEG = 0.3
"""Grados. Por debajo, el rig.json nuevo «se parece» al que tenía el móvil: el montaje no
cambió. Entre las cinco parejas de un disparo en el trípode la calibración varió 0,01° de yaw
y 0,1° de roll (`bench/dos-moviles-20261011-1321`), y 0,3° son ~9 px en el programa 1080p con
el encuadre más cerrado (HFOV 60°, focal ~1660 px): un cosido que apenas cambia a la vista."""

_CALIB = re.compile(r"^calib/(\d+)/([^/]+)$")


def ids(lista: dict[str, int]) -> set[str]:
    """Los disparos que hay en el móvil, con o sin su resumen."""
    return {m.group(1) for r in lista if (m := _CALIB.match(r))}


def listos(lista: dict[str, int], lado: str) -> set[str]:
    """Los disparos que este lado ya terminó: tienen su `summary-<lado>.json`."""
    return {m.group(1) for r in lista if (m := _CALIB.match(r)) and m.group(2) == f"summary-{lado}.json"}


def disparo(antes_izq: dict[str, int], ahora_izq: dict[str, int],
            antes_der: dict[str, int], ahora_der: dict[str, int]) -> str | None:
    """El disparo nuevo que los dos móviles ya terminaron (el más alto si hay varios), o None
    mientras falte alguno."""
    nuevos = (listos(ahora_izq, "left") - ids(antes_izq)) & (listos(ahora_der, "right") - ids(antes_der))
    return max(nuevos, key=int) if nuevos else None


def ficheros(lista: dict[str, int], ident: str) -> list[str]:
    """Las rutas (relativas a Documents) de `calib/<id>/`."""
    return sorted(r for r in lista if (m := _CALIB.match(r)) and m.group(1) == ident)


def resultado(contenido: dict) -> tuple[bool, list[str]]:
    """(calibra, las líneas que se enseñan) de lo que dejó `calibrate_bench_pairs.py --json`."""
    minimo = contenido.get("min_inliers", "?")
    umbral = contenido.get("ransac_threshold_px", "?")
    intentos = contenido.get("attempts") or []
    lineas = []
    if contenido.get("error"):
        lineas.append(f"   {contenido['error']}")
    buenos = [a for a in intentos if a.get("failure") is None]
    if intentos:
        lineas.append(f"{len(intentos)} parejas; calibran {len(buenos)} (hacen falta {minimo} puntos coherentes, "
                      f"RANSAC {umbral} px):")
    for a in intentos:
        donde = f"   {a['instant_ms']} ({a['delta_ms']:+d} ms)"
        if a.get("failure") is None:
            lineas.append(f"{donde}: {a['inliers']} de {a['matches']} puntos, residuo {a['residual_deg']:.3f}°")
        else:
            lineas.append(f"{donde}: {a['failure']}")
    if not contenido.get("calibrated"):
        lineas.append("❌ NO CALIBRA" + (f": ninguna de las {len(intentos)} parejas" if intentos else ""))
        return False, lineas
    elegida = next(a for a in intentos if a["instant_ms"] == contenido["chosen_instant_ms"])
    lineas.append(f"✅ CALIBRA con la pareja {elegida['instant_ms']}: {elegida['inliers']} de {elegida['matches']} "
                  f"puntos coherentes, residuo {elegida['residual_deg']:.3f}°")
    for lado in LADOS:
        c = elegida["cameras"][lado]
        lineas.append(f"   cámara {NOMBRE[lado]:<9} " + "  ".join(f"{e} {c[f'{e}_deg']:+7.2f}°" for e in EJES))
    return True, lineas


def angulos(rig: dict) -> dict[tuple[str, str], float]:
    """Los ángulos de un rig.json (v1, en radianes) en grados, por (lado, eje)."""
    return {(lado, e): math.degrees(float(rig[lado]["pose"][f"{e}_rad"])) for lado in LADOS for e in EJES}


def compara(nuevo: dict, viejo: dict) -> tuple[float, list[str]]:
    """(la mayor diferencia en grados, las líneas): cada ángulo del viejo frente al nuevo y si
    se parecen (PARECIDO_MAX_DEG)."""
    a, b = angulos(viejo), angulos(nuevo)
    lineas = []
    for lado in LADOS:
        partes = [f"{e} {a[lado, e]:+.2f} → {b[lado, e]:+.2f} ({b[lado, e] - a[lado, e]:+.2f})" for e in EJES]
        lineas.append(f"   cámara {NOMBRE[lado]:<9} " + "  ".join(partes))
    clave = max(a, key=lambda k: abs(b[k] - a[k]))
    mayor = abs(b[clave] - a[clave])
    donde = f"{clave[1]} de la {NOMBRE[clave[0]]}"
    if mayor <= PARECIDO_MAX_DEG:
        lineas.append(f"   ✅ se parece al que tenía: la diferencia mayor es {mayor:.2f}° ({donde}), "
                      f"menos de {PARECIDO_MAX_DEG}°; el montaje es el mismo")
    else:
        lineas.append(f"   ⚠️  distinto del que tenía: {mayor:.2f}° de diferencia ({donde}), más de "
                      f"{PARECIDO_MAX_DEG}°; el montaje cambió y el bueno es el nuevo")
    return mayor, lineas


def latido(lista: dict[str, int], desde: int) -> str | None:
    """El latido más nuevo de desde `desde` (relativo a Documents), o None."""
    vivos = [(t, lado) for t, lado in pasadas(lista) if t >= desde]
    if not vivos:
        return None
    t, lado = max(vivos)
    return f"bench/program-live-{lado}-{t}.json"


def enlace(d: dict) -> str:
    """Lo que el latido dice del enlace entre los dos (desde el 2026-10-15)."""
    info = d.get("link") or {}
    frase = info.get("summary")
    if not frase:
        return "el latido no dice nada del enlace"
    return f"{frase} ({info['medium']})" if info.get("medium") else str(frase)


def _lee_listado(ruta: str) -> dict[str, int]:
    with open(ruta, encoding="utf-8", errors="replace") as f:
        return listado(f.read())


def _lee_json(ruta: str) -> dict:
    with open(ruta, encoding="utf-8") as f:
        return json.load(f)


if __name__ == "__main__":
    orden, args = sys.argv[1], sys.argv[2:]
    if orden == "disparo":
        d = disparo(*(_lee_listado(a) for a in args[:4]))
        if d:
            print(d)
    elif orden == "ficheros":
        print("\n".join(ficheros(_lee_listado(args[0]), args[1])))
    elif orden == "resultado":
        bien, lineas = resultado(_lee_json(args[0]))
        print("\n".join(lineas))
        sys.exit(0 if bien else 1)
    elif orden == "compara":
        print("\n".join(compara(_lee_json(args[0]), _lee_json(args[1]))[1]))
    elif orden == "latido":
        r = latido(_lee_listado(args[0]), int(args[1]))
        if r:
            print(r)
    elif orden == "enlace":
        print(enlace(_lee_json(args[0])))
    else:
        sys.exit(f"orden desconocida: {orden}")
