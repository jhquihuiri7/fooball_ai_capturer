"""Pruebas de tools/recogida_pasada.py: python3 tools/test_recogida_pasada.py"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from recogida_pasada import calib, informes, resumen, rutas, ventana_calib

INICIO = 1_792_000_000  # el arranque del banco en la Mac (s)
DESDE = INICIO - 30  # con el margen del reloj del móvil
RIG0 = 918_925_072  # bench_start_rig_ms de la pasada

LISTADO = f"""Name                                                   Size
-----------------------------------------------------  ------
Documents/
Documents/bench/
Documents/bench/audio-{INICIO - 3600}.json                  812
Documents/bench/program-split-left-{INICIO - 3000}.json     9000
Documents/bench/program-split-{INICIO - 3600}.ts            812000000
Documents/bench/link-bench-left-parcial.json            300
Documents/bench/audio-{INICIO - 5}.json                     812
Documents/bench/program-split-{INICIO + 20}.ts              812000000
Documents/bench/program-split-left-{INICIO + 620}.json      9000
Documents/bench/program-views-{INICIO + 20}.jsonl           40000
Documents/calib/500000/left-500000.jpg                  900000
Documents/calib/{RIG0 + 33_000}/
Documents/calib/{RIG0 + 33_000}/left-{RIG0 + 33_000}.jpg      900000
Documents/calib/{RIG0 + 33_000}/summary-left.json       200
Documents/calib/9999999999/left-9999999999.jpg          900000
"""


class Rutas(unittest.TestCase):
    def test_solo_documents_sin_carpetas_ni_cabecera(self) -> None:
        r = rutas(LISTADO)
        self.assertIn(f"bench/audio-{INICIO - 5}.json", r)
        self.assertNotIn("bench/", r)
        self.assertFalse(any(x.startswith(("Name", "-")) for x in r))

    def test_ruta_en_otra_columna(self) -> None:
        self.assertEqual(rutas("  812  Documents/bench/a-1.json  2026-10-14\n"), ["bench/a-1.json"])


class Informes(unittest.TestCase):
    def test_solo_esta_pasada_y_su_ts(self) -> None:
        self.assertEqual(
            informes(rutas(LISTADO), DESDE),
            [
                f"bench/audio-{INICIO - 5}.json",  # el reloj del móvil, 5 s por detrás
                "bench/link-bench-left-parcial.json",  # sin hora en el nombre
                f"bench/program-split-left-{INICIO + 620}.json",
                f"bench/program-split-{INICIO + 20}.ts",
            ],
        )

    def test_sin_ts_de_la_pasada_no_trae_el_viejo(self) -> None:
        lista = [f"bench/program-split-{INICIO - 3600}.ts"]
        self.assertEqual(informes(lista, DESDE), [])


def _informe(carpeta: str, lado: str, hora: int, rig0: int | None, files: dict | None = None) -> None:
    os.makedirs(carpeta, exist_ok=True)
    inf: dict = {"duration_s": 600, "files": files or {}}
    if rig0 is not None:
        inf["bench_start_rig_ms"] = rig0
    with open(os.path.join(carpeta, f"program-split-{lado}-{hora}.json"), "w", encoding="utf-8") as f:
        json.dump(inf, f)


class Calib(unittest.TestCase):
    def test_la_carpeta_de_la_pasada_por_el_informe_de_cualquier_lado(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            izq, der = os.path.join(d, "izquierdo", "bench"), os.path.join(d, "derecho", "bench")
            os.makedirs(izq)
            _informe(der, "right", INICIO + 620, RIG0)
            _informe(der, "right", INICIO - 3000, 500_000)  # una pasada vieja: no cuenta
            v = ventana_calib([izq, der], DESDE)
            self.assertEqual(
                calib(rutas(LISTADO), v),
                [f"calib/{RIG0 + 33_000}/left-{RIG0 + 33_000}.jpg", f"calib/{RIG0 + 33_000}/summary-left.json"],
            )

    def test_sin_informe_no_trae_ninguna(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            _informe(d, "left", INICIO + 620, None)  # sin bench_start_rig_ms
            self.assertIsNone(ventana_calib([d], DESDE))
            self.assertEqual(calib(rutas(LISTADO), None), [])


class Resumen(unittest.TestCase):
    def test_lo_traido_y_lo_que_falta(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            lado = os.path.join(d, "izquierdo")
            k4 = f"bench4k/{INICIO + 20}/left-{INICIO + 20}.mov"
            _informe(
                os.path.join(lado, "bench"),
                "left",
                INICIO + 620,
                RIG0,
                {"mov": f"bench/program-split-{INICIO + 20}.mov", "rec4k": [k4]},
            )
            with open(os.path.join(lado, "bench", f"program-split-{INICIO + 20}.ts"), "wb") as f:
                f.write(b"x" * 2_000_000)
            os.makedirs(os.path.join(lado, "calib", "918958072"))
            with open(os.path.join(lado, "no-copiados.txt"), "w", encoding="utf-8") as f:
                f.write(k4 + "\n")
            r = resumen(lado, DESDE, False)
            self.assertTrue(r.startswith("izquierdo: 1 informes (program-split-left-"), r)
            self.assertIn(".ts 2.0 MB", r)
            self.assertIn("lo del informe 0 de 1", r)
            self.assertIn("4K 0 de 1", r)
            self.assertIn("calib 918958072 (0 ficheros)", r)
            self.assertIn(f"NO copiados (1): {k4}", r)
            self.assertIn("4K en el móvil", resumen(lado, DESDE, True))

    def test_sin_listado(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            lado = os.path.join(d, "derecho")
            os.makedirs(lado)
            open(os.path.join(lado, "sin-listado.txt"), "w").close()
            self.assertTrue(resumen(lado, DESDE, False).startswith("derecho: NADA"))


if __name__ == "__main__":
    unittest.main()
