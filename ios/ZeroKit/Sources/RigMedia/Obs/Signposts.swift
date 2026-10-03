// Señales para Instruments (IOS-05): un intervalo por etapa en Points of Interest.
//
// Es el equivalente del structlog del servidor para lo que no cabe en un log: dónde
// se va el tiempo de cada frame. Se deja puesto siempre; sin Instruments delante no
// cuesta nada medible.

import Foundation
import os

/// Las etapas del pipeline, con el nombre que verá Instruments y la telemetría.
public enum RigStage: String, CaseIterable, Sendable {
    case capture
    case blit
    case preprocess
    case infer
    case decode
    case render
    case encode
    case link
    case srt
}

public enum Signposts {
    public static let subsystem = "io.footballai.zero"

    private static let signposter = OSSignposter(
        subsystem: subsystem, category: .pointsOfInterest
    )

    /// Abre el intervalo de una etapa. Se cierra con `end(_:_:)`.
    public static func begin(_ stage: RigStage) -> OSSignpostIntervalState {
        signposter.beginInterval("stage", id: signposter.makeSignpostID(), "\(stage.rawValue)")
    }

    public static func end(_ stage: RigStage, _ state: OSSignpostIntervalState) {
        signposter.endInterval("stage", state, "\(stage.rawValue)")
    }

    /// Mide un bloque síncrono y devuelve lo suyo.
    public static func measure<T>(_ stage: RigStage, _ block: () throws -> T) rethrows -> T {
        let state = begin(stage)
        defer { end(stage, state) }
        return try block()
    }

    /// Un suceso puntual (un descarte, un reintento): aparece como marca, no intervalo.
    public static func event(_ name: StaticString, _ detail: String = "") {
        signposter.emitEvent(name, "\(detail)")
    }
}
