#!/bin/bash
# EMITIR sin tocar la pantalla con los dos iPhone (2026-10-15): el camino de producción de los
# toques (lado, «Este móvil dirige», «Enlace y emisión», «Abrir cámara», EMITIR y PARAR), no el
# banco split. Ver lib/src/auto_emitir.dart.
#
#   tools/emitir_auto.sh <fichero_secreto> <segundos> [--link aware|wifi] [--con-4k] [--sin-instalar]
#
# Compila el izquierdo y el derecho con AUTO_ROLE, AUTO_EMITIR, AUTO_LINK y AUTO_EMITIR_S,
# instala, cierra SOLO Zero, lanza los dos con RIG_LINK_SECRET (y nada más del banco: sin
# RIG_SPLIT ni RIG_LINK_*; el secreto no sale por pantalla), espera a que el maestro pare (los
# <segundos> de EMITIR más lo que tarde en estar LISTA) y recoge en bench/emitir-auto-<fecha>/
# los informes, el latido, el registro auto-emitir-<lado>-<t>.log y la copia .mov del programa
# (~2,7 GB/h). Al final, ffprobe y el veredicto (tools/cancha.py), como sesion_emitir.sh.
#
#   --link      el enlace de «Enlace y emisión»: aware (por defecto, el de la cancha) o wifi.
#   --con-4k    «Guardar vídeo» encendido (AUTO_EMITIR_4K): la 4K se graba y se queda en el móvil.
#   --sin-instalar  las apps que ya están (compiladas con estos mismos defines).
#
# Sin destino salvo que el 17 tenga un QR Soporte en el Keychain («Olvidar» en la tarjeta VPS).
# Los móviles, como en el banco: IZQ=<id devicectl del 17> DER=<id del 16 Pro>.
set -euo pipefail

SECRETO=${1:?fichero con el secreto del soporte (base64)}
SEG=${2:?segundos de EMITIR}
shift 2
LINK=aware; CON_4K=""; SIN_INSTALAR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --link) LINK=${2:?aware o wifi}; shift ;;
    --con-4k) CON_4K=1 ;;
    --sin-instalar) SIN_INSTALAR=1 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LINK" in aware|wifi) ;; *) echo "--link aware o wifi, no $LINK" >&2; exit 2 ;; esac
case "$SEG" in ''|*[!0-9]*) echo "segundos: un entero, no $SEG" >&2; exit 2 ;; esac
[ -r "$SECRETO" ] || { echo "no se puede leer $SECRETO" >&2; exit 2; }

IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17, el maestro
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
RUNNER=${RUNNER:-"$RAIZ/build/ios/iphoneos/Runner.app"}
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
CANCHA="python3 $RAIZ/tools/cancha.py"
SONDEO_S=${SONDEO_S:-60}                  # cada cuánto se mira si el maestro ya paró
ESPERA_ESCLAVO_S=${ESPERA_ESCLAVO_S:-20}  # lo que tarda el esclavo en escribir su informe tras PARAR
LISTA_TOPE_S=300                          # autoEmitirReadyTimeout: lo que el maestro espera a LISTA
ASIENTO_S=20                              # autoEmitirSlaveSettle: reloj y fase del esclavo
MARGEN_FIN_S=${MARGEN_FIN_S:-180}         # PARAR, cerrar la copia y escribir los informes
MARGEN_RELOJ_S=30                         # el reloj del móvil frente al del Mac
MOV_MB_POR_S=0.75                         # la copia del programa: 6 Mbit/s + AAC, ~2,7 GB/h

SALIDA=${SALIDA:-"$RAIZ/bench/emitir-auto-$(date +%Y%m%d-%H%M)"}
mkdir -p "$SALIDA/izquierdo" "$SALIDA/derecho"
exec > >(tee -a "$SALIDA/sesion.log") 2>&1

paso() { echo; echo "== $(date +%T) $*"; }

paso "Los dos iPhone"
CONECTADOS=$(zm_conectados "$IZQ" "$DER")
for d in "$IZQ" "$DER"; do
  if ! grep -q "$d" <<< "$CONECTADOS"; then
    echo "❌ $d no está conectado: cable (o la red), desbloqueado y «Confiar en este ordenador»"
    exit 1
  fi
done
echo "✅ los dos conectados"
MOV_GB=$(awk -v s="$SEG" -v r="$MOV_MB_POR_S" 'BEGIN {print int(s * r / 1000) + 1}')
LIBRE_MAC_GB=$(df -Pk "$SALIDA" | awk 'NR == 2 {print int($4 * 1024 / 1e9)}')
echo "el Mac tiene $LIBRE_MAC_GB GB libres; la copia del programa de $SEG s son ~$MOV_GB GB"
if [ "$LIBRE_MAC_GB" -lt $(( MOV_GB + 2 )) ]; then
  echo "⚠️  puede no caber la copia del programa: se intenta igual (lo que no se copie, en no-copiados.txt)"
fi

if [ -z "$SIN_INSTALAR" ]; then
  DEFINES="--dart-define=AUTO_EMITIR=true --dart-define=AUTO_LINK=$LINK --dart-define=AUTO_EMITIR_S=$SEG"
  [ -n "$CON_4K" ] && DEFINES="$DEFINES --dart-define=AUTO_EMITIR_4K=true"
  for par in "$IZQ:left" "$DER:right"; do
    d=${par%%:*}; lado=${par##*:}
    paso "Compilar e instalar el $lado ($DEFINES)"
    # Sin la de antes: si la compilación falla, que no se instale la del otro lado.
    rm -rf "$RUNNER"
    # shellcheck disable=SC2086
    if ! (cd "$RAIZ" && "$FLUTTER" build ios --release --dart-define=AUTO_ROLE=$lado $DEFINES \
        > "$SALIDA/flutter-build-$lado.log" 2>&1); then
      grep -E "rror" "$SALIDA/flutter-build-$lado.log" | head -20
      echo "❌ no compiló el $lado (todo en $SALIDA/flutter-build-$lado.log)"; exit 1
    fi
    grep -E "Built" "$SALIDA/flutter-build-$lado.log" || true
    [ -d "$RUNNER" ] || { echo "❌ no hay $RUNNER"; exit 1; }
    zm_instala "$d" "$RUNNER" || { echo "❌ no se instaló en $d"; exit 1; }
    echo "✅ instalada en el $lado"
  done
fi

paso "Lo que EMITIR busca en cada móvil"
for par in "$IZQ:izquierdo" "$DER:derecho"; do
  d=${par%%:*}; lado=${par##*:}
  if zm_lista "$d" "$SALIDA/$lado/listado-antes.txt"; then
    $CANCHA recursos "$SALIDA/$lado/listado-antes.txt" | sed "s/^/$lado: /"
    echo "$lado: $($CANCHA espacio "$SALIDA/$lado/listado-antes.txt" "$(date +%s)")"
  else
    echo "⚠️  $lado: sin listado del móvil"
  fi
done

paso "Lanzar los dos (solo RIG_LINK_SECRET en el entorno)"
zm_mata "$IZQ"; zm_mata "$DER"
INICIO=$(date +%s)
DESDE=$(( INICIO - MARGEN_RELOJ_S ))
echo "$INICIO" > "$SALIDA/inicio.txt"
ENTORNO=$(zm_entorno "$SECRETO" '{}')
trap 'rm -f "$ENTORNO"' EXIT
for d in "$IZQ" "$DER"; do
  zm_lanza "$d" "$ENTORNO" || echo "⚠️  no se pudo lanzar en $d (¿bloqueado?)"
done
rm -f "$ENTORNO"
TOPE_S=$(( LISTA_TOPE_S + ASIENTO_S + SEG + MARGEN_FIN_S ))
echo "✅ lanzados a las $(date -r "$INICIO" +%T): EMITIR sale solo con LISTA; PARAR a los $SEG s de EMITIR."
echo "   Se espera como mucho $(( TOPE_S / 60 )) min (hasta las $(date -r $(( INICIO + TOPE_S )) +%T))."

paso "Esperando a que el maestro pare"
FIN=$(( INICIO + TOPE_S ))
VISTO=""; ESTADO="nada"
while :; do
  if zm_lista "$IZQ" "$SALIDA/izquierdo/listado.txt"; then
    ESTADO=$($CANCHA estado "$SALIDA/izquierdo/listado.txt" "$DESDE")
    case "$ESTADO" in
      parado*) echo "$(date +%T) el maestro paró: ${ESTADO#parado }"; break ;;
      emitiendo*)
        set -- $ESTADO
        if [ "$2" != "$VISTO" ]; then echo "$(date +%T) EMITIENDO: $2"; VISTO=$2; fi
        echo "$(date +%T)   $2: $3 MB"
        ;;
      *) echo "$(date +%T) todavía sin EMITIR" ;;
    esac
  else
    echo "$(date +%T) sin listado del maestro (¿cable?)"
  fi
  if [ "$(date +%s)" -ge "$FIN" ]; then echo "$(date +%T) se acabó la espera: se recoge lo que haya"; break; fi
  sleep "$SONDEO_S"
done
case "$ESTADO" in parado*) sleep "$ESPERA_ESCLAVO_S" ;; esac

recoge_lado() {  # $1 dispositivo, $2 lado
  local dir="$SALIDA/$2" f tam t
  : > "$dir/no-copiados.txt"
  if ! zm_lista "$1" "$dir/listado.txt"; then
    echo "❌ $2: sin listado del móvil: no se recoge nada de este lado"
    return 0
  fi
  echo "$2: $($CANCHA espacio "$dir/listado.txt" "$DESDE")"
  for f in $($CANCHA informes "$dir/listado.txt" "$DESDE"); do zm_copia "$1" "$dir" "$f" || true; done
  # El registro del modo automático (lib/src/auto_emitir.dart), solo el de esta pasada.
  for f in $(grep -oE 'Documents/bench/auto-emitir-(left|right)-[0-9]+\.log' "$dir/listado.txt" | sort -u); do
    t=${f##*-}; t=${t%.log}
    [ "$t" -ge "$DESDE" ] && { zm_copia "$1" "$dir" "${f#Documents/}" || true; }
  done
  while read -r f tam; do
    [ -n "$f" ] || continue
    zm_copia "$1" "$dir" "$f" || true
  done < <($CANCHA medios "$dir/listado.txt" "$DESDE" 1)
  while read -r f tam; do
    [ -n "$f" ] || continue
    echo "✅ $2: 4K $f ($(( tam / 1000000 )) MB), se queda en el móvil"
  done < <($CANCHA k4 "$dir/listado.txt" "$DESDE")
}

paso "Recogiendo"
recoge_lado "$IZQ" izquierdo || echo "izquierdo: la recogida falló a medias"
recoge_lado "$DER" derecho || echo "derecho: la recogida falló a medias"

paso "El modo automático, paso a paso"
for lado in izquierdo derecho; do
  REG=$(ls "$SALIDA/$lado"/bench/auto-emitir-*.log 2>/dev/null | tail -1 || true)
  if [ -z "$REG" ]; then
    echo "⚠️  $lado: sin registro auto-emitir (¿la app compilada sin AUTO_EMITIR?)"
    continue
  fi
  grep -E "LISTA|EMITIR|EMITIENDO|PARAR|parado|esclavo|no arrancó|paró" "$REG" | sed "s/^/$lado: /" || true
done

paso "Los vídeos recogidos (ffprobe)"
$CANCHA verificar "$SALIDA" || true
paso "Veredicto"
$CANCHA veredicto "$SALIDA" "$DESDE" || true
echo
echo "Todo en $SALIDA"
