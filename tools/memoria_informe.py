"""La memoria y el programa de uno o varios informes del banco split, para comparar pasadas.

    python3 tools/memoria_informe.py bench/un-movil-*/program-split-left-*.json

La pendiente (MB/min) se ajusta desde el minuto 3: los primeros minutos son el arranque
(modelos, pools, la primera franja) y no la fuga.
"""

import json
import sys

DESDE_MIN = 3


def pendiente(serie: list[float]) -> float | None:
    ys = serie[DESDE_MIN:]
    if len(ys) < 2:
        return None
    xs = list(range(DESDE_MIN, DESDE_MIN + len(ys)))
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)


for ruta in sys.argv[1:]:
    d = json.load(open(ruta))
    fp = d.get("footprint_mb", [])
    p = pendiente(fp)
    print(ruta)
    print(f"  {d.get('role')} {d.get('duration_s')} s, {d.get('program_frames')} fotogramas, {d.get('program_sources')}")
    print(f"  sin el propio {d.get('without_master_frame')}, latencia p95 {d.get('added_latency_ms_p95')}, "
          f"térmica {sorted(set(d.get('thermal_by_minute', [])))}")
    print(f"  memoria {[round(v) for v in fp]}")
    print(f"  pendiente {'—' if p is None else f'{p:.2f} MB/min'} (desde el minuto {DESDE_MIN})")
