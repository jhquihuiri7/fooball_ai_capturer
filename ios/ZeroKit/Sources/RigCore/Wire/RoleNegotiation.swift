// Quién manda en el soporte (IOS-80, ADR 0023 §7), lógica pura.
//
// El rol (maestro o esclavo) ya no es el lado: lo dice el `term`, un entero ≥1 por
// partido que solo sube. Al conectar, cada móvil resuelve con lo que trae él y lo que
// trae el otro en su hello, y los dos tienen que llegar al MISMO resultado sin hablar
// más: un maestro, un esclavo y el mismo term. Por eso la regla es simétrica y los
// empates se rompen por el lado, que no cambia nunca.

import Foundation

public enum RigRole: String, Codable, Sendable {
    case master, slave
}

/// Lo que un móvil dice de sí al conectar (los campos del hello).
public struct RoleClaim: Equatable, Sendable {
    public let side: CameraSide
    public let role: RigRole
    /// 0 = todavía sin partido que dirigir.
    public let term: Int
    public let matchId: String?
    /// «Este móvil dirige»: solo decide al empezar un partido.
    public let prefersMaster: Bool

    public init(side: CameraSide, role: RigRole, term: Int, matchId: String?, prefersMaster: Bool) {
        self.side = side
        self.role = role
        self.term = term
        self.matchId = matchId
        self.prefersMaster = prefersMaster
    }
}

public enum RoleOutcome: Equatable, Sendable {
    /// Mi rol, el term con el que sigo y, si la situación era una mala configuración
    /// (dos maestros del mismo term), el error que hay que registrar.
    case resolved(role: RigRole, term: Int, matchId: String?, error: String?)
    /// Dos maestros de partidos distintos: no se resuelve solo; sin partes ni órdenes,
    /// y las dos pantallas piden elegir.
    case conflict
}

public enum RoleNegotiation {
    public static func negotiate(mine: RoleClaim, theirs: RoleClaim) -> RoleOutcome {
        // Un maestro con term 0 es provisional: arrancó solo y nunca negoció (ADR 0023 §7:
        // el term de un maestro es ≥1). No cuenta como maestro de un partido; si no, dos
        // móviles que prefieren dirigir y arrancan a la vez quedan en conflicto.
        let yoMaestro = mine.role == .master && mine.matchId != nil && mine.term > 0
        let elMaestro = theirs.role == .master && theirs.matchId != nil && theirs.term > 0

        // Dos maestros de partidos distintos: conflicto, a elegir a mano.
        if yoMaestro, elMaestro, mine.matchId != theirs.matchId {
            return .conflict
        }

        // Partidos distintos (o uno sin partido) con un solo maestro: el otro adopta el
        // partido y el term del maestro.
        if mine.matchId != theirs.matchId {
            if yoMaestro {
                return .resolved(role: .master, term: mine.term, matchId: mine.matchId, error: nil)
            }
            if elMaestro {
                return .resolved(role: .slave, term: theirs.term, matchId: theirs.matchId, error: nil)
            }
            // Nadie dirige: lo decide la preferencia, y el partido es el del que pasa a
            // dirigir (o el del otro, si aquel no traía ninguno). Los dos lados tienen
            // que elegir el mismo, así que no vale «el mío».
            return startByPreference(mine: mine, theirs: theirs, matchId: nil)
        }

        // El mismo partido: manda el term mayor.
        if mine.term != theirs.term {
            let mayor = max(mine.term, theirs.term)
            let quienMayor = mine.term > theirs.term ? mine : theirs
            if quienMayor.role == .master {
                let soyYo = quienMayor.side == mine.side
                return .resolved(role: soyYo ? .master : .slave, term: mayor, matchId: mine.matchId, error: nil)
            }
            // El del term mayor no es maestro: el otro tampoco puede seguir siéndolo
            // (traía un term viejo). Nadie dirige: preferencia con max + 1.
            return startByPreference(mine: mine, theirs: theirs, matchId: mine.matchId)
        }

        // El mismo partido y el mismo term.
        switch (mine.role, theirs.role) {
        case (.master, .master):
            // Solo pasa por mala configuración: manda el izquierdo, y se registra.
            return .resolved(
                role: mine.side == .left ? .master : .slave, term: mine.term, matchId: mine.matchId,
                error: "dos maestros con el term \(mine.term): manda el izquierdo"
            )
        case (.master, .slave):
            return .resolved(role: .master, term: mine.term, matchId: mine.matchId, error: nil)
        case (.slave, .master):
            return .resolved(role: .slave, term: mine.term, matchId: mine.matchId, error: nil)
        case (.slave, .slave):
            return startByPreference(mine: mine, theirs: theirs, matchId: mine.matchId)
        }
    }

    /// Sin maestro: el de la preferencia toma max + 1. Si los dos (o ninguno) la
    /// tienen, el izquierdo, que es la preferencia por defecto.
    /// `matchId` nil: el partido lo pone quien pasa a dirigir.
    private static func startByPreference(mine: RoleClaim, theirs: RoleClaim, matchId: String?) -> RoleOutcome {
        let term = max(mine.term, theirs.term) + 1
        let yoDirijo = mine.prefersMaster != theirs.prefersMaster ? mine.prefersMaster : mine.side == .left
        let (lider, otro) = yoDirijo ? (mine, theirs) : (theirs, mine)
        return .resolved(
            role: yoDirijo ? .master : .slave, term: term,
            matchId: matchId ?? lider.matchId ?? otro.matchId, error: nil
        )
    }
}
