#!/usr/bin/env python3
"""La cancha (2026-10-14): qué hay en cada iPhone tras EMITIR o el plan B, qué traer y qué dice.

Lo usan tools/sesion_emitir.sh, tools/recoger_partido.sh y tools/plan_b_cancha.sh.

    python3 tools/cancha.py desde <listado>                   # el arranque de la última pasada
    python3 tools/cancha.py pasadas <listado>                 # las pasadas que hay en el móvil
    python3 tools/cancha.py informes <listado> <desde>        # sus .json (informe y latido)
    python3 tools/cancha.py medios <listado> <desde> [1]      # vídeos, N0, vistas y audio (1: sin 4K)
    python3 tools/cancha.py k4 <listado> <desde>              # solo las 4K de la pasada
    python3 tools/cancha.py estado <listado> <desde>          # nada | emitiendo … | parado …
    python3 tools/cancha.py recursos <listado>                # rig.json y el detector, ✅/⚠️
    python3 tools/cancha.py espacio <listado> <desde>         # lo que ocupa Zero y lo de la pasada
    python3 tools/cancha.py verificar <carpeta>               # ffprobe de cada .mov y .ts
    python3 tools/cancha.py veredicto <carpeta> [desde]       # ✅/⚠️/❌ del programa y la parte

<listado>: la salida de `devicectl device info files` del contenedor de Zero. <desde>: un
epoch en s; lo de antes no es de la pasada. <carpeta>: la de la recogida, con `izquierdo/` y
`derecho/` y debajo las rutas relativas a Documents (como deja tools/banco_dos_moviles.sh).

Los nombres llevan la hora del móvil al crearse: la 4K de EMITIR `<lado>-<t>.mov` (y
`-<n>.mov` tras un corte), la copia del programa `program-<partido>-<t>.mov`, el latido
`bench/program-live-<lado>-<t de arranque>.json` y el informe
`bench/program-split-<lado>-<t de final>.json`.
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import sys

BYTES_POR_GB = 1e9
BYTES_POR_MB = 1e6
_UNIDADES = {"bytes": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
# La 4K se abre antes que el programa (CaptureHostApi.start, después startProgram): lo de
# la pasada empieza un poco antes que su latido. Y el reloj del Mac no es el del móvil.
MARGEN_PASADA_S = 120
# Un partido puede ser varias pasadas: si la app murió y se volvió a EMITIR, la última solo
# es lo de después. Entran las que empezaron hasta 3 h antes de la última.
VENTANA_PARTIDO_S = 3 * 3600

# Lo que se recoge de una pasada, por ruta relativa a Documents. El grupo 1 es su hora.
_INFORME = re.compile(r"^bench/(?:program-split-(?:left|right)|program-live-(?:left|right)|audio)-(\d+)\.json$")
_FINAL = re.compile(r"^bench/program-split-(left|right)-(\d+)\.json$")
_LATIDO = re.compile(r"^bench/program-live-(left|right)-(\d+)\.json$")
_4K = (re.compile(r"^(?:left|right)-(\d+)(?:-\d+)?\.mov$"), re.compile(r"^bench4k/(\d+)/[^/]+\.mov$"))
_PROGRAMA = (
    re.compile(r"^program-(?:.+-)?(\d{9,11})(?:-\d+)?\.mov$"),
    re.compile(r"^bench/program-split-(\d+)(?:-\d+)?\.(?:mov|ts)$"),
)
_OTROS = (
    re.compile(r"^bench/program-views-(\d+)\.jsonl$"),
    re.compile(r"^n0/(?:.+-)?(\d{9,11})-(?:left|right)\.jsonl$"),
    re.compile(r"^bench/audio-(\d+)\.aac$"),
)

_RUTA = re.compile(r"(?:^|\s)(Documents/\S+)")
_TAM = re.compile(r"\s(\d+(?:[.,]\d+)?|Zero)\s?(bytes|KB|MB|GB|TB)\b")
_NUM = re.compile(r"\s(\d+)\s*$|\s(\d+)\s")


def listado(texto: str) -> dict[str, int]:
    """Ruta relativa a Documents → bytes, del listado de devicectl (sin las carpetas).

    devicectl escribe el tamaño con unidades y coma decimal («3,36 GB», «Zero KB»); un número
    solo son bytes (los listados de las pruebas)."""
    salida: dict[str, int] = {}
    for linea in texto.splitlines():
        m = _RUTA.search(linea)
        if not m or m.group(1).endswith("/") or "Directory" in linea:
            continue
        resto = linea[m.end():]
        t = _TAM.search(" " + resto)
        if t:
            n = 0.0 if t.group(1) == "Zero" else float(t.group(1).replace(",", "."))
            tam = int(n * _UNIDADES[t.group(2)])
        else:
            n2 = _NUM.search(resto + " ")
            tam = int(next(g for g in n2.groups() if g)) if n2 else 0
        salida[m.group(1).removeprefix("Documents/")] = tam
    return salida


def _hora(patrones: tuple[re.Pattern[str], ...], ruta: str) -> int | None:
    for p in patrones:
        m = p.match(ruta)
        if m:
            return int(m.group(1))
    return None


def pasadas(lista: dict[str, int]) -> list[tuple[int, str]]:
    """(arranque, lado) de cada pasada con latido, de la más vieja a la más nueva."""
    return sorted((int(m.group(2)), m.group(1)) for r in lista if (m := _LATIDO.match(r)))


def desde_por_defecto(lista: dict[str, int]) -> int:
    """El arranque del último partido menos el margen: la primera de las pasadas con latido
    que empezaron en las `VENTANA_PARTIDO_S` antes de la última (la app que murió y se volvió a
    EMITIR son dos). En una app sin latido (anterior al 2026-10-14), por la 4K o la copia del
    programa más nuevas. 0 si nada."""
    p = pasadas(lista)
    if p:
        ultima = p[-1][0]
        return min(t for t, _ in p if t >= ultima - VENTANA_PARTIDO_S) - MARGEN_PASADA_S
    horas = [h for r in lista if (h := _hora(_4K + _PROGRAMA, r)) is not None]
    return max(horas) - MARGEN_PASADA_S if horas else 0


def informes(lista: dict[str, int], desde: int) -> list[str]:
    return sorted(r for r in lista if (m := _INFORME.match(r)) and int(m.group(1)) >= desde)


def es_4k(ruta: str) -> bool:
    return _hora(_4K, ruta) is not None


def medios(lista: dict[str, int], desde: int, sin_4k: bool) -> list[str]:
    """Lo grabado en la pasada, de lo pequeño a lo grande: el N0, las vistas y el audio, la
    copia del programa y al final las 4K (lo que más tarda). Sin los vacíos."""
    def de_la_pasada(patrones: tuple[re.Pattern[str], ...]) -> list[str]:
        return sorted(r for r in lista if lista[r] > 0 and (h := _hora(patrones, r)) is not None and h >= desde)

    salida = de_la_pasada(_OTROS) + de_la_pasada(_PROGRAMA)
    if not sin_4k:
        salida += de_la_pasada(_4K)
    return salida


def estado(lista: dict[str, int], desde: int) -> str:
    """`parado <informe>` si ya está el informe final del maestro (o de cualquiera); si no,
    `emitiendo <copia> <MB>` mientras crece; `nada` antes de EMITIR."""
    finales = sorted((int(m.group(2)), r) for r in lista if (m := _FINAL.match(r)) and int(m.group(2)) >= desde)
    if finales:
        return f"parado {finales[-1][1]}"
    copias = sorted((h, r) for r in lista if (h := _hora(_PROGRAMA, r)) is not None and h >= desde)
    if copias:
        r = copias[-1][1]
        return f"emitiendo {r} {lista[r] / BYTES_POR_MB:.0f}"
    latidos = [r for r in lista if (m := _LATIDO.match(r)) and int(m.group(2)) >= desde]
    return f"emitiendo {sorted(latidos)[-1]} 0" if latidos else "nada"


# Lo que EMITIR necesita en el móvil y no viene con la app (IOS-58).
DETECTOR = "bench-resources/players-centernet-mnv4.mlpackage/"
RIG = "rig.json"


def recursos(lista: dict[str, int]) -> list[str]:
    """✅/⚠️ de la calibración y del detector que busca EMITIR."""
    salida = []
    if RIG in lista:
        salida.append("✅ Documents/rig.json (la calibración del soporte)")
    else:
        salida.append("⚠️  sin Documents/rig.json: el cosido va con el soporte NOMINAL")
    if any(r.startswith(DETECTOR) for r in lista):
        salida.append("✅ el detector players-centernet-mnv4.mlpackage")
    else:
        salida.append("⚠️  sin bench-resources/players-centernet-mnv4.mlpackage: el director va sin detecciones")
    return salida


def _gb(b: float) -> str:
    return f"{b / BYTES_POR_GB:.1f} GB"


def espacio(lista: dict[str, int], desde: int) -> str:
    """Lo que ocupa Zero en el móvil, lo de la pasada y lo viejo por carpeta."""
    total = sum(lista.values())
    pasada = set(informes(lista, desde)) | set(medios(lista, desde, False))
    viejo: dict[str, int] = {}
    for r, b in lista.items():
        if r not in pasada:
            carpeta = r.split("/", 1)[0] if "/" in r else "(raíz)"
            viejo[carpeta] = viejo.get(carpeta, 0) + b
    grandes = ", ".join(f"{c} {_gb(b)}" for c, b in sorted(viejo.items(), key=lambda x: -x[1])[:4] if b > BYTES_POR_GB)
    return (f"Zero ocupa {_gb(total)}; esta pasada {_gb(sum(lista[r] for r in pasada))}; "
            f"de antes {_gb(total - sum(lista[r] for r in pasada))}" + (f" ({grandes})" if grandes else ""))


# ---------------------------------------------------------------------------------- ffprobe


def ffprobe(ruta: str) -> dict | None:
    """Lo que dice ffprobe del fichero, o None si no lo lee."""
    exe = shutil.which("ffprobe")
    if exe is None:
        return None
    r = subprocess.run(
        [exe, "-v", "error", "-show_entries",
         "format=duration,size:stream=codec_type,codec_name,width,height,avg_frame_rate,nb_frames", "-of", "json",
         ruta],
        capture_output=True, text=True, check=False,
    )
    if r.returncode != 0:
        return None
    try:
        datos = json.loads(r.stdout)
    except ValueError:
        return None
    return datos if datos.get("streams") else None


def _hms(s: float) -> str:
    s = int(round(s))
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


def verificar(carpeta: str) -> int:
    """Una línea por vídeo: se lee o no, cuánto dura y qué lleva. Devuelve los que fallan."""
    if shutil.which("ffprobe") is None:
        print("⚠️  sin ffprobe en el Mac (brew install ffmpeg): los vídeos no se comprueban")
        return 0
    malos = 0
    videos = sorted(glob.glob(os.path.join(carpeta, "**", "*.mov"), recursive=True)
                    + glob.glob(os.path.join(carpeta, "**", "*.ts"), recursive=True))
    if not videos:
        print("   (ningún vídeo recogido)")
    for v in videos:
        nombre = os.path.relpath(v, carpeta)
        if os.path.getsize(v) == 0:
            continue
        d = ffprobe(v)
        if d is None:
            malos += 1
            print(f"❌ {nombre}: no se lee ({_gb(os.path.getsize(v))})")
            continue
        dur = float(d.get("format", {}).get("duration") or 0)
        partes = []
        for s in d["streams"]:
            if s.get("codec_type") == "video":
                fps = s.get("avg_frame_rate", "0/1")
                num, _, den = fps.partition("/")
                f = float(num) / float(den) if den and float(den) else 0.0
                n = s.get("nb_frames")
                partes.append(f"{s.get('codec_name')} {s.get('width')}x{s.get('height')} {f:.1f} fps"
                              + (f", {int(n)} fotogramas" if n and str(n).isdigit() else ""))
            elif s.get("codec_type") == "audio":
                partes.append(s.get("codec_name", "audio"))
        print(f"✅ {nombre}: {_hms(dur)} ({_gb(os.path.getsize(v))}) · {' + '.join(partes)}")
    return malos


# --------------------------------------------------------------------------------- veredicto

# Los umbrales del veredicto (no son la aceptación de ninguna tarjeta: dicen qué mirar).
FPS_MIN = 28.0  # programFpsFloor de lib/src/constants.dart
LATENCIA_P95_MAX_MS = 150.0  # medida 143 ms con todo (2026-10-14); SPK-04 pide 120
MEMORIA_CRECE_MAX_MB = 300.0  # de lo del minuto 3 al máximo
RETROCESOS_MAX = 0.01  # vistas de dos lentes que salieron de una, sobre los fotogramas
COPIA_MIN = 0.99  # fotogramas en la copia .mov sobre los del programa
MINUTO_ESTABLE = 3  # los primeros minutos son el arranque (modelos, pools)
_TERMICA = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3}


def _pasadas_del_lado(bench: str, desde: int) -> list[tuple[str | None, str | None]]:
    """(informe final, latido) de cada pasada del lado desde `desde`, de la más vieja a la más
    nueva. Se emparejan por el arranque: el `bench_start_unix_ms` del informe es la hora del
    nombre del latido. Una app que murió deja solo el latido; una anterior al 2026-10-14, solo
    el informe."""
    grupos: dict[int, list[str | None]] = {}
    for ruta in glob.glob(os.path.join(bench, "*.json")):
        nombre = "bench/" + os.path.basename(ruta)
        if (m := _LATIDO.match(nombre)) and int(m.group(2)) >= desde:
            grupos.setdefault(int(m.group(2)), [None, None])[1] = ruta
        elif (m := _FINAL.match(nombre)) and int(m.group(2)) >= desde:
            try:
                arranque = int(_lee(ruta).get("bench_start_unix_ms", 0)) // 1000
            except (OSError, ValueError):
                arranque = 0
            grupos.setdefault(arranque or int(m.group(2)), [None, None])[0] = ruta
    return [(f, l) for _, (f, l) in sorted(grupos.items())]


def _lee(ruta: str) -> dict:
    with open(ruta, encoding="utf-8") as f:
        return json.load(f)


class _Notas:
    def __init__(self) -> None:
        self.malas = 0
        self.avisos = 0

    def ok(self, texto: str) -> None:
        print(f"  ✅ {texto}")

    def aviso(self, texto: str) -> None:
        self.avisos += 1
        print(f"  ⚠️  {texto}")

    def mal(self, texto: str) -> None:
        self.malas += 1
        print(f"  ❌ {texto}")

    def info(self, texto: str) -> None:
        print(f"     {texto}")

    def si(self, bueno: bool, texto: str, grave: bool = True) -> None:
        if bueno:
            self.ok(texto)
        elif grave:
            self.mal(texto)
        else:
            self.aviso(texto)


def _comunes(d: dict, n: _Notas) -> None:
    """Memoria, térmica, batería y disco: lo de los dos papeles."""
    huella = d.get("footprint_mb")
    # El informe la trae por minuto; el latido, la de ahora.
    fp = [v for v in huella if isinstance(v, (int, float)) and v > 0] if isinstance(huella, list) else []
    if fp:
        base = fp[min(MINUTO_ESTABLE, len(fp) - 1)]
        crece = max(fp) - base
        n.si(crece <= MEMORIA_CRECE_MAX_MB,
             f"memoria {fp[0]:.0f} → máx {max(fp):.0f} → {fp[-1]:.0f} MB (+{crece:.0f} desde el minuto {MINUTO_ESTABLE})",
             grave=False)
    elif isinstance(huella, (int, float)):
        n.info(f"memoria {huella:.0f} MB (la del último latido)")
    termica = d.get("thermal_by_minute") or ([d["thermal"]] if d.get("thermal") else [])
    if termica:
        peor = max(termica, key=lambda t: _TERMICA.get(t, 3))
        texto = f"térmica: la peor {peor} ({', '.join(f'{t} {termica.count(t)} min' for t in _TERMICA if t in termica)})"
        nivel = _TERMICA.get(peor, 3)
        if nivel <= 1:
            n.ok(texto)
        elif nivel == 2:
            n.aviso(texto + " · busca sombra")
        else:
            n.mal(texto + " · el móvil recorta")
    bat = [b for b in d.get("battery_by_minute", []) if isinstance(b, (int, float)) and b >= 0]
    if len(bat) >= 2:
        minutos = len(bat) - 1
        gasto = (bat[0] - bat[-1]) * 100 / minutos * 60
        if gasto > 0:
            queda = bat[-1] * 100 / gasto * 60
            n.info(f"batería {bat[0] * 100:.0f} % → {bat[-1] * 100:.0f} % en {minutos} min: "
                   f"−{gasto:.0f} %/h, le quedarían {queda:.0f} min")
        else:
            n.info(f"batería {bat[0] * 100:.0f} % → {bat[-1] * 100:.0f} % (cargando)")
    elif isinstance(d.get("battery"), (int, float)) and d["battery"] >= 0:
        n.info(f"batería {d['battery'] * 100:.0f} % al final")
    disco = d.get("disk_free_gb_by_minute") or ([d["disk_free_gb"]] if "disk_free_gb" in d else [])
    if disco:
        n.info(f"disco libre {disco[0]:.1f} → {disco[-1]:.1f} GB")
    eventos = d.get("app_events") or []
    if eventos:
        n.aviso(f"la app: {'; '.join(eventos[-6:])}")


def _duracion_s(d: dict) -> float:
    """Lo que duró la pasada: `elapsed_s` (desde el 2026-10-14), o la del banco, o los minutos
    de la huella."""
    for clave in ("elapsed_s", "duration_s"):
        v = d.get(clave)
        if isinstance(v, (int, float)) and v > 0:
            return float(v)
    return 60.0 * max(len(d.get("footprint_mb") or []) if isinstance(d.get("footprint_mb"), list) else 0, 1)


def _maestro(d: dict, n: _Notas) -> None:
    frames = int(d.get("program_frames", 0))
    dur = _duracion_s(d)
    media = frames / dur
    p5 = d.get("program_fps_p5")
    n.si(frames > 0 and media >= FPS_MIN,
         f"programa: {frames} fotogramas, {media:.1f} fps de media" + (f", p5 {p5:.1f}" if isinstance(p5, (int, float)) else ""))
    dos, una = int(d.get("two_lens_frames", 0)), int(d.get("one_lens_frames", 0))
    if dos + una:
        n.info(f"dos lentes {dos} ({100 * dos / (dos + una):.0f} %) · una lente (masterOnly) {una}")
    retro = int(d.get("part_fallbacks", 0))
    n.si(retro <= RETROCESOS_MAX * max(frames, 1), f"retrocesos a una lente: {retro}", grave=False)
    torn = int(d.get("torn_frames", 0))
    n.si(torn == 0, f"desgarros: {torn}", grave=False)
    if "added_latency_ms_p95" in d:
        lat = float(d["added_latency_ms_p95"])
        n.si(lat <= LATENCIA_P95_MAX_MS, f"latencia añadida p95 {lat:.0f} ms (p50 {float(d.get('added_latency_ms_p50', 0)):.0f})",
             grave=False)
    saltados = int(d.get("program_skipped_instants", 0))
    if saltados:
        n.aviso(f"instantes del programa saltados: {saltados}")
    sin_propio = int(d.get("without_master_frame", 0))
    if sin_propio:
        n.aviso(f"instantes sin fotograma propio (SIN SEÑAL o la cámara parada): {sin_propio}")
    files = d.get("files") or {}
    segs = files.get("mov_segments") or ([files["mov"]] if files.get("mov") else [])
    mov = int(d.get("mov_video_frames", 0))
    if segs:
        n.si(mov >= COPIA_MIN * frames,
             f"copia .mov: {', '.join(os.path.basename(s) for s in segs)} · {mov} fotogramas"
             + (f" ({100 * mov / frames:.0f} % del programa)" if frames else ""))
    elif "RIG_SPLIT_NO_MOV" in (d.get("link_switches") or []):
        n.info("sin copia .mov (RIG_SPLIT_NO_MOV)")
    else:
        n.mal("sin copia .mov del programa")
    for fallo in d.get("mov_failures") or []:
        n.aviso(f"la copia se cortó: {fallo}")
    resets = d.get("vt_session_resets") or {}
    if any(resets.values()):
        n.aviso(f"VideoToolbox rehecho (volvió del segundo plano): {resets}")
    pub = d.get("publish") or {}
    origen = (pub.get("target") or {}).get("source") or d.get("publish_source", "")
    if origen == "none":
        n.info("SRT: sin destino (sin QR Soporte): lo esperado sin VPS")
    elif origen:
        tramos = pub.get("sessions") or []
        rec = sum(int(t.get("reconnects", 0)) for t in tramos)
        n.info(f"SRT a {(pub.get('target') or {}).get('host', '?')} ({origen}): {len(tramos)} tramos, {rec} reconexiones")
    det = d.get("detect") or {}
    runs = int(det.get("runs", d.get("detect_runs", 0)) or 0)
    n.si(runs > 0, f"detector: {runs} pasadas" + (f" · {det['error']}" if det.get("error") else ""), grave=False)
    n.si(d.get("rig") == "rig.json", f"geometría: {d.get('rig') or '?'}", grave=False)
    caidas = [p for p in d.get("peer_states", []) if str(p).endswith(":down")]
    if caidas:
        n.aviso(f"el esclavo se cayó {len(caidas)} veces")


def _esclavo(d: dict, n: _Notas) -> None:
    partes = int(d.get("slave_parts", 0))
    n.si(partes > 0, f"partes enviadas: {partes} · sin parte {d.get('slave_no_parts', 0)} · "
         f"sin vista {d.get('slave_without_view', 0)}")
    fallos = int(d.get("slave_render_failures", 0))
    if fallos:
        n.aviso(f"fallos de render de la parte: {fallos}")


def veredicto(carpeta: str, desde: int = 0) -> int:
    """Lee los informes de los dos lados y dice qué está bien y qué no. Devuelve los ❌."""
    n = _Notas()
    vistos = 0
    for lado, final, latido in [(lado, f, l) for lado in ("izquierdo", "derecho")
                                for f, l in _pasadas_del_lado(os.path.join(carpeta, lado, "bench"), desde)]:
        vistos += 1
        d = _lee(final) if final else _lee(latido)  # type: ignore[arg-type]
        papel = "MAESTRO" if d.get("role") == "master" else "ESCLAVO"
        que = "EMITIR" if d.get("purpose") == "production" else "banco"
        fuente = "informe final" if final else ("latido final" if d.get("finished") else "SOLO EL LATIDO")
        print(f"{papel} · {lado} ({d.get('device', '?')}) · {que} · {fuente} · {_duracion_s(d) / 60:.1f} min")
        if final is None:
            n.mal("sin informe final: la app no llegó a PARAR (murió, se cerró o sigue emitiendo); "
                  "se sabe lo del último latido")
        if d.get("problem"):
            n.mal(f"problema: {d['problem']}")
        if papel == "MAESTRO":
            _maestro(d, n)
        else:
            _esclavo(d, n)
        _comunes(d, n)
    if vistos == 0:
        n.mal("ningún informe de la pasada en la carpeta")
    total = "✅ en orden" if n.malas == 0 and n.avisos == 0 else (
        f"⚠️  en marcha, con {n.avisos} cosas que mirar" if n.malas == 0 else f"❌ {n.malas} fallos y {n.avisos} avisos")
    print(f"VEREDICTO: {total}")
    return n.malas


if __name__ == "__main__":
    orden = sys.argv[1]
    if orden == "verificar":
        sys.exit(1 if verificar(sys.argv[2]) else 0)
    if orden == "veredicto":
        sys.exit(1 if veredicto(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0) else 0)
    with open(sys.argv[2], encoding="utf-8", errors="replace") as fichero:
        lista_ = listado(fichero.read())
    if orden == "desde":
        print(desde_por_defecto(lista_))
    elif orden == "pasadas":
        for t, lado in pasadas(lista_):
            print(t, lado)
    elif orden == "informes":
        print("\n".join(informes(lista_, int(sys.argv[3]))))
    elif orden == "medios":
        sin = len(sys.argv) > 4 and sys.argv[4] == "1"
        for r in medios(lista_, int(sys.argv[3]), sin):
            print(r, lista_[r])
    elif orden == "k4":
        for r in medios(lista_, int(sys.argv[3]), False):
            if es_4k(r):
                print(r, lista_[r])
    elif orden == "recursos":
        print("\n".join(recursos(lista_)))
    elif orden == "estado":
        print(estado(lista_, int(sys.argv[3])))
    elif orden == "espacio":
        print(espacio(lista_, int(sys.argv[3])))
    else:
        sys.exit(f"orden desconocida: {orden}")
