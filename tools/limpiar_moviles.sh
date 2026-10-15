#!/bin/bash
# Lo que ocupa Zero en cada iPhone, por carpeta, y borrar las pruebas viejas (2026-10-15), con los
# iPhone por cable al Mac:
#
#   tools/limpiar_moviles.sh                    # solo mira: bench/, bench4k/, nv12/, copias, calib/…
#   tools/limpiar_moviles.sh --borrar-pruebas   # y borra de bench/, bench4k/ y nv12/ lo de antes de hoy
#
# `devicectl` no sabe borrar ficheros del contenedor de una app (lista, copia, instala y
# desinstala la app entera), así que borra la app: lanzada con RIG_PURGE_BENCH=1, al arrancar
# borra de bench/, bench4k/ y nv12/ lo modificado antes de hoy y deja bench/purge-<t>.json
# (BenchPurge.swift). Nunca toca rig.json, bench-resources/, calib/, n0/ ni las copias
# program-*.mov. Aquí se lanza con eso solo (sin el secreto), se espera a su informe, se cierra
# SOLO Zero y se enseña lo que queda. Una app anterior a RIG_PURGE_BENCH no deja informe ni borra
# nada: se dice, y hay que instalar una de ahora (tools/plan_b_cancha.sh preparar y volver).
#
# Los móviles: IZQ=<id devicectl del 17> DER=<id del 16 Pro>; uno sin cable se salta.
# ESPERA_PURGA_S (90) y SONDEO_S (5) para la espera del informe.
set -euo pipefail

BORRAR=""
case "${1:-}" in
  --borrar-pruebas) BORRAR=1 ;;
  "") ;;
  *) echo "opción desconocida: $1 (solo --borrar-pruebas)" >&2; exit 2 ;;
esac

IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
CANCHA="python3 $RAIZ/tools/cancha.py"
ESPERA_PURGA_S=${ESPERA_PURGA_S:-90}   # el arranque de Zero y borrar unos miles de ficheros
SONDEO_S=${SONDEO_S:-5}
SALIDA=${SALIDA:-"$RAIZ/bench/limpieza-$(date +%Y%m%d-%H%M)"}

CONECTADOS=$(zm_conectados "$IZQ" "$DER")
MAL=0
for par in "$IZQ:izquierdo" "$DER:derecho"; do
  d=${par%%:*}; lado=${par##*:}
  echo
  if ! grep -q "$d" <<< "$CONECTADOS"; then
    echo "⚠️  $lado ($d) no está conectado: se salta"
    continue
  fi
  mkdir -p "$SALIDA/$lado"
  if ! zm_lista "$d" "$SALIDA/$lado/listado-antes.txt"; then
    echo "❌ $lado: sin listado del móvil"
    MAL=1
    continue
  fi
  echo "$lado ($d), lo que ocupa Zero:"
  $CANCHA ocupa "$SALIDA/$lado/listado-antes.txt" | sed 's/^/  /'
  [ -n "$BORRAR" ] || continue

  echo "$lado: Zero con RIG_PURGE_BENCH=1"
  zm_mata "$d"
  f=$(mktemp); echo '{"RIG_PURGE_BENCH": "1"}' > "$f"
  zm_lanza "$d" "$f" || echo "⚠️  no se pudo lanzar en $d (¿bloqueado?)"
  rm -f "$f"
  INFORME=""; t0=$(date +%s)
  while :; do
    sleep "$SONDEO_S"
    zm_lista "$d" "$SALIDA/$lado/listado-despues.txt" || true
    INFORME=$($CANCHA purga "$SALIDA/$lado/listado-antes.txt" "$SALIDA/$lado/listado-despues.txt")
    [ -n "$INFORME" ] && break
    [ $(( $(date +%s) - t0 )) -ge "$ESPERA_PURGA_S" ] && break
  done
  zm_mata "$d"
  if [ -z "$INFORME" ]; then
    echo "❌ $lado: en $ESPERA_PURGA_S s Zero no dejó bench/purge-*.json: la app instalada es anterior a"
    echo "   RIG_PURGE_BENCH y no borra nada. Instala una de ahora (tools/plan_b_cancha.sh preparar y volver)."
    MAL=1
    continue
  fi
  if zm_copia "$d" "$SALIDA/$lado" "$INFORME" >/dev/null; then
    $CANCHA resumen-purga "$SALIDA/$lado/$INFORME" | sed "s/^/$lado: /"
  fi
  echo "$lado, lo que queda:"
  $CANCHA ocupa "$SALIDA/$lado/listado-despues.txt" | sed 's/^/  /'
done
exit "$MAL"
