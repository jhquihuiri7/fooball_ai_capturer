#!/bin/bash
# La sesión de mesa de EMITIR con los dos iPhone (IOS-58), antes de la cancha: lo que se va a
# hacer allí (Zero desde el icono, Wi-Fi Aware, EMITIR en el 17 sin QR Soporte), con los dos
# por cable al Mac solo para instalar, mirar y recoger.
#
#   tools/sesion_emitir.sh <fichero_secreto> [--con-mac] [--sin-instalar] [--minutos N] [--con-4k]
#
# En una orden: compila sin AUTO_ROLE (la pantalla de lado), instala en los dos, cierra SOLO
# Zero, guarda el secreto del soporte en el Keychain de cada uno (un lanzamiento con
# RIG_LINK_SECRET; el secreto no sale por pantalla), cierra Zero, dice qué tocar, espera a que
# el maestro deje su informe de EMITIR (o a los N min, 45 por defecto) y recoge en
# bench/emitir-<fecha>/<lado>/ los informes, el latido y la copia .mov del programa. Al final,
# ffprobe de lo recogido y el veredicto (tools/cancha.py).
#
#   --con-mac       además, el «VPS» del Mac: MediaMTX (tools/mediamtx-programa.yml) y su QR
#                   Soporte (tools/qr_soporte_mac.sh), con la passphrase en un fichero 600 que
#                   se borra al acabar. Sin él, lo de la cancha: SIN DESTINO.
#   --sin-instalar  la app que ya está en los dos (desde 4fb5bf4: guarda el secreto al arrancar).
#   --con-4k        trae también las 4K (unos 3,4 GB cada 10 min y móvil).
#
# Los móviles, como en el banco: IZQ=<id devicectl del 17> DER=<id del 16 Pro>.
set -euo pipefail

SECRETO=${1:?fichero con el secreto del soporte (base64)}
shift
CON_MAC=""; SIN_INSTALAR=""; CON_4K=""; MINUTOS=45
while [ $# -gt 0 ]; do
  case "$1" in
    --con-mac) CON_MAC=1 ;;
    --sin-instalar) SIN_INSTALAR=1 ;;
    --con-4k) CON_4K=1 ;;
    --minutos) MINUTOS=${2:?minutos}; shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -r "$SECRETO" ] || { echo "no se puede leer $SECRETO" >&2; exit 2; }

IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17, el maestro
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
CANCHA="python3 $RAIZ/tools/cancha.py"
SONDEO_S=${SONDEO_S:-60}             # cada cuánto se mira si el maestro ya paró
ESPERA_ESCLAVO_S=${ESPERA_ESCLAVO_S:-20}  # lo que tarda el esclavo en escribir su informe tras PARAR
ARRANQUE_S=${ARRANQUE_S:-8}          # lo que se deja a Zero para guardar el secreto al arrancar
MARGEN_RELOJ_S=30                    # el reloj del móvil frente al del Mac
MAC_MIN_GB=10                        # lo libre en el Mac para compilar y traer la copia del programa

SALIDA=${SALIDA:-"$RAIZ/bench/emitir-$(date +%Y%m%d-%H%M)"}
mkdir -p "$SALIDA/izquierdo" "$SALIDA/derecho"
exec > >(tee -a "$SALIDA/sesion.log") 2>&1

paso() { echo; echo "== $(date +%T) $*"; }

paso "Los dos iPhone"
CONECTADOS=$(zm_conectados "$IZQ" "$DER")
for d in "$IZQ" "$DER"; do
  if ! grep -q "$d" <<< "$CONECTADOS"; then
    echo "❌ $d no está conectado: cable, desbloqueado y «Confiar en este ordenador»"
    exit 1
  fi
done
echo "✅ los dos conectados"
LIBRE_MAC_GB=$(df -Pk "$SALIDA" | awk 'NR == 2 {print int($4 * 1024 / 1e9)}')
if [ "$LIBRE_MAC_GB" -lt "$MAC_MIN_GB" ]; then
  echo "⚠️  el Mac tiene $LIBRE_MAC_GB GB libres: compilar y recoger piden ~$MAC_MIN_GB (con --con-4k, 4 GB más cada 10 min)"
fi

if [ -z "$SIN_INSTALAR" ]; then
  paso "Compilar sin AUTO_ROLE e instalar"
  RUNNER="$RAIZ/build/ios/iphoneos/Runner.app"
  # Sin la de antes: si la compilación falla, que no se instale una vieja.
  rm -rf "$RUNNER"
  if ! (cd "$RAIZ" && "$FLUTTER" build ios --release > "$SALIDA/flutter-build.log" 2>&1); then
    grep -E "rror" "$SALIDA/flutter-build.log" | head -20
    echo "❌ no compiló (todo en $SALIDA/flutter-build.log)"; exit 1
  fi
  grep -E "Built" "$SALIDA/flutter-build.log" || true
  [ -d "$RUNNER" ] || { echo "❌ no hay $RUNNER"; exit 1; }
  # La misma app, guardada para volver a ella tras el plan B (tools/plan_b_cancha.sh volver).
  mkdir -p "$RAIZ/build/cancha" && rm -rf "$RAIZ/build/cancha/emitir.app" && cp -R "$RUNNER" "$RAIZ/build/cancha/emitir.app"
  for d in "$IZQ" "$DER"; do
    zm_instala "$d" "$RUNNER" || { echo "❌ no se instaló en $d"; exit 1; }
  done
  echo "✅ instalada en los dos"
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

paso "El secreto del soporte al Keychain (un lanzamiento con RIG_LINK_SECRET)"
zm_mata "$IZQ"; zm_mata "$DER"
ENTORNO=$(zm_entorno "$SECRETO" '{}')
for d in "$IZQ" "$DER"; do
  zm_lanza "$d" "$ENTORNO" || echo "⚠️  no se pudo lanzar en $d (¿bloqueado?)"
done
rm -f "$ENTORNO"
sleep "$ARRANQUE_S"
zm_mata "$IZQ"; zm_mata "$DER"
echo "✅ guardado y Zero cerrada en los dos: a partir de aquí, desde el icono"

FRASE_DIR=""; MTX_PID=""
limpia() {
  [ -n "$MTX_PID" ] && kill "$MTX_PID" 2>/dev/null || true
  [ -n "$FRASE_DIR" ] && rm -rf "$FRASE_DIR" || true
}
trap limpia EXIT
if [ -n "$CON_MAC" ]; then
  paso "El «VPS» del Mac: MediaMTX y su QR Soporte"
  command -v mediamtx >/dev/null || { echo "❌ sin mediamtx (brew install mediamtx)"; exit 1; }
  FRASE_DIR=$(mktemp -d); chmod 700 "$FRASE_DIR"
  ( umask 077; openssl rand -hex 16 > "$FRASE_DIR/frase" )
  MTX_PATHS_PROGRAMA_SRTPUBLISHPASSPHRASE="$(cat "$FRASE_DIR/frase")" \
    mediamtx "$RAIZ/tools/mediamtx-programa.yml" > "$SALIDA/mediamtx.log" 2>&1 &
  MTX_PID=$!
  "$RAIZ/tools/qr_soporte_mac.sh" "$FRASE_DIR/frase" "$FRASE_DIR/qr-soporte.svg"
  open "$FRASE_DIR/qr-soporte.svg" 2>/dev/null || echo "abre $FRASE_DIR/qr-soporte.svg"
fi

INICIO=$(date +%s)
DESDE=$(( INICIO - MARGEN_RELOJ_S ))
echo "$INICIO" > "$SALIDA/inicio.txt"

paso "Ahora, en los iPhone (Zero desde el icono, como en la cancha)"
cat <<EOF
 1. Los dos en modo avión CON la Wi-Fi encendida y «No molestar», como en la cancha: sin
    llamadas ni datos (Wi-Fi Aware solo necesita la Wi-Fi). Sin red, «Red local» puede salir NO
    PERMITIDA y «Abrir cámara» tardar ~20 s: apúntalo. Si el enlace Aware no sube en modo avión,
    sin modo avión y con los datos móviles apagados. Batería externa si la hay.
 2. En el 17: lado IZQUIERDA y «Este móvil dirige». En el 16 Pro: DERECHA.
 3. «Enlace y emisión»: Aware en los dos. Si no se ven (o tras reinstalar), «Emparejar sin
    cable»: el derecho elige al 17 y teclea su código.
EOF
if [ -n "$CON_MAC" ]; then
  echo " 4. Los dos en la Wi-Fi del Mac (en modo avión también se puede unir). Tarjeta VPS: «Escanear"
  echo "    QR Soporte» contra la pantalla del Mac, en los dos."
else
  echo " 4. Tarjeta VPS vacía en el 17 («Olvidar» si había uno): en la cancha sale SIN DESTINO y el"
  echo "    programa se graba en el móvil."
fi
cat <<EOF
 5. «Abrir cámara» en los dos. Esperar LISTA: Enlace conectado, Reloj y Fase. Mira «Disco
    libre» (≥ 50 GB para 2 h; si no, borra bench/ y bench4k/ viejos en Archivos → En mi
    iPhone → Zero) y «Batería».
 6. En el 17: «Guardar vídeo» encendido y EMITIR. El 16 Pro pasa solo a EMITIENDO.
 7. Unos 10 min. Y lo que puede pasar en la cancha (cada cosa, después de 2-3 min normales):
    a) en el 16 Pro, cerrar Zero (deslizar), abrirla y «Abrir cámara»: vuelve solo al programa;
    b) en el 17, el botón lateral 10 s y desbloquear: el programa tiene que seguir (Programa a
       ~30 fps), y la 4K en un segmento nuevo;
    c) en el 17, otra app 10 s y volver.
 8. PARAR en el 17 (el 16 Pro para solo; si no, PARAR también en él).
Este guion mira el maestro cada $SONDEO_S s y recoge en cuanto haya informe (como mucho, $MINUTOS min).
EOF

paso "Esperando a que el maestro pare"
FIN=$(( $(date +%s) + MINUTOS * 60 ))
VISTO=""; SRT_MIRADO=""; ESTADO="nada"
while :; do
  if zm_lista "$IZQ" "$SALIDA/izquierdo/listado.txt"; then
    ESTADO=$($CANCHA estado "$SALIDA/izquierdo/listado.txt" "$DESDE")
    case "$ESTADO" in
      parado*) echo "$(date +%T) el maestro paró: ${ESTADO#parado }"; break ;;
      emitiendo*)
        set -- $ESTADO
        if [ "$2" != "$VISTO" ]; then echo "$(date +%T) EMITIENDO: $2"; VISTO=$2; fi
        echo "$(date +%T)   $2: $3 MB"
        if [ -n "$CON_MAC" ] && [ -z "$SRT_MIRADO" ]; then
          SRT_MIRADO=1
          if ffprobe -v error -rtsp_transport tcp -timeout 8000000 -show_entries stream=codec_name,width,height \
            -of compact rtsp://127.0.0.1:8554/programa > "$SALIDA/rtsp.txt" 2>&1 && grep -q h264 "$SALIDA/rtsp.txt"; then
            echo "✅ el programa llega al MediaMTX del Mac: $(tr '\n' ' ' < "$SALIDA/rtsp.txt")"
          else
            echo "❌ el programa NO llega al MediaMTX del Mac ($(head -1 "$SALIDA/rtsp.txt"))"
          fi
        fi
        ;;
    esac
  else
    echo "$(date +%T) sin listado del maestro (¿cable?)"
  fi
  if [ "$(date +%s)" -ge "$FIN" ]; then echo "$(date +%T) se acabó la espera ($MINUTOS min): se recoge lo que haya"; break; fi
  sleep "$SONDEO_S"
done
case "$ESTADO" in parado*) sleep "$ESPERA_ESCLAVO_S" ;; esac

recoge_lado() {  # $1 dispositivo, $2 lado
  local dir="$SALIDA/$2" f tam
  : > "$dir/no-copiados.txt"
  if ! zm_lista "$1" "$dir/listado.txt"; then
    echo "❌ $2: sin listado del móvil: no se recoge nada de este lado"
    return 0
  fi
  echo "$2: $($CANCHA espacio "$dir/listado.txt" "$DESDE")"
  for f in $($CANCHA informes "$dir/listado.txt" "$DESDE"); do zm_copia "$1" "$dir" "$f" || true; done
  while read -r f tam; do
    [ -n "$f" ] || continue
    zm_copia "$1" "$dir" "$f" || true
  done < <($CANCHA medios "$dir/listado.txt" "$DESDE" 1)
  local k4; k4=$($CANCHA k4 "$dir/listado.txt" "$DESDE")
  if [ -z "$k4" ]; then
    echo "⚠️  $2: sin 4K de esta pasada en el móvil («Guardar vídeo» apagado o sin la reserva de disco)"
  fi
  while read -r f tam; do
    [ -n "$f" ] || continue
    if [ -n "$CON_4K" ]; then
      echo "✅ $2: 4K $f ($(( tam / 1000000 )) MB), se trae"
      zm_copia "$1" "$dir" "$f" || true
    else
      echo "✅ $2: 4K $f ($(( tam / 1000000 )) MB), se queda en el móvil"
    fi
  done <<< "$k4"
}

paso "Recogiendo"
recoge_lado "$IZQ" izquierdo || echo "izquierdo: la recogida falló a medias"
recoge_lado "$DER" derecho || echo "derecho: la recogida falló a medias"
if [ -n "$CON_MAC" ]; then
  echo "MediaMTX: $(grep -c "is publishing to path 'programa'" "$SALIDA/mediamtx.log" || true) publicaciones del programa"
fi

paso "Los vídeos recogidos (ffprobe)"
$CANCHA verificar "$SALIDA" || true
paso "Veredicto"
$CANCHA veredicto "$SALIDA" "$DESDE" || true
echo
echo "Todo en $SALIDA"
