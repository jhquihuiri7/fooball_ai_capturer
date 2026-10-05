// La elección de roles con terms (IOS-83, ADR 0023 §8), lógica pura.
//
// El esclavo se promueve cuando se cumplen las tres condiciones: el enlace lleva caído
// ≥PROMOTE_AFTER_MS, su túnel tiene `welcome` y el hub dice `master_status: lost` desde
// hace ≥MASTER_LOST_PROMOTE_MS. Sin VPS no hay promoción automática: un esclavo aislado
// no sabe si cayó el maestro o es él quien está solo; la fuerza el operador («Este móvil
// dirige»). Promoverse es tomar term + 1. Quien vea un term mayor (en el enlace o en un
// 4409 del hub) lo guarda y pasa a esclavo.
//
// El maestro, con el enlace caído más de LINK_FENCE_MS en un partido que tuvo esclavo,
// solo publica tras un `welcome` recibido en un túnel abierto DESPUÉS de la caída: así,
// un maestro aislado que vuelve pregunta antes al hub y se entera del term nuevo.

import Foundation

public final class RoleElection {
    public private(set) var role: RigRole
    public private(set) var term: Int

    public init(role: RigRole, term: Int) {
        self.role = role
        self.term = term
    }

    /// Lo que sabe este móvil en un instante.
    public struct Situation: Equatable, Sendable {
        public var nowMs: Int64
        /// Desde cuándo está caído el enlace con el otro, o nil si está arriba.
        public var linkDownSinceMs: Int64?
        /// Su túnel al VPS tiene `welcome`.
        public var tunnelWelcome: Bool
        /// Desde cuándo el hub dice `master_status: lost`, o nil.
        public var masterLostSinceMs: Int64?
        /// El operador pulsó «Este móvil dirige» y lo confirmó.
        public var operatorForce: Bool

        public init(nowMs: Int64, linkDownSinceMs: Int64?, tunnelWelcome: Bool, masterLostSinceMs: Int64?,
                    operatorForce: Bool = false) {
            self.nowMs = nowMs; self.linkDownSinceMs = linkDownSinceMs; self.tunnelWelcome = tunnelWelcome
            self.masterLostSinceMs = masterLostSinceMs; self.operatorForce = operatorForce
        }
    }

    /// Un term del otro (en su latido o en un 4409): si es mayor, se adopta y se degrada.
    /// Devuelve si cambió algo.
    @discardableResult
    public func observe(peerTerm: Int, peerIsMaster: Bool) -> Bool {
        if peerTerm > term {
            term = peerTerm
            // Un term mayor del otro: si él dirige con ese term, este no puede dirigir.
            if peerIsMaster { role = .slave }
            return true
        }
        return false
    }

    /// El hub echó a este maestro con 4409 por un term mayor (ADR 0022 §8).
    public func evicted(byTerm t: Int) {
        if t > term { term = t }
        role = .slave
    }

    /// Si el esclavo debe promoverse ahora; si sí, toma term + 1 (lo que hay que guardar
    /// en disco ANTES de anunciarlo, ADR 0023 §7).
    @discardableResult
    public func evaluate(_ s: Situation) -> Bool {
        guard role == .slave else { return false }
        let automatica: Bool = {
            guard let caido = s.linkDownSinceMs, s.nowMs - caido >= LinkConstants.promoteAfterMs,
                  s.tunnelWelcome, let perdido = s.masterLostSinceMs,
                  s.nowMs - perdido >= LinkConstants.masterLostPromoteMs
            else { return false }
            return true
        }()
        guard automatica || s.operatorForce else { return false }
        term += 1
        role = .master
        return true
    }

    /// Si el maestro puede abrir o reabrir el SRT (el cercado del ADR 0023 §8).
    /// `welcomeAtMs`: cuándo llegó el último `welcome` del túnel, o nil.
    public func mayPublish(nowMs: Int64, linkDownSinceMs: Int64?, hadSlave: Bool, welcomeAtMs: Int64?) -> Bool {
        guard role == .master else { return false }
        guard hadSlave, let caido = linkDownSinceMs, nowMs - caido > LinkConstants.linkFenceMs else { return true }
        guard let w = welcomeAtMs else { return false }
        return w > caido
    }
}
