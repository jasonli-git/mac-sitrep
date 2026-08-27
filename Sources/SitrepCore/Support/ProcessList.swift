import Darwin
import Foundation

/// Process enumeration and identity via `libproc`.
///
/// Minimal by design at this milestone: enough to establish that the APIs are
/// reachable and to name a process. Structured per-process sampling is
/// Milestone 2's job.
public enum ProcessList {

    /// `PROC_PIDPATHINFO_MAXSIZE` from `<libproc.h>` — a C macro, so Swift does
    /// not import it. Defined there as `4 * MAXPATHLEN`.
    private static let pathBufferSize = 4 * 1024

    /// Every PID currently visible, including processes owned by other users.
    ///
    /// Listing them is unprivileged; reading their `rusage` is not. That
    /// asymmetry is why ``Rusage/read(pid:)`` returns `nil` for other users'
    /// processes and why it is reported as a disclosed gap.
    public static func pids() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)

        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount)
        guard written > 0 else { return [] }

        // The kernel may return fewer than it first reported, and pads with
        // zeroes; trim rather than trusting the original count.
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Executable path for a process, or `nil` if it has exited or is opaque.
    public static func path(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(pathBufferSize))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Process group id.
    ///
    /// Attribution matches on this rather than the parent chain: when an
    /// intermediate parent exits its children are re-parented to launchd, which
    /// severs any ppid walk back to the workload root. The group id survives
    /// that (ARCHITECTURE #26).
    public static func processGroupID(pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return pid_t(info.pbi_pgid)
    }

    /// Parent PID, for reconstructing the process tree.
    public static func parentPID(pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Short process name, e.g. `ollama`.
    public static func name(pid: pid_t) -> String? {
        path(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
