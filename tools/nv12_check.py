"""Lee los volcados NV12 de IOS-15 con el formato acordado con ML-18.

    python3 tools/nv12_check.py <carpeta con .nv12> <muestra.png>

[u32 BE longitud][cabecera JSON][plano Y][plano CbCr], planos sin relleno. Comprueba
cada fichero, dice los intervalos de rig_ms y pasa el último a PNG (BT.709 de rango
limitado) para verlo. Necesita numpy y Pillow.
"""
import json, struct, sys, pathlib
import numpy as np
from PIL import Image

def lee(ruta):
    datos = ruta.read_bytes()
    (n,) = struct.unpack(">I", datos[:4])
    cab = json.loads(datos[4:4 + n])
    w, h = cab["width"], cab["height"]
    cuerpo = datos[4 + n:]
    assert len(cuerpo) == w * h * 3 // 2, f"{ruta.name}: {len(cuerpo)} B, se esperaban {w*h*3//2}"
    y = np.frombuffer(cuerpo[: w * h], np.uint8).reshape(h, w)
    c = np.frombuffer(cuerpo[w * h :], np.uint8).reshape(h // 2, w // 2, 2)
    return cab, y, c

def a_rgb(y, c):
    kr, kb = 0.2126, 0.0722
    yn = (y.astype(float) - 16) / 219
    cb = (np.repeat(np.repeat(c[..., 0], 2, 0), 2, 1).astype(float) - 128) / 224
    cr = (np.repeat(np.repeat(c[..., 1], 2, 0), 2, 1).astype(float) - 128) / 224
    r = yn + 2 * (1 - kr) * cr; b = yn + 2 * (1 - kb) * cb; g = (yn - kr * r - kb * b) / (1 - kr - kb)
    return np.clip(np.stack([r, g, b], -1) * 255, 0, 255).astype(np.uint8)

ficheros = sorted(pathlib.Path(sys.argv[1]).glob("*.nv12"))
rig = []
for f in ficheros:
    cab, y, c = lee(f)
    rig.append(cab["rig_ms"])
print(f"{len(ficheros)} volcados legibles; cabecera de ejemplo: {cab}")
print("intervalos rig_ms:", np.diff(rig).tolist() if len(rig) > 1 else [])
print("luma media/desv:", round(float(y.mean()), 1), round(float(y.std()), 1))
Image.fromarray(a_rgb(y, c)).resize((960, 540)).save(sys.argv[2])
