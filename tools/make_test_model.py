"""El modelo mínimo de los tests del ejecutor Core ML (IOS-22).

Tiene la forma de un detector DETR de la ficha —entrada imagen RGB, salidas `logits`
[1, Q, C] y `boxes` [1, Q, 4] en cxcywh normalizado— pero es diminuto y determinista:
las salidas son funciones lineales de la media de la imagen, así el test sabe qué
esperar. Se regenera con:

    uvx --python 3.12 --from coremltools==8.3 python tools/make_test_model.py

y deja ios/ZeroKit/Tests/RigMediaTests/Fixtures/tiny-detr.mlpackage (pocos KB).
"""

import sys
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb

Q, C, H, W = 10, 3, 32, 64


@mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, H, W))], opset_version=ct.target.iOS17)
def prog(image):
    media = mb.reduce_mean(x=image, axes=[1, 2, 3], keep_dims=False)  # [1]
    m = mb.reshape(x=media, shape=[1, 1, 1])
    logits = mb.add(x=mb.mul(x=m, y=np.full((1, Q, C), 2.0, np.float32)),
                    y=np.linspace(-3, 3, Q * C, dtype=np.float32).reshape(1, Q, C), name="logits")
    boxes = mb.add(x=mb.mul(x=m, y=np.zeros((1, Q, 4), np.float32)),
                   y=np.tile(np.array([0.5, 0.5, 0.1, 0.2], np.float32), (1, Q, 1)), name="boxes")
    return logits, boxes


modelo = ct.convert(
    prog,
    inputs=[ct.ImageType(name="image", shape=(1, 3, H, W), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
)
destino = Path(sys.argv[1] if len(sys.argv) > 1 else "ios/ZeroKit/Tests/RigMediaTests/Fixtures/tiny-detr.mlpackage")
modelo.save(str(destino))
print("escrito", destino)
