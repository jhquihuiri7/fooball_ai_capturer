#!/bin/bash
# Tras la cancha: trae de los dos iPhone (por cable) lo de la última pasada —EMITIR o el plan B—
# y comprueba que los vídeos se leen.
#
#   tools/recoger_partido.sh [--desde <epoch|'AAAA-MM-DD HH:MM'>] [--sin-4k] [--solo izquierdo|derecho]
#
# Deja en bench/partido-<fecha>/<lado>/, con sus rutas de Documents: los informes y el latido
# (bench/program-split-*.json, bench/program-live-*.json), la copia del programa
# (program-<partido>-<t>.mov y sus segmentos, o el .mov/.ts del banco), el N0, las vistas, el
# audio y las 4K (<lado>-<t>.mov, o bench4k/<t>/ en el banco). Luego ffprobe de cada vídeo
# (se lee, cuánto dura, qué lleva) y el veredicto de los informes (tools/cancha.py).
#
# Qué es «la pasada»: por defecto, la última de cada móvil según su latido (desde 4fb5bf4) o,
# en una app más vieja, su 4K o su copia del programa más nuevas. --desde manda; el plan B
# deja su hora en bench/dos-moviles-<fecha>/lanzado.txt.
# Las 4K pesan ~20 GB por hora y móvil: se mira antes que quepan en el disco del Mac.
# Un móvil que no está conectado se salta (y se dice).
set -euo pipefail

DESDE_ARG=""; SIN_4K=""; SOLO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --desde) DESDE_ARG=${2:?epoch o fecha}; shift ;;
    --sin-4k) SIN_4K=1 ;;
    --solo) SOLO=${2:?izquierdo o derecho}; shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
CANCHA="python3 $RAIZ/tools/cancha.py"
SALIDA=${SALIDA:-"$RAIZ/bench/partido-$(date +%Y%m%d-%H%M)"}
mkdir -p "$SALIDA"
exec > >(tee -a "$SALIDA/recogida.log") 2>&1

DESDE=""
if [ -n "$DESDE_ARG" ]; then
  if [[ "$DESDE_ARG" =~ ^[0-9]+$ ]]; then
    DESDE=$DESDE_ARG
  else
    DESDE=$(date -j -f '%Y-%m-%d %H:%M' "$DESDE_ARG" +%s) || { echo "--desde: AAAA-MM-DD HH:MM o un epoch" >&2; exit 2; }
  fi
fi

CONECTADOS=$(zm_conectados "$IZQ" "$DER")
DESDE_USADO=""

recoge_lado() {  # $1 dispositivo, $2 lado
  local dev=$1 lado=$2 dir="$SALIDA/$2" desde f tam total libre
  mkdir -p "$dir"
  : > "$dir/no-copiados.txt"
  echo
  echo "== $(date +%T) $lado"
  if ! grep -q "$dev" <<< "$CONECTADOS"; then
    echo "⚠️  $lado ($dev) no está conectado: se salta"
    return 0
  fi
  if ! zm_lista "$dev" "$dir/listado.txt"; then
    echo "❌ $lado: sin listado del móvil tras $ZM_LISTADO_INTENTOS intentos (ver $dir/listado.txt.err)"
    return 0
  fi
  desde=${DESDE:-$($CANCHA desde "$dir/listado.txt")}
  DESDE_USADO=${DESDE_USADO:-$desde}
  echo "pasadas en el móvil (arranque, lado): $($CANCHA pasadas "$dir/listado.txt" | tail -5 | tr '\n' ';')"
  echo "se recoge desde $(date -r "$desde" '+%Y-%m-%d %H:%M:%S') ($desde)"
  echo "$($CANCHA espacio "$dir/listado.txt" "$desde")"
  for f in $($CANCHA informes "$dir/listado.txt" "$desde"); do zm_copia "$dev" "$dir" "$f" || true; done
  $CANCHA medios "$dir/listado.txt" "$desde" "$SIN_4K" > "$dir/medios.txt"
  total=$(awk '{s += $2} END {print s + 0}' "$dir/medios.txt")
  libre=$(df -Pk "$SALIDA" | awk 'NR == 2 {print $4 * 1024}')
  echo "a traer: $(wc -l < "$dir/medios.txt" | tr -d ' ') ficheros, $(( total / 1000000000 )) GB (libres en el Mac: $(( libre / 1000000000 )) GB)"
  if [ "$total" -gt "$libre" ]; then
    echo "❌ $lado: no cabe en el Mac; se traen solo los que no son 4K (vuelve con --sin-4k o libera disco)"
    $CANCHA medios "$dir/listado.txt" "$desde" 1 > "$dir/medios.txt"
  fi
  while read -r f tam; do
    [ -n "$f" ] || continue
    echo "  $(date +%T) $f ($(( tam / 1000000 )) MB)"
    zm_copia "$dev" "$dir" "$f" || true
  done < "$dir/medios.txt"
  if [ -n "$SIN_4K" ]; then
    $CANCHA k4 "$dir/listado.txt" "$desde" | while read -r f tam; do
      echo "  4K en el móvil: $f ($(( tam / 1000000 )) MB)"
    done
  fi
  local fallos; fallos=$(grep -c . "$dir/no-copiados.txt" || true)
  [ "$fallos" -eq 0 ] && echo "✅ $lado: todo copiado" || echo "❌ $lado: $fallos sin copiar (ver no-copiados.txt)"
}

[ -z "$SOLO" ] || [ "$SOLO" = izquierdo ] && { recoge_lado "$IZQ" izquierdo || echo "izquierdo: la recogida falló a medias"; }
[ -z "$SOLO" ] || [ "$SOLO" = derecho ] && { recoge_lado "$DER" derecho || echo "derecho: la recogida falló a medias"; }

echo
echo "== Los vídeos (ffprobe)"
$CANCHA verificar "$SALIDA" || true
echo
echo "== Veredicto"
$CANCHA veredicto "$SALIDA" "${DESDE_USADO:-0}" || true
echo
echo "Todo en $SALIDA"
