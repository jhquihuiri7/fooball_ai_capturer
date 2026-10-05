// Generado por tools/export_rig_constants.py del repo football-ai. NO EDITAR A MANO.
//
// Fuente de verdad: libs/vision/constants.py. Las unidades y el porqué de cada
// número viven en el comentario de cada constante, copiados de allí. Para
// regenerarlo y sincronizarlo:
//
//     uv run python tools/export_rig_constants.py
//     uv run python tools/export_golden.py --sync <ruta de la app>
//
// tests/unit/test_export_rig_constants.py falla si este fichero se queda atrás.

import Foundation

/// Las constantes de comportamiento de libs/vision, con los nombres de Python en
/// camelCase. En RigCore no se escribe ninguna a mano: se usa esta enumeración.
public enum RigConstants {
    /// Metros. Largo del campo, de línea de fondo a línea de fondo. Es el valor por
    /// defecto de §11.1, no una constante física: una cancha real mide lo que mide y su
    /// medida entra por `venues/<id>.yaml` (TASK 5.2). Está aquí para que el modelo pueda
    /// construirse sin fichero mientras ese formato no exista.
    /// (Python: `PITCH_LENGTH_M`.)
    public static let pitchLengthM: Double = 105.0

    /// Metros. Ancho del campo, de banda a banda. Mismo criterio que el largo.
    /// (Python: `PITCH_WIDTH_M`.)
    public static let pitchWidthM: Double = 68.0

    /// Número mínimo de puntos campo↔imagen para calibrar (§11.1).
    ///
    /// Una homografía tiene 8 grados de libertad, así que 4 correspondencias bastan para
    /// resolverla. El blueprint pide 6 justamente porque 4 no dejan margen: con el número
    /// exacto de ecuaciones el ajuste pasa por todos los puntos y el error de reproyección
    /// sale 0 aunque uno esté mal clicado. Con puntos de sobra, un punto mal marcado sube
    /// el error y se nota.
    /// (Python: `PITCH_MIN_CORRESPONDENCES`.)
    public static let pitchMinCorrespondences: Int = 6

    /// Píxeles. Distancia máxima a la que RANSAC considera que un punto es inlier.
    ///
    /// Es tolerancia de marcado humano, no de precisión del modelo: quien clica la esquina
    /// del área en un frame 4K falla por unos píxeles. Por debajo de ~2 px empezaría a
    /// descartar puntos buenos.
    /// (Python: `PITCH_RANSAC_REPROJ_THRESHOLD_PX`.)
    public static let pitchRansacReprojThresholdPx: Double = 3.0

    /// Píxeles. Error medio de reproyección por encima del cual la calibración se
    /// rechaza (AC de TASK 5.1).
    ///
    /// Ojo con qué mide: aquí se aplica sobre los inliers con los que se ajustó la homografía,
    /// y ese error siempre es optimista comparado con el de puntos de validación independientes,
    /// que es contra los que §11.1 fija el criterio de verdad.
    ///
    /// Y ojo con cuándo salta: como `PITCH_RANSAC_REPROJ_THRESHOLD_PX` ya acota el error de cada
    /// inlier a 3 px, casi cualquier calibración lo bastante mala como para superar 2 px de media
    /// pierde antes tantos puntos que la rechaza el mínimo de inliers. Medido: con ocho puntos
    /// desplazados en círculo, a 2.0 px de radio la calibración pasa con 0.83 px de error y a
    /// 2.5 px ya la tumba el recuento de inliers. Este umbral es entonces un último filtro para
    /// el caso de puntos sistemáticamente imprecisos pero coherentes entre sí —un frame movido,
    /// alguien clicando a ojo—, no la comprobación principal.
    /// (Python: `PITCH_MAX_MEAN_REPROJECTION_ERROR_PX`.)
    public static let pitchMaxMeanReprojectionErrorPx: Double = 2.0

    /// Adimensional. Cociente entre el segundo y el primer valor singular de los puntos
    /// centrados por debajo del cual se consideran alineados.
    ///
    /// Una homografía necesita puntos que abarquen un área. Si todos caen sobre una recta
    /// —por ejemplo, marcando solo la línea de medio campo— el sistema es degenerado y
    /// `findHomography` devuelve una matriz sin sentido en vez de fallar. Este cociente lo
    /// detecta antes de llamarla: vale 0 para puntos exactamente alineados y 1 para una
    /// nube isótropa.
    /// (Python: `PITCH_COLLINEARITY_RATIO`.)
    public static let pitchCollinearityRatio: Double = 0.001

    /// Adimensional. Determinante mínimo, en valor absoluto, de una homografía normalizada
    /// para darla por invertible.
    ///
    /// `H_inv` es la mitad del contrato de §11.1, así que una `H` que no se pueda invertir no es
    /// un modelo válido ni aunque reproyecte bien en un sentido.
    ///
    /// El valor está medido, no elegido a ojo. Cuatro emplazamientos del rango de §9 —cámara
    /// entre 10 y 20 m de altura y entre 40 y 70 m de retranqueo, focal de 2600 px sobre 4K— dan
    /// determinantes normalizados entre 3.3e-08 y 9.0e-08, mientras que una matriz de rango 2 da
    /// exactamente 0. Un umbral de 1e-8 dejaba un margen de 3×, que no es margen: este deja
    /// cuatro órdenes de magnitud por cada lado.
    /// (Python: `PITCH_MIN_HOMOGRAPHY_DET`.)
    public static let pitchMinHomographyDet: Double = 1e-12

    /// Metros. Desacuerdo medio máximo entre las dos cámaras del soporte al proyectar al
    /// campo los mismos puntos del suelo (ADR 0012, TASK B4).
    ///
    /// Con dos cámaras hay dos homografías, y las dos tienen que llevar un mismo punto del
    /// césped al mismo sitio. Si no lo hacen, un jugador que cruza la costura salta de
    /// posición, y el tracker lo ve como dos personas.
    ///
    /// El valor sale de la geometría de un soporte bajo, que es lo que el ADR 0012 acepta. La
    /// profundidad que cubre un píxel vertical crece con el cuadrado de la distancia: a una
    /// altura h y distancia d son d²/(h·f) metros por píxel. Con h = 2,7 m y f ≈ 1450 px, en el
    /// círculo central (d ≈ 38 m) eso son 0,37 m/px; un error de calibración de 1–2 px, que es
    /// lo normal clicando a mano, ya da 0,4–0,7 m. Un metro deja pasar eso y rechaza lo que ya
    /// no es imprecisión sino un punto mal emparejado.
    /// (Python: `PITCH_MAX_CROSS_CAMERA_ERROR_M`.)
    public static let pitchMaxCrossCameraErrorM: Double = 1.0

    /// Adimensional. Tercera coordenada homogénea mínima para dar por buena una proyección.
    ///
    /// Un punto cuya `w` sale 0 está sobre la línea del horizonte: la homografía lo manda al
    /// infinito y no hay píxel que le corresponda. Ocurre de verdad al pedir la posición de un
    /// punto del campo muy por detrás de la línea de fondo, así que se comprueba en vez de
    /// dejar que salga un `inf` silencioso.
    /// (Python: `PITCH_MIN_PROJECTIVE_W`.)
    public static let pitchMinProjectiveW: Double = 1e-09

    /// Metros. Margen alrededor de las líneas que sigue contando como área jugable al
    /// filtrar detecciones por los pies (`is_inside_playable` de §11.1).
    ///
    /// Un portero que saca, un lateral y un saque de esquina pisan fuera de las líneas sin
    /// dejar de ser parte del juego. Tres metros los cubren y dejan fuera los banquillos y
    /// el público, que es lo que el filtro existe para quitar (§14.2). El gating del balón
    /// usa el suyo propio, más ancho (§13.2), porque un balón en juego se aleja más de las
    /// líneas que un jugador.
    /// (Python: `PITCH_PLAYABLE_MARGIN_M`.)
    public static let pitchPlayableMarginM: Double = 3.0

    /// Giro de cada cámara respecto al frente del soporte, como estimación de partida. La
    /// calibración lo corrige; lo que importa de verdad es la inclinación, que no puede
    /// corregir.
    /// (Python: `DEFAULT_RIG_YAW_DEG`.)
    public static let defaultRigYawDeg: Double = 45.0

    /// Inclinación de partida hacia el césped. Es la que la calibración no puede deducir
    /// (ADR 0012, B5b): quien monta el soporte debe ajustarla con `--rig-pitch`.
    /// (Python: `DEFAULT_RIG_PITCH_DEG`.)
    public static let defaultRigPitchDeg: Double = -8.0

    /// Grados. Alabeo máximo creíble de una cámara del soporte tras calibrar. Un soporte bien
    /// montado se queda en unos pocos; los 180 de una cámara sin enderezar son otra cosa, y 45
    /// separa las dos sin dudas.
    /// (Python: `RIG_MAX_ROLL_DEG`.)
    public static let rigMaxRollDeg: Double = 45.0

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

    /// Parejas de fotogramas sincronizados que el maestro pide para calibrar (IOS-70). Cinco,
    /// como los instantes de `calibrate_from_recordings.py`: una sola puede caer con alguien
    /// cruzando el solape; de cinco se queda la mejor.
    /// (Python: `RIG_CALIB_PAIR_COUNT`.)
    public static let rigCalibPairCount: Int = 5

    /// Milisegundos entre los instantes de destino de dos parejas (IOS-70). Un segundo: lo
    /// bastante para que la escena cambie entre parejas y poco para que la sesión dure 5 s.
    /// (Python: `RIG_CALIB_PAIR_SPACING_MS`.)
    public static let rigCalibPairSpacingMs: Int = 1000

    /// Milisegundos entre la orden y el primer destino: lo que tarda la orden en llegar al
    /// esclavo por control con margen, para que los dos tengan el fotograma en el anillo.
    /// (Python: `RIG_CALIB_LEAD_MS`.)
    public static let rigCalibLeadMs: Int = 500

    /// Calidad del JPEG de cada fotograma de calibración (sin unidad, de 0 a 1). q95 deja las
    /// esquinas finas que busca el emparejado de rasgos sin pasar del tope de tamaño.
    /// (Python: `RIG_CALIB_JPEG_QUALITY`.)
    public static let rigCalibJpegQuality: Double = 0.95

    /// Bytes como mucho de un JPEG 4K de calibración (6 MiB): lo que acepta la subida del VPS
    /// (NUBE-09) por pareja y lado.
    /// (Python: `RIG_CALIB_JPEG_MAX_BYTES`.)
    public static let rigCalibJpegMaxBytes: Int = 6291456

    /// Frames que cada lado retiene esperando a su pareja.
    ///
    /// Es la respuesta a la pregunta «¿el otro frame viene de camino o ya no llega?», y se
    /// responde con espacio en vez de con tiempo: mientras el hueco no se llene, se espera; en
    /// cuanto se llena, el frame más antiguo sale solo y el programa sigue con una sola cámara
    /// (ADR 0012, decisión 4).
    ///
    /// Tres frames son ~100 ms a 30 fps de latencia añadida en el peor caso, que cabe de sobra
    /// en el presupuesto de la delay line de D2 (200 ms). Es además la cota de la cola, que
    /// CLAUDE.md §2 exige acotada: al llenarse se descarta el frame más viejo, nunca se encola
    /// más.
    /// (Python: `RIG_PAIR_BUFFER_FRAMES`.)
    public static let rigPairBufferFrames: Int = 3

    /// Fracción [0,1] de parejas completas por debajo de la cual el soporte se considera
    /// desincronizado.
    ///
    /// No hay una medida directa de «los relojes se han ido»: lo que se ve es que dejan de
    /// salir parejas completas, porque el desfase supera `RIG_PAIR_TOLERANCE_NS` y cada frame
    /// sale huérfano. Con los dos móviles sanos, lo normal es 1.0 salvo pérdidas de red
    /// sueltas, así que 0.90 ya es señal de que algo va mal y no ruido.
    /// (Python: `RIG_MIN_PAIR_COMPLETENESS`.)
    public static let rigMinPairCompleteness: Double = 0.9

    /// Hz. Diferencia máxima de cadencia admitida entre las dos cámaras.
    ///
    /// Tolera la pareja 29.97 / 30, que es la misma cadencia con distinta declaración, y
    /// rechaza 25 / 30, que no lo es. Mezclar cadencias no produce un error visible: produce
    /// un desfase que crece un frame cada pocos segundos, y eso hay que pararlo al construir
    /// la fuente, no descubrirlo a mitad de partido.
    /// (Python: `RIG_MAX_FPS_MISMATCH_HZ`.)
    public static let rigMaxFpsMismatchHz: Double = 0.5

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

    /// Radianes (~0,34°). Mediana de `separation_rad` de las detecciones fundidas del solape
    /// por encima de la cual se sugiere recalibrar el soporte (IOS-72).
    ///
    /// Con la calibración bien, la separación es paralaje más ruido: con las lentes a ~10 cm,
    /// 0,0025 rad a 40 m y 0,007 a 15 m, y la mayoría de los jugadores del solape están lejos,
    /// así que la mediana se queda por debajo de 0,003. Una pose movida suma su error a TODAS
    /// las parejas: 0,5° son 0,0087 rad, y la mediana pasa del umbral aunque los cercanos se
    /// desordenen. Por encima de `RIG_FUSE_MAX_ANGLE_RAD` las parejas dejan de fundirse y la
    /// mediana ya no lo ve: para eso está el estabilizador (`STABILIZER_MAX_SWAY_RAD`).
    /// (Python: `RIG_SEAM_WATCH_MAX_MEDIAN_RAD`.)
    public static let rigSeamWatchMaxMedianRad: Double = 0.006

    /// Separaciones que la vigilancia de la costura guarda para la mediana: unos 30 s del
    /// solape a 7,5 Hz con un puñado de parejas por ciclo. Más corta, un córner con todos los
    /// jugadores bajo el soporte (paralaje alto) daría un aviso falso.
    /// (Python: `RIG_SEAM_WATCH_WINDOW`.)
    public static let rigSeamWatchWindow: Int = 256

    /// Separaciones mínimas antes de opinar: con menos, la mediana es de unos pocos
    /// jugadores y no del soporte.
    /// (Python: `RIG_SEAM_WATCH_MIN_SAMPLES`.)
    public static let rigSeamWatchMinSamples: Int = 64

    /// Fracción. Diferencia relativa de focal entre la matriz intrínseca que el iPhone
    /// entrega por fotograma y la de rig.json por encima de la cual se avisa (IOS-72, M2).
    ///
    /// Un 1 % de focal es un 1 % de campo de visión: medio grado en el borde de la lente
    /// ultra gran angular, que en la costura ya se ve. Con el recorte activo bien fijado
    /// (estabilización apagada) la focal no se mueve; si se mueve, alguien cambió el modo de
    /// la cámara o el sistema cambió el recorte sin avisar.
    /// (Python: `RIG_INTRINSICS_MAX_FOCAL_REL`.)
    public static let rigIntrinsicsMaxFocalRel: Double = 0.01

    /// Píxeles nativos. Desplazamiento del centro óptico por fotograma frente a rig.json por
    /// encima del cual se avisa (IOS-72). Ocho píxeles en 4K son ~0,1° con la focal de la
    /// ultra gran angular: más que eso no es ruido del adjunto, es otro recorte.
    /// (Python: `RIG_INTRINSICS_MAX_CENTER_PX`.)
    public static let rigIntrinsicsMaxCenterPx: Double = 8.0

    /// Píxeles que se ensancha una zona ciega de una cámara. `cv2.remap` interpola entre
    /// vecinos, así que un píxel pegado al borde de la zona todavía arrastra algo de ella.
    /// (Python: `PANORAMA_BLIND_MARGIN_PX`.)
    public static let panoramaBlindMarginPx: Int = 2

    /// Uno de cada cuántos píxeles del solape, en cada eje, se mide para igualar el color de
    /// las dos cámaras. La media de una franja de cientos de miles de píxeles no cambia por mirar
    /// uno de cada 64, y medir deja de costar.
    /// (Python: `PANORAMA_COLOR_MATCH_STRIDE`.)
    public static let panoramaColorMatchStride: Int = 8

    /// Tope de la ganancia por canal (y de su inversa). Dos móviles que midieron la luz por
    /// separado difieren en fracciones de paso; más de 1.6x no es una diferencia de ajuste sino
    /// una cámara tapada o mirando a otro sitio, y «corregirla» quemaría la otra mitad.
    /// (Python: `PANORAMA_COLOR_MATCH_MAX_GAIN`.)
    public static let panoramaColorMatchMaxGain: Double = 1.6

    /// Peso de cada medida nueva en la ganancia (media exponencial). Con la exposición y el
    /// balance bloqueados en los móviles la diferencia es constante, así que se puede ir
    /// despacio: lo que se quiere filtrar es el jugador que cruza el solape.
    /// (Python: `PANORAMA_COLOR_MATCH_SMOOTHING`.)
    public static let panoramaColorMatchSmoothing: Double = 0.25

    /// Nivel medio (0-255) por debajo del cual un canal no se usa para medir: en negro, el
    /// cociente entre las dos cámaras es ruido dividido por ruido.
    /// (Python: `PANORAMA_COLOR_MATCH_MIN_LEVEL`.)
    public static let panoramaColorMatchMinLevel: Double = 12.0

    /// Píxeles medidos mínimos en el solape. Con menos, las cámaras casi no se pisan y no hay
    /// de dónde sacar una media fiable.
    /// (Python: `PANORAMA_COLOR_MATCH_MIN_PIXELS`.)
    public static let panoramaColorMatchMinPixels: Int = 64

    /// Radianes (~2°). Ancho de la franja en la que las dos cámaras se mezclan en la costura.
    ///
    /// Es un compromiso entre dos defectos que no se pueden eliminar a la vez. Una franja ancha
    /// disimula la diferencia de brillo entre los dos sensores, pero todo lo que se mueve dentro
    /// de ella sale **dos veces**: el paralaje y el desfase de exposición (hasta 50 cm de balón)
    /// se ven como doble imagen semitransparente. Una franja estrecha deja la doble imagen en
    /// pocos píxeles, a cambio de que un salto de brillo se note como línea.
    ///
    /// Con la exposición bloqueada e igual en los dos móviles (ADR 0012), el salto de brillo es
    /// pequeño y lo que hay que minimizar es el fantasma. 2° son ~50 px con la focal de la ultra
    /// gran angular sobre 4K (~1450 px/rad).
    /// (Python: `PANORAMA_FEATHER_RAD`.)
    public static let panoramaFeatherRad: Double = 0.035

    /// Puntos que se muestrean por cada borde de cada imagen para encontrar la extensión del
    /// lienzo. Los bordes de una cámara inclinada no son rectas en coordenadas cilíndricas, así
    /// que mirar solo las cuatro esquinas recortaría las panzas de los bordes superior e
    /// inferior.
    ///
    /// Impar a propósito: en una cámara sin alabeo, el extremo de esa panza cae justo en el
    /// centro del borde, y con un número par de muestras ese punto no se mira nunca.
    /// (Python: `PANORAMA_FIT_EDGE_SAMPLES`.)
    public static let panoramaFitEdgeSamples: Int = 65

    /// Píxeles de margen que se añaden al lienzo por cada lado.
    ///
    /// Con alabeo, el extremo de un borde ya no está en su centro y cae entre dos muestras. El
    /// error es de centésimas de píxel, pero basta para que la primera fila de la imagen quede
    /// fuera del lienzo. Un píxel de margen lo absorbe sin que nadie lo note.
    /// (Python: `PANORAMA_FIT_MARGIN_PX`.)
    public static let panoramaFitMarginPx: Double = 1.0

    /// Puntos ORB que se extraen por imagen.
    ///
    /// El solape entre las dos cámaras son ~20° de los ~106° de cada una: menos de una quinta
    /// parte de la imagen. Con los 500 puntos por defecto de ORB, repartidos por toda la imagen,
    /// al solape le tocarían unos 90, y tras el filtro de ratio y RANSAC no quedarían los
    /// suficientes para fiarse del resultado.
    /// (Python: `RIG_CALIB_MAX_FEATURES`.)
    public static let rigCalibMaxFeatures: Int = 4000

    /// Cociente máximo entre la distancia del mejor emparejamiento y la del segundo (prueba
    /// de Lowe). El césped es una textura repetitiva: un punto de hierba se parece a cien, y sin
    /// este filtro RANSAC recibe tantos emparejamientos falsos que deja de converger.
    /// (Python: `RIG_CALIB_RATIO_TEST`.)
    public static let rigCalibRatioTest: Double = 0.75

    /// Píxeles. Error de reproyección máximo para que un emparejamiento cuente como inlier.
    ///
    /// Se expresa en píxeles y se convierte a radianes con la focal de cada cámara, porque la
    /// precisión de ORB es de píxeles: el mismo umbral en radianes sería exigentísimo en 4K y
    /// laxísimo en una vista previa. 3 px absorben el ruido de localización y el paralaje de los
    /// objetos del fondo, que son los que dominan el solape.
    /// (Python: `RIG_CALIB_RANSAC_THRESHOLD_PX`.)
    public static let rigCalibRansacThresholdPx: Double = 3.0

    /// Hipótesis que prueba RANSAC. Una rotación se resuelve con dos direcciones, así que con
    /// la mitad de emparejamientos falsos cada hipótesis acierta con probabilidad 0.25, y 500
    /// iteraciones fallan todas con probabilidad 0.75^500: nunca.
    /// (Python: `RIG_CALIB_RANSAC_ITERATIONS`.)
    public static let rigCalibRansacIterations: Int = 500

    /// Semilla de RANSAC. Fija a propósito: la misma pareja de imágenes tiene que dar
    /// siempre la misma calibración, o un test que pasa hoy falla mañana sin haber cambiado
    /// nada.
    /// (Python: `RIG_CALIB_RANSAC_SEED`.)
    public static let rigCalibRansacSeed: Int = 0

    /// Emparejamientos coherentes mínimos para dar una rotación por buena.
    ///
    /// Dos bastan matemáticamente. Treinta es lo que hace falta para que una rotación que
    /// explica esos puntos por casualidad sea imposible en la práctica, y para que el residuo
    /// medio sea una medida y no un accidente.
    /// (Python: `RIG_CALIB_MIN_INLIERS`.)
    public static let rigCalibMinInliers: Int = 30

    /// Cuántas celdas del código cabrían a lo ancho del frame. Fija el tamaño de la celda
    /// en proporción a la imagen —16 px en 4K, 8 en 1080p— para que el código se lea igual en
    /// el original que en una copia reescalada. Solo se usan las 64 primeras.
    /// (Python: `RIG_TIMECODE_CELLS_ACROSS`.)
    public static let rigTimecodeCellsAcross: Int = 240

    /// Píxeles. Lado mínimo de una celda. Por debajo, el submuestreo de color 4:2:0 y los
    /// bloques del códec ya mezclan celdas vecinas.
    /// (Python: `RIG_TIMECODE_MIN_CELL_PX`.)
    public static let rigTimecodeMinCellPx: Int = 4

    /// Los 8 primeros bits del código (10110010). Sirven para dos cosas: saber que el frame
    /// lleva código —un cielo liso no se parece a este patrón— y calibrar el umbral entre
    /// blanco y negro con los valores reales que dejó el códec, en vez de suponer 128.
    /// (Python: `RIG_TIMECODE_PREAMBLE`.)
    public static let rigTimecodePreamble: Int = 178

    /// (Python: `RIG_TIMECODE_LUMA_ONE`.)
    public static let rigTimecodeLumaOne: Int = 235

    /// Luma de un bit a 1 y a 0. Son el blanco y el negro de rango limitado (BT.709), que es
    /// lo que codifica el iPhone: fuera de ese rango el códec recorta y el contraste baja.
    /// (Python: `RIG_TIMECODE_LUMA_ZERO`.)
    public static let rigTimecodeLumaZero: Int = 16

    /// Fracción central de cada celda que se promedia al leer. Los bordes de la celda son
    /// donde el códec emborrona con la vecina; el centro conserva el valor.
    /// (Python: `RIG_TIMECODE_SAMPLE_FRACTION`.)
    public static let rigTimecodeSampleFraction: Double = 0.5

    /// Ancho de banda de la densidad sobre el yaw, en radianes (10°).
    ///
    /// La §16.2 usa 8 m sobre el eje largo del campo. A los ~45 m que hay de media del soporte a
    /// la jugada, 8 m se ven bajo 10°. Más estrecho y la densidad sigue a cada jugador suelto;
    /// más ancho y dos grupos separados se funden en uno.
    /// (Python: `ACTION_KDE_BANDWIDTH_RAD`.)
    public static let actionKdeBandwidthRad: Double = 0.175

    /// Paso de la rejilla donde se evalúa la densidad, en radianes (2°).
    ///
    /// Un quinto del ancho de banda: suficiente para no perderse un pico y lo bastante grueso
    /// para que el barrido del lienzo entero sean un centenar de celdas. La moda no sale de la
    /// rejilla —se refina con la media de los jugadores de alrededor—, así que este paso no
    /// cuantiza la salida.
    /// (Python: `ACTION_KDE_STEP_RAD`.)
    public static let actionKdeStepRad: Double = 0.035

    /// Separación mínima entre la moda principal y la segunda para contarlas como dos, en
    /// radianes (20°). Por debajo son la misma cresta con dos cimas, no dos grupos.
    /// (Python: `ACTION_MODE_SEPARATION_RAD`.)
    public static let actionModeSeparationRad: Double = 0.35

    /// Jugadores de campo que hacen falta para que haya algo que llamar «la acción».
    ///
    /// Con dos o menos, el centroide es la posición de un jugador y la dispersión no significa
    /// nada. Es mejor no dar evidencia que dar una mala: el director se queda donde estaba.
    /// (Python: `ACTION_MIN_PLAYERS`.)
    public static let actionMinPlayers: Int = 3

    /// Jugadores detectados a partir de los cuales la confianza ya no sube. Son los 22 de la
    /// §16.2 menos los que en cualquier momento están tapados o fuera de cuadro.
    /// (Python: `ACTION_FULL_SQUAD`.)
    public static let actionFullSquad: Int = 14

    /// Confianza de partida de la evidencia de jugadores, de §16.2.
    /// (Python: `ACTION_CONFIDENCE_BASE`.)
    public static let actionConfidenceBase: Double = 0.25

    /// Cuánto suma tener el equipo entero detectado, de §16.2.
    /// (Python: `ACTION_CONFIDENCE_PER_SQUAD`.)
    public static let actionConfidencePerSquad: Double = 0.3

    /// Cuánto suma que haya una sola moda clara, de §16.2.
    /// (Python: `ACTION_CONFIDENCE_PER_UNIMODAL`.)
    public static let actionConfidencePerUnimodal: Double = 0.25

    /// Lo que aportaría el campo de convergencia de §16.2 paso 3, **y que este v0 no puede
    /// aportar**: vota hacia dónde se mueve cada jugador, y sin tracker no hay velocidad.
    ///
    /// No se redistribuye entre los otros términos a propósito. La confianza de esta evidencia
    /// tope en 0.80 mientras falte, y eso es exactamente lo que se quiere: cuando llegue el balón
    /// (TASK V6), la fusión por precisión de §17.2 preferirá el balón por sí sola, sin que nadie
    /// tenga que ajustar un peso a mano. El término vuelve con el tracker.
    /// (Python: `ACTION_CONFIDENCE_CONVERGENCE`.)
    public static let actionConfidenceConvergence: Double = 0.2

    /// Confianza mínima con la que se divide para sacar la incertidumbre, de §16.2. Evita que
    /// una evidencia malísima produzca una incertidumbre infinita en vez de solo muy grande.
    /// (Python: `ACTION_CONFIDENCE_FLOOR`.)
    public static let actionConfidenceFloor: Double = 0.15

    /// Incertidumbre de la evidencia con confianza 1, en radianes (6°).
    ///
    /// La §16.2 la fija en 6 m; a la distancia típica a la jugada son unos 6°. Es lo que entra
    /// como la incertidumbre de los jugadores en la fusión por precisión de §17.2
    /// cuando exista el balón.
    /// (Python: `ACTION_BASE_SIGMA_RAD`.)
    public static let actionBaseSigmaRad: Double = 0.105

    /// Frecuencia natural del paneo (§18.4 `pan_x.fn_base`).
    /// (Python: `DIRECTOR_YAW_FN_BASE_HZ`.)
    public static let directorYawFnBaseHz: Double = 0.45

    /// Hz que se suman con urgencia 1 (§18.4 `pan_x.fn_urgent_gain`).
    /// (Python: `DIRECTOR_YAW_URGENT_GAIN_HZ`.)
    public static let directorYawUrgentGainHz: Double = 0.35

    /// 23.4 °/s. Los 900 px/s de §18.4, que el propio blueprint anota como ~23 °/s.
    /// (Python: `DIRECTOR_YAW_V_MAX_RAD_S`.)
    public static let directorYawVMaxRadS: Double = 0.408

    /// 46.9 °/s². Los 1800 px/s² de §18.4.
    /// (Python: `DIRECTOR_YAW_A_MAX_RAD_S2`.)
    public static let directorYawAMaxRadS2: Double = 0.819

    /// 65 °/s. Los 2500 px/s de §18.4: lo deprisa que se le deja moverse al objetivo.
    /// (Python: `DIRECTOR_YAW_SLEW_RAD_S`.)
    public static let directorYawSlewRadS: Double = 1.134

    /// Fracción del plano que engancha el paneo (§18.4 `pan_x.dead_out_frac`).
    /// (Python: `DIRECTOR_YAW_DEAD_OUT_FRAC`.)
    public static let directorYawDeadOutFrac: Double = 0.09

    /// La que lo suelta (§18.4 `pan_x.dead_in_frac`). La mitad: esa diferencia es la
    /// histéresis, y también el error residual con el que la cámara se queda quieta.
    /// (Python: `DIRECTOR_YAW_DEAD_IN_FRAC`.)
    public static let directorYawDeadInFrac: Double = 0.045

    /// Dónde empieza a frenar contra el borde de lo que se ve (§18.4 `pan_x.wall_margin_frac`).
    /// (Python: `DIRECTOR_YAW_WALL_MARGIN_FRAC`.)
    public static let directorYawWallMarginFrac: Double = 0.05

    /// §18.4 `pan_y.fn_base`. Más baja que la del yaw a propósito: una cámara que cabecea se
    /// nota mucho más que una que panea, porque el horizonte es la referencia del espectador.
    /// (Python: `DIRECTOR_PITCH_FN_BASE_HZ`.)
    public static let directorPitchFnBaseHz: Double = 0.28

    /// §18.4 `pan_y.fn_urgent_gain`.
    /// (Python: `DIRECTOR_PITCH_URGENT_GAIN_HZ`.)
    public static let directorPitchUrgentGainHz: Double = 0.15

    /// 6.8 °/s. Los 260 px/s de §18.4.
    /// (Python: `DIRECTOR_PITCH_V_MAX_RAD_S`.)
    public static let directorPitchVMaxRadS: Double = 0.118

    /// 18.2 °/s². Los 700 px/s² de §18.4.
    /// (Python: `DIRECTOR_PITCH_A_MAX_RAD_S2`.)
    public static let directorPitchAMaxRadS2: Double = 0.318

    /// 23.4 °/s. Los 900 px/s de §18.4.
    /// (Python: `DIRECTOR_PITCH_SLEW_RAD_S`.)
    public static let directorPitchSlewRadS: Double = 0.408

    /// §18.4 `pan_y.dead_out_frac`, sobre el campo de visión **vertical**. Bastante mayor que
    /// la del yaw: el juego se mueve a lo largo del campo, no a lo alto.
    /// (Python: `DIRECTOR_PITCH_DEAD_OUT_FRAC`.)
    public static let directorPitchDeadOutFrac: Double = 0.15

    /// §18.4 `pan_y.dead_in_frac`.
    /// (Python: `DIRECTOR_PITCH_DEAD_IN_FRAC`.)
    public static let directorPitchDeadInFrac: Double = 0.07

    /// §18.4 no lo da para el eje vertical; se hereda del horizontal.
    /// (Python: `DIRECTOR_PITCH_WALL_MARGIN_FRAC`.)
    public static let directorPitchWallMarginFrac: Double = 0.05

    /// §18.4 `zoom_w.fn_base`. La más baja de las tres: un zoom que respira es lo que más
    /// delata a una cámara automática.
    /// (Python: `DIRECTOR_HFOV_FN_BASE_HZ`.)
    public static let directorHfovFnBaseHz: Double = 0.22

    /// §18.4 no le da ganancia por urgencia al zoom, y es coherente: cuando hay prisa se panea
    /// para no perder la jugada, no se cambia de plano.
    /// (Python: `DIRECTOR_HFOV_URGENT_GAIN_HZ`.)
    public static let directorHfovUrgentGainHz: Double = 0.0

    /// 10.9 °/s de campo de visión. Los 520 px/s de ancho de recorte de §18.4, convertidos en
    /// el plano NORMAL, que es donde se pasa la mayor parte del partido.
    /// (Python: `DIRECTOR_HFOV_V_MAX_RAD_S`.)
    public static let directorHfovVMaxRadS: Double = 0.19

    /// 18.9 °/s². Los 900 px/s² de §18.4, con la misma conversión.
    /// (Python: `DIRECTOR_HFOV_A_MAX_RAD_S2`.)
    public static let directorHfovAMaxRadS2: Double = 0.33

    /// 20 °/s. §18.4 no lo da: el objetivo del zoom no viene de un detector ruidoso sino de la
    /// gramática de planos, que ya trae sus propios tiempos de permanencia (V5). Se pone por
    /// encima de `v_max` para no limitar dos veces la misma cosa.
    /// (Python: `DIRECTOR_HFOV_SLEW_RAD_S`.)
    public static let directorHfovSlewRadS: Double = 0.349

    /// **Sin zona muerta**, a diferencia de los otros dos ejes.
    ///
    /// Vale para los dos umbrales. El objetivo del zoom es una decisión deliberada de la gramática
    /// de planos, no una estimación ruidosa que haya que filtrar: si hubiera zona muerta, el plano
    /// se quedaría permanentemente a un trozo del que se pidió, y quien lo pidió no tendría forma
    /// de saberlo. Lo que evita que el zoom vaya y venga es el dwell de §18.4, que es de V5.
    /// (Python: `DIRECTOR_HFOV_DEAD_FRAC`.)
    public static let directorHfovDeadFrac: Double = 0.0

    /// Frena antes de llegar al plano más cerrado que la lente puede servir (V0a) y al más
    /// abierto que las cámaras cubren. Chocar contra el tope del zoom se ve como un tirón.
    /// (Python: `DIRECTOR_HFOV_WALL_MARGIN_FRAC`.)
    public static let directorHfovWallMarginFrac: Double = 0.05

    /// Amortiguamiento de los tres ejes (§18.4 lo fija a 1.0 en los tres).
    ///
    /// Es el crítico: la cámara llega al objetivo lo más rápido posible **sin pasarse**. Un
    /// rebote, por pequeño que sea, el ojo lo lee como un error de quien opera.
    /// (Python: `DIRECTOR_ZETA`.)
    public static let directorZeta: Double = 1.0

    /// Cuánto frena el muro blando, en múltiplos del amortiguamiento crítico del eje.
    ///
    /// Se aplica en el fondo del margen y se desvanece hacia su borde interior, así que un eje
    /// que entre despacio casi no lo nota y uno que entre lanzado se para. Seis veces el crítico
    /// suena mucho y no lo es: solo actúa dentro del último 5 % del recorrido y solo contra el
    /// movimiento hacia fuera, que es exactamente donde se quiere que sea contundente.
    /// (Python: `DIRECTOR_WALL_DAMPING`.)
    public static let directorWallDamping: Double = 6.0

    /// Paso **máximo** de la rejilla donde se muestrea la rampa de la costura, en píxeles.
    ///
    /// La costura es un plano que pasa por el centro óptico, así que en el plano del programa es
    /// una recta y su rampa es una función suave. Muestrearla cada 16 px y estirar cuesta la
    /// décima parte que hacerlo píxel a píxel y no se distingue: es un difuminado, y su perfil
    /// exacto no lo mira nadie.
    ///
    /// Es un máximo y no un valor fijo porque el difuminado no siempre mide lo mismo: en una
    /// salida pequeña, o con una costura estrecha, 16 px son más anchos que la propia rampa, y
    /// entonces estirar la ensancha en vez de reproducirla. `ViewRenderer` aprieta el paso hasta
    /// que caben cuatro muestras dentro del difuminado.
    /// (Python: `PROGRAM_SEAM_GRID_PX`.)
    public static let programSeamGridPx: Int = 16

    /// Puntos por lado con los que se dibuja el borde del encuadre sobre el lienzo.
    ///
    /// El borde es recto en el plano del programa y curvo sobre el cilindro desenrollado. Con
    /// cuatro esquinas saldría un rectángulo que miente justo en los planos abiertos, que son
    /// donde más se curva; con nueve puntos por lado el error queda por debajo del píxel en el
    /// monitor, que es donde se mira.
    /// (Python: `VIEW_OUTLINE_SAMPLES`.)
    public static let viewOutlineSamples: Int = 9

    /// Distancia de la cámara a la jugada, en metros, por defecto.
    ///
    /// El soporte va en la banda a la altura del centro del campo (ADR 0012). Desde ahí, al centro
    /// de la jugada media hay el medio ancho del campo más lo que el trípode esté retirado de la
    /// línea: 34 + 6. Es lo que convierte los metros de §20.5 en grados de encuadre, y sale de
    /// dónde acabe el trípode (M3 de `docs/MEDICIONES.md`).
    /// (Python: `ACTION_DISTANCE_M`.)
    public static let actionDistanceM: Double = 40.0

    /// Dispersión de los jugadores por debajo de la cual se cierra a ATTACK (§20.5, regla 7).
    /// Es juego concentrado: un ataque organizado en el área.
    /// (Python: `SHOT_TIGHT_M`.)
    public static let shotTightM: Double = 25.0

    /// Dispersión por encima de la cual se abre a WIDE (§20.5, regla 5). Los equipos muy
    /// estirados son una transición, y en una transición lo que se pierde es la jugada.
    /// (Python: `SHOT_STRETCHED_M`.)
    public static let shotStretchedM: Double = 45.0

    /// Metros que tiene que contener el plano abierto. Un equipo completamente estirado.
    ///
    /// No es el campo entero: que la cámara **alcance** las dos esquinas es otro presupuesto, el
    /// angular, y lo cubre la cobertura del soporte.
    /// (Python: `SHOT_WIDE_M`.)
    public static let shotWideM: Double = 70.0

    /// Aire a los lados del grupo, en veces su dispersión. Un plano tan ancho como el grupo
    /// deja a los de los extremos partidos por el borde: el margen es lo que separa un encuadre
    /// de un recorte.
    /// (Python: `SHOT_HEADROOM`.)
    public static let shotHeadroom: Double = 1.3

    /// Confianza mínima de la evidencia para cerrar a ATTACK (§20.5, regla 7).
    ///
    /// La regla original pide `conf_ball > 0.6`; sin balón todavía (V6), el sustituto es la
    /// confianza de los jugadores. Cerrar es la decisión que más castiga equivocarse —lo que se
    /// queda fuera de cuadro no se recupera—, así que no se cierra con una estimación dudosa.
    /// (Python: `SHOT_TIGHT_CONFIDENCE`.)
    public static let shotTightConfidence: Double = 0.6

    /// Segundos mínimos en un plano antes de poder cambiar (§18.4 `zoom_w.dwell_min_s`).
    ///
    /// Es lo que impide que el zoom respire. Las reglas urgentes se lo saltan: perder la jugada
    /// por esperar dos segundos es peor que un cambio de plano rápido.
    /// (Python: `SHOT_DWELL_MIN_S`.)
    public static let shotDwellMinS: Double = 2.0

    /// Segundos que una condición tiene que sostenerse antes de entrar en su plano
    /// (§18.4 `zoom_w.dwell_enter_s`). Un grupo que se junta medio segundo no es un ataque.
    /// (Python: `SHOT_DWELL_ENTER_S`.)
    public static let shotDwellEnterS: Double = 1.2

    /// Lo mismo para abrir (§18.4 `zoom_w.dwell_exit_wide_s`). **Abrir es mucho más rápido que
    /// cerrar**, y es la asimetría más importante de la gramática: quedarse corto de plano cuesta
    /// la jugada, y quedarse ancho solo cuesta que se vea algo lejos.
    /// (Python: `SHOT_DWELL_EXIT_WIDE_S`.)
    public static let shotDwellExitWideS: Double = 0.4

    /// Segundos de plano de situación tras un saque de centro o un gol (§20.5, regla 3).
    /// Después de un gol lo que se quiere ver es la celebración y el campo, no el balón.
    /// (Python: `SHOT_SITUATION_S`.)
    public static let shotSituationS: Double = 4.0
}
