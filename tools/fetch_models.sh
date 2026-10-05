#!/bin/bash
# Baja los modelos del móvil (IOS-22): el .mlpackage.zip de cada entrada, comprueba su
# SHA-256 contra el manifiesto y lo deja descomprimido en ios/Runner/Models/.
#
#   tools/fetch_models.sh <url_base>     # p. ej. la carpeta del bucket de ML-04
#
# El manifiesto (ios/Runner/Models/manifest.json) es el espejo del bloque coreml de
# models/registry.yaml de football-ai; aquí solo se lee. Un SHA que no cuadra para todo.
set -euo pipefail
BASE=${1:?url base de los modelos}
DIR="$(cd "$(dirname "$0")/.." && pwd)/ios/Runner/Models"
MANIFIESTO="$DIR/manifest.json"
[ -f "$MANIFIESTO" ] || { echo "falta $MANIFIESTO" >&2; exit 1; }
python3 - "$MANIFIESTO" <<'PY' | while read -r fichero sha; do
import json, sys
for m in json.load(open(sys.argv[1]))["models"].values():
    print(m["file"], m["sha256"])
PY
  zip="$DIR/$fichero.zip"
  echo "bajando $fichero"
  curl -fsSL "$BASE/$fichero.zip" -o "$zip"
  visto=$(shasum -a 256 "$zip" | cut -d' ' -f1)
  if [ "$visto" != "$sha" ]; then
    rm -f "$zip"; echo "SHA-256 de $fichero no cuadra: $visto" >&2; exit 1
  fi
  rm -rf "${DIR:?}/$fichero"; unzip -q "$zip" -d "$DIR"; rm -f "$zip"
  echo "listo $fichero"
done
