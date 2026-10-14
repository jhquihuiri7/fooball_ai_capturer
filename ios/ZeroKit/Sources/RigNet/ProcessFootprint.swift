// La huella del proceso (`phys_footprint`, lo que mira jetsam), para la línea de tiempo
// del enlace (2026-10-14): cada suceso del transporte lleva la memoria de ese momento,
// así una caída y su vuelta dicen si dejaron algo retenido.

import Darwin
import Foundation

public enum ProcessFootprint {
    /// `phys_footprint` en MB, o nil si el sistema no lo da.
    public static func megabytes() -> Double? {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / bytesPerMb : nil
    }

    static let bytesPerMb = 1_048_576.0
}
