// La capa de red de ZeroKit (IOS-02).
//
// Hoy está vacía a propósito: existe para que el contrato de capas (RigCore ← RigNet)
// quede fijado desde el primer día. Lo que llegará aquí: el enlace UDP entre móviles
// con fragmentación propia (IOS-52, ADR 0023) y libsrt en su xcframework (IOS-55).

import Foundation
import RigCore

/// Marcador del módulo. Se borra cuando entre el primer tipo de verdad.
public enum RigNet {}
