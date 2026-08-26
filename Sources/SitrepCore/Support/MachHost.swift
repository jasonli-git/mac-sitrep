import Darwin

/// Mach host statistics — system-wide memory and per-CPU load.
///
/// These are the kernel's own counters, read directly. The alternative,
/// parsing `vm_stat` and `top` output, would cost a subprocess per sample and
/// perturb the measurement (ARCHITECTURE #1).
public enum MachHost {

    /// Page size in bytes. Constant for the life of the process.
    ///
    /// Read through `sysconf` rather than the `vm_kernel_page_size` global,
    /// which Swift 6 rejects as shared mutable state. This also gets the
    /// runtime value (16 KB on Apple Silicon) rather than a compile-time
    /// constant that may disagree with it.
    public static var pageSize: UInt64 {
        UInt64(sysconf(_SC_PAGESIZE))
    }

    /// System-wide virtual memory statistics.
    ///
    /// Counts are in pages; multiply by ``pageSize`` for bytes.
    public static func virtualMemory() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        return result == KERN_SUCCESS ? stats : nil
    }

    /// Cumulative CPU tick counts, one entry per logical CPU.
    ///
    /// Ticks are monotonic since boot. Utilization is the delta between two
    /// reads, which is Milestone 2's job — a single read says nothing about
    /// load, only that the counters are reachable.
    public static func processorTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }

        // host_processor_info allocates; the caller owns the deallocation.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Cumulative tick counts for one logical CPU.
    public struct CPUTicks: Equatable, Sendable {
        public let user: UInt32
        public let system: UInt32
        public let idle: UInt32
        public let nice: UInt32

        public var total: UInt64 {
            UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice)
        }
    }
}
