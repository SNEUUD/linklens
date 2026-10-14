import Darwin

/// Memory used by this process, as shown by Activity Monitor ("physical footprint").
enum Memory {
    struct Footprint {
        var current: UInt64
        var peak: UInt64
    }

    static func footprint() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Footprint(current: 0, peak: 0) }
        return Footprint(current: info.phys_footprint, peak: UInt64(info.ledger_phys_footprint_peak))
    }

    static func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }
}
