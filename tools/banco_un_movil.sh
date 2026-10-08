#!/bin/bash
# El banco split con UN solo iPhone: el maestro compone sin esclavo (sin partes ni
# decodificador). Sirve para separar lo que es del maestro (la memoria, el compositor, el
# codificador del programa, el director) cuando solo hay un móvil.
#
#   tools/banco_un_movil.sh <secreto> <segundos> '<json extra del entorno>' [dispositivo]
#
# Sin par y sin VPS, un maestro no se promueve solo (ADR 0023 §8): se fuerza con
# RIG_SPLIT_FORCE_AT_S a los 5 s, y tarda ~70 s en componer. La duración cuenta desde el
# arranque del banco. Usa la app ya instalada (lado izquierdo); el secreto va por un
# fichero temporal que se borra. Deja el informe en bench/un-movil-<fecha>/.
set -u
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SECRETO=$1; S=$2; EXTRA=${3:-'{}'}; DISP=${4:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}
APP=com.logicielapplab.zero
SALIDA="$RAIZ/bench/un-movil-$(date +%Y%m%d-%H%M)"
mkdir -p "$SALIDA"

informes() {  # el último informe del maestro en el iPhone
  xcrun devicectl device info files --device "$DISP" --domain-type appDataContainer --domain-identifier $APP 2>/dev/null \
    | awk '{print $1}' | grep -E '^Documents/bench/program-split-left-[0-9]+\.json$' | sort | tail -1
}

cierra() {  # solo la app Zero, nunca otro Runner del teléfono
  local apps procs; apps=$(mktemp); procs=$(mktemp)
  xcrun devicectl device info apps --device "$DISP" --json-output "$apps" >/dev/null 2>&1
  xcrun devicectl device info processes --device "$DISP" --json-output "$procs" >/dev/null 2>&1
  for pid in $(python3 "$RAIZ/tools/procesos_zero.py" "$apps" "$procs" $APP); do
    xcrun devicectl device process terminate --device "$DISP" --pid "$pid" >/dev/null 2>&1
  done
  rm -f "$apps" "$procs"
}

cierra; sleep 3
antes=$(informes)
f=$(mktemp)
python3 - "$SECRETO" "$S" "$EXTRA" > "$f" <<'PY'
import json, sys
s, seg, extra = sys.argv[1:]
env = {"RIG_LINK_MULTIPEER": "0", "RIG_LINK_SECRET": open(s).read().strip(), "RIG_LINK_INTERFACE": "wifi",
       "RIG_LINK_SIDE": "left", "RIG_SPLIT": "1", "RIG_SPLIT_S": seg, "RIG_SPLIT_FORCE_AT_S": "5"}
env.update(json.loads(extra))
print(json.dumps(env))
PY
salida=$(xcrun devicectl device process launch --device "$DISP" --environment-variables "$(cat "$f")" $APP 2>&1)
rm -f "$f"
echo "$salida" | grep -q "Launched application" || { echo "no se lanzó: $(echo "$salida" | tail -2)"; exit 1; }
echo "lanzado $(date +%H:%M:%S)"
sleep $((S + 30))
ultimo=$antes
for _ in $(seq 1 60); do
  ultimo=$(informes)
  [ "$ultimo" != "$antes" ] && break
  sleep 10
done
[ "$ultimo" = "$antes" ] && { echo "sin informe nuevo"; exit 1; }
sleep 5
xcrun devicectl device copy from --device "$DISP" --domain-type appDataContainer --domain-identifier $APP \
  --source "$ultimo" --destination "$SALIDA/$(basename "$ultimo")" >/dev/null 2>&1
cierra
echo "recogido $SALIDA/$(basename "$ultimo") $(date +%H:%M:%S)"
