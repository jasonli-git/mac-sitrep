import Darwin

/// Swap usage from the struct-valued `vm.swapusage` sysctl.
///
/// ``Sysctl/integer(_:as:)`` deliberately declines this key — it is an
/// `xsw_usage` struct, not a scalar, and returning its first eight bytes as an
/// integer would be garbage. Struct-valued keys get purpose-built readers.
///
/// Note that the reported figures describe the swap *file*, which macOS grows
/// and does not cleanly shrink. The zero-swap policy is defined on swap *rate*
/// instead — see ARCHITECTURE #6.
public enum SwapUsage {

    public static func read() -> Snapshot? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }

        return Snapshot(
            total: usage.xsu_total,
            used: usage.xsu_used,
            available: usage.xsu_avail,
            encrypted: usage.xsu_encrypted != 0
        )
    }

    public struct Snapshot: Equatable, Sendable {
        /// Total swap file size in bytes.
        public let total: UInt64
        /// Bytes currently in use.
        public let used: UInt64
        /// Bytes available within the allocated swap file.
        public let available: UInt64
        public let encrypted: Bool
    }
}

/// Memory pressure as the kernel reports it.
///
/// This is the same signal jetsam acts on, which is why it is a better health
/// input than any derived ratio of free pages.
public enum MemoryPressure {

    public enum Level: Int, Sendable, Equatable {
        case normal = 1
        case warning = 2
        case critical = 4

        public var label: String {
            switch self {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
        }
    }

    public static func level() -> Level? {
        guard let raw: Int = Sysctl.integer("kern.memorystatus_vm_pressure_level") else {
            return nil
        }
        return Level(rawValue: raw)
    }

    /// Cumulative compressor swap counters, monotonic since boot.
    ///
    /// The rate of change in these, not their absolute value, is what the
    /// zero-swap policy is defined on (ARCHITECTURE #6).
    ///
    /// Both the total and the pressure-driven subset are read, because they
    /// answer different questions. `swapOutsTotal` rising means the machine is
    /// swapping at all; `swapOutsUnderPressure` rising means it is swapping
    /// *because it is short of memory*, which is the health signal. A machine
    /// swapping for other reasons — freezer, scavenger, dark wake — is not
    /// necessarily in trouble.
    public static func swapCounters() -> SwapCounters? {
        guard
            let outsTotal: UInt64 = Sysctl.integer("vm.compressor.swapper.swapouts_total"),
            let insTotal: UInt64 = Sysctl.integer("vm.compressor.swapper.swapins_total"),
            let outsPressure: UInt64 = Sysctl.integer("vm.compressor.swapper.swapouts_pressure")
        else { return nil }

        return SwapCounters(
            swapOutsTotal: outsTotal,
            swapInsTotal: insTotal,
            swapOutsUnderPressure: outsPressure
        )
    }

    public struct SwapCounters: Equatable, Sendable {
        public let swapOutsTotal: UInt64
        public let swapInsTotal: UInt64
        public let swapOutsUnderPressure: UInt64
    }
}
