/// El tipo de evento que se transmite (ADR 0031 del repo football-ai): lo primero que se
/// elige al abrir la app.
///
/// El fútbol es lo de siempre: uno o dos móviles, el marcador, la jornada y las tarjetas. El
/// espectáculo (festivales, presentaciones artísticas) va con una cámara, EN VIVO, rótulos,
/// franjas y vídeos. El vóleibol va como el fútbol, con uno o dos móviles (enmienda del ADR 0031
/// del 2026-11-03), pero por ahora sin gráficos.
library;

enum EventKind {
  football('football', 'Fútbol'),
  show('show', 'Espectáculo'),
  volleyball('volleyball', 'Vóleibol');

  const EventKind(this.wire, this.label);

  /// Como va en el estado del maestro (`event_kind`).
  final String wire;

  /// Como se lee en la pantalla.
  final String label;

  /// Solo el fútbol tiene marcador, reloj, jornada, tarjetas y el mando nativo.
  bool get isFootball => this == EventKind.football;

  /// Va con el soporte, de uno o dos móviles: el fútbol y el vóley. El espectáculo, con una
  /// cámara.
  bool get usesRig => this == EventKind.football || this == EventKind.volleyball;

  /// El tipo de `event_kind`; uno desconocido (o un maestro de antes, sin el campo) es fútbol.
  static EventKind fromWire(Object? wire) =>
      EventKind.values.where((EventKind k) => k.wire == wire).firstOrNull ?? EventKind.football;
}
