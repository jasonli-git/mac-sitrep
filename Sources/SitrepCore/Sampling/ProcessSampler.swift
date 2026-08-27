import Darwin
import Foundation

/// Reads per-process resource usage across every visible process.
public enum ProcessSampler {

    public enum Sort: String, Sendable, CaseIterable {
        case ram
        case cpu
    }

    /// One instantaneous read of every readable process, keyed by PID.
    ///
    /// Processes owned by other users are skipped — `proc_pid_rusage` needs root
    /// for those, and mac-sitrep does not use root (ARCHITECTURE #4). The count
    /// of skipped PIDs is returned so callers can disclose it rather than
    /// presenting a partial list as complete.
    public static func read() -> (readings: [pid_t: ProcessReading], unreadable: Int) {
        let now = Date()
        var readings: [pid_t: ProcessReading] = [:]
        var unreadable = 0

        for pid in ProcessList.pids() {
            guard let usage = Rusage.read(pid: pid) else {
                unreadable += 1
                continue
            }

            let path = ProcessList.path(pid: pid)
            readings[pid] = ProcessReading(
                pid: pid,
                parentPID: ProcessList.parentPID(pid: pid),
                // A process whose path is unreadable still has real resource
                // usage, so it is kept and labelled by PID rather than dropped.
                name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)",
                executablePath: path,
                physicalFootprint: usage.physicalFootprint,
                peakFootprint: max(usage.lifetimePeakFootprint, usage.physicalFootprint),
                diskBytesRead: usage.diskBytesRead,
                diskBytesWritten: usage.diskBytesWritten,
                cpuNanoseconds: usage.userTimeNanoseconds + usage.systemTimeNanoseconds,
                timestamp: now
            )
        }

        return (readings, unreadable)
    }

    /// Reads only the named processes.
    ///
    /// The full ``read()`` costs roughly four syscalls per process across ~800
    /// processes. During a profiling run only the workload's own group matters
    /// at high frequency, and re-scanning everything twenty times a second cost
    /// ~13% CPU — enough for the profiler to perturb the CPU-bound workload it
    /// is trying to measure.
    public static func read(pids: some Sequence<pid_t>) -> [pid_t: ProcessReading] {
        let now = Date()
        var readings: [pid_t: ProcessReading] = [:]

        for pid in pids {
            guard let usage = Rusage.read(pid: pid) else { continue }
            let path = ProcessList.path(pid: pid)

            readings[pid] = ProcessReading(
                pid: pid,
                parentPID: ProcessList.parentPID(pid: pid),
                name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)",
                executablePath: path,
                physicalFootprint: usage.physicalFootprint,
                peakFootprint: max(usage.lifetimePeakFootprint, usage.physicalFootprint),
                diskBytesRead: usage.diskBytesRead,
                diskBytesWritten: usage.diskBytesWritten,
                cpuNanoseconds: usage.userTimeNanoseconds + usage.systemTimeNanoseconds,
                timestamp: now
            )
        }

        return readings
    }

    /// Takes two reads `interval` apart and derives per-process CPU.
    ///
    /// Processes that appear mid-interval are reported with zero CPU rather than
    /// dropped — they exist and hold memory, which is worth showing. Processes
    /// that exit mid-interval disappear, since there is nothing left to report.
    public static func snapshot(
        interval: TimeInterval = SystemSampler.defaultInterval,
        sort: Sort = .ram,
        limit: Int? = nil
    ) -> ProcessSnapshot {
        let (before, _) = read()
        Thread.sleep(forTimeInterval: interval)
        let (after, unreadable) = read()

        var samples: [ProcessSample] = []
        samples.reserveCapacity(after.count)

        for (pid, current) in after {
            let elapsed = current.timestamp.timeIntervalSince(
                before[pid]?.timestamp ?? current.timestamp
            )

            var utilization = 0.0
            if let previous = before[pid],
               elapsed > 0,
               current.cpuNanoseconds >= previous.cpuNanoseconds {
                let consumed = Double(current.cpuNanoseconds - previous.cpuNanoseconds)
                utilization = consumed / 1_000_000_000 / elapsed
            }

            samples.append(
                ProcessSample(
                    pid: current.pid,
                    parentPID: current.parentPID,
                    name: current.name,
                    executablePath: current.executablePath,
                    physicalFootprint: current.physicalFootprint,
                    peakFootprint: current.peakFootprint,
                    diskBytesRead: current.diskBytesRead,
                    diskBytesWritten: current.diskBytesWritten,
                    cpuUtilization: utilization
                )
            )
        }

        // PID is the tiebreaker so equal-valued rows keep a stable order between
        // invocations rather than shuffling on every run.
        switch sort {
        case .ram:
            samples.sort {
                $0.physicalFootprint == $1.physicalFootprint
                    ? $0.pid < $1.pid
                    : $0.physicalFootprint > $1.physicalFootprint
            }
        case .cpu:
            samples.sort {
                $0.cpuUtilization == $1.cpuUtilization
                    ? $0.pid < $1.pid
                    : $0.cpuUtilization > $1.cpuUtilization
            }
        }

        return ProcessSnapshot(
            timestamp: Date(),
            intervalSeconds: interval,
            processes: limit.map { Array(samples.prefix($0)) } ?? samples,
            unreadableProcessCount: unreadable
        )
    }
}
