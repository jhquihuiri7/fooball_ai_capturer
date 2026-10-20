/// El tipo de evento que se transmite (ADR 0031 del repo football-ai): lo primero que se
/// elige al abrir la app.
///
/// El fútbol es lo de siempre: uno o dos móviles, el marcador, la jornada y las tarjetas. El
/// espectáculo (festivales, presentaciones artísticas) va con una cámara, EN VIVO, rótulos,
/// franjas y vídeos. El vóleibol, por ahora, con una cámara y sin gráficos.
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

  /// Solo el fútbol tiene marcador, reloj, jornada, tarjetas y dos móviles.
  bool get isFootball => this == EventKind.football;

  /// El tipo de `event_kind`; uno desconocido (o un maestro de antes, sin el campo) es fútbol.
  static EventKind fromWire(Object? wire) =>
      EventKind.values.where((EventKind k) => k.wire == wire).firstOrNull ?? EventKind.football;
}
