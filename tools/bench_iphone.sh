#!/usr/bin/env bash
# Un banco de BenchRunner (IOS-08) en el iPhone, desatendido: compila la app con
# BENCH=<banco>, la instala, cierra la Zero que estuviera abierta, la lanza, espera el
# informe nuevo (Documents/bench/<banco>-<epoch>.json en el contenedor de la app), lo
# baja al Mac y vuelve a cerrar la Zero.
#
#   tools/bench_iphone.sh <banco> [DISPOSITIVO]
#
#   BENCH_PARAMS='{"calls": 2000}'            los parámetros del banco (van compilados)
#   ENTORNO='{"MODEL_BENCH_SPEC": "x.json"}'   variables de entorno del lanzamiento
#   SIN_COMPILAR=1    lanza la Zero ya instalada (sin compilar ni instalar)
#   SALIDA=<dir>      dónde dejar el informe (bench/<banco>-<fecha>/ por defecto)
#   NOMBRE=<f.json>   cómo llamarlo al bajarlo (por defecto, como en el iPhone)
#   ESPERA_S=600      tope de espera del informe, en segundos
#
# Solo cierra la Zero (tools/procesos_zero.py): toda app de Flutter se llama Runner.app
# y en el teléfono puede haber otras. El iPhone, desbloqueado y con el Bloqueo
# automático en Nunca: iOS suspende la app al bloquear. Sale con 1 si no hay informe.
set -euo pipefail

BANCO=${1:?el banco: decoder-bench, model-bench, director-bench, metal-bench…}
DEVICE=${2:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # el iPhone 17
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
ESPERA_S=${ESPERA_S:-600}
SALIDA=${SALIDA:-"$RAIZ/bench/$BANCO-$(date +%Y%m%d-%H%M)"}
mkdir -p "$SALIDA"

zero_pids() {
  local apps procs
  apps=$(mktemp); procs=$(mktemp)
  xcrun devicectl device info apps --device "$DEVICE" --json-output "$apps" >/dev/null 2>&1 || true
  xcrun devicectl device info processes --device "$DEVICE" --json-output "$procs" >/dev/null 2>&1 || true
  python3 "$RAIZ/tools/procesos_zero.py" "$apps" "$procs" "$APP"
  rm -f "$apps" "$procs"
}

mata() {
  for pid in $(zero_pids); do
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" >/dev/null 2>&1 || true
  done
}

informes() {
  xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$APP" 2>/dev/null | awk '{print $1}' \
    | grep -E "^Documents/bench/$BANCO-[0-9]+\.json$" | sort || true
}

if [ -z "${SIN_COMPILAR:-}" ]; then
  DEFINES=(--dart-define=BENCH="$BANCO")
  [ -z "${BENCH_PARAMS:-}" ] || DEFINES+=(--dart-define=BENCH_PARAMS="$BENCH_PARAMS")
  (cd "$RAIZ" && "$FLUTTER" build ios --release --no-pub "${DEFINES[@]}" 2>&1 | grep -E "Built|rror")
  xcrun devicectl device install app --device "$DEVICE" \
    "$RAIZ/build/ios/iphoneos/Runner.app" | grep -E "App installed|rror"
fi

antes=$(informes)
mata
echo "== $BANCO en $DEVICE"
LANZA=(xcrun devicectl device process launch --device "$DEVICE")
[ -z "${ENTORNO:-}" ] || LANZA+=(--environment-variables "$ENTORNO")
"${LANZA[@]}" "$APP" | tail -1

# Muerta = dos miradas seguidas sin proceso: una sola puede ser un devicectl que falla.
t0=$(date +%s)
nuevo=""
sin_proceso=0
while [ $(( $(date +%s) - t0 )) -lt "$ESPERA_S" ]; do
  sleep 5
  nuevo=$(comm -13 <(echo "$antes") <(informes) | tail -1)
  [ -n "$nuevo" ] && break
  if [ $(( $(date +%s) - t0 )) -gt 30 ]; then
    if [ -z "$(zero_pids)" ]; then sin_proceso=$(( sin_proceso + 1 )); else sin_proceso=0; fi
    if [ "$sin_proceso" -ge 2 ]; then
      echo "   la Zero murió sin informe; el registro:" >&2
      echo "   xcrun devicectl device info files --device $DEVICE --domain-type systemCrashLogs" >&2
      break
    fi
  fi
done
if [ -z "$nuevo" ]; then
  echo "   sin informe de $BANCO" >&2
  exit 1
fi

destino="$SALIDA/${NOMBRE:-$(basename "$nuevo")}"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$APP" --source "$nuevo" --destination "$destino" >/dev/null
mata
echo "   en el iPhone: $nuevo"
echo "   informe: $destino"
"$(dirname "$FLUTTER")/dart" "$RAIZ/tools/bench_summary.dart" "$destino" || true
