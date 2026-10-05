#!/bin/bash
# El banco con los dos iPhone, desatendido (H3: cosido, color, calibración y enlace).
#
#   tools/banco_dos_moviles.sh split  <fichero_secreto> [segundos]   # IOS-43/44/38/70/47/48/64
#   tools/banco_dos_moviles.sh link90 <fichero_secreto> [segundos]   # SPK-02 / IOS-52
#
# <fichero_secreto>: el secreto del soporte en base64, en un fichero (no se imprime nunca).
# Los móviles, por variable de entorno o los de siempre:
#   IZQ=<id devicectl del izquierdo>   DER=<id del derecho>
# Deja los informes en bench/dos-moviles-<fecha>/ (Documents/bench y Documents/calib de cada uno).
set -euo pipefail

MODO=${1:?split o link90}
SECRETO=${2:?fichero con el secreto del soporte}
SEG=${3:-}
IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SALIDA="$RAIZ/bench/dos-moviles-$(date +%Y%m%d-%H%M)"
mkdir -p "$SALIDA"

# El entorno de lanzamiento, en JSON, sin pasar el secreto por la línea de órdenes.
entorno() {  # $1 lado, $2 json extra
  python3 - "$SECRETO" "$1" "$2" <<'PY'
import json, sys
secreto, lado, extra = sys.argv[1:]
e = {"RIG_LINK_MULTIPEER": "0", "RIG_LINK_SECRET": open(secreto).read().strip(),
     "RIG_LINK_INTERFACE": "wifi", "RIG_LINK_SIDE": lado}
e.update(json.loads(extra))
print(json.dumps(e))
PY
}

instala() {  # $1 dispositivo, $2 dart-defines
  (cd "$RAIZ" && $FLUTTER build ios --release $2 2>&1 | grep -E "Built|rror")
  xcrun devicectl device install app --device "$1" "$RAIZ/build/ios/iphoneos/Runner.app" | grep -c "App installed"
}

# Mata cualquier proceso viejo de la app: uno de otra instalación se queda el puerto 8090.
mata() {  # $1 dispositivo
  for pid in $(xcrun devicectl device info processes --device "$1" 2>/dev/null | awk '/Runner.app\/Runner/ {print $1}'); do
    xcrun devicectl device process terminate --device "$1" --pid "$pid" >/dev/null 2>&1 || true
  done
}

lanza() {  # $1 dispositivo, $2 lado, $3 json extra
  local f; f=$(mktemp); entorno "$2" "$3" > "$f"
  xcrun devicectl device process launch --device "$1" --environment-variables "$(cat "$f")" $APP | tail -1
  rm -f "$f"
}

recoge() {  # $1 dispositivo, $2 nombre
  # Solo lo de esta pasada: los informes (.json), el último programa (.ts) y la
  # calibración. Copiar la carpeta entera arrastra los vídeos de pasadas viejas.
  mkdir -p "$SALIDA/$2/bench" "$SALIDA/$2/calib"
  local lista; lista=$(xcrun devicectl device info files --device "$1" --domain-type appDataContainer \
    --domain-identifier $APP 2>/dev/null | awk '{print $1}')
  local ts; ts=$(echo "$lista" | grep -E '^Documents/bench/program-split-[0-9]+\.ts$' | sort | tail -1)
  for f in $(echo "$lista" | grep -E '^Documents/(bench/[^/]+\.json|calib/.+)$') $ts; do
    xcrun devicectl device copy from --device "$1" --domain-type appDataContainer --domain-identifier $APP \
      --source "$f" --destination "$SALIDA/$2/${f#Documents/}" >/dev/null 2>&1 || true
  done
}

espera() {  # $1 segundos
  local t0; t0=$(date +%s)
  until [ $(( $(date +%s) - t0 )) -ge "$1" ]; do sleep 10; done
}

case "$MODO" in
  split)
    SEG=${SEG:-600}
    # Cada móvil, con su rol fijo: AUTO_ROLE salta la pantalla de elegir.
    instala "$IZQ" "--dart-define=AUTO_ROLE=left"
    instala "$DER" "--dart-define=AUTO_ROLE=right"
    mata "$IZQ"; mata "$DER"
    EXTRA="{\"RIG_SPLIT\": \"1\", \"RIG_SPLIT_S\": \"$SEG\", \"RIG_CALIB_AT_S\": \"30\", \"RIG_ADS\": \"bench.json\"}"
    lanza "$IZQ" left "$EXTRA"
    lanza "$DER" right "$EXTRA"
    espera $(( SEG + 45 ))
    ;;
  link90)
    SEG=${SEG:-5400}
    instala "$IZQ" "--dart-define=BENCH=link-bench"
    instala "$DER" "--dart-define=BENCH=link-bench"
    mata "$IZQ"; mata "$DER"
    EXTRA="{\"RIG_LINK_BENCH_S\": \"$SEG\", \"RIG_LINK_CUT_AT_S\": \"0\", \"RIG_LINK_PARTS\": \"1\", \"RIG_LINK_PARTS_PROFILE\": \"0,10,30\", \"RIG_LINK_PARTS_STEP_S\": \"300\"}"
    lanza "$IZQ" left "$EXTRA"
    lanza "$DER" right "$EXTRA"
    espera $(( SEG + 60 ))
    ;;
  *) echo "modo desconocido: $MODO" >&2; exit 2 ;;
esac

recoge "$IZQ" izquierdo
recoge "$DER" derecho
echo "informes en $SALIDA"
find "$SALIDA" -name "*.json" -newer "$0" | head -20
