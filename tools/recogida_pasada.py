#!/usr/bin/env python3
"""Qué traer de un móvil al acabar una pasada de tools/banco_dos_moviles.sh, y qué se trajo.

    python3 tools/recogida_pasada.py informes <listado> <desde>
    python3 tools/recogida_pasada.py calib <listado> <desde> <carpeta bench>...
    python3 tools/recogida_pasada.py resumen <carpeta del lado> <desde> [1]

<listado>: la salida de `devicectl device info files` del contenedor de la app.
<desde>: el epoch (s) del arranque del banco en la Mac, menos el margen del reloj del móvil.
Las rutas salen una por línea, relativas a Documents.

- informes: los .json de Documents/bench de ESTA pasada (la hora de su nombre no es anterior
  a <desde>; los que no llevan hora, como el informe parcial del enlace, también) y el
  último programa-split-<t>.ts de la pasada.
- calib: las fotos de las carpetas Documents/calib/<id>/ tomadas durante la pasada. El <id>
  es la hora del soporte en ms (no la de pared): la ventana sale de `bench_start_rig_ms` y
  `duration_s` de los informes program-split de la pasada, de cualquiera de los dos lados.
- resumen: una línea con lo que hay en la carpeta del lado (con un `1`, sin las 4K).
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys

from ficheros_pasada import ficheros

# La foto de calibración se dispara RIG_CALIB_AT_S después de que haya enlace, dentro de la
# pasada; las holguras solo separan esta pasada de otras y de las de antes de reiniciar el
# móvil (el reloj del soporte vuelve a empezar), que caen a horas o días.
HOLGURA_CALIB_ANTES_S = 30  # s antes del arranque del banco (bench_start_rig_ms)
HOLGURA_CALIB_DESPUES_S = 600  # s después del final de la pasada (arranque + duration_s)
MS_POR_S = 1000
BYTES_POR_MB = 1e6
BYTES_POR_GB = 1e9

_RUTA = re.compile(r"(?:^|\s)(Documents/\S+)")
_HORA_JSON = re.compile(r"-(\d+)\.json$")
_JSON_BENCH = re.compile(r"^bench/[^/]+\.json$")
_TS = re.compile(r"^bench/program-split-(\d+)\.ts$")
_CALIB = re.compile(r"^calib/(\d+)/[^/]+$")


def rutas(listado: str) -> list[str]:
    """Las rutas de Documents del listado de devicectl, sin el «Documents/», sin repetir."""
    vistas: dict[str, None] = {}
    for linea in listado.splitlines():
        m = _RUTA.search(linea)
        if m and not m.group(1).endswith("/"):
            vistas[m.group(1).removeprefix("Documents/")] = None
    return list(vistas)


def informes(lista: list[str], desde: int) -> list[str]:
    """Los .json de bench de esta pasada y su .ts (el último), en ese orden."""
    salida = []
    for r in sorted(lista):
        if _JSON_BENCH.match(r):
            m = _HORA_JSON.search(r)
            if m is None or int(m.group(1)) >= desde:
                salida.append(r)
    ts = [(int(m.group(1)), r) for r in lista if (m := _TS.match(r)) and int(m.group(1)) >= desde]
    if ts:
        salida.append(max(ts)[1])
    return salida


def ventana_calib(carpetas: list[str], desde: int) -> tuple[int, int] | None:
    """[desde, hasta] en ms del soporte, según los informes program-split de la pasada."""
    tramos = []
    for carpeta in carpetas:
        for ruta in glob.glob(os.path.join(carpeta, "program-split-*-*.json")):
            m = _HORA_JSON.search(ruta)
            if not m or int(m.group(1)) < desde:
                continue
            try:
                with open(ruta, encoding="utf-8") as f:
                    inf = json.load(f)
                t0, dur = int(inf["bench_start_rig_ms"]), float(inf["duration_s"])
            except (OSError, ValueError, KeyError, TypeError):
                continue
            tramos.append((t0, t0 + int(dur * MS_POR_S)))
    if not tramos:
        return None
    return (
        min(a for a, _ in tramos) - HOLGURA_CALIB_ANTES_S * MS_POR_S,
        max(b for _, b in tramos) + HOLGURA_CALIB_DESPUES_S * MS_POR_S,
    )


def calib(lista: list[str], ventana: tuple[int, int] | None) -> list[str]:
    """Las fotos (y sus .json) de las carpetas calib/<id>/ con el <id> dentro de la ventana."""
    if ventana is None:
        return []
    return sorted(r for r in lista if (m := _CALIB.match(r)) and ventana[0] <= int(m.group(1)) <= ventana[1])


def _tam(b: float) -> str:
    return f"{b / BYTES_POR_GB:.1f} GB" if b >= BYTES_POR_GB else f"{b / BYTES_POR_MB:.1f} MB"


def resumen(lado: str, desde: int, sin_4k: bool) -> str:
    """Lo recogido de un lado: informes, .ts, lo del informe, 4K, calibración y lo que falta."""
    nombre = os.path.basename(lado.rstrip("/"))
    sin_listado = os.path.join(lado, "sin-listado.txt")
    if os.path.exists(sin_listado):
        return f"{nombre}: NADA, no hubo listado del móvil ({sin_listado})"
    bench = os.path.join(lado, "bench")
    jsons = sorted(glob.glob(os.path.join(bench, "*.json")))
    ps = [os.path.basename(j) for j in jsons if os.path.basename(j).startswith("program-split-")]
    partes = [f"{len(jsons)} informes" + (f" ({', '.join(ps)})" if ps else ", ninguno program-split")]
    ts = glob.glob(os.path.join(bench, "program-split-*.ts"))
    partes.append(f".ts {_tam(os.path.getsize(ts[0]))}" if ts else "sin .ts")
    try:
        esperados = ficheros(bench, desde, False)
    except (OSError, ValueError):  # un informe a medio escribir
        esperados = []
    otros = [f for f in esperados if not f.startswith("bench4k/")]
    k4 = [f for f in esperados if f.startswith("bench4k/")]

    def hay(f: str) -> bool:
        return os.path.isfile(os.path.join(lado, f)) and os.path.getsize(os.path.join(lado, f)) > 0

    if otros:
        partes.append(f"lo del informe {sum(map(hay, otros))} de {len(otros)}")
    if sin_4k:
        partes.append("4K en el móvil (SIN_4K=1)")
    elif k4:
        traidas = [f for f in k4 if hay(f)]
        tam = sum(os.path.getsize(os.path.join(lado, f)) for f in traidas)
        partes.append(f"4K {len(traidas)} de {len(k4)} ({_tam(tam)})")
    else:
        partes.append("sin 4K")
    carpetas = sorted(d for d in glob.glob(os.path.join(lado, "calib", "*")) if os.path.isdir(d))
    partes.append(
        "calib " + (", ".join(f"{os.path.basename(d)} ({len(os.listdir(d))} ficheros)" for d in carpetas) or "ninguna")
    )
    try:
        with open(os.path.join(lado, "no-copiados.txt"), encoding="utf-8") as f:
            fallos = [x.strip() for x in f if x.strip()]
    except OSError:
        fallos = []
    partes.append(f"NO copiados ({len(fallos)}): {', '.join(fallos)}" if fallos else "todo copiado")
    return f"{nombre}: " + "; ".join(partes)


if __name__ == "__main__":
    orden = sys.argv[1]
    if orden == "resumen":
        print(resumen(sys.argv[2], int(sys.argv[3]), len(sys.argv) > 4 and sys.argv[4] == "1"))
        sys.exit(0)
    with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
        lista = rutas(f.read())
    desde = int(sys.argv[3])
    elegidas = informes(lista, desde) if orden == "informes" else calib(lista, ventana_calib(sys.argv[4:], desde))
    for r in elegidas:
        print(r)
