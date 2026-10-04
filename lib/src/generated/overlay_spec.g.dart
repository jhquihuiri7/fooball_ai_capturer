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

}
