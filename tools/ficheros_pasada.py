#!/usr/bin/env python3
"""Lo que grabó una pasada del banco split, según su informe (SPK-04).

    python3 tools/ficheros_pasada.py <carpeta bench copiada> <epoch de inicio> [1]

Busca en la carpeta los informes `program-split-<lado>-<epoch>.json` de ESTA pasada (con el
epoch no anterior al inicio del banco: los de pasadas viejas también se copian, y sus
vídeos no se quieren) y escribe, uno por línea, las rutas relativas a Documents de lo que
el más reciente dice en `files`: el .mov del programa, sus vistas por instante, el N0 y
las 4K. El .ts ya lo trae el banco. Con un tercer argumento `1`, sin las 4K.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys

# Lo que se recoge además de los informes, en este orden; `rec4k` es una lista.
CLAVES = ("mov", "views", "e0")


def ficheros(carpeta: str, inicio: int, sin_4k: bool) -> list[str]:
    informes = []
    for ruta in glob.glob(os.path.join(carpeta, "program-split-*-*.json")):
        m = re.search(r"-(\d+)\.json$", ruta)
        if m and int(m.group(1)) >= inicio:
            informes.append((int(m.group(1)), ruta))
    if not informes:
        return []
    with open(max(informes)[1], encoding="utf-8") as f:
        files = json.load(f).get("files", {})
    salida = [files[k] for k in CLAVES if files.get(k)]
    if not sin_4k:
        salida += list(files.get("rec4k", []))
    return salida


if __name__ == "__main__":
    carpeta, inicio = sys.argv[1], int(sys.argv[2])
    sin_4k = len(sys.argv) > 3 and sys.argv[3] == "1"
    for r in ficheros(carpeta, inicio, sin_4k):
        print(r)
