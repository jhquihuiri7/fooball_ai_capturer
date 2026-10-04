// Generado por tools/export_overlay_spec.py. NO EDITAR A MANO.
//
// Fuente de verdad: tools/overlay_preview.py (medidas y paleta del gráfico),
// tools/lineup_card.py (la alineación), tools/ad_strip.py (los fundidos) y
// tools/program_contract.py (formato del programa). Para regenerarlo:
//
//     uv run python tools/export_overlay_spec.py
//
// El guardián falla si este fichero se queda atrás.


/// Las medidas del gráfico, derivadas de Python (REF-32). Px sobre 1920.
abstract final class OverlaySpec {
  static const int programWidth = 1920;
  static const int programHeight = 1080;
  static const double programFps = 30.0;
  static const double refWidth = 1920.0;
  static const int stripHeight = 108;
  static const int margin = 48;
  static const int stripTop = 972;

  /// Paleta en ARGB de 32 bits, lista para Color(valor).
  static const Map<String, int> colorsArgb = {
    'bar': 0xF0060A0B, // Fondo de la franja. Lo pinta el panel: el anuncio va encima, con alfa.
    'edge': 0x1AFFFFFF, // Filete de 1 px que separa la franja del césped.
    'home': 0xFFF26A24, // Color del equipo local. Un anuncio no debe usarlo: se lee como marcador.
    'away': 0xFF16B3A6, // Color del equipo visitante. Misma razón para no usarlo.
    'live': 0xFFE11D26, // Rojo del indicador EN DIRECTO. Reservado; ningún anuncio lo usa.
    'leaf': 0xFF7CC242, // Verde institucional del claim de la franja.
    'white': 0xFFFFFFFF, // Texto principal sobre la franja.
    'dim': 0xFF9AA8A6, // Texto secundario sobre la franja.
    'chrome': 0xE6090E0F, // Fondo del marcador (el bug).
    'chrome_soft': 0xD1090E0F, // Fondo del indicador de cámara.
  };

  /// Tamaños de letra, px sobre 1920.
  static const Map<String, int> fontSizes = {
    'team': 34,
    'score': 38,
    'clock': 32,
    'comp': 17,
    'live': 17,
    'cam': 18,
    'slot': 18,
    'sub': 16,
    'claim': 23,
    'ai': 17,
  };

  /// El marcador (overlay_preview.py).
  static const Map<String, int> scoreboard = {
    'bug_w': 704,
    'bug_h': 88,
    'bug_chamfer': 26,
    'crest_w': 86,
    'live_y': 148,
    'live_h': 30,
    'cam_y': 44,
    'cam_h': 38,
    'margin': 48,
  };

  /// La alineación (lineup_card.py).
  static const Map<String, int> lineup = {
    'margin_x': 60,
    'title_y': 50,
    'title_size': 72,
    'list_y': 150,
    'list_w': 500,
    'row_h': 42,
    'row_step': 50,
    'row_text_size': 26,
    'shadow_dy': 4,
    'subs_y': 718,
    'subs_title_size': 34,
    'subs_size': 25,
    'subs_line_h': 31,
    'bottom_pad': 24,
    'header_y': 52,
    'header_h': 76,
    'header_w': 720,
    'header_text_size': 44,
    'crest_r': 60,
  };

  /// Los anuncios: cadencia y fundidos (ad_strip.py).
  static const Map<String, int> ad = {
    'fps': 30,
    'fps_pod': 25,
    'beat_s': 10,
    'entry_frames': 10,
    'exit_frames': 10,
    'slide_px': 12,
  };

  /// El campo, las camisetas, el DT y los factores de color (lineup_card.py).
  static const Map<String, double> lineupGeometry = {
    'pitch_cx': 1270.0,
    'pitch_top': 170.0,
    'pitch_bottom': 790.0,
    'pitch_top_w': 880.0,
    'pitch_bottom_w': 1140.0,
    'slab_h': 26.0,
    'pitch_stripes': 10.0,
    'line_w': 3.0,
    'line_alpha': 120.0,
    'arc_samples': 72.0,
    'touch_u0': 0.02,
    'touch_u1': 0.98,
    'touch_t0': 0.02,
    'touch_t1': 0.98,
    'halfway_t': 0.06,
    'circle_ru': 0.12,
    'circle_rt': 0.1,
    'box_u0': 0.2,
    'box_u1': 0.8,
    'box_t0': 0.72,
    'box_t1': 0.98,
    'goal_box_u0': 0.37,
    'goal_box_u1': 0.63,
    'goal_box_t0': 0.9,
    'goal_box_t1': 0.98,
    'spot_t': 0.8,
    'd_ru': 0.1,
    'd_rt': 0.1,
    'keeper_t': 0.86,
    'back_t': 0.66,
    'front_t': 0.1,
    'line_spread': 0.8,
    'max_slot_gap': 0.27,
    'shirt_w': 72.0,
    'shirt_aspect': 0.92,
    'shirt_body': 0.28,
    'label_w': 196.0,
    'label_h': 28.0,
    'label_gap': 5.0,
    'label_text_size': 18.0,
    'coach_y': 846.0,
    'coach_h': 52.0,
    'coach_w': 460.0,
    'coach_text_size': 32.0,
    'role_h': 30.0,
    'role_w': 250.0,
    'role_gap': 6.0,
    'role_text_size': 18.0,
    'bg_top_k': 0.78,
    'bg_bottom_k': 0.55,
    'ink_k': 0.32,
    'slab_k': 0.5,
    'stripe_lighten': 0.12,
    'shirt_lighten': 0.22,
    'shadow_k': 0.42,
  };

  /// Colores fijos de la alineación, en ARGB.
  static const Map<String, int> lineupColorsArgb = {
    'shirt': 0xFF1E3A8A,
    'keeper_shirt': 0xFFF5C542,
    'crest_fill': 0xFF090E0F,
  };

  /// Textos fijos de la alineación.
  static const Map<String, String> lineupTexts = {
    'title': 'ALINEACIÓN',
    'subs_title': 'SUPLENTES',
    'role': 'DIRECTOR TÉCNICO',
  };

  /// Silueta de la camiseta en una caja de ancho 1: x en [-0.5, 0.5], y en [0, 1].
  static const List<(double, double)> lineupShirtShape = [
    (-0.17, 0.0),
    (-0.07, 0.07),
    (0.0, 0.09),
    (0.07, 0.07),
    (0.17, 0.0),
    (0.5, 0.14),
    (0.42, 0.4),
    (0.3, 0.36),
    (0.3, 1.0),
    (-0.3, 1.0),
    (-0.3, 0.36),
    (-0.42, 0.4),
    (-0.5, 0.14),
  ];

  /// Alturas de las rayas de la camiseta, en fracción de su alto.
  static const List<double> lineupShirtStripes = [0.34, 0.5, 0.66, 0.82];

  /// La tarjeta SIN SEÑAL (live_panel.py, §21.6).
  static const String slateText = 'SIN SEÑAL';
  /// Alto del texto, como fracción del alto del frame.
  static const double slateTextHeight = 0.08;
  static const int slateBackgroundArgb = 0xFF121212;
  static const int slateForegroundArgb = 0xFFE6ECEC;

}
