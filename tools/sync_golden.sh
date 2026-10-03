#!/usr/bin/env bash
# Comprueba que los dorados del servidor están enteros (IOS-03).
#
# Los ficheros los deja `export_golden.py --sync` desde el repo football-ai; este
# script SOLO verifica cada golden-manifest.json: versión del esquema y sha256 de
# cada fichero prometido. Sale con 0 si todo cuadra; con 1 nombrando lo que no.

set -euo pipefail
cd "$(dirname "$0")/.."

fallos=0
for carpeta in ios/ZeroKit/Tests/RigCoreTests/Golden test/golden; do
  manifiesto="$carpeta/golden-manifest.json"
  if [ ! -f "$manifiesto" ]; then
    echo "falta $manifiesto: lanza export_golden.py --sync desde football-ai" >&2
    fallos=1
    continue
  fi
  python3 - "$carpeta" <<'EOF' || fallos=1
import hashlib
import json
import sys
from pathlib import Path

carpeta = Path(sys.argv[1])
manifiesto = json.loads((carpeta / "golden-manifest.json").read_text())
if manifiesto["schema"] != 1:
    sys.exit(f"{carpeta}: schema {manifiesto['schema']}, la app espera 1")
if not manifiesto.get("source_commit"):
    sys.exit(f"{carpeta}: manifiesto sin source_commit")
for nombre, esperado in sorted(manifiesto["files"].items()):
    ruta = carpeta / nombre
    if not ruta.is_file():
        sys.exit(f"{carpeta}/{nombre}: falta, y el manifiesto lo promete")
    sha = hashlib.sha256(ruta.read_bytes()).hexdigest()
    if sha != esperado:
        sys.exit(f"{carpeta}/{nombre}: sha256 no cuadra con el manifiesto")
print(f"{carpeta}: {len(manifiesto['files'])} ficheros al dia (commit {manifiesto['source_commit'][:9]})")
EOF
done
exit "$fallos"
