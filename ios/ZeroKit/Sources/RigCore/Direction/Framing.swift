// El encuadre a mano de «Una cámara» (ADR 0033, IOS-115): porte línea a línea de
// libs/vision/framing.py del repo football-ai (REF-68), contra su dorado framing.json.
//
// El operador dibuja un recuadro sobre la vista general, que es la lente entera enderezada
// (`FullLensView`). El programa pasa a una cámara virtual que gira hacia el centro del
// recuadro y abarca lo que él abarca: no es un recorte. Todo se resuelve en el plano de la
// vista general, en coordenadas normalizadas (0–1 de izquierda a derecha y de arriba
// abajo). Cámara y vista son pinhole, así que bastan las cuatro esquinas de un encuadre
// para saber si cabe, y el encuadre nunca sale de la vista general.
//
// Un encuadre (`Framing`) es dónde cae su centro en la vista general y su campo horizontal.
// El paso suave interpola el yaw, el pitch y el logaritmo del campo con aceleración y
// frenada, y vuelve a meter cada punto del camino en la lente. Ningún número se teclea
// aquí: salen de RigConstants (CAMERA_*, FRAMING_*, de libs/vision/constants.py).

import Foundation

/// Un encuadre: dónde cae su centro en la vista general (0–1) y cuánto abarca.
public struct Framing: Equatable, Sendable {
    public let centerU: Double
    public let centerV: Double
    public let hfovRad: Double

    public init(centerU: Double, centerV: Double, hfovRad: Double) {
        self.centerU = centerU
        self.centerV = centerV
        self.hfovRad = hfovRad
    }
}

/// Una orden del mando que no se puede aplicar: el texto va tal cual al operador.
public enum FramingError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self { case let .invalid(texto): return texto }
    }
}

/// La rotación cámara → soporte de una vista sin roll: `CameraPose(yaw, pitch, 0)`.
private struct FramingRotation: Sendable {
    let m: [Double]  // por filas, 3×3

    init(yawRad: Double, pitchRad: Double) {
        let cy = cos(yawRad), sy = sin(yawRad)
        let cp = cos(pitchRad), sp = sin(pitchRad)
        m = [cy, sy * sp, sy * cp, 0, cp, -sp, -sy, cy * sp, cy * cp]
    }

    func apply(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
         m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
         m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    /// `mᵀ · v`: de ejes del soporte a ejes de la cámara.
    func applyT(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[3] * v.1 + m[6] * v.2,
         m[1] * v.0 + m[4] * v.1 + m[7] * v.2,
         m[2] * v.0 + m[5] * v.1 + m[8] * v.2)
    }
}

/// Yaw y pitch de una dirección, como `RectilinearView.directionAt`.
private func framingYawPitch(_ d: (Double, Double, Double)) -> (yaw: Double, pitch: Double) {
    (atan2(d.0, d.2), atan2(-d.1, hypot(d.0, d.2)))
}

/// La vista general de una cámara y los encuadres que caben en ella.
///
/// `width`×`height` es el tamaño del programa: la vista general tiene su misma relación de
/// aspecto, así que un recuadro de 16:9 en píxeles es un cuadrado en coordenadas
/// normalizadas.
public struct FramingSpace: Sendable {
    public let width: Int
    public let height: Int
    public let overview: RectilinearView
    public let hfovMax: Double
    public let hfovMin: Double
    private let r0: FramingRotation
    private let tanX: Double
    private let tanY: Double

    public init(camera: RigCamera, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        overview = try RectilinearView(
            yawRad: camera.pose.yawRad, pitchRad: camera.pose.pitchRad,
            hfovRad: FullLensView.hfovRad(of: camera, width: width, height: height),
            width: width, height: height
        )
        r0 = FramingRotation(yawRad: overview.yawRad, pitchRad: overview.pitchRad)
        tanX = tan(overview.hfovRad / 2)
        tanY = tanX * Double(height) / Double(width)
        hfovMax = overview.hfovRad
        hfovMin = min(FullLensView.hfovRad(zoom: RigConstants.cameraZoomMax), hfovMax)
    }

    /// El zoom de la app Cámara que corresponde a ese campo horizontal.
    public static func zoom(hfovRad: Double) -> Double {
        RigConstants.fullFrameHalfWidthMm / (RigConstants.mainCameraEquivalentFocalMm * tan(hfovRad / 2))
    }

    // MARK: - De la vista general al soporte y vuelta

    /// La dirección, en ejes del soporte, del punto (u, v) de la vista general.
    private func ray(_ u: Double, _ v: Double) -> (Double, Double, Double) {
        r0.apply(((2 * u - 1) * tanX, (2 * v - 1) * tanY, 1))
    }

    /// (u, v, z) de una dirección en la vista general; z ≤ 0 si queda detrás.
    private func toOverview(_ d: (Double, Double, Double)) -> (u: Double, v: Double, z: Double) {
        let c = r0.applyT(d)
        guard c.2 > 0 else { return (.nan, .nan, c.2) }
        return ((c.0 / c.2 / tanX + 1) / 2, (c.1 / c.2 / tanY + 1) / 2, c.2)
    }

    private func axis(_ u: Double, _ v: Double) -> FramingRotation {
        let (yaw, pitch) = framingYawPitch(ray(u, v))
        return FramingRotation(yawRad: yaw, pitchRad: pitch)
    }

    private func corners(_ u: Double, _ v: Double, _ hfovRad: Double) -> [(u: Double, v: Double, z: Double)] {
        let r = axis(u, v)
        let tx = tan(hfovRad / 2)
        let ty = tx * Double(height) / Double(width)
        // Desde arriba a la izquierda, en el sentido del reloj.
        return [(-tx, -ty), (tx, -ty), (tx, ty), (-tx, ty)].map { toOverview(r.apply(($0.0, $0.1, 1))) }
    }

    private func fits(_ u: Double, _ v: Double, _ hfovRad: Double) -> Bool {
        let lo = -RigConstants.framingFitEps, hi = 1 + RigConstants.framingFitEps
        return corners(u, v, hfovRad).allSatisfy { $0.z > 0 && lo <= $0.u && $0.u <= hi && lo <= $0.v && $0.v <= hi }
    }

    /// El valor más cercano a `outside` que aún cabe, yendo desde `inside`, que cabe.
    private static func bisect(inside: Double, outside: Double, _ cabe: (Double) -> Bool) -> Double {
        var dentro = inside, fuera = outside
        for _ in 0..<RigConstants.framingFitIterations {
            let mitad = (dentro + fuera) / 2
            if cabe(mitad) {
                dentro = mitad
            } else {
                fuera = mitad
            }
        }
        return dentro
    }

    // MARK: - Lo que cabe

    /// El encuadre metido en la lente: el campo entre 3× y la lente entera, y la vista corrida
    /// hacia dentro si se sale. Primero en vertical, con el centro en medio, y luego en
    /// horizontal: así un recuadro pegado a un lado solo se corre hacia ese lado.
    public func fit(_ f: Framing) -> Framing {
        let hfov = min(max(f.hfovRad, hfovMin), hfovMax)
        var u = min(max(f.centerU, 0), 1)
        var v = min(max(f.centerV, 0), 1)
        if !fits(0.5, v, hfov) {
            v = Self.bisect(inside: 0.5, outside: v) { fits(0.5, $0, hfov) }
        }
        if !fits(u, v, hfov) {
            let vFijo = v
            u = Self.bisect(inside: 0.5, outside: u) { fits($0, vFijo, hfov) }
        }
        return Framing(centerU: u, centerV: v, hfovRad: hfov)
    }

    /// La lente entera: la vista general misma.
    public func full() -> Framing {
        Framing(centerU: 0.5, centerV: 0.5, hfovRad: hfovMax)
    }

    /// El encuadre de partida: el zoom que se eligió en el móvil, centrado.
    public func start(zoom: Double) -> Framing {
        fit(Framing(centerU: 0.5, centerV: 0.5, hfovRad: FullLensView.hfovRad(zoom: zoom)))
    }

    // MARK: - Las órdenes del mando

    /// `camera/frame`: el recuadro dibujado, llevado a 16:9 creciendo su lado corto alrededor
    /// del centro, y la cámara que gira hacia su centro y lo abarca entero.
    public func frameRect(x0: Double, y0: Double, x1: Double, y1: Double) throws -> Framing {
        guard [x0, y0, x1, y1].allSatisfy(\.isFinite) else {
            throw FramingError.invalid("el recuadro tiene que llevar números: \((x0, y0, x1, y1))")
        }
        func dentro(_ x: Double) -> Double { min(max(x, 0), 1) }
        let izq = min(dentro(x0), dentro(x1)), der = max(dentro(x0), dentro(x1))
        let arr = min(dentro(y0), dentro(y1)), aba = max(dentro(y0), dentro(y1))
        let lado = max(der - izq, aba - arr)
        guard lado >= RigConstants.cameraFrameMinSize else {
            throw FramingError.invalid(
                "el recuadro es más pequeño que \(RigConstants.cameraFrameMinSize) de la vista: \(lado)"
            )
        }
        let uc = (izq + der) / 2, vc = (arr + aba) / 2
        let r = axis(uc, vc)
        let altoSobreAncho = Double(height) / Double(width)
        // La tangente del medio campo que hace falta para abarcar las esquinas y los puntos
        // medios de los lados: visto desde la cámara girada, el recuadro es un trapecio.
        var medio = 0.0
        for du in [-1.0, 0, 1] {
            for dv in [-1.0, 0, 1] where !(du == 0 && dv == 0) {
                let c = r.applyT(ray(uc + du * lado / 2, vc + dv * lado / 2))
                medio = max(medio, abs(c.0 / c.2), abs(c.1 / c.2) / altoSobreAncho)
            }
        }
        return fit(Framing(centerU: uc, centerV: vc, hfovRad: 2 * atan(medio)))
    }

    /// `camera/zoom`: más cerca (>1) o más lejos (<1) alrededor del mismo centro.
    public func zoomBy(_ f: Framing, factor: Double) throws -> Framing {
        let bajo = RigConstants.cameraZoomFactorMin, alto = RigConstants.cameraZoomFactorMax
        guard bajo <= factor, factor <= alto else {
            throw FramingError.invalid("el factor de zoom tiene que estar entre \(bajo) y \(alto): \(factor)")
        }
        return fit(Framing(centerU: f.centerU, centerV: f.centerV, hfovRad: 2 * atan(tan(f.hfovRad / 2) / factor)))
    }

    /// `camera/pan`: el centro pasa al punto (0,5 + dx, 0,5 + dy) del encuadre actual.
    public func panBy(_ f: Framing, dx: Double, dy: Double) throws -> Framing {
        let tope = RigConstants.cameraPanMax
        guard abs(dx) <= tope, abs(dy) <= tope else {
            throw FramingError.invalid("el paso tiene que estar entre -\(tope) y \(tope): \((dx, dy))")
        }
        let tx = tan(f.hfovRad / 2)
        let ty = tx * Double(height) / Double(width)
        let p = toOverview(axis(f.centerU, f.centerV).apply((2 * dx * tx, 2 * dy * ty, 1)))
        guard p.z > 0 else { return f }
        return fit(Framing(centerU: p.u, centerV: p.v, hfovRad: f.hfovRad))
    }

    // MARK: - El paso suave

    /// Dónde va la cámara `elapsedMs` después de salir de `a` hacia `b`. Con `durationMs` 0
    /// es el corte: llega de golpe.
    public func between(_ a: Framing, _ b: Framing, elapsedMs: Double,
                        durationMs: Double = RigConstants.cameraMoveMs) -> Framing {
        if durationMs <= 0 || elapsedMs >= durationMs { return b }
        let t = min(max(elapsedMs / durationMs, 0), 1)
        let s = t * t * (3 - 2 * t)  // aceleración y frenada
        let (yawA, pitchA) = framingYawPitch(ray(a.centerU, a.centerV))
        let (yawB, pitchB) = framingYawPitch(ray(b.centerU, b.centerV))
        let yaw = yawA + s * (yawB - yawA).remainder(dividingBy: 2 * .pi)
        let pitch = pitchA + s * (pitchB - pitchA)
        let hfov = exp(log(a.hfovRad) + s * (log(b.hfovRad) - log(a.hfovRad)))
        let cp = cos(pitch)
        let p = toOverview((cp * sin(yaw), -sin(pitch), cp * cos(yaw)))
        guard p.z > 0 else { return b }
        return fit(Framing(centerU: p.u, centerV: p.v, hfovRad: hfov))
    }

    // MARK: - Lo que se enseña

    /// La cámara virtual del programa para ese encuadre.
    public func view(_ f: Framing) throws -> RectilinearView {
        let (yaw, pitch) = framingYawPitch(ray(f.centerU, f.centerV))
        return try RectilinearView(yawRad: yaw, pitchRad: pitch, hfovRad: f.hfovRad, width: width, height: height)
    }

    /// El contorno del encuadre en la vista general: cuatro esquinas desde arriba a la
    /// izquierda, en el sentido del reloj. Casi un rectángulo: lo tuerce la perspectiva.
    public func outline(_ f: Framing) -> [(u: Double, v: Double)] {
        corners(f.centerU, f.centerV, f.hfovRad).map { ($0.u, $0.v) }
    }

    /// El zoom en la escala de la app Cámara.
    public func zoom(_ f: Framing) -> Double {
        Self.zoom(hfovRad: f.hfovRad)
    }

    /// Si el mando avisa «se verá borroso»: pasado el 2×.
    public func soft(_ f: Framing) -> Bool {
        zoom(f) > RigConstants.cameraZoomSoft * (1 + RigConstants.framingFitEps)
    }
}

/// Cómo está el encuadre, para el mando: el destino y si va de camino.
public struct FramingStatus: Equatable, Sendable {
    public let target: Framing
    public let zoom: Double
    /// Las cuatro esquinas del contorno del destino, u y v alternos.
    public let outline: [Double]
    public let moving: Bool
    public let soft: Bool
}

/// El encuadre de la pasada de «Una cámara»: a dónde va y por dónde va.
///
/// Las órdenes llegan del mando (por Pigeon) y el programa lee la vista en cada fotograma,
/// desde hilos distintos: todo va bajo un candado. El tiempo es el del host, monótono.
public final class FramingController: @unchecked Sendable {
    public let space: FramingSpace
    /// El encuadre de partida: el zoom que se eligió en el móvil, centrado.
    public let startFraming: Framing
    private let nowMs: () -> Double
    private let lock = NSLock()
    private var from: Framing
    private var to: Framing
    private var startedMs: Double
    private var durationMs: Double

    /// `nowMs`: el reloj monótono en ms; los tests ponen uno falso.
    public init(space: FramingSpace, zoom: Double, nowMs: @escaping () -> Double = FramingController.hostNowMs) {
        self.space = space
        self.nowMs = nowMs
        startFraming = space.start(zoom: zoom)
        from = startFraming
        to = startFraming
        startedMs = nowMs()
        durationMs = 0
    }

    public static func hostNowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    private func current(_ ahora: Double) -> Framing {
        space.between(from, to, elapsedMs: ahora - startedMs, durationMs: durationMs)
    }

    /// Por dónde va la cámara ahora.
    public func framing() -> Framing {
        lock.lock(); defer { lock.unlock() }
        return current(nowMs())
    }

    /// La vista del programa ahora.
    public func view() -> RectilinearView? {
        try? space.view(framing())
    }

    /// El destino: a dónde va, o donde está si ya llegó.
    public var target: Framing {
        lock.lock(); defer { lock.unlock() }
        return to
    }

    /// Va a `target` desde donde esté ahora: en `cameraMoveMs` con aceleración y frenada, o
    /// de golpe con `cut`.
    public func go(to target: Framing, cut: Bool) {
        lock.lock(); defer { lock.unlock() }
        let ahora = nowMs()
        from = current(ahora)
        to = space.fit(target)
        startedMs = ahora
        durationMs = cut ? 0 : RigConstants.cameraMoveMs
    }

    public func status() -> FramingStatus {
        lock.lock(); defer { lock.unlock() }
        let ahora = nowMs()
        return FramingStatus(
            target: to,
            zoom: space.zoom(to),
            outline: space.outline(to).flatMap { [$0.u, $0.v] },
            moving: durationMs > 0 && ahora - startedMs < durationMs,
            soft: space.soft(to)
        )
    }
}
