import Darwin
import Foundation

/// The sampling loop, as a state machine.
///
/// Deliberately free of process management, signal handling, and sleeping so it
/// can be driven synchronously from tests: `tick(at:)` does exactly one cycle
/// and returns what it recorded. `sitrepd` supplies the clock and the loop.
///
/// The key property is that this **never sleeps to obtain a rate**. It holds the
/// previous `SystemReading` and deltas against it on each tick — which is the
/// whole reason `SystemReading` and `Sample` are separate types (ARCHITECTURE
/// "Sampling"). The CLI's 500 ms blocking sample is the compromise; this is not.
public final class Collector {

    /// How often to sample, as a function of how the machine is doing.
    public struct Cadence: Sendable {
        /// Interval while healthy.
        public let resting: TimeInterval
        /// Interval while degraded — high resolution exactly during an incident.
        public let alert: TimeInterval

        public static let `default` = Cadence(resting: 10, alert: 1)

        public func interval(for health: HealthState) -> TimeInterval {
            health == .healthy ? resting : alert
        }
    }

    /// Top consumers stored per tick. Storing every readable process would be
    /// roughly 4.3 M rows a day (ARCHITECTURE #22).
    public static let processesPerTick = 15

    /// How often process detail is captured, relative to system samples.
    ///
    /// Enumerating ~800 processes costs far more than reading a handful of
    /// sysctls, so it runs on a slower schedule than the system sample. At the
    /// resting cadence this is every third tick, roughly every 30 seconds.
    public static let processSampleEveryNTicks = 3

    public private(set) var tracker: HealthTracker
    public private(set) var tickCount = 0

    private let store: SampleStore
    private let cadence: Cadence
    private var previousReading: SystemReading?
    private var previousProcessReadings: [pid_t: ProcessReading] = [:]

    /// Previous self-measurement, for deriving the daemon's own sustained CPU.
    private var previousSelfCPUSeconds: Double?
    private var previousSelfTimestamp: Date?

    public init(
        store: SampleStore,
        cadence: Cadence = .default,
        tracker: HealthTracker = HealthTracker()
    ) {
        self.store = store
        self.cadence = cadence
        self.tracker = tracker
    }

    /// What one tick produced.
    public struct TickResult: Sendable {
        public let sample: Sample?
        public let health: HealthState
        public let healthChanged: Bool
        /// How long the caller should wait before the next tick.
        public let nextInterval: TimeInterval
    }

    /// Performs one cycle: read, derive, classify, persist.
    ///
    /// The first tick has no previous reading and so produces no sample — it
    /// only primes the delta. That is why the daemon's first row appears one
    /// interval after start, not immediately.
    @discardableResult
    public func tick(at now: Date = Date()) throws -> TickResult {
        tickCount += 1
        let reading = SystemSampler.read()

        guard let previous = previousReading else {
            previousReading = reading
            return TickResult(
                sample: nil, health: tracker.current, healthChanged: false,
                nextInterval: cadence.interval(for: tracker.current)
            )
        }

        guard let sample = Sample(from: previous, to: reading) else {
            // Readings not separated in time; keep the older one so the next
            // tick still has a usable baseline rather than losing the interval.
            return TickResult(
                sample: nil, health: tracker.current, healthChanged: false,
                nextInterval: cadence.interval(for: tracker.current)
            )
        }
        previousReading = reading

        let changed = tracker.observe(sample: sample, at: now) != nil
        try store.insert(sample, resolution: .raw, health: tracker.current)

        if changed {
            try store.record(
                .healthChange,
                detail: "\(tracker.current.rawValue): \(tracker.reasons.joined(separator: ", "))",
                at: now
            )
        }

        if tickCount % Self.processSampleEveryNTicks == 0 {
            try captureProcesses(at: now)
        }

        try recordSelf(at: now)

        return TickResult(
            sample: sample,
            health: tracker.current,
            healthChanged: changed,
            nextInterval: cadence.interval(for: tracker.current)
        )
    }

    /// Stores the top consumers, deriving CPU from the previous process read.
    private func captureProcesses(at now: Date) throws {
        let (readings, _) = ProcessSampler.read()

        var samples: [ProcessSample] = []
        samples.reserveCapacity(readings.count)

        for (pid, current) in readings {
            var utilization = 0.0
            if let previous = previousProcessReadings[pid],
               current.cpuNanoseconds >= previous.cpuNanoseconds {
                let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
                if elapsed > 0 {
                    utilization = Double(current.cpuNanoseconds - previous.cpuNanoseconds)
                        / 1_000_000_000 / elapsed
                }
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
        previousProcessReadings = readings

        // Union of the memory and CPU leaders, so a process that is CPU-heavy
        // but memory-light still lands in history. Ranking on memory alone
        // would make a busy compile invisible.
        let byMemory = samples.sorted { $0.physicalFootprint > $1.physicalFootprint }
            .prefix(Self.processesPerTick)
        let byCPU = samples.sorted { $0.cpuUtilization > $1.cpuUtilization }
            .prefix(Self.processesPerTick / 3)

        var seen = Set<pid_t>()
        let selected = (byMemory + byCPU).filter { seen.insert($0.pid).inserted }

        try store.insertProcesses(selected, at: now)
    }

    /// Records mac-sitrep's own consumption, including sustained CPU.
    ///
    /// This is the figure a one-shot CLI structurally cannot produce: CPU as a
    /// fraction needs an interval, and a process that lives for 40 ms has no
    /// meaningful one. Here there is a previous measurement to divide against.
    private func recordSelf(at now: Date) throws {
        guard let usage = Rusage.current() else { return }

        var utilization = 0.0
        if let previousCPU = previousSelfCPUSeconds, let previousAt = previousSelfTimestamp {
            let elapsed = now.timeIntervalSince(previousAt)
            if elapsed > 0, usage.cpuSeconds >= previousCPU {
                utilization = (usage.cpuSeconds - previousCPU) / elapsed
            }
        }
        previousSelfCPUSeconds = usage.cpuSeconds
        previousSelfTimestamp = now

        let peak = max(usage.lifetimePeakFootprint, usage.physicalFootprint)
        try store.insertDaemonSample(
            footprint: usage.physicalFootprint,
            peak: peak,
            cpuUtilization: utilization,
            at: now
        )

        // Exceeding its own budget is an incident like any other. Recording it
        // rather than ignoring it is what makes principle 6 more than a slogan.
        if peak > SelfBudget.memoryBytes || utilization > SelfBudget.cpuFraction {
            try store.record(
                .budgetExceeded,
                detail: "peak \(Format.bytes(peak)), cpu \(Format.percent(utilization))",
                at: now
            )
        }
    }
}
