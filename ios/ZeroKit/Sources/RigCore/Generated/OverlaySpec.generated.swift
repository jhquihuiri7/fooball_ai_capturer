// Generado por tools/export_overlay_spec.py. NO EDITAR A MANO.
//
// Fuente de verdad: tools/overlay_preview.py (medidas y paleta del gráfico),
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
    public static let programFps = 25
    public static let refWidth = 1920
    public static let stripHeight = 108
    public static let margin = 48
    public static let stripTop = 972

    /// Paleta, como [r, g, b, a] de 0 a 255.
    public static let colors: [String: [Int]] = [
        "bar": [6, 10, 11, 240],  // Fondo de la franja. Lo pinta el panel: el anuncio va encima, con alfa.
        "edge": [255, 255, 255, 26],  // Filete de 1 px que separa la franja del césped.
        "home": [242, 106, 36, 255],  // Color del equipo local. Un anuncio no debe usarlo: se lee como marcador.
        "away": [22, 179, 166, 255],  // Color del equipo visitante. Misma razón para no usarlo.
        "live": [225, 29, 38, 255],  // Rojo del indicador EN DIRECTO. Reservado; ningún anuncio lo usa.
        "leaf": [124, 194, 66, 255],  // Verde institucional del claim de la franja.
        "white": [255, 255, 255, 255],  // Texto principal sobre la franja.
        "dim": [154, 168, 166, 255],  // Texto secundario sobre la franja.
        "chrome": [9, 14, 15, 230],  // Fondo del marcador (el bug).
        "chrome_soft": [9, 14, 15, 209],  // Fondo del indicador de cámara.
    ]

    /// Tamaños de letra, px sobre 1920.
    public static let fontSizes: [String: Int] = [
        "team": 34,
        "score": 38,
        "clock": 32,
        "comp": 17,
        "live": 17,
        "cam": 18,
        "slot": 18,
        "sub": 16,
        "claim": 23,
        "ai": 17,
    ]

    /// Candidatas de fuente, en orden. La app usa su familia nativa.
    public static let fontCandidates: [String] = [
        "C:/Windows/Fonts/ARIALNB.TTF",
        "C:/Windows/Fonts/arialbd.ttf",
        "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ]
    public static let fontRegular: [String] = [
        "C:/Windows/Fonts/ARIALN.TTF",
        "C:/Windows/Fonts/arial.ttf",
        "/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]

    /// El marcador (overlay_preview.py).
    public static let scoreboard: [String: Int] = [
        "bug_w": 704,
        "bug_h": 88,
        "bug_chamfer": 26,
        "crest_w": 86,
        "live_y": 148,
        "live_h": 30,
        "cam_y": 44,
        "cam_h": 38,
        "margin": 48,
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
        "shadow_dy": 4,
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
    ]

    /// Los anuncios: cadencia y fundidos (ad_strip.py).
    public static let ad: [String: Int] = [
        "fps": 25,
        "beat_s": 10,
        "entry_frames": 10,
        "exit_frames": 10,
        "slide_px": 12,
    ]

}
