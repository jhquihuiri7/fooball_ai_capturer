#!/bin/bash
# Pruebas de los guiones de la cancha con un devicectl falso (tools/fake_xcrun.py), sin iPhone:
#   tools/test_guiones_cancha.sh
# sesion_emitir.sh (espera, recoge y veredicto; el secreto nunca sale), recoger_partido.sh (la
# última pasada, la app que murió a mitad, --sin-4k y --desde) y plan_b_cancha.sh (lanzar y
# soltar con las apps guardadas, y volver) y calibrar_cancha.sh (calibra e instala, --solo-comprobar,
# no calibra y no toca, sin fotos). Ninguno puede cerrar otra app que no sea Zero. Con ffmpeg, los vídeos de prueba son de verdad (y uno, fragmentado y cortado a mitad).
set -uo pipefail

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
# CONSERVA=1 deja la carpeta de la prueba para mirarla.
[ -n "${CONSERVA:-}" ] && echo "prueba en $T" || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/bash\nexec python3 %q "$@"\n' "$RAIZ/tools/fake_xcrun.py" > "$T/bin/xcrun"
chmod +x "$T/bin/xcrun"
export PATH="$T/bin:$PATH" FAKE_DIR="$T/fake" ZM_LISTADO_PAUSA_S_PRUEBA=0
IZQ=IZQ-17; DER=DER-16PRO
export IZQ DER

BIEN=0; MAL=0
ok() { BIEN=$(( BIEN + 1 )); echo "  ✓ $1"; }
falla() { MAL=$(( MAL + 1 )); echo "  ✗ $1"; }
espera_que() {  # $1 descripción, $2… la orden
  local d=$1; shift
  if "$@"; then ok "$d"; else falla "$d"; fi
}
tiene() { grep -q -- "$2" "$1"; }
no_tiene() { ! grep -q -- "$2" "$1"; }

SECRETO="$T/secreto"
python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())' > "$SECRETO"
VALOR=$(cat "$SECRETO")

# Vídeos de prueba: uno entero y uno fragmentado cortado a mitad (como una app que muere).
FIX="$T/fix"; mkdir -p "$FIX"
HAY_FFMPEG=""
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  HAY_FFMPEG=1
  ffmpeg -v error -f lavfi -i testsrc=size=320x180:rate=30 -t 4 -c:v mpeg4 -g 15 "$FIX/entero.mov"
  ffmpeg -v error -f lavfi -i testsrc=size=320x180:rate=30 -t 8 -c:v mpeg4 -g 15 \
    -movflags +frag_keyframe+empty_moov "$FIX/frag.mov"
  head -c $(( $(stat -f %z "$FIX/frag.mov") / 2 )) "$FIX/frag.mov" > "$FIX/cortado.mov"
else
  echo "(sin ffmpeg: vídeos de mentira, sin comprobar con ffprobe)"
  printf 'no es un mov' > "$FIX/entero.mov"; cp "$FIX/entero.mov" "$FIX/cortado.mov"
fi

informe() {  # $1 fichero, $2 papel, $3 propósito, $4 lado, $5 t, $6 final (true/false), [$7 latido]
  python3 - "$@" <<'PY'
import json, sys
f, papel, prop, lado, t, final = sys.argv[1:7]
latido = len(sys.argv) > 7
t = int(t)
d = {"name": "program-live" if latido else "program-split", "purpose": prop, "side": lado,
     "role": papel, "device": "iPhone18,3" if lado == "left" else "iPhone17,1", "elapsed_s": 600.0,
     "finished": final == "true", "rig": "rig.json", "problem": "", "bench_start_unix_ms": t * 1000,
     "footprint_mb": [360, 470, 478, 480, 482, 483, 483, 484, 484, 485],
     "thermal_by_minute": ["nominal"] * 4 + ["fair"] * 6, "battery_by_minute": [0.9 - 0.01 * i for i in range(10)],
     "disk_free_gb_by_minute": [80.0 - 0.4 * i for i in range(10)], "app_events": []}
if papel == "master":
    d.update({"program_frames": 18000, "two_lens_frames": 9000, "one_lens_frames": 9000, "part_fallbacks": 12,
              "torn_frames": 0, "added_latency_ms_p50": 141.0, "added_latency_ms_p95": 143.0, "program_fps_p5": 29.2,
              "mov_video_frames": 18000, "mov_segments": 1, "mov_failures": [],
              "files": {"mov": f"program-zero-{t}.mov", "mov_segments": [f"program-zero-{t}.mov"],
                        "e0": f"n0/zero-{t}-left.jsonl"},
              "publish": {"requested": True, "target": {"source": "none"}, "sessions": []},
              "detect": {"runs": 4500, "error": ""}, "peer_states": [], "vt_session_resets": {}})
else:
    d.update({"slave_parts": 17500, "slave_no_parts": 400, "slave_without_view": 3, "slave_render_failures": 0,
              "files": {}})
if latido:  # como lo escribe SplitBench.writeLive: lo de ahora, sin percentiles
    d.update({"footprint_mb": 485.0, "thermal": "fair", "battery": 0.81, "disk_free_gb": 76.4})
    d.pop("disk_free_gb_by_minute")
json.dump(d, open(f, "w"))
PY
}

pon() {  # $1 dispositivo, $2 fichero, $3 ruta en Documents: está desde el principio
  mkdir -p "$(dirname "$FAKE_DIR/dev/$1/Documents/$3")"; cp "$2" "$FAKE_DIR/dev/$1/Documents/$3"
}

nuevo_fake() {
  rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR/dev/$IZQ/Documents" "$FAKE_DIR/dev/$DER/Documents"
  printf '%s\n%s\n' "$IZQ" "$DER" > "$FAKE_DIR/conectados"
  echo '{}' > "$FAKE_DIR/guion.json"
}

# ------------------------------------------------------------------------------------------
echo "sesion_emitir.sh: espera a que el maestro pare, recoge y da el veredicto"
nuevo_fake
VIEJO=$(( $(date +%s) - 86400 ))
AHORA=$(( $(date +%s) + 5 ))
informe "$FIX/viejo.json" master production left "$VIEJO" true
pon "$IZQ" "$FIX/viejo.json" "bench/program-split-left-$VIEJO.json"
pon "$IZQ" "$FIX/entero.mov" "left-$VIEJO.mov"
pon "$IZQ" "$FIX/viejo.json" "rig.json"
pon "$IZQ" "$FIX/viejo.json" "bench-resources/players-centernet-mnv4.mlpackage/Manifest.json"
informe "$FIX/live-l.json" master production left "$AHORA" false latido
informe "$FIX/final-l.json" master production left "$AHORA" true
informe "$FIX/final-r.json" slave production right "$AHORA" true
echo '{"t": 1}' > "$FIX/n0.jsonl"
python3 - "$FAKE_DIR/guion.json" "$IZQ" "$DER" "$FIX" "$AHORA" <<'PY'
import json, sys
g, izq, der, fix, t = sys.argv[1:]
t = int(t)
json.dump({
    izq: {"2": [["pon", f"{fix}/entero.mov", f"program-zero-{t}.mov"],
                ["pon", f"{fix}/live-l.json", f"bench/program-live-left-{t}.json"],
                ["pon", f"{fix}/entero.mov", f"left-{t}.mov"]],
          "3": [["pon", f"{fix}/final-l.json", f"bench/program-split-left-{t + 600}.json"],
                ["pon", f"{fix}/n0.jsonl", f"n0/zero-{t}-left.jsonl"]]},
    der: {"1": [["pon", f"{fix}/final-r.json", f"bench/program-split-right-{t + 601}.json"],
                ["pon", f"{fix}/entero.mov", f"right-{t}.mov"]]},
}, open(g, "w"))
PY
touch "$FAKE_DIR/dev/$IZQ/corriendo"
OUT="$T/sesion"; mkdir -p "$OUT"
SALIDA="$OUT/s" SONDEO_S=0 ESPERA_ESCLAVO_S=0 ARRANQUE_S=0 \
  "$RAIZ/tools/sesion_emitir.sh" "$SECRETO" --sin-instalar --minutos 2 > "$OUT/salida.txt" 2>&1
espera_que "termina bien" test $? -eq 0
espera_que "ve EMITIR y la parada" tiene "$OUT/salida.txt" "el maestro paró"
espera_que "guarda el secreto en los dos (Keychain del fake)" test -s "$FAKE_DIR/dev/$IZQ/keychain" -a -s "$FAKE_DIR/dev/$DER/keychain"
espera_que "el lanzamiento lleva solo RIG_LINK_SECRET" tiene "$FAKE_DIR/log" "lanza com.logicielapplab.zero con \['RIG_LINK_SECRET'\]"
espera_que "el secreto no sale por pantalla" no_tiene "$OUT/salida.txt" "$VALOR"
espera_que "ni en el registro de la sesión" no_tiene "$OUT/s/sesion.log" "$VALOR"
espera_que "cierra Zero" tiene "$FAKE_DIR/log" "cierra Zero"
espera_que "nunca otra app" no_tiene "$FAKE_DIR/log" "CERRÓ OTRA APP"
espera_que "trae la copia .mov del programa" test -s "$OUT/s/izquierdo/program-zero-$AHORA.mov"
espera_que "trae los dos informes finales" test -s "$OUT/s/izquierdo/bench/program-split-left-$(( AHORA + 600 )).json" \
  -a -s "$OUT/s/derecho/bench/program-split-right-$(( AHORA + 601 )).json"
espera_que "trae el N0 y el latido" test -s "$OUT/s/izquierdo/n0/zero-$AHORA-left.jsonl" -a -s "$OUT/s/izquierdo/bench/program-live-left-$AHORA.json"
espera_que "no trae lo de pasadas viejas" test ! -e "$OUT/s/izquierdo/bench/program-split-left-$VIEJO.json"
espera_que "sin --con-4k, la 4K se queda en el móvil (y se dice)" tiene "$OUT/salida.txt" "4K left-$AHORA.mov"
espera_que "y no se copia" test ! -e "$OUT/s/izquierdo/left-$AHORA.mov"
[ -n "$HAY_FFMPEG" ] && espera_que "ffprobe lee el programa" tiene "$OUT/salida.txt" "✅ izquierdo/program-zero-$AHORA.mov"
espera_que "veredicto en orden" tiene "$OUT/salida.txt" "VEREDICTO: ✅ en orden"
espera_que "la batería por hora" tiene "$OUT/salida.txt" "%/h"
espera_que "la recogida no se queja" no_tiene "$OUT/salida.txt" "falló a medias"
espera_que "mira rig.json en cada móvil" tiene "$OUT/salida.txt" "izquierdo: ✅ Documents/rig.json"
espera_que "y avisa si falta el detector" tiene "$OUT/salida.txt" "derecho: ⚠️  sin bench-resources/players-centernet"

echo "sesion_emitir.sh: sin el 16 Pro conectado no empieza"
nuevo_fake
echo "$IZQ" > "$FAKE_DIR/conectados"
SALIDA="$T/sesion2" SONDEO_S=0 ARRANQUE_S=0 "$RAIZ/tools/sesion_emitir.sh" "$SECRETO" --sin-instalar > "$T/sesion2.txt" 2>&1
espera_que "sale con error" test $? -ne 0
espera_que "dice cuál falta" tiene "$T/sesion2.txt" "$DER no está conectado"
espera_que "no lanza nada" no_tiene "$FAKE_DIR/log" "lanza"

# ------------------------------------------------------------------------------------------
echo "recoger_partido.sh: la última pasada; el esclavo murió a mitad (solo latido y .mov cortado)"
nuevo_fake
P0=$(( $(date +%s) - 7200 ))   # el partido
VIEJO=$(( P0 - 86400 ))
informe "$FIX/p-final-l.json" master production left "$P0" true
informe "$FIX/p-live-l.json" master production left "$P0" true latido
informe "$FIX/p-live-r.json" slave production right "$P0" false latido
pon "$IZQ" "$FIX/entero.mov" "left-$VIEJO.mov"
pon "$IZQ" "$FIX/viejo.json" "bench/program-split-left-$VIEJO.json"
pon "$IZQ" "$FIX/p-live-l.json" "bench/program-live-left-$P0.json"
pon "$IZQ" "$FIX/p-final-l.json" "bench/program-split-left-$(( P0 + 6000 )).json"
pon "$IZQ" "$FIX/entero.mov" "program-zero-$P0.mov"
pon "$IZQ" "$FIX/entero.mov" "program-zero-$P0-2.mov"
pon "$IZQ" "$FIX/entero.mov" "left-$(( P0 - 1 )).mov"
pon "$IZQ" "$FIX/entero.mov" "left-$(( P0 - 1 ))-2.mov"
pon "$IZQ" "$FIX/n0.jsonl" "n0/zero-$P0-left.jsonl"
pon "$DER" "$FIX/p-live-r.json" "bench/program-live-right-$(( P0 + 2 )).json"
pon "$DER" "$FIX/cortado.mov" "right-$P0.mov"
OUT="$T/partido"
SALIDA="$OUT" "$RAIZ/tools/recoger_partido.sh" > "$T/partido.txt" 2>&1
espera_que "termina" test $? -eq 0
espera_que "trae la copia del programa y su segundo segmento" test -s "$OUT/izquierdo/program-zero-$P0.mov" -a -s "$OUT/izquierdo/program-zero-$P0-2.mov"
espera_que "trae las dos 4K del maestro (el corte abrió otro segmento)" test -s "$OUT/izquierdo/left-$(( P0 - 1 )).mov" -a -s "$OUT/izquierdo/left-$(( P0 - 1 ))-2.mov"
espera_que "trae la 4K del esclavo" test -s "$OUT/derecho/right-$P0.mov"
espera_que "no trae la 4K vieja" test ! -e "$OUT/izquierdo/left-$VIEJO.mov"
espera_que "el N0" test -s "$OUT/izquierdo/n0/zero-$P0-left.jsonl"
if [ -n "$HAY_FFMPEG" ]; then
  espera_que "el .mov cortado a mitad se lee (fragmentos)" tiene "$T/partido.txt" "✅ derecho/right-$P0.mov"
fi
espera_que "dice que el esclavo no llegó a PARAR" tiene "$T/partido.txt" "SOLO EL LATIDO"
espera_que "y lo cuenta como fallo" tiene "$T/partido.txt" "VEREDICTO: ❌"
espera_que "todo copiado en los dos" tiene "$T/partido.txt" "✅ derecho: todo copiado"
espera_que "la recogida no se queja" no_tiene "$T/partido.txt" "falló a medias"

echo "recoger_partido.sh --sin-4k --desde, y un móvil sin cable"
echo "$IZQ" > "$FAKE_DIR/conectados"
OUT="$T/partido2"
SALIDA="$OUT" "$RAIZ/tools/recoger_partido.sh" --sin-4k --desde "$(date -r $(( P0 - 60 )) '+%Y-%m-%d %H:%M')" > "$T/partido2.txt" 2>&1
espera_que "termina" test $? -eq 0
espera_que "sin las 4K" test ! -e "$OUT/izquierdo/left-$(( P0 - 1 )).mov"
espera_que "pero dice que están en el móvil" tiene "$T/partido2.txt" "4K en el móvil: left-$(( P0 - 1 )).mov"
espera_que "trae el programa" test -s "$OUT/izquierdo/program-zero-$P0.mov"
espera_que "se salta el que no está" tiene "$T/partido2.txt" "derecho ($DER) no está conectado"

# ------------------------------------------------------------------------------------------
echo "plan_b_cancha.sh: lanzar y soltar con las apps guardadas; volver"
nuevo_fake
APPS="$T/apps"; mkdir -p "$APPS/auto-left.app" "$APPS/auto-right.app" "$APPS/emitir.app"; echo abc1234 > "$APPS/VERSION"
touch "$FAKE_DIR/dev/$IZQ/corriendo" "$FAKE_DIR/dev/$DER/corriendo"
SALIDA="$T/planb" CANCHA_APPS="$APPS" "$RAIZ/tools/plan_b_cancha.sh" lanzar "$SECRETO" > "$T/planb.txt" 2>&1
espera_que "sale enseguida, sin esperar" test $? -eq 0
espera_que "instala la app de banco de cada lado" tiene "$FAKE_DIR/log" "$IZQ instala auto-left.app"
espera_que "(y la del derecho)" tiene "$FAKE_DIR/log" "$DER instala auto-right.app"
espera_que "cierra Zero antes de lanzar" tiene "$FAKE_DIR/log" "$IZQ cierra Zero"
espera_que "nunca otra app" no_tiene "$FAKE_DIR/log" "CERRÓ OTRA APP"
espera_que "deja la hora del lanzamiento" test -s "$T/planb/lanzado.txt"
espera_que "no recoge nada" no_tiene "$FAKE_DIR/log" "info files"
espera_que "el secreto no sale por pantalla" no_tiene "$T/planb.txt" "$VALOR"
python3 - "$FAKE_DIR/dev/$IZQ/entorno.json" > "$T/planb-entorno.txt" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
print(" ".join(f"{k}={e[k]}" for k in sorted(e) if k != "RIG_LINK_SECRET"))
PY
for par in RIG_SPLIT=1 RIG_SPLIT_S=7200 RIG_LINK_INTERFACE=aware RIG_SPLIT_RECORD_4K=1 RIG_SPLIT_DIRECTOR=1 \
           RIG_DETECT=players-centernet-mnv4.mlpackage RIG_AUDIO=1 RIG_SPLIT_NO_TS=1 RIG_LINK_SIDE=left RIG_LINK_MULTIPEER=0; do
  espera_que "el entorno lleva $par" tiene "$T/planb-entorno.txt" "$par"
done
espera_que "dice cómo recoger" tiene "$T/planb.txt" "tools/recoger_partido.sh --desde"
CANCHA_APPS="$APPS" "$RAIZ/tools/plan_b_cancha.sh" volver > "$T/volver.txt" 2>&1
espera_que "volver instala EMITIR en los dos" test "$(grep -c 'instala emitir.app' "$FAKE_DIR/log")" -eq 2

# ------------------------------------------------------------------------------------------
echo "emitir_auto.sh: compila cada lado con sus defines, lanza solo con el secreto, espera y recoge"
nuevo_fake
AHORA=$(( $(date +%s) + 5 ))
informe "$FIX/live-l.json" master production left "$AHORA" false latido
informe "$FIX/final-l.json" master production left "$AHORA" true
informe "$FIX/final-r.json" slave production right "$AHORA" true
printf '0.0s auto-emitir: LISTA\n20.0s auto-emitir: EMITIR\n20.1s auto-emitir: EMITIENDO\n620.1s auto-emitir: PARAR (600 s)\n' > "$FIX/auto-l.log"
printf '0.0s auto-emitir: este móvil es el esclavo: espera la orden del maestro\n' > "$FIX/auto-r.log"
python3 - "$FAKE_DIR/guion.json" "$IZQ" "$DER" "$FIX" "$AHORA" <<'PY2'
import json, sys
g, izq, der, fix, t = sys.argv[1:]
t = int(t)
json.dump({
    izq: {"2": [["pon", f"{fix}/entero.mov", f"program-zero-{t}.mov"],
                ["pon", f"{fix}/live-l.json", f"bench/program-live-left-{t}.json"],
                ["pon", f"{fix}/auto-l.log", f"bench/auto-emitir-left-{t}.log"]],
          "3": [["pon", f"{fix}/final-l.json", f"bench/program-split-left-{t + 600}.json"],
                ["pon", f"{fix}/n0.jsonl", f"n0/zero-{t}-left.jsonl"]]},
    der: {"1": [["pon", f"{fix}/final-r.json", f"bench/program-split-right-{t + 601}.json"],
                ["pon", f"{fix}/auto-r.log", f"bench/auto-emitir-right-{t}.log"]]},
}, open(g, "w"))
PY2
cat > "$T/bin/flutter-falso" <<EOF
#!/bin/bash
echo "flutter \$*" >> "$FAKE_DIR/log"
mkdir -p "\$RUNNER"
EOF
chmod +x "$T/bin/flutter-falso"
touch "$FAKE_DIR/dev/$IZQ/corriendo" "$FAKE_DIR/dev/$DER/corriendo"
OUT="$T/auto"
SALIDA="$OUT" SONDEO_S=0 ESPERA_ESCLAVO_S=0 FLUTTER="$T/bin/flutter-falso" RUNNER="$T/build/Runner.app" \
  "$RAIZ/tools/emitir_auto.sh" "$SECRETO" 600 --link aware > "$T/auto.txt" 2>&1
espera_que "termina bien" test $? -eq 0
espera_que "compila el izquierdo con sus defines" tiene "$FAKE_DIR/log" \
  "flutter build ios --release --dart-define=AUTO_ROLE=left --dart-define=AUTO_EMITIR=true --dart-define=AUTO_LINK=aware --dart-define=AUTO_EMITIR_S=600"
espera_que "y el derecho" tiene "$FAKE_DIR/log" "--dart-define=AUTO_ROLE=right --dart-define=AUTO_EMITIR=true"
espera_que "cada uno en su móvil, en orden" test "$(grep -E 'flutter|instala' "$FAKE_DIR/log" | sed -E 's/.*AUTO_ROLE=(left|right).*/\1/; s/ instala.*//' | tr '\n' ' ')" = "left $IZQ right $DER "
espera_que "sin --con-4k, sin AUTO_EMITIR_4K" no_tiene "$FAKE_DIR/log" "AUTO_EMITIR_4K"
espera_que "lanza los dos solo con RIG_LINK_SECRET (ni RIG_SPLIT ni RIG_LINK_*)" \
  test "$(grep -c "lanza com.logicielapplab.zero con \['RIG_LINK_SECRET'\]" "$FAKE_DIR/log")" -eq 2
espera_que "cierra Zero antes" tiene "$FAKE_DIR/log" "$IZQ cierra Zero"
espera_que "nunca otra app" no_tiene "$FAKE_DIR/log" "CERRÓ OTRA APP"
espera_que "el secreto no sale por pantalla" no_tiene "$T/auto.txt" "$VALOR"
espera_que "ni en el registro de la sesión" no_tiene "$OUT/sesion.log" "$VALOR"
espera_que "ve la parada" tiene "$T/auto.txt" "el maestro paró"
espera_que "trae la copia .mov del programa" test -s "$OUT/izquierdo/program-zero-$AHORA.mov"
espera_que "trae los informes y el latido" test -s "$OUT/izquierdo/bench/program-split-left-$(( AHORA + 600 )).json" \
  -a -s "$OUT/derecho/bench/program-split-right-$(( AHORA + 601 )).json" -a -s "$OUT/izquierdo/bench/program-live-left-$AHORA.json"
espera_que "trae el registro auto-emitir de los dos" test -s "$OUT/izquierdo/bench/auto-emitir-left-$AHORA.log" \
  -a -s "$OUT/derecho/bench/auto-emitir-right-$AHORA.log"
espera_que "y lo resume" tiene "$T/auto.txt" "izquierdo: 20.1s auto-emitir: EMITIENDO"
espera_que "el esclavo esperó la orden" tiene "$T/auto.txt" "derecho: 0.0s auto-emitir: este móvil es el esclavo"
[ -n "$HAY_FFMPEG" ] && espera_que "ffprobe lee el programa" tiene "$T/auto.txt" "✅ izquierdo/program-zero-$AHORA.mov"
espera_que "veredicto en orden" tiene "$T/auto.txt" "VEREDICTO: ✅ en orden"

echo "emitir_auto.sh: --con-4k y --link wifi; sin el 16 Pro no empieza"
nuevo_fake
touch "$FAKE_DIR/dev/$IZQ/corriendo"
A2=$(( $(date +%s) + 5 ))
pon "$IZQ" "$FIX/final-l.json" "bench/program-split-left-$A2.json"   # el maestro ya paró
SALIDA="$T/auto2" SONDEO_S=0 ESPERA_ESCLAVO_S=0 MARGEN_FIN_S=0 FLUTTER="$T/bin/flutter-falso" RUNNER="$T/build/Runner.app" \
  "$RAIZ/tools/emitir_auto.sh" "$SECRETO" 1 --link wifi --con-4k > "$T/auto2.txt" 2>&1 || true
espera_que "con --con-4k, AUTO_EMITIR_4K y el enlace wifi" tiene "$FAKE_DIR/log" "AUTO_LINK=wifi --dart-define=AUTO_EMITIR_S=1 --dart-define=AUTO_EMITIR_4K=true"
echo "$IZQ" > "$FAKE_DIR/conectados"; : > "$FAKE_DIR/log"
SALIDA="$T/auto3" FLUTTER="$T/bin/flutter-falso" RUNNER="$T/build/Runner.app" \
  "$RAIZ/tools/emitir_auto.sh" "$SECRETO" 600 > "$T/auto3.txt" 2>&1
espera_que "sale con error" test $? -ne 0
espera_que "no compila ni lanza nada" no_tiene "$FAKE_DIR/log" "flutter\|lanza"
"$RAIZ/tools/emitir_auto.sh" "$SECRETO" 600 --link multipeer > "$T/auto4.txt" 2>&1
espera_que "--link multipeer no vale (no hay programa)" test $? -eq 2

# ------------------------------------------------------------------------------------------
# calibrar_cancha.sh: la calibración de football-ai se sustituye por una falsa que mira que le
# llegan las fotos del disparo nuevo y deja el rig.json de FALSO_RIG (o no calibra).
cat > "$T/bin/calibrador-falso" <<'PY'
#!/usr/bin/env python3
import json, math, os, sys
a = sys.argv[1:]
op = lambda n: a[a.index(n) + 1]
bench, boot, out, js = op("--bench"), op("--boot"), op("--out"), op("--json")
open(os.path.join(os.environ["FAKE_DIR"], "calibrador.log"), "a").write(f"--boot {boot}\n")
fotos = [os.path.join(bench, c, "calib", boot, f"{s}-{boot}.jpg") for c, s in (("izquierdo", "left"), ("derecho", "right"))]
base = {"chosen_instant_ms": None, "out": None, "error": None, "min_inliers": 30, "ransac_threshold_px": 3.0}
if not all(os.path.isfile(f) for f in fotos):
    json.dump({**base, "calibrated": False, "attempts": [], "error": "faltan las fotos"}, open(js, "w"))
    sys.exit(2)
if os.environ.get("FALSO_NO_CALIBRA"):
    fallo = "solo hay 14 emparejamientos entre las dos imagenes y hacen falta 30"
    json.dump({**base, "calibrated": False, "attempts": [{"instant_ms": int(boot), "delta_ms": -2, "failure": fallo}]},
              open(js, "w"))
    sys.exit(1)
rig = json.load(open(os.environ["FALSO_RIG"]))
json.dump(rig, open(out, "w"), indent=2)
cams = {s: {f"{e}_deg": math.degrees(rig[s]["pose"][f"{e}_rad"]) for e in ("yaw", "pitch", "roll")} for s in ("left", "right")}
json.dump({**base, "calibrated": True, "chosen_instant_ms": int(boot), "out": out, "attempts": [
    {"instant_ms": int(boot), "delta_ms": 3, "failure": None, "inliers": 100, "matches": 199, "residual_deg": 0.061,
     "cameras": cams}]}, open(js, "w"))
PY
chmod +x "$T/bin/calibrador-falso"
CASA="$RAIZ/docs/img/rig-tripode-20261011.json"
python3 - "$CASA" "$T/rig-nuevo.json" <<'PY'
import json, math, sys
rig = json.load(open(sys.argv[1]))
rig["right"]["pose"]["roll_rad"] += math.radians(0.1)   # el mismo montaje, otra calibración
json.dump(rig, open(sys.argv[2], "w"), indent=2)
PY
APPS="$T/apps"; mkdir -p "$APPS/auto-left.app" "$APPS/auto-right.app" "$APPS/emitir.app"; echo abc1234 > "$APPS/VERSION"
CVIEJO=600000; CNUEVO=1004334720
calib_fake() {  # $1 1: las fotos aparecen en el segundo listado (Zero haciendo el disparo)
  nuevo_fake
  for par in "$IZQ:left" "$DER:right"; do
    d=${par%%:*}; s=${par##*:}
    pon "$d" "$CASA" "rig.json"
    pon "$d" "$FIX/entero.mov" "calib/$CVIEJO/$s-$CVIEJO.jpg"
    pon "$d" "$FIX/n0.jsonl" "calib/$CVIEJO/summary-$s.json"
    touch "$FAKE_DIR/dev/$d/corriendo"
  done
  [ "$1" = 1 ] || return 0
  python3 - "$FAKE_DIR/guion.json" "$IZQ" "$DER" "$FIX" "$CNUEVO" <<'PY'
import json, sys
g, izq, der, fix, n = sys.argv[1:]
def fotos(s):
    acc = []
    for k in range(5):
        t = int(n) + 1000 * k
        acc += [["pon", f"{fix}/entero.mov", f"calib/{n}/{s}-{t}.jpg"], ["pon", f"{fix}/n0.jsonl", f"calib/{n}/{s}-{t}.json"]]
    return acc + [["pon", f"{fix}/n0.jsonl", f"calib/{n}/summary-{s}.json"]]
json.dump({izq: {"2": fotos("left")}, der: {"3": fotos("right")}}, open(g, "w"))
PY
}
entorno_de() {  # $1 dispositivo: el entorno de su último lanzamiento, sin el secreto
  python3 - "$FAKE_DIR/dev/$1/entorno.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
print(" ".join(f"{k}={e[k]}" for k in sorted(e) if k != "RIG_LINK_SECRET"))
PY
}
apps_instaladas() { grep ' instala ' "$FAKE_DIR/log" | sed -E 's/^([^ ]+) instala (.*)$/\1:\2/' | tr '\n' ' '; }

echo "calibrar_cancha.sh: calibra e instala en los dos"
calib_fake 1
OUT="$T/calib"
SALIDA="$OUT" SONDEO_S=0 CANCHA_APPS="$APPS" CALIBRADOR="$T/bin/calibrador-falso" FALSO_RIG="$T/rig-nuevo.json" \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" > "$T/calib.txt" 2>&1
espera_que "termina bien" test $? -eq 0
espera_que "instala la de banco de cada lado y al final EMITIR en los dos" test "$(apps_instaladas)" = \
  "$IZQ:auto-left.app $DER:auto-right.app $IZQ:emitir.app $DER:emitir.app "
espera_que "cierra Zero" tiene "$FAKE_DIR/log" "$IZQ cierra Zero"
espera_que "nunca otra app" no_tiene "$FAKE_DIR/log" "CERRÓ OTRA APP"
entorno_de "$IZQ" > "$T/calib-entorno.txt"
for par in RIG_CALIB_AT_S=10 RIG_SPLIT=1 RIG_SPLIT_S=360 RIG_LINK_INTERFACE=aware RIG_LINK_SIDE=left \
           RIG_LINK_MULTIPEER=0 RIG_SPLIT_NO_TS=1 RIG_SPLIT_NO_MOV=1; do
  espera_que "el entorno lleva $par" tiene "$T/calib-entorno.txt" "$par"
done
espera_que "el derecho, su lado" tiene <(entorno_de "$DER") "RIG_LINK_SIDE=right"
espera_que "lanza con el secreto (al Keychain del fake)" test -s "$FAKE_DIR/dev/$IZQ/keychain" -a -s "$FAKE_DIR/dev/$DER/keychain"
espera_que "el secreto no sale por pantalla" no_tiene "$T/calib.txt" "$VALOR"
espera_que "ni en el registro" no_tiene "$OUT/calibrar.log" "$VALOR"
espera_que "espera al derecho, que acaba un listado después" tiene "$T/calib.txt" "aún no están las fotos de los dos"
espera_que "calibra el disparo nuevo" tiene "$FAKE_DIR/calibrador.log" "--boot $CNUEVO"
espera_que "trae las 11 de cada lado" test "$(ls "$OUT/izquierdo/calib/$CNUEVO" | wc -l)" -eq 11 -a "$(ls "$OUT/derecho/calib/$CNUEVO" | wc -l)" -eq 11
espera_que "y no las del disparo viejo" test ! -e "$OUT/izquierdo/calib/$CVIEJO"
espera_que "dice puntos, residuo y ángulos" tiene "$T/calib.txt" "✅ CALIBRA con la pareja $CNUEVO: 100 de 199 puntos coherentes, residuo 0.061°"
espera_que "el roll de la derecha" tiene "$T/calib.txt" "cámara derecha   yaw  +40.73°  pitch   -5.58°  roll   -6.11°"
espera_que "guarda el viejo de cada uno" cmp -s "$OUT/izquierdo/antes/rig.json" "$CASA"
espera_que "(el del derecho)" cmp -s "$OUT/derecho/antes/rig.json" "$CASA"
espera_que "dice que se parece al de casa" tiene "$T/calib.txt" "se parece al que tenía: la diferencia mayor es 0.10° (roll de la derecha)"
espera_que "lo sube a los dos" test "$(grep -c 'sube Documents/rig.json' "$FAKE_DIR/log")" -eq 2
espera_que "y quedó: el izquierdo" cmp -s "$FAKE_DIR/dev/$IZQ/Documents/rig.json" "$T/rig-nuevo.json"
espera_que "y el derecho" cmp -s "$FAKE_DIR/dev/$DER/Documents/rig.json" "$T/rig-nuevo.json"
espera_que "lo comprueba bajándolo" tiene "$T/calib.txt" "✅ derecho: Documents/rig.json es el nuevo"
espera_que "veredicto" tiene "$T/calib.txt" "VEREDICTO: ✅ calibrado e instalado en los dos"
espera_que "Zero cerrada al acabar" test ! -e "$FAKE_DIR/dev/$IZQ/corriendo" -a ! -e "$FAKE_DIR/dev/$DER/corriendo"

echo "calibrar_cancha.sh --solo-comprobar: calibra y compara, no instala"
calib_fake 1
SALIDA="$T/calib2" SONDEO_S=0 CANCHA_APPS="$APPS" CALIBRADOR="$T/bin/calibrador-falso" FALSO_RIG="$T/rig-nuevo.json" \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" --solo-comprobar > "$T/calib2.txt" 2>&1
espera_que "termina bien" test $? -eq 0
espera_que "compara" tiene "$T/calib2.txt" "se parece al que tenía"
espera_que "no sube nada" no_tiene "$FAKE_DIR/log" "sube"
espera_que "los móviles siguen con el de casa" cmp -s "$FAKE_DIR/dev/$IZQ/Documents/rig.json" "$CASA"
espera_que "dice cómo instalarlo" tiene "$T/calib2.txt" "devicectl device copy to --device $DER"
espera_que "y deja EMITIR" test "$(grep -c 'instala emitir.app' "$FAKE_DIR/log")" -eq 2

echo "calibrar_cancha.sh: no calibra y no toca los móviles"
calib_fake 1
SALIDA="$T/calib3" SONDEO_S=0 CANCHA_APPS="$APPS" CALIBRADOR="$T/bin/calibrador-falso" FALSO_NO_CALIBRA=1 \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" > "$T/calib3.txt" 2>&1
espera_que "sale con error" test $? -ne 0
espera_que "dice que no calibra" tiene "$T/calib3.txt" "❌ NO CALIBRA: ninguna de las 1 parejas"
espera_que "y por qué" tiene "$T/calib3.txt" "solo hay 14 emparejamientos"
espera_que "y qué hacer" tiene "$T/calib3.txt" "aceptar el de casa"
espera_que "no sube nada" no_tiene "$FAKE_DIR/log" "sube"
espera_que "el izquierdo sigue con el de casa" cmp -s "$FAKE_DIR/dev/$IZQ/Documents/rig.json" "$CASA"
espera_que "y el derecho" cmp -s "$FAKE_DIR/dev/$DER/Documents/rig.json" "$CASA"
espera_que "deja EMITIR en los dos" test "$(grep -c 'instala emitir.app' "$FAKE_DIR/log")" -eq 2
espera_que "nunca otra app" no_tiene "$FAKE_DIR/log" "CERRÓ OTRA APP"
espera_que "el secreto no sale" no_tiene "$T/calib3.txt" "$VALOR"

echo "calibrar_cancha.sh: sin fotos (el enlace no subió), sin el 16 Pro, o sin las apps"
calib_fake 0
informe "$FIX/live-mudo.json" master bench left "$(date +%s)" false latido
python3 - "$FIX/live-mudo.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["link"] = {"summary": "no ve al otro en 300 s", "medium": "aware"}
json.dump(d, open(sys.argv[1], "w"))
PY
python3 - "$FAKE_DIR/guion.json" "$IZQ" "$FIX" "$(( $(date +%s) + 2 ))" <<'PY'
import json, sys
g, izq, fix, t = sys.argv[1:]
json.dump({izq: {"2": [["pon", f"{fix}/live-mudo.json", f"bench/program-live-left-{t}.json"]]}}, open(g, "w"))
PY
SALIDA="$T/calib4" SONDEO_S=0 ESPERA_S=0 CANCHA_APPS="$APPS" CALIBRADOR="$T/bin/calibrador-falso" \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" > "$T/calib4.txt" 2>&1
espera_que "sale con error" test $? -ne 0
espera_que "dice que no llegaron" tiene "$T/calib4.txt" "no llegaron las fotos de los dos"
espera_que "y lo que dice el latido del enlace" tiene "$T/calib4.txt" "izquierdo: no ve al otro en 300 s (aware)"
espera_que "no calibra" test ! -e "$FAKE_DIR/calibrador.log"
espera_que "no sube nada" no_tiene "$FAKE_DIR/log" "sube"
espera_que "deja EMITIR en los dos" test "$(grep -c 'instala emitir.app' "$FAKE_DIR/log")" -eq 2
echo "$IZQ" > "$FAKE_DIR/conectados"; : > "$FAKE_DIR/log"
SALIDA="$T/calib5" CANCHA_APPS="$APPS" CALIBRADOR="$T/bin/calibrador-falso" \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" > "$T/calib5.txt" 2>&1
espera_que "sin el 16 Pro, error" test $? -ne 0
espera_que "y no instala ni lanza nada" no_tiene "$FAKE_DIR/log" "instala\|lanza"
printf '%s\n%s\n' "$IZQ" "$DER" > "$FAKE_DIR/conectados"
SALIDA="$T/calib6" CANCHA_APPS="$T/sin-apps" CALIBRADOR="$T/bin/calibrador-falso" \
  "$RAIZ/tools/calibrar_cancha.sh" "$SECRETO" > "$T/calib6.txt" 2>&1
espera_que "sin las apps guardadas, error" test $? -ne 0
espera_que "y dice cómo prepararlas" tiene "$T/calib6.txt" "plan_b_cancha.sh preparar"
espera_que "sin lanzar nada" no_tiene "$FAKE_DIR/log" "instala\|lanza"

echo
echo "$BIEN bien, $MAL mal"
[ "$MAL" -eq 0 ]
