// El monitor térmico y de presión (IOS-06): los sensores de la escalera.
//
// Escucha `thermalStateDidChangeNotification` y hace KVO de
// `AVCaptureDevice.systemPressureState` (solo iOS: en el Mac no existe). No decide
// nada: convierte lo que dice el sistema a los niveles puros de RigCore y avisa.

import AVFoundation
import Foundation
import os
import RigCore

public final class ThermalMonitor {
    private let log = Logger(subsystem: Signposts.subsystem, category: "thermal")
    private var thermalObserver: NSObjectProtocol?
    private var pressureObservation: NSKeyValueObservation?

    public private(set) var thermal: ThermalLevel
    public private(set) var pressure: PressureLevel = .nominal

    /// Se llama con cada cambio, con los dos niveles vigentes.
    public var onUpdate: ((ThermalLevel, PressureLevel) -> Void)?

    public init() {
        thermal = Self.level(from: ProcessInfo.processInfo.thermalState)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.thermal = Self.level(from: ProcessInfo.processInfo.thermalState)
            self.log.info("térmica: \(self.thermal.rawValue)")
            self.onUpdate?(self.thermal, self.pressure)
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        pressureObservation?.invalidate()
    }

    /// Engancha la presión del dispositivo de captura. Se llama al abrir la cámara y
    /// otra vez si la sesión se reconstruye.
    public func observe(device: AVCaptureDevice) {
        #if os(iOS)
        pressureObservation?.invalidate()
        pressure = Self.level(from: device.systemPressureState)
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) {
            [weak self] device, _ in
            guard let self else { return }
            let nivel = Self.level(from: device.systemPressureState)
            DispatchQueue.main.async {
                self.pressure = nivel
                self.log.info("presión: \(nivel.rawValue)")
                self.onUpdate?(self.thermal, nivel)
            }
        }
        #endif
    }

    public static func level(from state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    #if os(iOS)
    public static func level(from state: AVCaptureDevice.SystemPressureState) -> PressureLevel {
        switch state.level {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        case .shutdown: return .shutdown
        default: return .critical
        }
    }
    #endif
}
