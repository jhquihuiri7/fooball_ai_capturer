#!/usr/bin/env bash
# SPK-53: el estado del spotter N4 en el ANE, MLState frente a E/S explícita.
#
#   tools/spk53_bench.sh recursos <runs/spk53 del repo de entrenamiento>
#   tools/spk53_bench.sh mac                  # el carril del Mac: swift test, sin iPhone
#   tools/spk53_bench.sh iphone [DISPOSITIVO] # compila, instala, copia, mide y baja
#
# `recursos` deja en build/spk53/bench-resources/ los dos .mlpackage, la secuencia
# dorada (golden/n4-step-v1) y tres ficheros de modelos: bench-spk53.json (las dos
# variantes), bench-spk53-explicit.json y bench-spk53-mlstate.json.
#
# `iphone` compila la app con BENCH=model-bench, la instala, sube los recursos a
# Documents/bench-resources (sin borrar lo que ya hubiera) y lanza el banco DOS veces,
# una por variante (MODEL_BENCH_SPEC), con tools/bench_iphone.sh: si una tumba la app,
# la otra ya tiene su informe. En el iPhone quedan en Documents/bench/model-bench-<epoch>.json
# y bajan a bench/spk53-<fecha>/n4-step-{explicit,mlstate}.json. Solo se cierra la Zero
# (procesos_zero.py). El iPhone, desbloqueado y con el Bloqueo automático en Nunca (iOS
# suspende la app al bloquear).
#
# Los recursos del iPhone (dos paquetes de 2,8 MB y 34 MB de secuencia dorada) no van a
# git: salen de runs/spk53 del repo de entrenamiento (su PROGRESS dice cómo rehacerlos).
# Los fixtures diminutos de los tests del Mac (n4-tiny-*) sí, en Tests/RigMediaTests/Fixtures.
set -euo pipefail

MODO=${1:?recursos, mac o iphone}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
STAGE="$RAIZ/build/spk53/bench-resources"
APP=com.logicielapplab.zero
FLUTTER=${FLUTTER:-/Users/alexander/flutter_3.44.8/bin/flutter}
ESPERA_S=${ESPERA_S:-600}   # tope por variante; el banco tarda segundos

spec() {  # $1 fichero, $2.. variantes
  local fichero=$1; shift
  python3 - "$fichero" "$@" <<'PY'
import json, sys
fichero, *variantes = sys.argv[1:]
modelos = [
    {"name": f"n4-step-{v}", "package": f"n4-step-{v}.mlpackage",
     "sequence": "golden/n4-step-v1", "predictions": 1000, "warmup": 50,
     "compute_units": "cpu_and_ne"}
    for v in variantes
]
with open(fichero, "w") as f:
    json.dump({"models": modelos}, f, indent=2)
PY
}

case "$MODO" in
  recursos)
    ORIGEN=${2:?la carpeta runs/spk53 del repo de entrenamiento}
    rm -rf "$STAGE"; mkdir -p "$STAGE/golden"
    for v in explicit mlstate; do
      cp -R "$ORIGEN/n4-step-$v.mlpackage" "$STAGE/"
    done
    cp -R "$ORIGEN/golden/n4-step-v1" "$STAGE/golden/"
    spec "$STAGE/bench-spk53.json" explicit mlstate
    spec "$STAGE/bench-spk53-explicit.json" explicit
    spec "$STAGE/bench-spk53-mlstate.json" mlstate
    du -sh "$STAGE"/*
    ;;

  mac)
    [ -d "$STAGE" ] || { echo "primero: $0 recursos <runs/spk53>" >&2; exit 1; }
    DEST="$RAIZ/ios/ZeroKit/Tests/RigMediaTests/BenchResources"
    cp -R "$STAGE"/. "$DEST"/
    cd "$RAIZ/ios/ZeroKit"
    MODEL_BENCH_SPEC=bench-spk53.json swift test --filter ModelBenchTests 2>&1 \
      | sed -n '/MODELBENCH-REPORT-BEGIN/,/MODELBENCH-REPORT-END/p;/Executed/p;/error/p'
    echo "informe también en ~/Documents/bench/model-bench-<epoch>.json"
    ;;

  iphone)
    DEVICE=${2:-8FBBECC4-5239-59C4-BE22-5EEFB5958863}   # el iPhone 17
    [ -d "$STAGE" ] || { echo "primero: $0 recursos <runs/spk53>" >&2; exit 1; }
    SALIDA="$RAIZ/bench/spk53-$(date +%Y%m%d-%H%M)"
    mkdir -p "$SALIDA"

    (cd "$RAIZ" && "$FLUTTER" build ios --release --no-pub --dart-define=BENCH=model-bench 2>&1 \
      | grep -E "Built|rror")
    xcrun devicectl device install app --device "$DEVICE" \
      "$RAIZ/build/ios/iphoneos/Runner.app" | grep -E "App installed|rror"
    xcrun devicectl device copy to --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$APP" \
      --source "$STAGE" --destination Documents/bench-resources | tail -1
    # Que los ficheros de modelos estén donde ModelBench los busca, no una carpeta más abajo.
    subidos=$(xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$APP" 2>/dev/null | awk '{print $1}')
    for v in explicit mlstate; do
      # Sin tubería: con pipefail, `echo | grep -q` falla (SIGPIPE) justo cuando encuentra.
      grep -qx "Documents/bench-resources/bench-spk53-$v.json" <<< "$subidos" || {
        echo "no está Documents/bench-resources/bench-spk53-$v.json en el iPhone" >&2; exit 1; }
    done

    for v in explicit mlstate; do
      SIN_COMPILAR=1 SALIDA="$SALIDA" NOMBRE="n4-step-$v.json" ESPERA_S="$ESPERA_S" \
        ENTORNO="{\"MODEL_BENCH_SPEC\": \"bench-spk53-$v.json\"}" \
        "$RAIZ/tools/bench_iphone.sh" model-bench "$DEVICE" || echo "   n4-step-$v: sin informe"
    done

    # El resumen de lo que decide SPK-53, por variante.
    python3 - "$SALIDA" <<'PY'
import json, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("n4-step-*.json")):
    r = json.loads(f.read_text())
    n = f.stem
    c, s = r["counters"], r["stages_ms"].get(f"{n}/step", {})
    if c.get(f"{n}/failed"):
        print(f"{n}: FALLÓ — {r['params'].get(f'{n}/error')}")
        continue
    print(f"{n} [{r['params'].get(f'{n}/state_mode')}] {r['device']} iOS {r['system_version']}")
    print(f"  ANE {c.get(f'{n}/ane_cost_pct_x100', 0) / 100:.2f} % del coste "
          f"({c.get(f'{n}/ops_off_ane')} de {c.get(f'{n}/ops_total')} ops fuera)")
    print(f"  paso p50 {s.get('p50_ms')} ms · p90 {s.get('p90_ms')} · p99 {s.get('p99_ms')}")
    print(f"  dorado: {c.get(f'{n}/golden_violations')} fuera, peor delta "
          f"{c.get(f'{n}/golden_max_delta_x1e6', 0) / 1e6:.4f}; reinicio "
          f"{c.get(f'{n}/repeat_violations')}; intercalado {c.get(f'{n}/interleave_violations')}")
    print(f"  compile {c.get(f'{n}/compile_ms')} ms · load {c.get(f'{n}/load_ms')} ms · "
          f"térmica {' → '.join(r['thermal'])}")
    # La aceptación de la tarjeta SPK-53, criterio a criterio.
    criterios = {
        "ANE >= 95 %": c.get(f"{n}/ane_cost_pct_x100", 0) >= 9500,
        "p50 <= 1,7 ms": s.get("p50_ms", float("inf")) <= 1.7,
        "100 pasos en el dorado": c.get(f"{n}/sequence_steps") == 100
        and c.get(f"{n}/golden_violations") == 0,
        "sin fugas": c.get(f"{n}/repeat_violations") == 0
        and c.get(f"{n}/interleave_violations") == 0,
    }
    print("  " + " · ".join(f"{k} {'sí' if ok else 'NO'}" for k, ok in criterios.items()))
PY
    echo "informes en $SALIDA"
    ;;

  *) echo "modo desconocido: $MODO (recursos, mac o iphone)" >&2; exit 2 ;;
esac
