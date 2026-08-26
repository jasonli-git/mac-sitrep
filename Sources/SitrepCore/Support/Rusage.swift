import Darwin

/// Per-process resource usage via `proc_pid_rusage(2)`.
///
/// This is the single most valuable syscall in the project. One call yields
/// physical footprint, the kernel's own lifetime peak footprint, disk I/O, and
/// CPU time — see ARCHITECTURE #5 for why footprint rather than RSS.
///
/// Unprivileged for processes the current user owns. Other users' processes
/// return `nil`, which is a disclosed gap rather than an error (ARCHITECTURE #4).
public enum Rusage {

    /// Reads resource usage for a process, or `nil` if it is gone or not ours.
    public static func read(pid: pid_t) -> Snapshot? {
        var info = rusage_info_v4()

        // `rusage_info_t` is `UnsafeMutableRawPointer?`, so the rebind target
        // must be the *optional* form. Rebinding to the non-optional type does
        // not compile.
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }

        return Snapshot(
            physicalFootprint: info.ri_phys_footprint,
            lifetimePeakFootprint: info.ri_lifetime_max_phys_footprint,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten,
            userTimeNanoseconds: info.ri_user_time,
            systemTimeNanoseconds: info.ri_system_time
        )
    }

    /// Resource usage for the calling process.
    public static func current() -> Snapshot? {
        read(pid: getpid())
    }

    /// A point-in-time reading for one process.
    public struct Snapshot: Equatable, Sendable {

        /// Physical footprint in bytes — the figure Activity Monitor shows.
        public let physicalFootprint: UInt64

        /// Highest physical footprint reached during this process's lifetime,
        /// as the kernel recorded it.
        ///
        /// Reported raw, exactly as the kernel gave it. Note that this is
        /// refreshed at task-accounting boundaries rather than synchronously
        /// with ``physicalFootprint``, so during rapid growth it can read
        /// *lower* than the current footprint — observed on an M4 with a ~32 KB
        /// shortfall. Callers deriving a peak must take the max of this and
        /// their observed samples; ``SelfFootprint`` does. See ARCHITECTURE #17.
        public let lifetimePeakFootprint: UInt64

        public let diskBytesRead: UInt64
        public let diskBytesWritten: UInt64
        public let userTimeNanoseconds: UInt64
        public let systemTimeNanoseconds: UInt64

        /// Total CPU time consumed, in seconds.
        public var cpuSeconds: Double {
            Double(userTimeNanoseconds + systemTimeNanoseconds) / 1_000_000_000
        }
    }
}
