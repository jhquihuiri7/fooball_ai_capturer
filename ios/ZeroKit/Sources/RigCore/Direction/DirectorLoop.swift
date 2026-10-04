// El bucle del director del maestro, lógica pura (IOS-37, réplica del cálculo de
// vista de tools/program_director.py sin el render).
//
// Dos ritmos: en cada ciclo de detección (7,5 Hz) entra la fusión de las dos cámaras
// y de ella sale la acción; a 30 Hz, en cada instante de la rejilla del ProgramClock,
// el motor da un paso y sale un ViewCommand (ADR 0023 §5). La integración en vivo,
// con hilos y Pigeon, es de IOS-73: aquí no hay reloj, el tiempo lo traen los rigMs.

import Foundation

/// Las ganancias de color de cada lado, que IOS-38 calcula y viajan en la vista.
public struct ColorGains: Equatable, Sendable {
    public var left: [Double]
    public var right: [Double]

    public init(left: [Double], right: [Double]) {
        self.left = left
        self.right = right
    }

    /// Sin igualado: los dos sensores tal cual.
    public static let unity = ColorGains(left: [1, 1, 1], right: [1, 1, 1])
}

/// Lo que el maestro manda para el fotograma del programa de instante `targetRigMs`.
public struct ViewCommand: Equatable, Sendable {
    public let targetRigMs: Int64
    /// Contador de vistas, sin huecos; da la vuelta en u32 como en el enlace.
    public let viewId: UInt32
    public let yawRad: Double
    public let pitchRad: Double
    public let hfovRad: Double
    /// Qué lados pintan algo de esta vista. El que no está manda `no_part`.
    public let sides: [CameraSide]
    public let seamYawRad: Double
    public let featherRad: Double
    public let gains: ColorGains

    public init(
        targetRigMs: Int64, viewId: UInt32, yawRad: Double, pitchRad: Double, hfovRad: Double,
        sides: [CameraSide], seamYawRad: Double, featherRad: Double, gains: ColorGains
    ) {
        self.targetRigMs = targetRigMs
        self.viewId = viewId
        self.yawRad = yawRad
        self.pitchRad = pitchRad
        self.hfovRad = hfovRad
        self.sides = sides
        self.seamYawRad = seamYawRad
        self.featherRad = featherRad
        self.gains = gains
    }
}

/// Lo que el operador decide sobre la cámara.
public enum DirectorMode: Equatable, Sendable {
    /// La IA dirige: acción y gramática de planos.
    case auto
    /// El operador apunta; el muelle lo lleva allí sin tirones.
    case manual(RigDirection, hfovRad: Double)
    /// El plano abierto, centrado y quieto.
    case fixedWide
}

public final class DirectorLoop {
    public let rig: RigModel
    /// El lienzo de las dos lentes: la cobertura completa.
    public let canvas: CylindricalCanvas
    public let width: Int
    public let height: Int
    /// `true` si hasta el plano más abierto amplía píxeles que la lente no capturó.
    public private(set) var upscaling: Bool
    public private(set) var evidence: PlayerEvidence?
    public private(set) var shot: ShotDecision?
    public var mode: DirectorMode = .auto
    /// La IA de la escalera de degradación (ADR 0019). Apagada, las detecciones se
    /// ignoran y la cámara vuelve, al ritmo normal del muelle, al plano abierto.
    public var aiEnabled = true
    public var gains: ColorGains = .unity
    /// El lado que queda cuando el otro se ha caído, o `nil` con las dos.
    public private(set) var singleLens: CameraSide?

    private let engine: VirtualCameraEngine
    private let grammar: ShotGrammar
    private let hfovMinRad: Double?
    private let hfovMaxRad: Double?
    private let frameDurationMs: Double
    /// La acción de este ciclo, que el próximo paso del motor consume una sola vez.
    private var pendingTarget: RigDirection?
    /// Crece una vez si un ciclo trae más jugadores; después no vuelve a asignar.
    private let estimator = ActionEstimator(playerCapacity: RigConstants.actionFullSquad)
    private var lastRigMs: Int64?
    private var nextViewId: UInt32 = 0

    /// `frameDurationMs` es el paso de la rejilla del ProgramClock (IOS-84): los
    /// huecos de varios fotogramas se integran en pasos de ese tamaño, porque el
    /// muelle explícito no es estable con un dt arbitrario.
    public init(
        rig: RigModel,
        canvas: CylindricalCanvas,
        width: Int,
        height: Int,
        plan: ShotPlan,
        frameDurationMs: Double,
        hfovMinRad: Double? = nil,
        hfovMaxRad: Double? = nil
    ) throws {
        precondition(frameDurationMs > 0, "el paso de la rejilla debe ser positivo")
        self.rig = rig
        self.canvas = canvas
        self.width = width
        self.height = height
        self.hfovMinRad = hfovMinRad
        self.hfovMaxRad = hfovMaxRad
        self.frameDurationMs = frameDurationMs
        let (limites, amplia) = try Self.programLimits(
            rig: rig, canvas: canvas, width: width, height: height,
            hfovMinRad: hfovMinRad, hfovMaxRad: hfovMaxRad
        )
        upscaling = amplia
        // Se arranca en el plano más abierto que cabe y centrado: sin detecciones
        // todavía, ver el campo entero es mejor que apuntar a ciegas.
        let vista = try RectilinearView(
            yawRad: (canvas.yawMinRad + canvas.yawMaxRad) / 2.0,
            pitchRad: (canvas.pitchMinRad + canvas.pitchMaxRad) / 2.0,
            hfovRad: limites.hfovHigh,
            width: width,
            height: height
        )
        engine = VirtualCameraEngine(view: vista, limits: limites)
        grammar = ShotGrammar(plan: plan)
    }

    public var view: RectilinearView { engine.view }
    public var limits: CameraLimits { engine.limits }
    public var settled: Bool { engine.settled }

    /// Gol o saque de centro: plano de situación (llega de Dart por Pigeon).
    public func markSituation() {
        grammar.markSituation()
    }

    /// Pasa a una lente o vuelve a las dos. Los límites se recalculan con la
    /// cobertura de lo que queda, recortada al mismo pitch que el lienzo completo.
    public func setSingleLens(_ side: CameraSide?) throws {
        guard side != singleLens else { return }
        let lienzo = try side.map {
            try CylindricalCanvas.fit(
                rig,
                focalPx: canvas.focalPx,
                pitchLimitsRad: (canvas.pitchMinRad, canvas.pitchMaxRad),
                sides: [$0]
            )
        } ?? canvas
        let (limites, amplia) = try Self.programLimits(
            rig: rig, canvas: lienzo, width: width, height: height,
            hfovMinRad: hfovMinRad, hfovMaxRad: hfovMaxRad
        )
        engine.limits = limites
        upscaling = amplia
        singleLens = side
    }

    /// Un ciclo de detección, ya emparejado por rigMs (IOS-32): funde y estima la
    /// acción. El paso del motor que lo consume es el siguiente `tick`.
    public func ingest(left: [PlayerDetection], right: [PlayerDetection]) {
        let quedan = singleLens.map { $0 == .left ? (left, [PlayerDetection]()) : ([], right) }
            ?? (left, right)
        ingest(rig.fusePlayers(left: quedan.0, right: quedan.1))
    }

    /// Lo mismo con detecciones ya fundidas.
    public func ingest<S: ActionSighting>(_ sightings: [S]) {
        guard aiEnabled else { return }
        pendingTarget = observe(sightings)
    }

    /// El ViewCommand del instante `targetRigMs` de la rejilla del programa.
    public func tick(targetRigMs: Int64) throws -> ViewCommand {
        if let anterior = lastRigMs, targetRigMs > anterior {
            let dtMs = Double(targetRigMs - anterior)
            let pasos = max(1, Int((dtMs / frameDurationMs).rounded()))
            let dtS = dtMs / 1000.0 / Double(pasos)
            for paso in 0..<pasos {
                // La acción del ciclo se persigue en el primer paso; los demás siguen
                // al último objetivo, como en la referencia.
                try advance(target: paso == 0 ? takePending() : nil, dtS: dtS)
            }
        }
        if lastRigMs == nil || targetRigMs > lastRigMs! {
            lastRigMs = targetRigMs
        }
        return command(targetRigMs: targetRigMs)
    }

    /// Un paso con la semántica exacta de ProgramDirector.step: `sightings` vacío es
    /// «el detector no terminó», no «no hay jugadores». Es lo que replica el dorado.
    @discardableResult
    public func step<S: ActionSighting>(_ sightings: [S], dtS: Double) throws -> RectilinearView {
        let objetivo = sightings.isEmpty ? nil : observe(sightings)
        return try advance(target: objetivo, dtS: dtS)
    }

    // MARK: - Por dentro

    private func observe<S: ActionSighting>(_ sightings: [S]) -> RigDirection? {
        let nueva = estimator.evidence(from: sightings)
        if let nueva {
            evidence = nueva
        }
        return nueva?.direction
    }

    private func takePending() -> RigDirection? {
        defer { pendingTarget = nil }
        return pendingTarget
    }

    @discardableResult
    private func advance(target: RigDirection?, dtS: Double) throws -> RectilinearView {
        let centro = RigDirection(
            yawRad: (limits.yawLow + limits.yawHigh) / 2.0,
            pitchRad: (limits.pitchLow + limits.pitchHigh) / 2.0
        )
        switch mode {
        case let .manual(direccion, hfovRad):
            return try engine.step(target: direccion, hfovRad: hfovRad, dtS: dtS)
        case .fixedWide:
            return try engine.step(target: centro, hfovRad: limits.hfovHigh, dtS: dtS)
        case .auto where !aiEnabled:
            return try engine.step(target: centro, hfovRad: limits.hfovHigh, dtS: dtS)
        case .auto:
            // La gramática ve la última evidencia buena: que el detector no haya
            // terminado no es que no haya jugadores.
            let decision = try grammar.step(evidence, dtS: dtS)
            shot = decision
            return try engine.step(target: target, hfovRad: decision.hfovRad, dtS: dtS)
        }
    }

    private func command(targetRigMs: Int64) -> ViewCommand {
        let vista = engine.view
        var lados = sidesFor(rig: rig, view: vista)
        if let singleLens {
            lados = [singleLens]
        }
        defer { nextViewId &+= 1 }
        return ViewCommand(
            targetRigMs: targetRigMs,
            viewId: nextViewId,
            yawRad: vista.yawRad,
            pitchRad: vista.pitchRad,
            hfovRad: vista.hfovRad,
            sides: lados,
            seamYawRad: (rig.camera(.left).pose.yawRad + rig.camera(.right).pose.yawRad) / 2.0,
            featherRad: RigConstants.panoramaFeatherRad,
            gains: gains
        )
    }

    /// Plano con el que se pregunta por el máximo para que CameraLimits no rechace la
    /// pregunta antes de contestarla. No limita nada (el `_MINIMO_ABSOLUTO_RAD` de la
    /// referencia): un grado.
    private static let probeHfovRad = Double.pi / 180

    /// Los límites del programa como los calcula ProgramDirector: el mínimo es el que
    /// la lente sirve a 1:1, salvo que no quepa; entonces manda lo que cabe, porque
    /// una imagen blanda se puede ver y unas franjas negras no.
    public static func programLimits(
        rig: RigModel,
        canvas: CylindricalCanvas,
        width: Int,
        height: Int,
        hfovMinRad: Double? = nil,
        hfovMaxRad: Double? = nil
    ) throws -> (CameraLimits, upscaling: Bool) {
        let topeCerrado = hfovMinRad ?? tightestServableHfovRad(rig, programWidth: width)
        let aspecto = Double(height) / Double(width)
        let cabe = try CameraLimits.fromCanvas(
            canvas,
            hfovMinRad: min(topeCerrado, probeHfovRad),
            hfovMaxRad: hfovMaxRad ?? Double.pi,
            aspect: aspecto
        ).hfovHigh
        let limites = try CameraLimits.fromCanvas(
            canvas,
            hfovMinRad: min(topeCerrado, cabe),
            hfovMaxRad: hfovMaxRad ?? Double.pi,
            aspect: aspecto
        )
        return (limites, topeCerrado > cabe)
    }
}
