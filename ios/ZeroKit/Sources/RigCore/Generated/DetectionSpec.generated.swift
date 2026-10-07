// Generado por tools/export_detection_spec.py del repo football-ai. NO EDITAR A MANO.
//
// Fuente de verdad: libs/vision/constants.py y libs/vision/band.py. Para
// regenerarlo y sincronizarlo:
//
//     uv run python tools/export_detection_spec.py
//     uv run python tools/export_golden.py --sync <ruta de la app>
//
// tests/unit/test_band_geometry.py falla si este fichero se queda atrás.

import Foundation

/// El contrato de los detectores (ADR 0020): entradas, cadencias, postproceso y la
/// versión de band.json. En la app no se teclea ninguno de estos números.
public enum DetectionSpec {
    /// Píxeles. Ancho de entrada del detector de jugadores (ADR 0020, REF-25): el 4K a
    /// ×0,5 exacto. Hoy solo lo usa ort.py como respaldo cuando el .onnx declara ejes
    /// dinámicos; la entrada real la describe la ficha del registro.
    /// (Python: `PLAYER_INPUT_WIDTH`.)
    public static let playerInputWidth: Int = 1920

    /// Píxeles. Alto de entrada del detector (ADR 0020, REF-25): la franja jugable,
    /// reducida sin deformar. 1152 filas nativas a ×0,5; más que eso entra en mosaico.
    /// (Python: `PLAYER_INPUT_HEIGHT`.)
    public static let playerInputHeight: Int = 576

    /// Reducción de la franja jugable hacia la entrada del detector (ADR 0020): el 4K
    /// a la mitad, sin deformar (sx = sy). Es también la escala de la parte LEJANA del
    /// mosaico cuando la franja no cabe entera.
    /// (Python: `PLAYER_BAND_SCALE`.)
    public static let playerBandScale: Double = 0.5

    /// Hz. Frecuencia objetivo del detector de jugadores: 1 de cada 4 fotogramas a
    /// 30 fps (ADR 0020). El escalón L1 de la escalera térmica la baja a 5 Hz (IOS-06).
    /// (Python: `PLAYER_TARGET_HZ`.)
    public static let playerTargetHz: Double = 7.5

    /// Score mínimo [0,1] para aceptar una detección. Deliberadamente bajo (§14.2):
    /// preferimos recall a precisión porque el tracker filtra el ruido después, y una caja
    /// imprecisa sigue sirviendo para el fallback de acción y el zoom. Subirlo degrada la
    /// cobertura, que es lo único que este detector tiene que garantizar.
    /// (Python: `PLAYER_CONF_THRESHOLD`.)
    public static let playerConfThreshold: Double = 0.25

    /// Cota superior de detecciones devueltas por ciclo. En el campo hay 22 jugadores,
    /// 3 árbitros y algún portero suelto; 64 deja margen para duplicados antes del tracker
    /// y acota el trabajo del post-procesado, que corre en el camino caliente.
    /// (Python: `PLAYER_MAX_DETECTIONS`.)
    public static let playerMaxDetections: Int = 64

    /// Píxeles nativos. Cuánto puede separarse el borde de una media caja de la junta del
    /// mosaico para contarla como «tocando la junta» (REF-26). El recorte por región deja el
    /// borde EXACTO en la junta; el margen cubre el redondeo del viaje entrada↔nativo.
    /// (Python: `PLAYER_SEAM_EPS_PX`.)
    public static let playerSeamEpsPx: Double = 1.5

    /// Fracción (0-1) del ancho de la caja más estrecha que tiene que solaparse en X para
    /// casar dos medias cajas a ambos lados de la junta. Por debajo son dos personas distintas
    /// hombro con hombro, no una partida.
    /// (Python: `PLAYER_SEAM_MIN_X_OVERLAP`.)
    public static let playerSeamMinXOverlap: Double = 0.5

    /// Píxeles. Lado de cada ROI nativa del heatmap del balón (ADR 0020): el lote fijo es
    /// [2, 3, 256, 256]. Es a la vez la entrada del modelo (el `BALL_HEATMAP_INPUT` de REF-27):
    /// la ROI es nativa y no se reescala. Las BALL_DETR_* de arriba son del detector DETR del
    /// pod, que vive hasta el corte.
    /// (Python: `BALL_ROI_SIDE`.)
    public static let ballRoiSide: Int = 256

    /// Hz. Cadencia del lote de 2 ROIs nativas alrededor de la predicción del Kalman.
    /// (Python: `BALL_ROI_HZ`.)
    public static let ballRoiHz: Int = 15

    /// Hz. Cadencia de la búsqueda global sobre el mosaico de la franja.
    /// (Python: `BALL_GLOBAL_HZ`.)
    public static let ballGlobalHz: Int = 3

    /// Hz. La búsqueda global al perder el balón: se sube hasta reencontrarlo.
    /// (Python: `BALL_GLOBAL_LOST_HZ`.)
    public static let ballGlobalLostHz: Int = 10

    /// Píxeles. Ancho del mosaico de la búsqueda global: la mitad del 4K, para que la parte
    /// lejana entre nativa en dos mitades apiladas (ADR 0020).
    /// (Python: `BALL_GLOBAL_INPUT_WIDTH`.)
    public static let ballGlobalInputWidth: Int = 1920

    /// Píxeles. Alto del mosaico de la búsqueda global: el del retranqueo de 10 m, que fijó
    /// REF-33 mientras M3 no esté medido. El de 6 m (1296) quedó fuera de presupuesto.
    /// (Python: `BALL_GLOBAL_INPUT_HEIGHT`.)
    public static let ballGlobalInputHeight: Int = 896

    /// ROIs por ciclo en el lote fijo del balón (ADR 0020): la predicción del Kalman y una
    /// segunda hipótesis. Es la N de [N, 3, S, S]; una ROI que falta va a ceros.
    /// (Python: `BALL_MAX_ROIS_PER_CYCLE_MOBILE`.)
    public static let ballMaxRoisPerCycleMobile: Int = 2

    /// Frames en gris apilados por canal en la entrada del balón (ADR 0020): t-2, t-1 y t,
    /// consecutivos de captura (33 ms) aunque la inferencia vaya a otra cadencia.
    /// (Python: `BALL_TEMPORAL_FRAMES`.)
    public static let ballTemporalFrames: Int = 3

    /// Píxeles de entrada por celda del heatmap del balón (ADR 0020). La salida a stride 2
    /// más el offset subpíxel es lo que deja el error de localización por debajo de un píxel
    /// de entrada sin pagar un heatmap a resolución completa.
    /// (Python: `BALL_HEATMAP_STRIDE`.)
    public static let ballHeatmapStride: Int = 2

    /// Celdas. Lado de la ventana del máximo local al buscar picos: un pico tiene que ser
    /// el mayor de su vecindario 3×3. Más grande y dos balones a seis celdas se funden; más
    /// pequeño no existe (1×1 haría pico cada celda).
    /// (Python: `HEATMAP_PEAK_KERNEL`.)
    public static let heatmapPeakKernel: Int = 3

    /// Score mínimo de una celda para ser candidata a pico, sin unidades (0-1).
    /// PROVISIONAL, a calibrar por banda de distancia con el informe de ML-41: el balón lejano
    /// activa menos que el cercano y un umbral único lo infrarrepresenta.
    /// (Python: `BALL_HEATMAP_THRESHOLD`.)
    public static let ballHeatmapThreshold: Double = 0.3

    /// IoU, sin unidades (0-1). Dos cajas de la misma clase con más solape que esto son el
    /// mismo objeto y sobrevive la de mejor score. 0.5 es el valor clásico: más bajo borra
    /// jugadores pegados en un córner; más alto deja duplicados que el tracker cuenta dos
    /// veces.
    /// (Python: `NMS_IOU_THRESHOLD`.)
    public static let nmsIouThreshold: Double = 0.5

    /// Cajas que entran a la NMS como máximo, las de mejor score. Es el número de queries
    /// de D-FINE: una inferencia no puede producir más candidatos útiles que eso, y el
    /// prefiltro con `argpartition` hace que el coste de la NMS no dependa de cuánta basura
    /// emita una cabeza CNN por debajo del umbral.
    /// (Python: `PRE_NMS_TOPK`.)
    public static let preNmsTopk: Int = 300

    /// Radianes (~1.15°). Separación angular por debajo de la cual dos detecciones, una de
    /// cada cámara, se consideran el mismo objeto (ADR 0012, decisión 3).
    ///
    /// El valor sale del paralaje, que es el error irreducible de este montaje. Con las lentes
    /// a ~10 cm, un objeto a 5 m se ve desde las dos cámaras con 0.02 rad de diferencia; a 15 m
    /// son 0.007 y a 40 m, 0.0025. Se dimensiona para el caso peor —la banda cercana, justo bajo
    /// el soporte— porque ahí es donde el mismo jugador se vería como dos si el umbral fuera más
    /// estrecho.
    ///
    /// Cuesta lo que cuesta: a 40 m, 0.02 rad son ~80 cm, así que dos jugadores muy juntos en el
    /// solape pueden fundirse en uno. Es el compromiso correcto para lo que alimenta —el centro
    /// de acción y el planificador de ROIs, que razonan sobre dónde está el juego— y sería el
    /// umbral equivocado para contar jugadores.
    /// (Python: `RIG_FUSE_MAX_ANGLE_RAD`.)
    public static let rigFuseMaxAngleRad: Double = 0.02

    /// Nanosegundos (16 ms). Desfase máximo para dar dos frames por simultáneos.
    ///
    /// Es medio frame a 30 fps, que es exactamente el peor caso de dos sensores que corren
    /// libres: sin genlock, sus instantes de exposición caen en cualquier punto del intervalo
    /// y el desfase no se puede reducir por software. Lo que se puede es medirlo, y el ADR
    /// 0012 (decisión 2) deja esa medida en el soporte.
    ///
    /// Qué significa físicamente, que es lo que decide si el umbral vale: a 16 ms, un balón a
    /// 30 m/s recorre 50 cm y un jugador a 7 m/s recorre 12 cm. En la costura eso es
    /// desdoblamiento visible para el balón y despreciable para el jugador. Subirlo empareja
    /// más frames a costa de coser instantes cada vez más distintos; bajarlo deja huérfanos
    /// frames que sí eran del mismo instante.
    /// (Python: `RIG_PAIR_TOLERANCE_NS`.)
    public static let rigPairToleranceNs: Int = 16000000

    /// Versión del formato de `band.json`. Como en rig.json y pitch.json, un fichero de
    /// otra versión se rechaza al leer en vez de adivinarse.
    /// (Python: `BAND_FILE_VERSION`.)
    public static let bandFileVersion: Int = 1
}
