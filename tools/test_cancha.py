"""Pruebas de tools/cancha.py: python3 tools/test_cancha.py"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cancha import (  # noqa: E402
    MARGEN_PASADA_S,
    desde_por_defecto,
    espacio,
    estado,
    informes,
    listado,
    medios,
    pasadas,
    recursos,
    verificar,
    veredicto,
)

T = 1_792_000_000  # el arranque de EMITIR (s)
VIEJO = T - 86_400

# Como lo escribe devicectl (columnas, unidades con coma decimal, «Zero KB»).
LISTADO = f"""12:45:19  Acquired tunnel connection to device.
3480 files:
Name                                                     URL Resources                   Size          Modification date
------------------------------------------------------   -----------------------------   -----------   ------------------
Documents                                                Writable, Readable, Directory   576 bytes     11/10/26, 3:07 PM
Documents/rig.json                                       Writable, Readable              687 bytes     11/10/26, 1:40 PM
Documents/left-{VIEJO}.mov                               Writable, Readable              3,36 GB       4/10/26, 6:35 PM
Documents/bench/program-split-left-{VIEJO}.json          Writable, Readable              9 KB          4/10/26, 6:35 PM
Documents/bench/program-split-{VIEJO}.ts                 Writable, Readable              Zero KB       4/10/26, 6:35 PM
Documents/bench/program-live-left-{T}.json               Writable, Readable              3 KB          14/10/26, 6:35 PM
Documents/left-{T - 1}.mov                               Writable, Readable              22,5 GB       14/10/26, 6:35 PM
Documents/left-{T - 1}-2.mov                             Writable, Readable              104 MB        14/10/26, 6:35 PM
Documents/program-zero-{T}.mov                           Writable, Readable              1,27 GB       14/10/26, 6:35 PM
Documents/program-zero-{T}-2.mov                         Writable, Readable              12,5 MB       14/10/26, 6:35 PM
Documents/n0/zero-{T}-left.jsonl                         Writable, Readable              538 KB        14/10/26, 6:35 PM
Documents/calib/918925072/left-918925072.jpg             Writable, Readable              2,1 MB        14/10/26, 6:35 PM
"""


class Listado(unittest.TestCase):
    def test_rutas_y_tamanos_como_los_escribe_devicectl(self) -> None:
        lista = listado(LISTADO)
        self.assertNotIn("", lista)
        self.assertEqual(lista["rig.json"], 687)
        self.assertEqual(lista[f"left-{VIEJO}.mov"], 3_360_000_000)
        self.assertEqual(lista[f"program-zero-{T}-2.mov"], 12_500_000)
        self.assertEqual(lista[f"bench/program-split-{VIEJO}.ts"], 0)
        self.assertNotIn("Documents", lista)  # las carpetas no

    def test_un_numero_solo_son_bytes(self) -> None:
        self.assertEqual(listado("Documents/bench/a-1.json   812\n"), {"bench/a-1.json": 812})


class LaPasada(unittest.TestCase):
    def test_desde_el_latido_de_la_ultima(self) -> None:
        lista = listado(LISTADO)
        self.assertEqual(pasadas(lista), [(T, "left")])
        self.assertEqual(desde_por_defecto(lista), T - MARGEN_PASADA_S)

    def test_el_partido_que_se_corto_y_se_volvio_a_emitir_son_dos_pasadas(self) -> None:
        lista = {f"bench/program-live-left-{T}.json": 1, f"bench/program-live-left-{T + 3000}.json": 1,
                 f"bench/program-live-left-{VIEJO}.json": 1}
        self.assertEqual(desde_por_defecto(lista), T - MARGEN_PASADA_S)

    def test_sin_latido_por_la_4k_o_la_copia_mas_nuevas(self) -> None:
        lista = {k: v for k, v in listado(LISTADO).items() if "program-live" not in k}
        self.assertEqual(desde_por_defecto(lista), T - MARGEN_PASADA_S)
        self.assertEqual(desde_por_defecto({"rig.json": 1}), 0)

    def test_informes_solo_de_la_pasada(self) -> None:
        self.assertEqual(informes(listado(LISTADO), T - MARGEN_PASADA_S), [f"bench/program-live-left-{T}.json"])

    def test_medios_de_lo_pequeno_a_las_4k_sin_vacios_ni_viejos(self) -> None:
        lista = listado(LISTADO)
        desde = T - MARGEN_PASADA_S
        self.assertEqual(
            medios(lista, desde, False),
            [f"n0/zero-{T}-left.jsonl", f"program-zero-{T}-2.mov", f"program-zero-{T}.mov",
             f"left-{T - 1}-2.mov", f"left-{T - 1}.mov"],
        )
        self.assertEqual(medios(lista, desde, True), [f"n0/zero-{T}-left.jsonl", f"program-zero-{T}-2.mov",
                                                      f"program-zero-{T}.mov"])
        # El banco: su .mov y su .ts, la 4K de bench4k y las vistas.
        banco = {f"bench/program-split-{T}.mov": 9, f"bench/program-split-{T}.ts": 0,
                 f"bench4k/{T}/left-{T}.mov": 9, f"bench/program-views-{T}.jsonl": 9, f"bench/audio-{T}.aac": 9}
        self.assertEqual(medios(banco, T, False), [f"bench/audio-{T}.aac", f"bench/program-views-{T}.jsonl",
                                                   f"bench/program-split-{T}.mov", f"bench4k/{T}/left-{T}.mov"])


class Estado(unittest.TestCase):
    def test_nada_emitiendo_y_parado(self) -> None:
        self.assertEqual(estado({"rig.json": 1}, T), "nada")
        lista = {f"program-zero-{T}.mov": 12_000_000, f"bench/program-live-left-{T}.json": 3}
        self.assertEqual(estado(lista, T - 30), f"emitiendo program-zero-{T}.mov 12")
        self.assertEqual(estado({f"bench/program-live-left-{T}.json": 3}, T - 30),
                         f"emitiendo bench/program-live-left-{T}.json 0")
        lista[f"bench/program-split-left-{T + 600}.json"] = 9
        self.assertEqual(estado(lista, T - 30), f"parado bench/program-split-left-{T + 600}.json")
        # Un informe viejo no es la parada de esta pasada.
        self.assertEqual(estado({f"bench/program-split-left-{VIEJO}.json": 9}, T - 30), "nada")

    def test_recursos(self) -> None:
        self.assertEqual(recursos({"rig.json": 687, "bench-resources/players-centernet-mnv4.mlpackage/Manifest.json": 1}),
                         ["✅ Documents/rig.json (la calibración del soporte)",
                          "✅ el detector players-centernet-mnv4.mlpackage"])
        faltan = recursos({"bench-resources/otro.mlpackage/Manifest.json": 1})
        self.assertTrue(all(x.startswith("⚠️") for x in faltan), faltan)

    def test_espacio(self) -> None:
        texto = espacio(listado(LISTADO), T - MARGEN_PASADA_S)
        self.assertTrue(texto.startswith("Zero ocupa 27.2 GB; esta pasada 23.9 GB; de antes 3.4 GB"), texto)
        self.assertIn("(raíz) 3.4 GB", texto)


def _informe(carpeta: str, nombre: str, **campos: object) -> None:
    os.makedirs(carpeta, exist_ok=True)
    base: dict = {"elapsed_s": 600.0, "footprint_mb": [360, 470, 478, 480, 482], "thermal_by_minute": ["nominal"] * 5}
    base.update(campos)
    with open(os.path.join(carpeta, nombre), "w", encoding="utf-8") as f:
        json.dump(base, f)


MAESTRO = dict(role="master", purpose="production", program_frames=18_000, two_lens_frames=9_000,
               one_lens_frames=9_000, part_fallbacks=3, torn_frames=0, added_latency_ms_p95=143.0, rig="rig.json",
               mov_video_frames=18_000, files={"mov": "program-zero-1.mov"}, detect={"runs": 10})


class Veredicto(unittest.TestCase):
    def _corre(self, carpeta: str, desde: int = 0) -> tuple[int, str]:
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            malas = veredicto(carpeta, desde)
        return malas, salida.getvalue()

    def test_en_orden(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            _informe(os.path.join(d, "izquierdo", "bench"), f"program-split-left-{T}.json", **MAESTRO)
            _informe(os.path.join(d, "derecho", "bench"), f"program-split-right-{T}.json", role="slave",
                     purpose="production", slave_parts=17_000)
            malas, texto = self._corre(d)
            self.assertEqual(malas, 0, texto)
            self.assertIn("VEREDICTO: ✅ en orden", texto)
            self.assertIn("MAESTRO · izquierdo", texto)
            self.assertIn("ESCLAVO · derecho", texto)

    def test_lo_que_falla_y_lo_que_avisa(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            mal = dict(MAESTRO, files={}, torn_frames=5, added_latency_ms_p95=190.0,
                       thermal_by_minute=["fair", "serious", "critical"], rig="nominal")
            _informe(os.path.join(d, "izquierdo", "bench"), f"program-split-left-{T}.json", **mal)
            malas, texto = self._corre(d)
            self.assertEqual(malas, 2, texto)  # sin copia .mov y la térmica crítica
            self.assertIn("❌ sin copia .mov del programa", texto)
            self.assertIn("⚠️  desgarros: 5", texto)
            self.assertIn("⚠️  latencia añadida p95 190 ms", texto)
            self.assertIn("❌ térmica: la peor critical", texto)
            self.assertIn("⚠️  geometría: nominal", texto)

    def test_sin_copia_por_el_interruptor_del_banco_no_es_un_fallo(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            _informe(os.path.join(d, "izquierdo", "bench"), f"program-split-left-{T}.json",
                     **dict(MAESTRO, files={}, link_switches=["RIG_SPLIT_NO_MOV"], purpose="bench"))
            malas, texto = self._corre(d)
            self.assertEqual(malas, 0, texto)
            self.assertIn("sin copia .mov (RIG_SPLIT_NO_MOV)", texto)

    def test_solo_el_latido_si_la_app_murio(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            _informe(os.path.join(d, "izquierdo", "bench"), f"program-live-left-{T}.json",
                     **dict(MAESTRO, finished=False, footprint_mb=480.0))
            malas, texto = self._corre(d)
            self.assertIn("SOLO EL LATIDO", texto)
            self.assertEqual(malas, 1, texto)

    def test_la_app_que_murio_y_se_volvio_a_emitir_son_dos_pasadas(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            bench = os.path.join(d, "izquierdo", "bench")
            _informe(bench, f"program-live-left-{T}.json", **dict(MAESTRO, finished=False, footprint_mb=480.0))
            _informe(bench, f"program-live-left-{T + 3000}.json", **dict(MAESTRO, finished=True, footprint_mb=480.0))
            _informe(bench, f"program-split-left-{T + 6000}.json", **dict(MAESTRO, bench_start_unix_ms=(T + 3000) * 1000))
            malas, texto = self._corre(d, T - 60)
            self.assertEqual(texto.count("MAESTRO · izquierdo"), 2, texto)
            self.assertEqual(texto.count("SOLO EL LATIDO"), 1, texto)
            self.assertEqual(texto.count("informe final"), 2, texto)  # el aviso de la primera y la segunda
            self.assertEqual(malas, 1, texto)

    def test_lo_de_antes_de_la_pasada_no_cuenta(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            _informe(os.path.join(d, "izquierdo", "bench"), f"program-split-left-{VIEJO}.json", **MAESTRO)
            malas, texto = self._corre(d, T)
            self.assertIn("ningún informe de la pasada", texto)
            self.assertEqual(malas, 1)


@unittest.skipIf(shutil.which("ffprobe") is None, "sin ffprobe")
class Verificar(unittest.TestCase):
    def test_un_fichero_que_no_es_video_falla(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "roto.mov"), "wb") as f:
                f.write(b"no es un mov" * 100)
            salida = io.StringIO()
            with contextlib.redirect_stdout(salida):
                self.assertEqual(verificar(d), 1)
            self.assertIn("❌ roto.mov: no se lee", salida.getvalue())


if __name__ == "__main__":
    unittest.main()
