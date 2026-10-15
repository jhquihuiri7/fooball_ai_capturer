#!/bin/bash
# Calibrar el soporte en la cancha en una orden (2026-10-15), con los dos iPhone por cable al Mac.
# EMITIR cose con Documents/rig.json de cada iPhone; si en la cancha quedan montados distinto que
# en casa, el cosido no casa. EMITIR no toma fotos de calibración: esto sí.
#
#   tools/calibrar_cancha.sh <fichero_secreto> [--solo-comprobar] [--sin-instalar]
#
# 1. Instala en cada móvil su app de banco (build/cancha/auto-left.app y auto-right.app, las de
#    `tools/plan_b_cancha.sh preparar`), cierra SOLO Zero y lanza un banco split corto por Wi-Fi
#    Aware con RIG_CALIB_AT_S: el maestro dispara las 5 parejas de fotos a los DISPARO_S s de
#    enlazar (CalibrationPairs, IOS-70). Sin .ts ni copia .mov.
# 2. En cuanto los dos han terminado su disparo (calib/<id>/summary-<lado>.json), cierra Zero,
#    trae calib/<id>/ de los dos a bench/calib-cancha-<fecha>/{izquierdo,derecho}/ y vuelve a
#    instalar build/cancha/emitir.app en los dos (también si algo falla a mitad).
# 3. Calibra con football-ai (tools/calibrate_bench_pairs.py, los umbrales del repo: RANSAC 3 px y
#    30 puntos coherentes), sin red (`uv run --no-sync`).
# 4. Si calibra: los ángulos, los puntos y el residuo; el rig.json que tenía cada móvil (bajado
#    antes a <salida>/<lado>/antes/rig.json, que es la copia de seguridad) frente al nuevo; instala
#    el nuevo en Documents/rig.json de los dos y lo vuelve a bajar para comprobarlo.
#    Si no calibra: no toca los móviles y dice por qué y qué hacer.
#
#   --solo-comprobar  hace 1-3 y compara, pero no instala el rig.json
#   --sin-instalar    usa la app que ya hay en los móviles y no reinstala nada: con la de EMITIR,
#                     en cada uno hay que elegir el lado y «Abrir cámara» al abrirse
#
# Los móviles, como en el banco: IZQ=<id devicectl del 17> DER=<id del 16 Pro>. Más: CANCHA_APPS
# (las apps), REFERENCIA (football-ai), CALIB_ENLACE (aware; wifi en casa), DISPARO_S, ESPERA_S,
# SONDEO_S, CALIB_EXTRA (JSON con más entorno) y SALIDA. CALIBRADOR sustituye a la calibración de
# football-ai en las pruebas (tools/test_guiones_cancha.sh). El secreto no sale nunca por pantalla.
set -euo pipefail

SECRETO=${1:?fichero con el secreto del soporte (base64)}
shift
SOLO_COMPROBAR=""; SIN_INSTALAR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --solo-comprobar) SOLO_COMPROBAR=1 ;;
    --sin-instalar) SIN_INSTALAR=1 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -r "$SECRETO" ] || { echo "no se puede leer $SECRETO" >&2; exit 2; }

IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17, el maestro
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
APPS=${CANCHA_APPS:-"$RAIZ/build/cancha"}
REFERENCIA=${REFERENCIA:-"$RAIZ/../fooball_ai_streaming"}
CALIB="python3 $RAIZ/tools/calib_cancha.py"
ENLACE=${CALIB_ENLACE:-aware}   # en la cancha no hay router
DISPARO_S=${DISPARO_S:-10}      # s de enlace antes de las fotos: la exposición ya está asentada
ESPERA_S=${ESPERA_S:-300}       # lo más que se esperan las fotos: Aware ha tardado ~2 min en enlazar
SONDEO_S=${SONDEO_S:-15}        # cada cuánto se mira si ya están (un listado tarda unos segundos)
SPLIT_S=$(( ESPERA_S + 60 ))    # el banco no acaba antes de que se dejen de esperar las fotos
MARGEN_RELOJ_S=30               # el reloj del móvil frente al del Mac (los nombres de los latidos)

SALIDA=${SALIDA:-"$RAIZ/bench/calib-cancha-$(date +%Y%m%d-%H%M)"}
mkdir -p "$SALIDA/izquierdo" "$SALIDA/derecho"
exec > >(tee -a "$SALIDA/calibrar.log") 2>&1

paso() { echo; echo "== $(date +%T) $*"; }

calibra() {  # los argumentos de calibrate_bench_pairs.py
  if [ -n "${CALIBRADOR:-}" ]; then "$CALIBRADOR" "$@"; return; fi
  (cd "$REFERENCIA" && uv run --no-sync python tools/calibrate_bench_pairs.py "$@")
}

# La orden, para instalar un rig.json a mano (el viejo, el de casa o el nuevo).
orden_instalar() {  # $1 dispositivo, $2 fichero
  echo "xcrun devicectl device copy to --device $1 --domain-type appDataContainer --domain-identifier $APP --source $2 --destination Documents/rig.json"
}

paso "Los dos iPhone"
CONECTADOS=$(zm_conectados "$IZQ" "$DER")
for d in "$IZQ" "$DER"; do
  grep -q "$d" <<< "$CONECTADOS" || { echo "❌ $d no está conectado: cable, desbloqueado y «Confiar en este ordenador»"; exit 1; }
done
echo "✅ los dos conectados"
if [ -z "$SIN_INSTALAR" ]; then
  for a in auto-left auto-right emitir; do
    [ -d "$APPS/$a.app" ] || { echo "❌ falta $APPS/$a.app: en casa, tools/plan_b_cancha.sh preparar (o --sin-instalar)"; exit 1; }
  done
  VERSION_APPS=$(cat "$APPS/VERSION" 2>/dev/null || echo '?')
  echo "✅ las apps de $APPS ($VERSION_APPS)"
  # Al acabar vuelve emitir.app de ahí: si es más vieja que el repo, los móviles bajan de versión.
  HEAD_REPO=$(git -C "$RAIZ" rev-parse --short HEAD 2>/dev/null || echo '?')
  [ "$VERSION_APPS" = "$HEAD_REPO" ] || \
    echo "⚠️  son de $VERSION_APPS y el repo está en $HEAD_REPO: al acabar queda ESA emitir.app (¿tools/plan_b_cancha.sh preparar?)"
fi
if [ -z "${CALIBRADOR:-}" ]; then
  command -v uv >/dev/null || { echo "❌ sin uv en el Mac: la calibración es de football-ai"; exit 1; }
  if ! calibra --help > "$SALIDA/calibrador.txt" 2>&1; then
    tail -3 "$SALIDA/calibrador.txt"
    echo "❌ football-ai ($REFERENCIA) no puede calibrar: en casa, cd $REFERENCIA && uv sync --group nube"
    exit 1
  fi
  echo "✅ football-ai calibra sin red ($REFERENCIA)"
fi

paso "Lo que tiene cada móvil ahora (y la copia de su rig.json)"
for par in "$IZQ:izquierdo" "$DER:derecho"; do
  d=${par%%:*}; lado=${par##*:}
  zm_lista "$d" "$SALIDA/$lado/listado-antes.txt" || { echo "❌ $lado: sin listado del móvil; no se lanza nada"; exit 1; }
  if grep -qE '(^|[[:space:]])Documents/rig\.json[[:space:]]' "$SALIDA/$lado/listado-antes.txt"; then
    if zm_copia "$d" "$SALIDA/$lado/antes" rig.json; then
      echo "$lado: rig.json guardado en $SALIDA/$lado/antes/rig.json"
    else
      echo "❌ $lado: no se pudo bajar su rig.json; no se sigue (no habría copia del viejo)"; exit 1
    fi
  else
    echo "$lado: ⚠️  no tiene rig.json (EMITIR cose con el soporte NOMINAL)"
  fi
done

INSTALADAS=""
# Vuelve a dejar EMITIR en los dos si se instalaron las apps de banco. También al salir a mitad.
vuelve() {
  [ -n "$INSTALADAS" ] || return 0
  INSTALADAS=""
  local d
  for d in "$IZQ" "$DER"; do
    zm_mata "$d"
    if zm_instala "$d" "$APPS/emitir.app"; then echo "✅ EMITIR otra vez en $d"
    else echo "❌ no se pudo volver a instalar EMITIR en $d: tools/plan_b_cancha.sh volver"; fi
  done
}
trap vuelve EXIT

if [ -z "$SIN_INSTALAR" ]; then
  paso "La app de banco de cada lado (luego vuelve la de EMITIR)"
  zm_mata "$IZQ"; zm_mata "$DER"
  INSTALADAS=1
  zm_instala "$IZQ" "$APPS/auto-left.app" || { echo "❌ no se instaló en $IZQ"; exit 1; }
  zm_instala "$DER" "$APPS/auto-right.app" || { echo "❌ no se instaló en $DER"; exit 1; }
  echo "✅ instaladas"
fi

paso "Las fotos de calibración: un banco corto por $ENLACE, el disparo a los $DISPARO_S s de enlazar"
INICIO=$(date +%s)
zm_mata "$IZQ"; zm_mata "$DER"
for par in "$IZQ:left" "$DER:right"; do
  d=${par%%:*}; lado=${par##*:}
  extra=$(python3 - "$lado" "$ENLACE" "$SPLIT_S" "$DISPARO_S" "${CALIB_EXTRA:-}" <<'PY'
import json, sys
lado, enlace, split_s, disparo_s, extra = sys.argv[1:]
e = {"RIG_LINK_MULTIPEER": "0", "RIG_LINK_INTERFACE": enlace, "RIG_LINK_SIDE": lado, "RIG_SPLIT": "1",
     "RIG_SPLIT_S": split_s, "RIG_CALIB_AT_S": disparo_s, "RIG_SPLIT_NO_TS": "1", "RIG_SPLIT_NO_MOV": "1"}
e.update(json.loads(extra or "{}"))
print(json.dumps(e))
PY
)
  f=$(zm_entorno "$SECRETO" "$extra")
  zm_lanza "$d" "$f" || echo "⚠️  no se pudo lanzar en $d (¿bloqueado?)"
  rm -f "$f"
done
[ -n "$SIN_INSTALAR" ] && echo "Si un móvil enseña la pantalla de lado: su lado y «Abrir cámara». No pulses EMITIR."
echo "Lanzado. Los dos quietos y mirando a la cancha hasta que acabe (máx. $ESPERA_S s)."

ID=""
while :; do
  sleep "$SONDEO_S"
  zm_lista "$IZQ" "$SALIDA/izquierdo/listado-ahora.txt" || true
  zm_lista "$DER" "$SALIDA/derecho/listado-ahora.txt" || true
  ID=$($CALIB disparo "$SALIDA/izquierdo/listado-antes.txt" "$SALIDA/izquierdo/listado-ahora.txt" \
                      "$SALIDA/derecho/listado-antes.txt" "$SALIDA/derecho/listado-ahora.txt")
  [ -n "$ID" ] && break
  transcurrido=$(( $(date +%s) - INICIO ))
  [ "$transcurrido" -ge "$ESPERA_S" ] && break
  echo "  $(date +%T) aún no están las fotos de los dos ($transcurrido s)"
done
zm_mata "$IZQ"; zm_mata "$DER"

if [ -z "$ID" ]; then
  echo "❌ en $ESPERA_S s no llegaron las fotos de los dos. Lo que dice el latido de cada uno:"
  for par in "$IZQ:izquierdo" "$DER:derecho"; do
    d=${par%%:*}; lado=${par##*:}
    l=$($CALIB latido "$SALIDA/$lado/listado-ahora.txt" $(( INICIO - MARGEN_RELOJ_S )) 2>/dev/null || true)
    if [ -n "$l" ] && zm_copia "$d" "$SALIDA/$lado" "$l" >/dev/null; then
      echo "  $lado: $($CALIB enlace "$SALIDA/$lado/$l")"
    else
      echo "  $lado: sin latido de esta pasada (¿no arrancó el banco?)"
    fi
  done
  echo "No se toca el rig.json de los móviles. Otra vez, con los dos desbloqueados y cerca: tools/calibrar_cancha.sh <secreto>"
  vuelve
  exit 1
fi

paso "Disparo $ID: traer calib/$ID/ de los dos"
for par in "$IZQ:izquierdo" "$DER:derecho"; do
  d=${par%%:*}; lado=${par##*:}
  n=0
  for f in $($CALIB ficheros "$SALIDA/$lado/listado-ahora.txt" "$ID"); do
    zm_copia "$d" "$SALIDA/$lado" "$f" && n=$(( n + 1 )) || true
  done
  echo "$lado: $n ficheros en $SALIDA/$lado/calib/$ID"
done
vuelve

paso "Calibrar (football-ai, los umbrales del repo)"
set +e
calibra --bench "$SALIDA" --boot "$ID" --out "$SALIDA/rig.json" --json "$SALIDA/calibracion.json" \
  > "$SALIDA/calibracion.txt" 2>&1
CODIGO=$?
set -e
if [ ! -s "$SALIDA/calibracion.json" ]; then
  tail -5 "$SALIDA/calibracion.txt"
  echo "❌ la calibración no dejó resultado (código $CODIGO; todo en $SALIDA/calibracion.txt). No se toca nada."
  exit 1
fi
if ! $CALIB resultado "$SALIDA/calibracion.json" || [ "$CODIGO" -ne 0 ] || [ ! -s "$SALIDA/rig.json" ]; then
  echo
  echo "No se toca el rig.json de los móviles: siguen con el que tenían."
  echo "Qué hacer:"
  echo " - Apuntar el soporte a la cancha: con textura en el solape de las dos cámaras (gradas, vallas,"
  echo "   árboles, edificios), lejos (más de 20 m; de cerca el paralaje rompe la rotación pura) y quieto"
  echo "   durante las fotos; no a césped liso ni al cielo. Y otra vez: tools/calibrar_cancha.sh <secreto>"
  echo " - O, si los dos móviles siguen montados igual que en casa, aceptar el de casa: ya está en los dos."
  for par in "$IZQ:izquierdo" "$DER:derecho"; do
    d=${par%%:*}; lado=${par##*:}
    if [ ! -s "$SALIDA/$lado/antes/rig.json" ]; then
      echo "   ⚠️  el $lado no tiene rig.json; el de casa, a mano:"
      echo "   $(orden_instalar "$d" "$RAIZ/docs/img/rig-tripode-20261011.json")"
    fi
  done
  exit 1
fi

paso "El nuevo frente al que tenía cada móvil"
for lado in izquierdo derecho; do
  if [ -s "$SALIDA/$lado/antes/rig.json" ]; then
    echo "$lado (antes → ahora, grados):"
    $CALIB compara "$SALIDA/rig.json" "$SALIDA/$lado/antes/rig.json"
  else
    echo "$lado: no tenía rig.json (iba con el soporte NOMINAL)"
  fi
done

if [ -n "$SOLO_COMPROBAR" ]; then
  echo
  echo "--solo-comprobar: NO se instala. El rig.json nuevo está en $SALIDA/rig.json. Para instalarlo:"
  echo "  $(orden_instalar "$IZQ" "$SALIDA/rig.json")"
  echo "  $(orden_instalar "$DER" "$SALIDA/rig.json")"
  exit 0
fi

paso "Instalar el nuevo en Documents/rig.json de los dos (y comprobarlo)"
MAL=0
for par in "$IZQ:izquierdo" "$DER:derecho"; do
  d=${par%%:*}; lado=${par##*:}
  rm -rf "$SALIDA/$lado/instalado"
  if ! "$XCRUN" devicectl device copy to --device "$d" --domain-type appDataContainer --domain-identifier "$APP" \
      --source "$SALIDA/rig.json" --destination Documents/rig.json > "$SALIDA/$lado/copia-rig.txt" 2>&1; then
    echo "❌ $lado: no se pudo copiar (ver $SALIDA/$lado/copia-rig.txt)"
    MAL=1
  elif zm_copia "$d" "$SALIDA/$lado/instalado" rig.json >/dev/null && cmp -s "$SALIDA/rig.json" "$SALIDA/$lado/instalado/rig.json"; then
    echo "✅ $lado: Documents/rig.json es el nuevo (bajado y comparado)"
    continue
  else
    echo "❌ $lado: el Documents/rig.json que se baja no es el nuevo"
    MAL=1
  fi
  [ -s "$SALIDA/$lado/antes/rig.json" ] && echo "   para volver al que tenía: $(orden_instalar "$d" "$SALIDA/$lado/antes/rig.json")"
done
if [ "$MAL" -ne 0 ]; then
  echo "VEREDICTO: ❌ calibrado, pero no quedó instalado en los dos"
  exit 1
fi
echo "VEREDICTO: ✅ calibrado e instalado en los dos. Los viejos, en $SALIDA/<lado>/antes/rig.json."
echo "EMITIR desde el icono: la fila del soporte dice «calibrada · rig.json»."
