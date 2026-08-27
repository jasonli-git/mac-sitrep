import Darwin
import Foundation

/// Decides which processes count as "the workload".
///
/// Two populations, measured differently, because they are different problems:
///
/// - **The spawned group** — everything in the process group `sitrep run`
///   created. Matched on pgid rather than the parent chain, since a parent
///   exiting re-parents its children to launchd and severs any ppid walk
///   (ARCHITECTURE #26).
/// - **Declared external services** — daemons that were already running and hold
///   resources on the workload's behalf. Ollama and LM Studio are the motivating
///   cases: the model's memory lives there, not in the wrapped client, which
///   often shows near-zero RAM (ARCHITECTURE #10).
public struct Attribution: Sendable {

    private let processGroupID: pid_t
    private let services: [ProjectConfig.ExternalService]

    /// Footprint each service held before the run, so only the increase is
    /// attributed. Without this, a run against an Ollama instance that already
    /// had a model loaded would claim the whole 9 GB as its own.
    private let serviceBaseline: [String: UInt64]

    public init(
        processGroupID: pid_t,
        services: [ProjectConfig.ExternalService],
        baseline: [String: UInt64] = [:]
    ) {
        self.processGroupID = processGroupID
        self.services = services
        self.serviceBaseline = baseline
    }

    /// Watches declared services for `duration` and returns the highest
    /// footprint each held.
    ///
    /// Runs before the workload starts, so it cannot know the process group id —
    /// which is why the baseline is produced as plain data and handed to the
    /// `Attribution` that follows, rather than the two sharing an instance.
    ///
    /// Takes the maximum across the window rather than a single read: a service
    /// caught mid-collection would give an artificially low baseline and inflate
    /// everything attributed afterwards.
    public static func measureBaseline(
        services: [ProjectConfig.ExternalService],
        duration: TimeInterval,
        interval: TimeInterval
    ) -> [String: UInt64] {
        guard !services.isEmpty else { return [:] }

        var baseline: [String: UInt64] = [:]
        let probe = Attribution(processGroupID: 0, services: services)
        let deadline = Date().addingTimeInterval(duration)

        repeat {
            let snapshot = ProcessSampler.read().readings
            for service in services {
                let footprint = probe.footprint(of: service, in: snapshot)
                baseline[service.name] = max(baseline[service.name] ?? 0, footprint)
            }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline

        return baseline
    }

    /// One observation of the attributed populations.
    public struct Observation: Sendable {
        public let ownFootprint: UInt64
        /// Kernel-tracked peak across the spawned group.
        public let ownKernelPeak: UInt64
        public let ownCPU: Double
        public let ownDiskRead: UInt64
        public let ownDiskWritten: UInt64

        /// Current footprint per service, before baseline subtraction.
        public let serviceFootprints: [String: UInt64]

        /// CPU used by everything that is not this workload.
        public let contendingCPU: Double
    }

    public func baseline(for service: String) -> UInt64 { serviceBaseline[service] ?? 0 }

    /// Attributes one snapshot of every readable process.
    public func observe(
        _ snapshot: [pid_t: ProcessReading],
        previous: [pid_t: ProcessReading],
        elapsed: TimeInterval
    ) -> Observation {
        var ownFootprint: UInt64 = 0
        var ownKernelPeak: UInt64 = 0
        var ownCPU = 0.0
        var ownDiskRead: UInt64 = 0
        var ownDiskWritten: UInt64 = 0
        var contendingCPU = 0.0

        let ownPIDs = Set(
            snapshot.keys.filter { ProcessList.processGroupID(pid: $0) == processGroupID }
        )
        let servicePIDs = Set(
            services.flatMap { service in
                snapshot.values
                    .filter { matches($0, service) }
                    .map(\.pid)
            }
        )

        for (pid, reading) in snapshot {
            let cpu = utilization(of: reading, previous: previous[pid], elapsed: elapsed)

            if ownPIDs.contains(pid) {
                ownFootprint += reading.physicalFootprint
                // The kernel high-water mark is valid here: every process in the
                // group was started by this run, so its lifetime *is* the run.
                ownKernelPeak += reading.peakFootprint
                ownCPU += cpu
                ownDiskRead += reading.diskBytesRead
                ownDiskWritten += reading.diskBytesWritten
            } else if !servicePIDs.contains(pid) && pid != getpid() {
                // Everything that is neither the workload nor a declared service
                // nor the profiler itself is contention.
                contendingCPU += cpu
            }
        }

        var serviceFootprints: [String: UInt64] = [:]
        for service in services {
            serviceFootprints[service.name] = footprint(of: service, in: snapshot)
        }

        return Observation(
            ownFootprint: ownFootprint,
            ownKernelPeak: ownKernelPeak,
            ownCPU: ownCPU,
            ownDiskRead: ownDiskRead,
            ownDiskWritten: ownDiskWritten,
            serviceFootprints: serviceFootprints,
            contendingCPU: contendingCPU
        )
    }

    /// Total attributable to external services: the increase over baseline.
    ///
    /// Clamped at zero. A service that shrank during the run did not contribute
    /// negative memory, and a negative figure would silently reduce the reported
    /// peak.
    ///
    /// Note this uses *observed* footprints only. The kernel's lifetime peak is
    /// unusable for a pre-existing daemon — it includes history from before we
    /// attached, which would attribute an earlier, unrelated peak to this run.
    public func externalDelta(observedPeaks: [String: UInt64]) -> UInt64 {
        services.reduce(into: UInt64(0)) { total, service in
            let peak = observedPeaks[service.name] ?? 0
            let base = serviceBaseline[service.name] ?? 0
            total += peak > base ? peak - base : 0
        }
    }

    private func footprint(
        of service: ProjectConfig.ExternalService, in snapshot: [pid_t: ProcessReading]
    ) -> UInt64 {
        snapshot.values
            .filter { matches($0, service) }
            .reduce(0) { $0 + $1.physicalFootprint }
    }

    private func matches(
        _ reading: ProcessReading, _ service: ProjectConfig.ExternalService
    ) -> Bool {
        // Matched on the executable path when there is one, falling back to the
        // process name for processes whose path is unreadable.
        if let path = reading.executablePath {
            return path.localizedCaseInsensitiveContains(service.executableContains)
        }
        return reading.name.localizedCaseInsensitiveContains(service.executableContains)
    }

    private func utilization(
        of current: ProcessReading, previous: ProcessReading?, elapsed: TimeInterval
    ) -> Double {
        guard let previous, elapsed > 0, current.cpuNanoseconds >= previous.cpuNanoseconds
        else { return 0 }

        return Double(current.cpuNanoseconds - previous.cpuNanoseconds) / 1_000_000_000 / elapsed
    }
}
