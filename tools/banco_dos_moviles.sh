#!/bin/bash
# El banco con los dos iPhone, desatendido (H3: cosido, color, calibración y enlace).
#
#   tools/banco_dos_moviles.sh split  <fichero_secreto> [segundos]   # IOS-43/44/38/70/47/48/64
#   tools/banco_dos_moviles.sh link90 <fichero_secreto> [segundos]   # SPK-02 / IOS-52
#   tools/banco_dos_moviles.sh emparejar <fichero_secreto>           # IOS-14, una vez
#
# Wi-Fi Aware (IOS-14, SPK-08): `emparejar` instala la app normal en los dos y la abre;
# a mano, en cada uno su lado y «Emparejar sin cable» (el derecho elige el iPhone 17 y
# teclea el código que enseña el izquierdo). Después, el banco del enlace sin router:
#   BANCO_EXTRA='{"RIG_LINK_INTERFACE": "aware"}' tools/banco_dos_moviles.sh link90 <secreto> 600
#
# <fichero_secreto>: el secreto del soporte en base64, en un fichero (no se imprime nunca).
# Los móviles, por variable de entorno o los de siempre:
#   IZQ=<id devicectl del izquierdo>   DER=<id del derecho>
# Más variables para los dos: BANCO_EXTRA='{"RIG_AUDIO": "1"}' (el micro va siempre;
# con 1 deja además audio-<t>.aac y su informe; con 0, sin micro ni AAC).
# Deja en bench/dos-moviles-<fecha>/<lado>/ solo lo de esta pasada: sus informes de
# Documents/bench, su .ts, su calibración (calib/<id>/) y, al final, un resumen por lado.
#
# SPK-04 (el render repartido): el director de guion y la 4K local de cada móvil, 10 min:
#   BANCO_EXTRA='{"RIG_SPLIT_SCRIPT": "spk04", "RIG_SPLIT_RECORD_4K": "1"}' \
#     tools/banco_dos_moviles.sh split <secreto> 600
# Además de los informes, recoge lo que el informe de ESTA pasada dice que grabó (`files`):
# el programa (.ts y .mov), sus vistas por instante (program-views-<t>.jsonl), el N0 del
# maestro (n0/banco-<t>-<lado>.jsonl) y las 4K (bench4k/<t>/<lado>-<t>.mov, ~3,4 GB cada
# una). SIN_4K=1 no trae las 4K (se quedan en el móvil).
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
INICIO=$(date +%s)  # los informes de esta pasada son posteriores: los viejos no se recogen

# El entorno de lanzamiento, en JSON, sin pasar el secreto por la línea de órdenes.
entorno() {  # $1 lado, $2 json extra
  python3 - "$SECRETO" "$1" "$2" <<'PY'
import json, os, sys
secreto, lado, extra = sys.argv[1:]
e = {"RIG_LINK_MULTIPEER": "0", "RIG_LINK_SECRET": open(secreto).read().strip(),
     "RIG_LINK_INTERFACE": "wifi", "RIG_LINK_SIDE": lado}
e.update(json.loads(extra))
# BANCO_EXTRA: variables de entorno más, en JSON (p. ej. RIG_DETECT o RIG_AUDIO).
e.update(json.loads(os.environ.get("BANCO_EXTRA", "{}")))
print(json.dumps(e))
PY
}

instala() {  # $1 dispositivo, $2 dart-defines
  (cd "$RAIZ" && $FLUTTER build ios --release $2 2>&1 | grep -E "Built|rror")
  xcrun devicectl device install app --device "$1" "$RAIZ/build/ios/iphoneos/Runner.app" | grep -c "App installed"
}

# Mata el proceso de Zero (uno viejo se queda el puerto 8090). Toda app de Flutter se
# llama Runner.app: se mira la carpeta de la Zero instalada para no cerrar otras apps.
mata() {  # $1 dispositivo
  local apps procs; apps=$(mktemp); procs=$(mktemp)
  xcrun devicectl device info apps --device "$1" --json-output "$apps" >/dev/null 2>&1 || true
  xcrun devicectl device info processes --device "$1" --json-output "$procs" >/dev/null 2>&1 || true
  for pid in $(python3 "$(dirname "$0")/procesos_zero.py" "$apps" "$procs" "$APP"); do
    xcrun devicectl device process terminate --device "$1" --pid "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$apps" "$procs"
}

lanza() {  # $1 dispositivo, $2 lado, $3 json extra
  local f t0; f=$(mktemp); entorno "$2" "$3" > "$f"
  t0=$(date +%s)
  xcrun devicectl device process launch --device "$1" --environment-variables "$(cat "$f")" $APP | tail -1
  # La hora de cada lanzamiento y lo que tardó devicectl: en …-20261010-1106 el derecho abrió
  # su enlace ~100 s después que el izquierdo y no quedó dicho si fue el lanzamiento o la app.
  echo "  $(date +%T) $2 lanzado ($(( $(date +%s) - t0 )) s)"
  rm -f "$f"
}

# Los nombres llevan la hora del reloj de cada móvil, que va unos segundos por delante o
# detrás del de la Mac: lo de esta pasada es lo que lleva una hora no anterior a DESDE. El
# margen es menor que los 45 s que separan el último informe de una pasada del arranque
# de la siguiente.
MARGEN_RELOJ_S=30
DESDE=$(( INICIO - MARGEN_RELOJ_S ))
# El listado del contenedor a veces sale vacío o falla (el derecho, iOS 27, 2026-10-14 08:54).
LISTADO_INTENTOS=3
LISTADO_TIMEOUT_S=180   # s que puede tardar un listado, con miles de fotos de calibración
LISTADO_PAUSA_S=10      # s entre un intento y el siguiente

copia() {  # $1 dispositivo, $2 lado, $3 ruta relativa a Documents; lo que falla, a no-copiados.txt
  mkdir -p "$(dirname "$SALIDA/$2/$3")"
  xcrun devicectl device copy from --device "$1" --domain-type appDataContainer --domain-identifier $APP \
    --source "Documents/$3" --destination "$SALIDA/$2/$3" >/dev/null 2>&1 && return 0
  echo "  $2: NO se pudo copiar $3"
  echo "$3" >> "$SALIDA/$2/no-copiados.txt"
}

lista() {  # $1 dispositivo, $2 lado: el listado del contenedor, en $SALIDA/$2/listado.txt
  local n=1
  while [ "$n" -le $LISTADO_INTENTOS ]; do
    xcrun devicectl device info files --device "$1" --domain-type appDataContainer --domain-identifier $APP \
      --timeout $LISTADO_TIMEOUT_S > "$SALIDA/$2/listado.txt" 2> "$SALIDA/$2/listado.err" || true
    if grep -q 'Documents/' "$SALIDA/$2/listado.txt"; then return 0; fi
    echo "  $2: el listado del móvil salió vacío o falló (intento $n de $LISTADO_INTENTOS)"
    if [ "$n" -lt $LISTADO_INTENTOS ]; then sleep $LISTADO_PAUSA_S; fi
    n=$(( n + 1 ))
  done
  return 1
}

recoge() {  # $1 dispositivo, $2 lado
  # Solo lo de esta pasada (tools/recogida_pasada.py): sus informes .json, su programa .ts y
  # lo que el informe program-split dice que grabó (tools/ficheros_pasada.py: .mov, vistas,
  # N0 y 4K). Copiar todo Documents/bench y Documents/calib tardaba ~10 min. La calibración
  # va aparte (recoge_calib), cuando ya están los informes de los dos lados.
  mkdir -p "$SALIDA/$2/bench"
  : > "$SALIDA/$2/no-copiados.txt"
  if ! lista "$1" "$2"; then
    echo "  $2: SIN LISTADO tras $LISTADO_INTENTOS intentos: no se recoge nada de este lado (ver $2/listado.err)"
    echo "sin listado del contenedor tras $LISTADO_INTENTOS intentos" > "$SALIDA/$2/sin-listado.txt"
    return 0
  fi
  local f
  for f in $(python3 "$RAIZ/tools/recogida_pasada.py" informes "$SALIDA/$2/listado.txt" "$DESDE" || true); do
    copia "$1" "$2" "$f"
  done
  # El esclavo deja un program-split-<t>.ts vacío: no sirve.
  find "$SALIDA/$2/bench" -name 'program-split-*.ts' -size 0 -delete || true
  for f in $(python3 "$RAIZ/tools/ficheros_pasada.py" "$SALIDA/$2/bench" "$DESDE" "${SIN_4K:-}" || true); do
    [ -e "$SALIDA/$2/$f" ] && continue
    echo "  $2: $f"
    copia "$1" "$2" "$f"
  done
}

recoge_calib() {  # $1 dispositivo, $2 lado: las carpetas calib/<id>/ de esta pasada
  [ -e "$SALIDA/$2/sin-listado.txt" ] && return 0
  local f fotos
  fotos=$(python3 "$RAIZ/tools/recogida_pasada.py" calib "$SALIDA/$2/listado.txt" "$DESDE" "$SALIDA"/*/bench || true)
  if [ -z "$fotos" ]; then
    echo "  $2: sin calibración de esta pasada (o sin informe program-split que la feche)"
    return 0
  fi
  for f in $fotos; do copia "$1" "$2" "$f"; done
}

espera() {  # $1 segundos
  local t0; t0=$(date +%s)
  until [ $(( $(date +%s) - t0 )) -ge "$1" ]; do sleep 10; done
}

case "$MODO" in
  split)
    SEG=${SEG:-600}
    # Cada móvil, con su rol fijo: AUTO_ROLE salta la pantalla de elegir.
    [ -n "${SIN_INSTALAR:-}" ] || instala "$IZQ" "--dart-define=AUTO_ROLE=left"
    [ -n "${SIN_INSTALAR:-}" ] || instala "$DER" "--dart-define=AUTO_ROLE=right"
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
  emparejar)
    # Sin AUTO_ROLE ni BENCH: hace falta la pantalla de lado para el botón.
    instala "$IZQ" ""
    instala "$DER" ""
    mata "$IZQ"; mata "$DER"
    lanza "$IZQ" left "{}"
    lanza "$DER" right "{}"
    echo "En los dos: su lado y «Emparejar sin cable». El derecho elige al izquierdo y teclea su código."
    exit 0
    ;;
  *) echo "modo desconocido: $MODO" >&2; exit 2 ;;
esac

# Llamadas con ||, un fallo dentro de un lado no corta el script (set -e no aplica dentro).
echo "$(date +%T) recogiendo"
recoge "$IZQ" izquierdo || echo "  izquierdo: la recogida falló a medias"
recoge "$DER" derecho || echo "  derecho: la recogida falló a medias"
recoge_calib "$IZQ" izquierdo || echo "  izquierdo: la calibración falló a medias"
recoge_calib "$DER" derecho || echo "  derecho: la calibración falló a medias"
echo "$(date +%T) informes en $SALIDA"
for lado in izquierdo derecho; do
  python3 "$RAIZ/tools/recogida_pasada.py" resumen "$SALIDA/$lado" "$DESDE" "${SIN_4K:-}" \
    || echo "$lado: sin resumen"
done
