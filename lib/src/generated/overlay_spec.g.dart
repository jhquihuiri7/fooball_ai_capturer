// Generado por tools/export_overlay_spec.py. NO EDITAR A MANO.
//
// Fuente de verdad: tools/brand.py (la marca Gala Sports, ADR 0026),
// tools/overlay_preview.py (medidas y papeles de la paleta),
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
    'bar': 0xF007111F, // Fondo de la franja. Lo pinta el panel: el anuncio va encima, con alfa.
    'edge': 0xFF00E5C4, // Filete teal que separa la franja del césped.
    'home': 0xFF00E5C4, // Equipo local (teal). Un anuncio no lo usa de acento: se lee como marcador.
    'away': 0xFFFFFFFF, // Equipo visitante (blanco). Como acento tampoco; como texto, sí.
    'live': 0xFFE3141F, // Rojo de EN VIVO. Reservado; ningún anuncio lo usa.
    'white': 0xFFFFFFFF, // Texto principal sobre la franja.
    'dim': 0xFF94A3B8, // Texto secundario sobre la franja.
    'chrome': 0xFF101D2D, // Fondo del marcador (el bug).
    'chrome_soft': 0xE007111F, // Chips sobre el vídeo: cámara, reloj y competición.
  };

  /// Los tokens de la marca por su nombre, en ARGB (tools/brand.py).
  static const Map<String, int> brandArgb = {
    'teal-electrico': 0xFF00E5C4,
    'verde-oceano': 0xFF00A892,
    'azul-deportivo': 0xFF0066FF,
    'azul-profundo': 0xFF07111F,
    'azul-marino': 0xFF101D2D,
    'gris-claro': 0xFFF8FAFC,
    'gris-oceanico': 0xFF94A3B8,
    'amarillo-energia': 0xFFFFD43B,
    'rojo-vivo': 0xFFE3141F,
    'blanco': 0xFFFFFFFF,
    'gris-tinte': 0xFFD3DFEA,
  };

  /// Tamaños de letra, px sobre 1920.
  static const Map<String, int> fontSizes = {
    'team': 36,
    'score': 56,
    'clock': 32,
    'comp': 22,
    'live': 24,
    'cam': 22,
    'crest': 26,
    'slot': 22,
    'sub': 15,
    'claim': 30,
    'ai': 16,
  };

  /// Las familias: «display» es Barlow Condensed y «sans», Inter.
  static const Map<String, String> fontFamilies = {
    'display': 'Barlow Condensed',
    'sans': 'Inter',
  };

  /// La familia de cada texto.
  static const Map<String, String> fontFaces = {
    'team': 'display',
    'score': 'display',
    'clock': 'display',
    'comp': 'display',
    'live': 'sans',
    'cam': 'display',
    'crest': 'display',
    'slot': 'display',
    'sub': 'sans',
    'claim': 'display',
    'ai': 'sans',
  };

  /// El peso de cada texto.
  static const Map<String, int> fontWeights = {
    'team': 700,
    'score': 800,
    'clock': 700,
    'comp': 600,
    'live': 800,
    'cam': 700,
    'crest': 800,
    'slot': 700,
    'sub': 500,
    'claim': 700,
    'ai': 500,
  };

  /// La franja (overlay_preview.py).
  static const Map<String, int> strip = {
    'edge_h': 2,
    'reserved_left': 360,
    'reserved_right': 300,
    'logo_h': 48,
    'logo_gap': 16,
    'logo_src_w': 97,
    'logo_src_h': 84,
    'claim_line_h': 32,
    'divider_pad': 26,
    'slot_gap': 40,
    'slot_icon_r': 14,
    'raya_w': 6,
    'raya_h': 28,
    'raya_gap': 14,
  };

  /// La jornada (fixtures_card.py).
  static const Map<String, int> fixtures = {
    'max': 8,
    'time_max_chars': 16,
    'subtitle_max_chars': 32,
    'list_cy': 628,
    'row_pitch': 96,
    'band_half_w': 700,
    'band_h': 80,
    'band_alpha': 200,
    'time_w': 176,
    'time_h': 46,
    'time_size': 30,
    'time_dy_with_subtitle': 12,
    'subtitle_dy': -25,
    'subtitle_size': 20,
    'crest_w': 54,
    'crest_gap': 28,
    'crest_initials_size': 17,
    'name_gap': 18,
    'name_size': 38,
    'name_max_w': 430,
  };

  /// El entretiempo (halftime_card.py).
  static const Map<String, int> halftime = {
    'title_y': 118,
    'title_size': 80,
    'title_raya_w': 10,
    'title_raya_h': 56,
    'title_raya_gap': 28,
    'comp_y': 190,
    'comp_size': 30,
    'icon_cy': 430,
    'icon_box': 280,
    'isotipo_h': 200,
    'crest_w': 176,
    'crest_cy': 410,
    'crest_dx': 520,
    'crest_initials_size': 55,
    'name_y': 590,
    'name_size': 46,
    'name_max_w': 480,
    'score_y': 770,
    'score_h': 130,
    'score_size': 104,
    'goal_min_w': 150,
    'goal_pad_x': 28,
    'goal_dash_gap': 24,
    'veil_alpha': 153,
    'backdrop_blur_sigma': 24,
    'when_y': 770,
    'when_h': 104,
    'when_size': 56,
    'when_pad_x': 48,
    'when_min_w': 300,
    'venue_y': 872,
    'venue_size': 34,
    'guest_y': 664,
    'guest_size': 64,
    'guest_max_w': 1400,
    'role_y': 738,
    'role_size': 36,
  };

  /// El marcador (overlay_preview.py).
  static const Map<String, int> scoreboard = {
    'margin': 48,
    'top_y': 44,
    'status_h': 44,
    'status_pad_x': 56,
    'status_gap': 16,
    'status_to_bar': 18,
    'bar_h': 76,
    'tip_w': 18,
    'tip_overlap': 8,
    'body_pad_x': 28,
    'body_edge_h': 3,
    'row_gap': 22,
    'crest_w': 84,
    'crest_h': 100,
    'goals_margin': 6,
    'goal_min_w': 72,
    'goal_pad_x': 12,
    'goal_dash_gap': 14,
    'live_pad_l': 14,
    'live_pad_r': 16,
    'live_dot': 12,
    'live_gap': 10,
    'chip_pad_x': 16,
    'chip_gap': 10,
    'clock_ring': 2,
    'cam_icon_r': 9,
    'cam_icon_line': 2,
    'radius': 6,
    'skew_deg': 30,
    'shadow_dy': 4,
    'shadow_blur': 16,
    'shadow_alpha_pct': 40,
    'bar_shadow_alpha_pct': 45,
    'status_icon': 30,
    'status_icon_gap': 10,
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
    'crest_initials_size': 30,
    'header_edge_h': 3,
    'row_radius': 8,
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
    'shirt_stripe_k': 0.75,
  };

  /// Colores fijos de la alineación, en ARGB.
  static const Map<String, int> lineupColorsArgb = {
    'background': 0xFF07111F,
    'row_fill': 0xFF101D2D,
    'pitch_dark': 0xFF101D2D,
    'pitch_light': 0xFF1C2A3C,
    'slab': 0xFF0066FF,
    'chalk': 0xFF00E5C4,
    'keeper_shirt': 0xFF0066FF,
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

  /// Textos fijos del marcador.
  static const Map<String, String> scoreboardTexts = {
    'live': 'EN VIVO',
    'camera': 'CÁMARA IA',
  };

  /// El escudo genérico: su caja, el filo y la altura de las siglas (brand.py).
  static const Map<String, double> crest = {
    'box_w': 48.0,
    'box_h': 56.0,
    'stroke': 2.5,
    'initials_y': 31.0,
  };

  /// Silueta del escudo en su caja de 48×56, ya con las curvas en tramos.
  static const List<(double, double)> crestShape = [
    (24.0, 2.5),
    (43.5, 8.5),
    (43.5, 26.0),
    (43.4008, 28.4764),
    (43.1092, 30.8439),
    (42.6345, 33.104),
    (41.9859, 35.2578),
    (41.1727, 37.3068),
    (40.2041, 39.2521),
    (39.0893, 41.0953),
    (37.8375, 42.8375),
    (36.458, 44.4801),
    (34.96, 46.0244),
    (33.3527, 47.4718),
    (31.6453, 48.8234),
    (29.8471, 50.0808),
    (27.9674, 51.2451),
    (26.0153, 52.3177),
    (24.0, 53.3),
    (21.9847, 52.3177),
    (20.0326, 51.2451),
    (18.1529, 50.0808),
    (16.3547, 48.8234),
    (14.6473, 47.4718),
    (13.04, 46.0244),
    (11.542, 44.4801),
    (10.1625, 42.8375),
    (8.9107, 41.0953),
    (7.7959, 39.2521),
    (6.8273, 37.3068),
    (6.0141, 35.2578),
    (5.3655, 33.104),
    (4.8908, 30.8439),
    (4.5992, 28.4764),
    (4.5, 26.0),
    (4.5, 8.5),
  ];

  static const String halftimeTitle = 'ENTRETIEMPO';
  static const String fulltimeTitle = 'FINAL DEL PARTIDO';
  static const String nextMatchTitle = 'PRÓXIMO PARTIDO';
  /// Caracteres como mucho del cuándo y del dónde del próximo partido.
  static const int nextTextMaxChars = 32;
  static const String fixturesTitle = 'JORNADA';
  static const String interviewTitle = 'ENTREVISTAS';
  /// Caracteres como mucho de cada texto editable de la franja.
  static const int stripTextMaxChars = 32;
  /// Las dos líneas del claim de partida.
  static const List<String> stripClaimDefault = [
    'EL DEPORTE',
    'TAMBIÉN CONSERVA',
  ];
  /// Los tres mensajes de partida del centro: título y subtítulo.
  static const List<(String, String)> stripSlotsDefault = [
    ('GALÁPAGOS', 'SIEMPRE CONTIGO'),
    ('NUESTRAS ISLAS', 'NUESTRO FUTURO'),
    ('ENERGÍA LIMPIA', 'PARA UN MEJOR MAÑANA'),
  ];

  /// La tarjeta SIN SEÑAL (live_panel.py, §21.6).
  static const String slateText = 'SIN SEÑAL';
  /// Alto del texto, como fracción del alto del frame.
  static const double slateTextHeight = 0.08;
  static const int slateBackgroundArgb = 0xFF07111F;
  static const int slateForegroundArgb = 0xFFF8FAFC;
  /// Peso de Barlow Condensed en la tarjeta.
  static const int slateFontWeight = 800;

}
