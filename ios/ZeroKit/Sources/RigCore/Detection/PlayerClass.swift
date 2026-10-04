// Las clases del detector de personas (réplica de PlayerClass en libs/core/enums.py).
// Los valores en crudo son los nombres de clase del dataset: cambiarlos rompería los
// modelos entrenados y los dorados.

import Foundation

public enum PlayerClass: String, CaseIterable, Sendable {
    case player
    case goalkeeper
    case referee
}
