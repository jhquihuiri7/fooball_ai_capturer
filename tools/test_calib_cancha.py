"""Pruebas de tools/calib_cancha.py: python3 tools/test_calib_cancha.py"""

from __future__ import annotations

import copy
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from calib_cancha import (  # noqa: E402
    PARECIDO_MAX_DEG,
    compara,
    disparo,
    enlace,
    ficheros,
    ids,
    latido,
    listos,
    resultado,
)


def _lista(*rutas: str) -> dict[str, int]:
    return {r: 100 for r in rutas}


VIEJO = "500000"
NUEVO = "1004334720"
ANTES_IZQ = _lista(f"calib/{VIEJO}/left-{VIEJO}.jpg", f"calib/{VIEJO}/summary-left.json", "rig.json")
ANTES_DER = _lista(f"calib/{VIEJO}/right-{VIEJO}.jpg", f"calib/{VIEJO}/summary-right.json", "rig.json")


def _con(antes: dict[str, int], lado: str, resumen: bool) -> dict[str, int]:
    ahora = dict(antes)
    ahora[f"calib/{NUEVO}/{lado}-{NUEVO}.jpg"] = 100
    ahora[f"calib/{NUEVO}/{lado}-{NUEVO}.json"] = 100
    if resumen:
        ahora[f"calib/{NUEVO}/summary-{lado}.json"] = 100
    return ahora


# El rig.json del trípode (2026-10-11), en radianes.
RIG = {
    "version": 1,
    "left": {"intrinsics": {"fx": 1440.3}, "pose": {"yaw_rad": -0.7108, "pitch_rad": -0.1396, "roll_rad": 0.0}},
    "right": {"intrinsics": {"fx": 1429.2}, "pose": {"yaw_rad": 0.7108, "pitch_rad": -0.0974, "roll_rad": -0.1084}},
}


def _girado(rig: dict, lado: str, eje: str, grados: float) -> dict:
    otro = copy.deepcopy(rig)
    otro[lado]["pose"][f"{eje}_rad"] += math.radians(grados)
    return otro


CALIBRA = {
    "calibrated": True, "chosen_instant_ms": 2, "out": "rig.json", "error": None, "min_inliers": 30,
    "ransac_threshold_px": 3.0,
    "attempts": [
        {"instant_ms": 1, "delta_ms": 3, "failure": "solo hay 14 emparejamientos entre las dos imagenes"},
        {"instant_ms": 2, "delta_ms": -2, "failure": None, "inliers": 100, "matches": 199, "residual_deg": 0.061,
         "cameras": {"left": {"yaw_deg": -40.73, "pitch_deg": -8.0, "roll_deg": 0.0},
                     "right": {"yaw_deg": 40.73, "pitch_deg": -5.58, "roll_deg": -6.21}}},
    ],
}


class Disparo(unittest.TestCase):
    def test_ids_y_listos(self) -> None:
        ahora = _con(ANTES_IZQ, "left", resumen=False)
        self.assertEqual(ids(ahora), {VIEJO, NUEVO})
        self.assertEqual(listos(ahora, "left"), {VIEJO})
        self.assertEqual(listos(ahora, "right"), set())

    def test_el_nuevo_cuando_los_dos_lo_terminan(self) -> None:
        izq, der = _con(ANTES_IZQ, "left", True), _con(ANTES_DER, "right", True)
        self.assertEqual(disparo(ANTES_IZQ, izq, ANTES_DER, der), NUEVO)

    def test_mientras_a_uno_le_falta_el_resumen_no_hay(self) -> None:
        izq, der = _con(ANTES_IZQ, "left", True), _con(ANTES_DER, "right", False)
        self.assertIsNone(disparo(ANTES_IZQ, izq, ANTES_DER, der))

    def test_lo_que_ya_estaba_no_es_nuevo(self) -> None:
        self.assertIsNone(disparo(ANTES_IZQ, ANTES_IZQ, ANTES_DER, ANTES_DER))

    def test_el_resumen_del_otro_lado_no_cuenta(self) -> None:
        izq = dict(ANTES_IZQ)
        izq[f"calib/{NUEVO}/summary-right.json"] = 10
        self.assertIsNone(disparo(ANTES_IZQ, izq, ANTES_DER, _con(ANTES_DER, "right", True)))

    def test_ficheros_solo_los_de_ese_disparo(self) -> None:
        self.assertEqual(ficheros(_con(ANTES_IZQ, "left", True), NUEVO), [
            f"calib/{NUEVO}/left-{NUEVO}.jpg", f"calib/{NUEVO}/left-{NUEVO}.json", f"calib/{NUEVO}/summary-left.json"])


class Resultado(unittest.TestCase):
    def test_calibra_con_la_elegida_y_sus_angulos(self) -> None:
        bien, lineas = resultado(CALIBRA)
        texto = "\n".join(lineas)
        self.assertTrue(bien)
        self.assertIn("2 parejas; calibran 1 (hacen falta 30 puntos coherentes, RANSAC 3.0 px)", texto)
        self.assertIn("✅ CALIBRA con la pareja 2: 100 de 199 puntos coherentes, residuo 0.061°", texto)
        self.assertIn("cámara derecha   yaw  +40.73°  pitch   -5.58°  roll   -6.21°", texto)
        self.assertIn("1 (+3 ms): solo hay 14 emparejamientos", texto)

    def test_no_calibra_dice_cada_motivo(self) -> None:
        malo = dict(CALIBRA, calibrated=False, chosen_instant_ms=None, attempts=CALIBRA["attempts"][:1])
        bien, lineas = resultado(malo)
        self.assertFalse(bien)
        self.assertIn("solo hay 14 emparejamientos", "\n".join(lineas))
        self.assertEqual(lineas[-1], "❌ NO CALIBRA: ninguna de las 1 parejas")

    def test_sin_empezar_dice_el_error(self) -> None:
        bien, lineas = resultado({"calibrated": False, "attempts": [], "error": "no existe x"})
        self.assertFalse(bien)
        self.assertEqual(lineas, ["   no existe x", "❌ NO CALIBRA"])


class Compara(unittest.TestCase):
    def test_el_mismo_se_parece(self) -> None:
        mayor, lineas = compara(RIG, RIG)
        self.assertEqual(mayor, 0.0)
        self.assertIn("✅ se parece al que tenía", lineas[-1])

    def test_un_poco_girado_se_parece_y_dice_donde(self) -> None:
        mayor, lineas = compara(_girado(RIG, "right", "roll", 0.2), RIG)
        self.assertAlmostEqual(mayor, 0.2, places=6)
        self.assertIn("(roll de la derecha)", lineas[-1])
        self.assertIn("✅", lineas[-1])
        self.assertIn("roll -6.21 → -6.01 (+0.20)", lineas[1])

    def test_mas_del_umbral_es_otro_montaje(self) -> None:
        mayor, lineas = compara(_girado(RIG, "left", "yaw", -(PARECIDO_MAX_DEG + 1)), RIG)
        self.assertGreater(mayor, PARECIDO_MAX_DEG)
        self.assertIn("⚠️  distinto del que tenía: 1.30° de diferencia (yaw de la izquierda)", lineas[-1])


class Latido(unittest.TestCase):
    def test_el_mas_nuevo_desde(self) -> None:
        lista = _lista("bench/program-live-left-100.json", "bench/program-live-left-300.json",
                       "bench/program-live-right-200.json")
        self.assertEqual(latido(lista, 150), "bench/program-live-left-300.json")
        self.assertIsNone(latido(lista, 400))

    def test_enlace(self) -> None:
        self.assertEqual(enlace({"link": {"summary": "enlace arriba", "medium": "aware"}}), "enlace arriba (aware)")
        self.assertEqual(enlace({"link": {"summary": "no ve al otro en 600 s"}}), "no ve al otro en 600 s")
        self.assertEqual(enlace({}), "el latido no dice nada del enlace")


if __name__ == "__main__":
    unittest.main()
