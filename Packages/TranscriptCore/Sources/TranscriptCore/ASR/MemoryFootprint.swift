import Darwin
import Foundation

/// Physical footprint of this process, the number jetsam actually judges.
public enum MemoryFootprint {
    /// Current footprint in bytes, or nil if the kernel refuses the query.
    public static func current() -> Int64? {
        guard let bytes = info().map({ Int64($0.phys_footprint) }), bytes > 0 else { return nil }
        return bytes
    }

    /// High-water mark since launch, read from the task ledger so no sampling
    /// thread is needed.
    public static func peak() -> Int64? {
        guard let bytes = info().map({ Int64($0.ledger_phys_footprint_peak) }), bytes > 0 else { return nil }
        return bytes
    }

    /// Memory this process may still allocate before jetsam. iOS-only; returns nil
    /// on macOS, and on the Simulator it reports the *host* budget (see repo notes).
    public static func availableToProcess() -> Int64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? Int64(available) : nil
        #else
        return nil
        #endif
    }

    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
