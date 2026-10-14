"""El desfase A/V del programa o de la 4K con palmadas delante de la cámara (IOS-54).

    python3 tools/av_clap.py <program-split-<t>.ts | <lado>-<t>.mov de la 4K> [--hojas <carpeta>]

El programa, en su .ts: la copia .mov (ProgramRecorder, AAC sin recodificar) la lee
ffmpeg 44 ms tarde, aunque AVFoundation la lee bien (medido el 2026-10-14).

Una palmada suena y se ve a la vez. Por cada una:
  - el audio da su arranque con precisión de muestra (la primera por encima del 30 % de su
    pico);
  - el vídeo, el intervalo entre fotogramas en que las manos se paran: el último que se
    mueve tras el de más movimiento, que se mueve solo la parte de su duración anterior al
    contacto (las manos llegan a velocidad casi constante). El movimiento es la media de
    |diferencia| entre fotogramas, que crece con lo que se desplazan los bordes, menos el
    ruido de la ventana. Da el contacto con resolución de unos ms; con 10 palmadas o más,
    la mediana es la cifra.
Desfase = audio − contacto: positivo, el audio va tarde. La aceptación de IOS-54 es
±20 ms (objetivo). Con palmadas al principio y al final de una pasada larga, la mediana de
cada minuto dice además si el audio deriva.

Los instantes salen de ffmpeg con -copyts (showinfo y ashowinfo), en el mismo eje que el
rigMs del programa (PTS = rigMs × 90). Con --hojas deja, por palmada, una tira de
fotogramas alrededor del contacto para comprobarlo a ojo. Necesita ffmpeg, numpy y, para
las hojas, Pillow.
"""

import argparse
import pathlib
import re
import subprocess
import sys

import numpy as np

ANCHO = 160  # px del vídeo reducido para medir el movimiento
RATE = 48_000  # Hz del audio decodificado
PICO_ARRANQUE = 0.3  # el arranque: la primera muestra por encima de esta parte del pico
ANTES_DEL_PICO_S = 0.05  # dónde se busca el arranque, antes del pico
SEPARACION_S = 1.0  # dos palmadas, al menos esto separadas
UMBRAL_RUIDO = 10.0  # una palmada supera esto × la mediana del nivel
UMBRAL_PICO = 0.1  # y esta parte del pico más alto de la pasada
VENTANA_S = (-0.5, 0.3)  # los fotogramas que se miran alrededor del sonido
QUIETO = 0.05  # un intervalo está quieto si se mueve menos que esto × el pico
OBJETIVO_MS = 20.0
DISPERSION_MS = 10.0  # más, y no eran todo palmadas limpias (en el Mac, sintéticas: <1 ms)

PTS = re.compile(r"pts_time:\s*(-?[0-9.]+)")


def ffmpeg_info(args: list[str]) -> tuple[bytes, list[float]]:
    """Corre ffmpeg con -copyts y devuelve su salida y los pts_time de (a)showinfo."""
    r = subprocess.run(
        ["ffmpeg", "-v", "info", "-hide_banner", "-copyts", *args],
        capture_output=True,
        check=True,
    )
    tiempos = [float(m.group(1)) for linea in r.stderr.decode(errors="replace").splitlines()
               if "showinfo" in linea and (m := PTS.search(linea))]
    return r.stdout, tiempos


def audio(fichero: str) -> tuple[np.ndarray, float]:
    """El audio en mono a 48 kHz y el instante de su primera muestra."""
    crudo, tiempos = ffmpeg_info(["-i", fichero, "-map", "0:a:0", "-ac", "1", "-ar", str(RATE),
                                  "-af", "ashowinfo", "-f", "f32le", "-"])
    if not tiempos:
        sys.exit("sin audio")
    return np.frombuffer(crudo, np.float32), tiempos[0]


def video(fichero: str) -> tuple[np.ndarray, np.ndarray]:
    """Los fotogramas en gris reducidos y su instante."""
    crudo, tiempos = ffmpeg_info(["-i", fichero, "-map", "0:v:0", "-fps_mode", "passthrough",
                                  "-vf", f"scale={ANCHO}:-2,format=gray,showinfo",
                                  "-f", "rawvideo", "-"])
    n = len(tiempos)
    alto = len(crudo) // (n * ANCHO)
    return np.frombuffer(crudo, np.uint8).reshape(n, alto, ANCHO), np.array(tiempos)


def palmadas(x: np.ndarray, t0: float) -> list[float]:
    """El instante de arranque de cada palmada."""
    nivel = np.abs(x)
    umbral = max(UMBRAL_RUIDO * float(np.median(nivel)), UMBRAL_PICO * float(nivel.max()))
    arranques: list[float] = []
    i = 0
    paso = int(SEPARACION_S * RATE)
    candidatos = np.flatnonzero(nivel > umbral)
    while i < len(candidatos):
        inicio = candidatos[i]
        trozo = nivel[inicio: inicio + paso]
        pico = inicio + int(trozo.argmax())
        desde = max(0, pico - int(ANTES_DEL_PICO_S * RATE))
        sobre = np.flatnonzero(nivel[desde: pico + 1] > PICO_ARRANQUE * nivel[pico])
        arranques.append(t0 + (desde + int(sobre[0])) / RATE)
        i = int(np.searchsorted(candidatos, inicio + paso))
    return arranques


def contacto(fotos: np.ndarray, tiempos: np.ndarray, sonido: float) -> tuple[float, int] | None:
    """El instante estimado del contacto y el primer fotograma con las manos juntas."""
    dentro = np.flatnonzero((tiempos >= sonido + VENTANA_S[0]) & (tiempos <= sonido + VENTANA_S[1]))
    if len(dentro) < 4:
        return None
    # mov[j]: lo que cambió del fotograma dentro[j-1] al dentro[j].
    mov = np.array([0.0] + [float(np.mean(np.abs(fotos[k].astype(np.int16) - fotos[k - 1])))
                            for k in dentro[1:]])
    mov = np.clip(mov - np.median(mov), 0, None)
    # Desde el pico (un intervalo entero a toda velocidad), el último que aún se mueve: el
    # contacto cae dentro, en la parte que se movió.
    pleno = float(mov.max())
    q = int(np.argmax(mov))
    if pleno == 0 or q == 0:
        return None
    while q + 1 < len(mov) and mov[q + 1] > QUIETO * pleno:
        q += 1
    parte = min(1.0, float(mov[q]) / pleno)
    t_antes, t_q = float(tiempos[dentro[q - 1]]), float(tiempos[dentro[q]])
    return t_antes + parte * (t_q - t_antes), int(dentro[q])


def hoja(fotos: np.ndarray, tiempos: np.ndarray, c: int, sonido: float, ruta: pathlib.Path) -> None:
    """Seis fotogramas alrededor del contacto, con su instante frente al sonido; el
    primero con las manos juntas, marcado con *."""
    from PIL import Image, ImageDraw

    ks = [k for k in range(c - 3, c + 3) if 0 <= k < len(fotos)]
    alto = fotos.shape[1]
    tira = Image.new("L", (ANCHO * len(ks), alto + 14), 0)
    dibujo = ImageDraw.Draw(tira)
    for j, k in enumerate(ks):
        tira.paste(Image.fromarray(fotos[k]), (j * ANCHO, 14))
        marca = "*" if k == c else ""
        dibujo.text((j * ANCHO + 2, 1), f"{(tiempos[k] - sonido) * 1000:+.0f} ms{marca}", fill=255)
    tira.resize((tira.width * 2, tira.height * 2)).save(ruta)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fichero")
    ap.add_argument("--hojas", type=pathlib.Path, help="carpeta para las tiras de cada palmada")
    a = ap.parse_args()

    x, t0 = audio(a.fichero)
    fotos, tiempos = video(a.fichero)
    print(f"audio desde {t0:.3f} s ({len(x) / RATE:.1f} s); vídeo {len(tiempos)} fotogramas "
          f"desde {tiempos[0]:.3f} s")
    desfases = []
    por_minuto: dict[int, list[float]] = {}
    sonidos = palmadas(x, t0)
    for n, sonido in enumerate(sonidos, 1):
        r = contacto(fotos, tiempos, sonido)
        if r is None:
            print(f"palmada {n} a {sonido:.3f} s: no se ve el contacto")
            continue
        visto, c = r
        d = (sonido - visto) * 1000
        desfases.append(d)
        por_minuto.setdefault(int((sonido - sonidos[0]) // 60), []).append(d)
        print(f"palmada {n}: audio {sonido:.4f} s · contacto {visto:.4f} s (fotograma {c}) · desfase {d:+.1f} ms")
        if a.hojas:
            a.hojas.mkdir(parents=True, exist_ok=True)
            hoja(fotos, tiempos, c, sonido, a.hojas / f"palmada-{n:02d}.png")
    if not desfases:
        sys.exit("ninguna palmada medida")
    med = float(np.median(desfases))
    print(f"{len(desfases)} palmadas: mediana {med:+.1f} ms, media {np.mean(desfases):+.1f}, "
          f"desviación {np.std(desfases):.1f} (audio − vídeo; objetivo ±{OBJETIVO_MS:.0f} ms)")
    if len(por_minuto) > 1:  # palmadas al principio y al final: la deriva se vería aquí
        for m, ds in sorted(por_minuto.items()):
            print(f"  minuto {m}: mediana {np.median(ds):+.1f} ms ({len(ds)} palmadas)")
    if np.std(desfases) > DISPERSION_MS:
        print(f"dispersión de más de {DISPERSION_MS:.0f} ms: ¿todo eran palmadas? Mírese con --hojas")
    print("ok" if abs(med) <= OBJETIVO_MS else "FUERA del objetivo")


if __name__ == "__main__":
    main()
