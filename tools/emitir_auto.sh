#!/bin/bash
# EMITIR sin tocar la pantalla con los dos iPhone (2026-10-15): el camino de producción de los
# toques (lado, «Este móvil dirige», «Enlace y emisión», «Abrir cámara», EMITIR y PARAR), no el
# banco split. Ver lib/src/auto_emitir.dart.
#
#   tools/emitir_auto.sh <fichero_secreto> <segundos> [--link aware|wifi|single] [--lado left|right]
#                        [--con-4k] [--sin-instalar]
#
# Compila el izquierdo y el derecho con AUTO_ROLE, AUTO_EMITIR, AUTO_LINK y AUTO_EMITIR_S,
# instala, cierra SOLO Zero, lanza los dos con RIG_LINK_SECRET (y nada más del banco: sin
# RIG_SPLIT ni RIG_LINK_*; el secreto no sale por pantalla), espera a que el maestro pare (los
# <segundos> de EMITIR más lo que tarde en estar LISTA) y recoge en bench/emitir-auto-<fecha>/
# los informes, el latido, el registro auto-emitir-<lado>-<t>.log y la copia .mov del programa
# (~2,7 GB/h). Al final, ffprobe y el veredicto (tools/cancha.py), como sesion_emitir.sh.
#
#   --link      el enlace de «Enlace y emisión»: aware (por defecto, el de la cancha) o wifi; o
#               single, «Una cámara (sin pareja)» (2026-10-15): UN solo móvil, el de --lado, que
#               emite solo con su cámara. No hace falta el otro conectado; ni se compila ni se toca.
#   --lado      con --link single, qué móvil: left (IZQ, por defecto) o right (DER).
#   --con-4k    «Guardar vídeo» encendido (AUTO_EMITIR_4K): la 4K se graba y se queda en el móvil.
#   --sin-instalar  las apps que ya están (compiladas con estos mismos defines).
#
# Sin destino salvo que el 17 tenga un QR Soporte en el Keychain («Olvidar» en la tarjeta VPS).
# Los móviles, como en el banco: IZQ=<id devicectl del 17> DER=<id del 16 Pro>.
set -euo pipefail

SECRETO=${1:?fichero con el secreto del soporte (base64)}
SEG=${2:?segundos de EMITIR}
shift 2
LINK=aware; LADO=left; CON_4K=""; SIN_INSTALAR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --link) LINK=${2:?aware, wifi o single}; shift ;;
    --lado) LADO=${2:?left o right}; shift ;;
    --con-4k) CON_4K=1 ;;
    --sin-instalar) SIN_INSTALAR=1 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LINK" in aware|wifi|single) ;; *) echo "--link aware, wifi o single, no $LINK" >&2; exit 2 ;; esac
case "$LADO" in left|right) ;; *) echo "--lado left o right, no $LADO" >&2; exit 2 ;; esac
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

# Los móviles de la pasada, «dispositivo:lado:carpeta», y el que emite (el primero). Con
# «Una cámara» (--link single), solo el de --lado, y sin esclavo al que dejar asentar.
if [ "$LINK" = single ]; then
  if [ "$LADO" = right ]; then MOVILES="$DER:right:derecho"; else MOVILES="$IZQ:left:izquierdo"; fi
  ASIENTO_S=0
else
  MOVILES="$IZQ:left:izquierdo $DER:right:derecho"
fi
EMISOR=${MOVILES%% *}; EMISOR_ID=${EMISOR%%:*}; EMISOR_DIR=${EMISOR##*:}

SALIDA=${SALIDA:-"$RAIZ/bench/emitir-auto-$(date +%Y%m%d-%H%M)"}
for m in $MOVILES; do mkdir -p "$SALIDA/${m##*:}"; done
exec > >(tee -a "$SALIDA/sesion.log") 2>&1

paso() { echo; echo "== $(date +%T) $*"; }

if [ "$LINK" = single ]; then
  paso "Una cámara (sin pareja): el $EMISOR_DIR ($EMISOR_ID), solo"
else
  paso "Los dos iPhone"
fi
CONECTADOS=$(zm_conectados $(for m in $MOVILES; do echo "${m%%:*}"; done))
for m in $MOVILES; do
  d=${m%%:*}
  if ! grep -q "$d" <<< "$CONECTADOS"; then
    echo "❌ $d no está conectado: cable (o la red), desbloqueado y «Confiar en este ordenador»"
    exit 1
  fi
done
[ "$LINK" = single ] && echo "✅ conectado (el otro móvil no hace falta)" || echo "✅ los dos conectados"
MOV_GB=$(awk -v s="$SEG" -v r="$MOV_MB_POR_S" 'BEGIN {print int(s * r / 1000) + 1}')
LIBRE_MAC_GB=$(df -Pk "$SALIDA" | awk 'NR == 2 {print int($4 * 1024 / 1e9)}')
echo "el Mac tiene $LIBRE_MAC_GB GB libres; la copia del programa de $SEG s son ~$MOV_GB GB"
if [ "$LIBRE_MAC_GB" -lt $(( MOV_GB + 2 )) ]; then
  echo "⚠️  puede no caber la copia del programa: se intenta igual (lo que no se copie, en no-copiados.txt)"
fi

if [ -z "$SIN_INSTALAR" ]; then
  DEFINES="--dart-define=AUTO_EMITIR=true --dart-define=AUTO_LINK=$LINK --dart-define=AUTO_EMITIR_S=$SEG"
  [ -n "$CON_4K" ] && DEFINES="$DEFINES --dart-define=AUTO_EMITIR_4K=true"
  for m in $MOVILES; do
    d=${m%%:*}; lado=${m#*:}; lado=${lado%%:*}
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
for m in $MOVILES; do
  d=${m%%:*}; lado=${m##*:}
  if zm_lista "$d" "$SALIDA/$lado/listado-antes.txt"; then
    $CANCHA recursos "$SALIDA/$lado/listado-antes.txt" | sed "s/^/$lado: /"
    echo "$lado: $($CANCHA espacio "$SALIDA/$lado/listado-antes.txt" "$(date +%s)")"
  else
    echo "⚠️  $lado: sin listado del móvil"
  fi
done

paso "Lanzar (solo RIG_LINK_SECRET en el entorno)"
for m in $MOVILES; do zm_mata "${m%%:*}"; done
INICIO=$(date +%s)
DESDE=$(( INICIO - MARGEN_RELOJ_S ))
echo "$INICIO" > "$SALIDA/inicio.txt"
ENTORNO=$(zm_entorno "$SECRETO" '{}')
trap 'rm -f "$ENTORNO"' EXIT
for m in $MOVILES; do
  d=${m%%:*}
  zm_lanza "$d" "$ENTORNO" || echo "⚠️  no se pudo lanzar en $d (¿bloqueado?)"
done
rm -f "$ENTORNO"
TOPE_S=$(( LISTA_TOPE_S + ASIENTO_S + SEG + MARGEN_FIN_S ))
echo "✅ lanzado(s) a las $(date -r "$INICIO" +%T): EMITIR sale solo con LISTA; PARAR a los $SEG s de EMITIR."
echo "   Se espera como mucho $(( TOPE_S / 60 )) min (hasta las $(date -r $(( INICIO + TOPE_S )) +%T))."

paso "Esperando a que el maestro pare"
FIN=$(( INICIO + TOPE_S ))
VISTO=""; ESTADO="nada"
while :; do
  if zm_lista "$EMISOR_ID" "$SALIDA/$EMISOR_DIR/listado.txt"; then
    ESTADO=$($CANCHA estado "$SALIDA/$EMISOR_DIR/listado.txt" "$DESDE")
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
for m in $MOVILES; do
  recoge_lado "${m%%:*}" "${m##*:}" || echo "${m##*:}: la recogida falló a medias"
done

paso "El modo automático, paso a paso"
for m in $MOVILES; do
  lado=${m##*:}
  REG=$(ls "$SALIDA/$lado"/bench/auto-emitir-*.log 2>/dev/null | tail -1 || true)
  if [ -z "$REG" ]; then
    echo "⚠️  $lado: sin registro auto-emitir (¿la app compilada sin AUTO_EMITIR?)"
    continue
  fi
  grep -E "LISTA|EMITIR|EMITIENDO|PARAR|parado|esclavo|no arrancó|paró|una cámara" "$REG" | sed "s/^/$lado: /" || true
done

paso "Los vídeos recogidos (ffprobe)"
$CANCHA verificar "$SALIDA" || true
paso "Veredicto"
$CANCHA veredicto "$SALIDA" "$DESDE" || true
echo
echo "Todo en $SALIDA"
