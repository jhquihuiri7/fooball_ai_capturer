#!/usr/bin/env bash
# Baja los informes de banco del iPhone (IOS-08).
#
#   tools/bench_pull.sh [UDID]
#
# Copia Documents/bench/ de la app al directorio bench/ del repo, por WiFi o cable.
# El UDID por defecto es el iPhone de Alexander (memory/project_environment_mac_17sep).
# Si da CoreDeviceError 4000, el iPhone está bloqueado o fuera de la red.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-00008150-001619460278401C}"
BUNDLE="com.logicielapplab.zero"
DEST="bench"
mkdir -p "$DEST"

xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source Documents/bench \
  --destination "$DEST/"

echo "informes en $DEST/bench/:"
ls -la "$DEST/bench/" | tail -n +2
