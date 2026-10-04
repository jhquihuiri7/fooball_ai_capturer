/// `round()` de Python (y `np.round`): a mitad, al par. Las maquetas del repo
/// football-ai redondean así sus medidas, y 4,5 px son 4, no 5.
library;

int pyRound(double v) {
  final double suelo = v.floorToDouble();
  final double resto = v - suelo;
  if (resto > 0.5) return suelo.toInt() + 1;
  if (resto < 0.5) return suelo.toInt();
  return suelo.toInt().isEven ? suelo.toInt() : suelo.toInt() + 1;
}
