import Darwin
import Foundation

/// One instantaneous read of a single process.
///
/// `cpuNanoseconds` is cumulative over the process's life, so per-process CPU
/// utilization needs two readings — the same constraint as system-wide CPU.
public struct ProcessReading: Sendable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t?
    public let name: String
    public let executablePath: String?
    public let physicalFootprint: UInt64
    public let peakFootprint: UInt64
    public let diskBytesRead: UInt64
    public let diskBytesWritten: UInt64
    public let cpuNanoseconds: UInt64
    public let timestamp: Date
}

/// A process over an interval, with derived CPU utilization.
public struct ProcessSample: Sendable, Encodable, Equatable {
    public let pid: pid_t
    public let parentPID: pid_t?
    public let name: String
    public let executablePath: String?

    /// Physical footprint in bytes — Activity Monitor's "Memory", not RSS
    /// (ARCHITECTURE #5).
    public let physicalFootprint: UInt64

    /// Highest footprint over the process's lifetime.
    ///
    /// Derived as `max(kernel high-water mark, live footprint)` because the
    /// kernel's mark is refreshed at accounting boundaries and can briefly read
    /// below the live value (ARCHITECTURE #17).
    public let peakFootprint: UInt64

    public let diskBytesRead: UInt64
    public let diskBytesWritten: UInt64

    /// Busy fraction over the interval, where 1.0 is one core saturated.
    ///
    /// Unlike system-wide utilization this is **not** capped at 1: a process
    /// using four cores fully reports 4.0. That matches what `top` shows as
    /// 400% and is the more useful figure for spotting a parallel workload.
    public let cpuUtilization: Double
}

/// The result of sampling every visible process.
public struct ProcessSnapshot: Sendable, Encodable {
    public let timestamp: Date
    public let intervalSeconds: Double
    public let processes: [ProcessSample]

    /// How many PIDs were visible but could not be read.
    ///
    /// Enumerating processes is unprivileged; reading their resource usage is
    /// not, so processes owned by other users — mostly system daemons — return
    /// nothing. This count is reported rather than quietly dropped: a top-N list
    /// that silently omits root-owned processes would misattribute the machine's
    /// memory. Same discipline as `doctor`'s unavailable list (SPEC principle 11).
    public let unreadableProcessCount: Int

    /// Total footprint across processes that could be read.
    public var readableFootprint: UInt64 {
        processes.reduce(0) { $0 + $1.physicalFootprint }
    }
}
