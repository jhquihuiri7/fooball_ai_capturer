"""Los PID de Zero en un iPhone, para que el banco los cierre (tools/banco_dos_moviles.sh).

Toda app de Flutter se llama Runner.app: solo se devuelven los Runner de la carpeta de la
Zero instalada. Nada más es seguro: una app de otro proyecto lanzada desde Xcode puede no
salir en la lista de apps instaladas (visto el 2026-10-07), y al reinstalar Zero iOS ya
cierra la instancia vieja.

    python3 procesos_zero.py <apps.json> <procesos.json> <bundle id de Zero>
"""

import json
import sys


def carpeta(url: str) -> str:
    """file:///…/Application/<UUID>/Runner.app/ → /…/Application/<UUID>"""
    return url.replace("file://", "").rstrip("/").rsplit("/", 1)[0]


def pids(apps: list[dict], procesos: list[dict], zero: str) -> list[int]:
    de_zero = {carpeta(a["url"]) for a in apps if a.get("bundleIdentifier") == zero and a.get("url")}
    salida = []
    for p in procesos:
        ruta = p.get("executable", "").replace("file://", "")
        if "/Runner.app/Runner" in ruta and ruta.split("/Runner.app/")[0] in de_zero:
            salida.append(int(p["processIdentifier"]))
    return salida


if __name__ == "__main__":
    try:
        apps = json.load(open(sys.argv[1]))["result"]["apps"]
        procesos = json.load(open(sys.argv[2]))["result"]["runningProcesses"]
    except (OSError, KeyError, ValueError):
        sys.exit(0)
    for pid in pids(apps, procesos, sys.argv[3]):
        print(pid)
