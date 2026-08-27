import Darwin
import Foundation

/// Launches a workload in its own process group.
///
/// `Foundation.Process` cannot set the child's process group, and that matters
/// more than it looks: attribution follows the process *group*, not the parent
/// chain. When an intermediate parent exits — a shell wrapper, a build script
/// that backgrounds work — its children are re-parented to launchd and any ppid
/// walk back to our root fails. The process group id survives re-parenting, so
/// descendants stay attributable for the whole run.
///
/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP` sets the group atomically at
/// spawn. Calling `setpgid` on the child afterwards races against its `exec`.
public enum Spawn {

    public struct Failure: Error, CustomStringConvertible {
        public let code: Int32
        public let executable: String

        public var description: String {
            "could not launch \(executable): \(String(cString: strerror(code)))"
        }
    }

    public struct Child: Sendable {
        public let pid: pid_t
        /// Equal to `pid`: the child is the leader of its new group.
        public let processGroupID: pid_t
    }

    /// Spawns `arguments` in a new process group, inheriting stdio.
    ///
    /// Stdio is inherited deliberately — the workload's output belongs on the
    /// user's terminal. Capturing it would add buffering and a drain thread to
    /// the measurement path for no benefit to the numbers.
    public static func launch(
        _ arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) throws -> Child {
        guard let executable = arguments.first else {
            throw Failure(code: EINVAL, executable: "<empty>")
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // pgroup 0 means "new group whose id is the child's pid".
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        // The environment is always materialized rather than passing `environ`
        // for the inherit case: `&envp` cannot appear in a ternary, and having
        // one code path is worth the few allocations.
        let variables = environment ?? ProcessInfo.processInfo.environment
        var envp = variables.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        // posix_spawnp resolves a bare name against PATH, so callers can say
        // "python" rather than an absolute path.
        let result = posix_spawnp(
            &pid, executable, &fileActions, &attributes, argv, envp
        )

        guard result == 0 else {
            throw Failure(code: result, executable: executable)
        }
        return Child(pid: pid, processGroupID: pid)
    }

    /// Blocks until `pid` exits, returning what it cost.
    public static func wait(pid: pid_t) -> Completion {
        var status: Int32 = 0
        var usage = rusage()

        while wait4(pid, &status, 0, &usage) == -1 {
            if errno != EINTR { return Completion(exitCode: -1, cpuSeconds: 0) }
        }
        return Completion(exitCode: exitCode(from: status), cpuSeconds: seconds(of: usage))
    }

    /// What a finished child cost, straight from the kernel.
    public struct Completion: Sendable {
        public let exitCode: Int32
        /// Exact CPU time the child and its reaped descendants consumed.
        ///
        /// Not sampled, so it carries no window-averaging error. A sampled
        /// "peak CPU" is a property of the sampling rate as much as of the
        /// workload — a 15 ms burst read through a 50 ms window reports about a
        /// third of its true intensity. This number has no such caveat.
        public let cpuSeconds: Double
    }

    /// Checks whether `pid` has exited without blocking, reaping it if so.
    ///
    /// Returns `nil` while the child is still running, or its completion once
    /// it has finished.
    ///
    /// A sampling loop **must** poll with this rather than testing liveness with
    /// `kill(pid, 0)`. An exited child remains a zombie until its parent reaps
    /// it, and a zombie still answers `kill(pid, 0)` successfully — so a
    /// liveness check never goes false and the loop spins forever. That is not
    /// hypothetical: it hung the first profiling run.
    public static func poll(pid: pid_t) -> Completion? {
        var status: Int32 = 0
        var usage = rusage()

        while true {
            // wait4 rather than waitpid: it fills in the child's rusage, which
            // is the only exact source of CPU time. Sampling can only ever
            // approximate it.
            let result = wait4(pid, &status, WNOHANG, &usage)
            if result == 0 { return nil }           // still running
            if result == pid {
                return Completion(
                    exitCode: exitCode(from: status), cpuSeconds: seconds(of: usage)
                )
            }
            if errno == EINTR { continue }          // interrupted; retry
            return Completion(exitCode: -1, cpuSeconds: 0)  // gone, or never ours
        }
    }

    static func seconds(of usage: rusage) -> Double {
        func total(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return total(usage.ru_utime) + total(usage.ru_stime)
    }

    /// Terminates a whole process group, escalating if it does not stop.
    ///
    /// Signals the *group*, not the pid, which is the point of spawning into
    /// one: a workload that forked children would otherwise leave them running
    /// after the leader dies. `SIGTERM` first so a workload can clean up,
    /// `SIGKILL` only if it does not.
    public static func terminateGroup(_ processGroupID: pid_t, graceSeconds: TimeInterval = 5) {
        kill(-processGroupID, SIGTERM)

        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if poll(pid: processGroupID) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(-processGroupID, SIGKILL)
        _ = poll(pid: processGroupID)
    }

    /// Decodes a `waitpid` status.
    ///
    /// A signalled process reports `128 + signal`, the shell convention, so a
    /// workload killed by `SIGKILL` is distinguishable from one exiting 9.
    private static func exitCode(from status: Int32) -> Int32 {
        status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
    }
}
