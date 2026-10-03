#!/usr/bin/env bash
# El contrato de capas de ZeroKit (IOS-02): la réplica del .importlinter del servidor.
#
#   RigCore  — solo Foundation. Ni simd, ni Accelerate, ni UIKit, ni CoreVideo, y por
#              supuesto ni RigMedia ni RigNet: es la parte que se compara con los
#              dorados y la que correría en Windows.
#
# Sale con 0 si el contrato se cumple; con 1 nombrando cada import que sobra.

set -euo pipefail

cd "$(dirname "$0")/.."
CORE="ios/ZeroKit/Sources/RigCore"

if [ ! -d "$CORE" ]; then
  echo "check_layers: no existe $CORE" >&2
  exit 1
fi

fallos=0
while IFS= read -r linea; do
  fichero="${linea%%:*}"
  resto="${linea#*:}"       # línea:contenido
  contenido="${resto#*:}"
  modulo="$(echo "$contenido" | sed -E 's/^[[:space:]]*import[[:space:]]+//; s/[[:space:]].*$//')"
  if [ "$modulo" != "Foundation" ]; then
    echo "RigCore importa $modulo (solo se permite Foundation): $fichero" >&2
    fallos=1
  fi
done < <(grep -rn --include='*.swift' -E '^[[:space:]]*import[[:space:]]' "$CORE" || true)

if [ "$fallos" -eq 0 ]; then
  echo "check_layers: RigCore solo importa Foundation"
fi
exit "$fallos"
