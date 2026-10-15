#!/bin/bash
# El plan B de la cancha: si EMITIR desde la pantalla falla, el banco split largo que sí está
# probado en los dos iPhone (Wi-Fi Aware, director, CenterNet, micro y la 4K de cada uno),
# lanzado desde el Mac con los iPhone por cable. Se lanza y se suelta: los cables se pueden
# quitar, la pasada termina sola a los <segundos> y escribe su informe. Se recoge después,
# en casa, con tools/recoger_partido.sh.
#
#   tools/plan_b_cancha.sh preparar                          # EN CASA, con internet
#   tools/plan_b_cancha.sh lanzar <fichero_secreto> [segundos]  # en la cancha (7200 por defecto)
#   tools/plan_b_cancha.sh volver                            # otra vez la app de EMITIR
#
# preparar: compila las tres apps (la de banco de cada lado, con AUTO_ROLE, y la de EMITIR) y
#   las guarda en build/cancha/: en la cancha no se compila (la firma puede pedir red).
# lanzar: tools/banco_dos_moviles.sh split con SOLO_LANZAR=1, APPS=build/cancha y el entorno de
#   abajo. Sin las apps guardadas no instala nada: con la app de EMITIR, en cada móvil hay que
#   elegir el lado y «Abrir cámara» (el banco arranca entonces; no pulsar EMITIR).
# volver: instala build/cancha/emitir.app en los dos (la deja sesion_emitir.sh y preparar).
#
# Lo que graba en 2 h (7200 s): el maestro, la copia .mov del programa a 6 Mbit/s (5,4 GB), las
# vistas por instante (~0,2 GB), el N0, el audio y su 4K a 45 Mbit/s (40,5 GB); el esclavo, su
# 4K. La 4K pide 42,5 GB libres al arrancar (RecordingPolicy.benchReserveBytes) y se cierra con
# menos de 2 GB. Sin el .ts del banco (RIG_SPLIT_NO_TS): es otra copia del programa.
# PLAN_B_EXTRA cambia el entorno (JSON).
set -euo pipefail

ORDEN=${1:?preparar, lanzar o volver}
IZQ=${IZQ:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # iPhone 17
DER=${DER:-11BE5E85-F450-5C4B-B19E-ADA3EF036831}   # iPhone 16 Pro
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
APP=com.logicielapplab.zero
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
APPS=${CANCHA_APPS:-"$RAIZ/build/cancha"}
# shellcheck source=tools/zero_movil.sh
source "$RAIZ/tools/zero_movil.sh"
PLAN_B_EXTRA=${PLAN_B_EXTRA:-'{"RIG_LINK_INTERFACE": "aware", "RIG_AUDIO": "1", "RIG_SPLIT_DIRECTOR": "1", "RIG_DETECT": "players-centernet-mnv4.mlpackage", "RIG_SPLIT_RECORD_4K": "1", "RIG_SPLIT_NO_TS": "1"}'}
SEG_DEFECTO=7200   # 2 h: calentamiento, dos partes de 45 min, el descanso y margen
PREPARAR_MIN_GB=5  # lo libre en el Mac para compilar las tres apps

compila() {  # $1 nombre en build/cancha, $2 dart-defines
  local runner="$RAIZ/build/ios/iphoneos/Runner.app"
  rm -rf "$runner"
  echo "$(date +%T) compilando $1"
  (cd "$RAIZ" && "$FLUTTER" build ios --release $2 > "$APPS/$1.log" 2>&1) || { echo "❌ $1 no compiló: $APPS/$1.log"; exit 1; }
  rm -rf "${APPS:?}/$1.app" && cp -R "$runner" "$APPS/$1.app"
}

case "$ORDEN" in
  preparar)
    mkdir -p "$APPS"
    libre=$(df -Pk "$APPS" | awk 'NR == 2 {print int($4 * 1024 / 1e9)}')
    [ "$libre" -ge "$PREPARAR_MIN_GB" ] || echo "⚠️  el Mac tiene $libre GB libres: compilar tres veces puede no caber"
    compila auto-left "--dart-define=AUTO_ROLE=left"
    compila auto-right "--dart-define=AUTO_ROLE=right"
    compila emitir ""
    git -C "$RAIZ" rev-parse --short HEAD > "$APPS/VERSION"
    echo "✅ en $APPS: auto-left.app, auto-right.app y emitir.app ($(cat "$APPS/VERSION"))"
    ;;
  lanzar)
    SECRETO=${2:?fichero con el secreto del soporte}
    SEG=${3:-$SEG_DEFECTO}
    CONECTADOS=$(zm_conectados "$IZQ" "$DER")
    for d in "$IZQ" "$DER"; do
      grep -q "$d" <<< "$CONECTADOS" || { echo "❌ $d no está conectado (cable, desbloqueado, «Confiar»)"; exit 1; }
    done
    if [ -d "$APPS/auto-left.app" ] && [ -d "$APPS/auto-right.app" ]; then
      echo "Las apps de banco de $APPS ($(cat "$APPS/VERSION" 2>/dev/null || echo '?'))"
      APPS="$APPS" SOLO_LANZAR=1 BANCO_EXTRA="$PLAN_B_EXTRA" "$RAIZ/tools/banco_dos_moviles.sh" split "$SECRETO" "$SEG"
    else
      echo "⚠️  Sin las apps de banco guardadas ($APPS): se lanza la que hay instalada."
      echo "   En cada móvil, al abrirse: su lado y «Abrir cámara» (el banco arranca ahí). NO pulses EMITIR."
      SIN_INSTALAR=1 SOLO_LANZAR=1 BANCO_EXTRA="$PLAN_B_EXTRA" "$RAIZ/tools/banco_dos_moviles.sh" split "$SECRETO" "$SEG"
    fi
    ;;
  volver)
    [ -d "$APPS/emitir.app" ] || { echo "❌ no hay $APPS/emitir.app: tools/plan_b_cancha.sh preparar o sesion_emitir.sh"; exit 1; }
    for d in "$IZQ" "$DER"; do
      zm_mata "$d"
      zm_instala "$d" "$APPS/emitir.app" && echo "✅ EMITIR instalada en $d" || echo "❌ no se instaló en $d"
    done
    ;;
  *) echo "orden desconocida: $ORDEN" >&2; exit 2 ;;
esac
