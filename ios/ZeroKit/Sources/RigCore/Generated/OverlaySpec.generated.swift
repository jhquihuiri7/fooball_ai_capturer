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


import Foundation

/// Las medidas del gráfico, derivadas de Python (REF-32). Px sobre 1920.
public enum OverlaySpec {
    public static let programWidth = 1920
    public static let programHeight = 1080
    public static let programFps = 30
    public static let refWidth = 1920
    public static let stripHeight = 108
    public static let margin = 48
    public static let stripTop = 972

    /// Paleta, como [r, g, b, a] de 0 a 255.
    public static let colors: [String: [Int]] = [
        "bar": [7, 17, 31, 240],  // Fondo de la franja. Lo pinta el panel: el anuncio va encima, con alfa.
        "edge": [0, 229, 196, 255],  // Filete teal que separa la franja del césped.
        "home": [0, 229, 196, 255],  // Equipo local (teal). Un anuncio no lo usa de acento: se lee como marcador.
        "away": [255, 255, 255, 255],  // Equipo visitante (blanco). Como acento tampoco; como texto, sí.
        "live": [227, 20, 31, 255],  // Rojo de EN VIVO. Reservado; ningún anuncio lo usa.
        "white": [255, 255, 255, 255],  // Texto principal sobre la franja.
        "dim": [148, 163, 184, 255],  // Texto secundario sobre la franja.
        "chrome": [16, 29, 45, 255],  // Fondo del marcador (el bug).
        "chrome_soft": [7, 17, 31, 224],  // Chips sobre el vídeo: cámara, reloj y competición.
    ]

    /// Los tokens de la marca por su nombre, como [r, g, b] (tools/brand.py).
    public static let brand: [String: [Int]] = [
        "teal-electrico": [0, 229, 196],
        "verde-oceano": [0, 168, 146],
        "azul-deportivo": [0, 102, 255],
        "azul-profundo": [7, 17, 31],
        "azul-marino": [16, 29, 45],
        "gris-claro": [248, 250, 252],
        "gris-oceanico": [148, 163, 184],
        "amarillo-energia": [255, 212, 59],
        "rojo-vivo": [227, 20, 31],
        "blanco": [255, 255, 255],
        "gris-tinte": [211, 223, 234],
    ]

    /// Tamaños de letra, px sobre 1920.
    public static let fontSizes: [String: Int] = [
        "team": 36,
        "score": 56,
        "clock": 40,
        "comp": 22,
        "live": 24,
        "crest": 26,
        "slot": 22,
        "sub": 15,
        "claim": 30,
        "ai": 16,
    ]

    /// Las familias: «display» es Barlow Condensed y «sans», Inter.
    public static let fontFamilies: [String: String] = [
        "display": "Barlow Condensed",
        "sans": "Inter",
    ]
    /// La familia de cada texto.
    public static let fontFaces: [String: String] = [
        "team": "display",
        "score": "display",
        "clock": "display",
        "comp": "display",
        "live": "sans",
        "crest": "display",
        "slot": "display",
        "sub": "sans",
        "claim": "display",
        "ai": "sans",
    ]
    /// El peso de cada texto.
    public static let fontWeights: [String: Int] = [
        "team": 700,
        "score": 800,
        "clock": 700,
        "comp": 600,
        "live": 800,
        "crest": 800,
        "slot": 700,
        "sub": 500,
        "claim": 700,
        "ai": 500,
    ]

    /// La franja (overlay_preview.py).
    public static let strip: [String: Int] = [
        "edge_h": 2,
        "reserved_left": 360,
        "reserved_right": 300,
        "logo_h": 48,
        "logo_gap": 16,
        "logo_src_w": 97,
        "logo_src_h": 84,
        "claim_line_h": 32,
        "divider_pad": 26,
        "slot_gap": 40,
        "slot_icon_r": 14,
        "raya_w": 6,
        "raya_h": 28,
        "raya_gap": 14,
    ]

    /// La jornada (fixtures_card.py).
    public static let fixtures: [String: Int] = [
        "max": 8,
        "time_max_chars": 16,
        "subtitle_max_chars": 32,
        "list_cy": 628,
        "row_pitch": 96,
        "band_half_w": 700,
        "band_h": 80,
        "band_alpha": 200,
        "time_w": 176,
        "time_h": 46,
        "time_size": 30,
        "time_dy_with_subtitle": 12,
        "subtitle_dy": -25,
        "subtitle_size": 20,
        "crest_w": 54,
        "crest_gap": 28,
        "crest_initials_size": 17,
        "name_gap": 18,
        "name_size": 38,
        "name_max_w": 430,
    ]

    /// El entretiempo (halftime_card.py).
    public static let halftime: [String: Int] = [
        "title_y": 118,
        "title_size": 80,
        "title_raya_w": 10,
        "title_raya_h": 56,
        "title_raya_gap": 28,
        "comp_y": 190,
        "comp_size": 30,
        "icon_cy": 430,
        "icon_box": 280,
        "isotipo_h": 200,
        "crest_w": 176,
        "crest_cy": 410,
        "crest_dx": 520,
        "crest_initials_size": 55,
        "name_y": 590,
        "name_size": 46,
        "name_max_w": 480,
        "score_y": 770,
        "score_h": 130,
        "score_size": 104,
        "goal_min_w": 150,
        "goal_pad_x": 28,
        "goal_dash_gap": 24,
        "veil_alpha": 153,
        "backdrop_blur_sigma": 24,
        "when_y": 770,
        "when_h": 104,
        "when_size": 56,
        "when_pad_x": 48,
        "when_min_w": 300,
        "venue_y": 872,
        "venue_size": 34,
        "guest_y": 664,
        "guest_size": 64,
        "guest_max_w": 1400,
        "role_y": 738,
        "role_size": 36,
    ]

    /// El marcador (overlay_preview.py).
    public static let scoreboard: [String: Int] = [
        "margin": 48,
        "top_y": 44,
        "status_h": 44,
        "status_pad_x": 56,
        "status_to_bar": 18,
        "bar_h": 76,
        "tip_w": 18,
        "tip_overlap": 8,
        "body_pad_x": 28,
        "body_edge_h": 3,
        "row_gap": 22,
        "crest_w": 84,
        "crest_h": 100,
        "goals_margin": 6,
        "goal_min_w": 72,
        "goal_pad_x": 12,
        "goal_dash_gap": 14,
        "live_pad_l": 14,
        "live_pad_r": 16,
        "live_dot": 12,
        "live_gap": 10,
        "chip_pad_x": 16,
        "clock_gap": 12,
        "clock_pad_x": 22,
        "live_below": 18,
        "corner_logo_h": 64,
        "corner_pad": 12,
        "corner_gap": 24,
        "radius": 6,
        "skew_deg": 30,
        "shadow_dy": 4,
        "shadow_blur": 16,
        "shadow_alpha_pct": 40,
        "bar_shadow_alpha_pct": 45,
    ]

    /// La alineación (lineup_card.py).
    public static let lineup: [String: Int] = [
        "margin_x": 60,
        "title_y": 50,
        "title_size": 72,
        "list_y": 150,
        "list_w": 500,
        "row_h": 42,
        "row_step": 50,
        "row_text_size": 26,
        "subs_y": 718,
        "subs_title_size": 34,
        "subs_size": 25,
        "subs_line_h": 31,
        "bottom_pad": 24,
        "header_y": 52,
        "header_h": 76,
        "header_w": 720,
        "header_text_size": 44,
        "crest_r": 60,
        "crest_initials_size": 30,
        "header_edge_h": 3,
        "row_radius": 8,
    ]

    /// Los anuncios: cadencia y fundidos (ad_strip.py).
    public static let ad: [String: Int] = [
        "fps": 30,
        "fps_pod": 25,
        "beat_s": 10,
        "entry_frames": 10,
        "exit_frames": 10,
        "slide_px": 12,
    ]

}
