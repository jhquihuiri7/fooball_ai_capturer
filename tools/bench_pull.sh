#!/usr/bin/env bash
# Baja los informes de banco del iPhone (IOS-08).
#
#   tools/bench_pull.sh [UDID] [BUNDLE]
#
# Copia Documents/bench/ de la app al directorio bench/ del repo, por WiFi o cable.
# El UDID por defecto es el iPhone de Alexander (memory/project_environment_mac_17sep).
# BUNDLE por defecto es la app; el runner de XCTest (SPK-50) escribe en SU propio
# contenedor, asi que para bajar un model-bench se pasa el bundle del runner
# (se ve con `devicectl device info apps`). Si da CoreDeviceError 4000, el iPhone
# esta bloqueado o fuera de la red.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-00008150-001619460278401C}"
BUNDLE="${2:-com.logicielapplab.zero}"
DEST="bench"
mkdir -p "$DEST"

xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source Documents/bench \
  --destination "$DEST"

echo "informes en $DEST/:"
ls -la "$DEST"/*.json | tail -n +1
