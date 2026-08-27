import Foundation

/// A measured statistic across repeated runs.
///
/// Named `Statistic` rather than `Measurement` to avoid colliding with
/// Foundation's generic `Measurement<UnitType>`, which would force every call
/// site to qualify the type.
///
/// Median plus range rather than a single number: peak RAM varies with thermal
/// state, page-cache warmth, quantization, context length, and background load,
/// so one sample is barely better than a guess (ARCHITECTURE #11). The spread
/// is part of the finding — a wide range says the measurement is unstable, and
/// hiding it would make a shaky number look authoritative.
public struct Statistic: Codable, Sendable, Equatable {
    public let median: Double
    public let min: Double
    public let max: Double
    public let samples: Int

    public init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count

        guard !sorted.isEmpty else {
            median = 0
            min = 0
            max = 0
            return
        }

        min = sorted.first ?? 0
        max = sorted.last ?? 0
        // Even counts average the middle pair, so a two-run profile reports the
        // mean rather than arbitrarily favouring the lower value.
        median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }

    /// Spread as a fraction of the median. Above roughly 0.2 the measurement is
    /// too noisy to publish without saying so.
    public var relativeSpread: Double {
        median == 0 ? 0 : (max - min) / median
    }
}

/// What one execution of a scenario cost.
public struct RunResult: Codable, Sendable, Equatable {
    public let index: Int
    public let exitCode: Int32
    public let wallClockSeconds: Double

    /// Peak footprint of the spawned process group.
    public let ownPeakRAMBytes: UInt64
    /// Peak footprint attributable to declared external services, measured as
    /// the increase over their pre-run baseline.
    public let externalPeakRAMBytes: UInt64
    public let peakCPU: Double
    public let diskReadBytes: UInt64
    public let diskWrittenBytes: UInt64
    public let peakSwapOutsPerSecond: Double
    public let worstThermal: ThermalState
    /// CPU used by processes that were not part of this workload, averaged over
    /// the run. High values mean the machine was busy with something else.
    public let contendingCPU: Double

    /// Whether the run was killed for exceeding its time limit. A timed-out run
    /// measured a hang, not the work.
    public let timedOut: Bool

    /// Whether a declared service was still growing when the settle cap expired,
    /// meaning its peak is a lower bound rather than a measurement.
    public let externalSettleTruncated: Bool

    /// How many times the workload was sampled during this run.
    ///
    /// A run shorter than a few sample intervals cannot be characterized, and
    /// reporting its peak as though it were measured would be a confident lie —
    /// a 280 ms workload once reported "0 B peak" simply because nothing was
    /// observed. Carried so the caller can say so.
    public let sampleCount: Int

    public var totalPeakRAMBytes: UInt64 { ownPeakRAMBytes + externalPeakRAMBytes }

    /// Whether the run was sampled often enough to characterize.
    ///
    /// Deliberately independent of ``timedOut``: a run can be well-sampled and
    /// still have been killed, and folding the two together made a 31-sample
    /// timeout report as "fewer than 3 samples". Each failure gets its own
    /// message because each has a different fix.
    public var wasObserved: Bool { sampleCount >= 3 }

    /// Whether this run's numbers describe the work rather than a failure.
    public var isUsable: Bool { wasObserved && !timedOut && exitCode == 0 }
}

/// The published artifact.
///
/// Committed to the profiled project's repository and treated as the source of
/// truth for what gets published, while the daemon's SQLite history stays
/// local and disposable (ARCHITECTURE #7). Milestone 5 renders Markdown from
/// this; nothing renders from live measurement.
public struct Profile: Codable, Sendable, Equatable {

    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let scenario: String
    public let command: [String]
    public let version: String
    public let generatedAt: Date
    public let machine: Machine
    public let toolVersion: String

    public let runs: [RunResult]

    public let peakRAMBytes: Statistic
    public let ownPeakRAMBytes: Statistic
    public let externalPeakRAMBytes: Statistic
    public let peakCPU: Statistic
    public let wallClockSeconds: Statistic
    public let diskReadBytes: Statistic
    public let diskWrittenBytes: Statistic

    public let conditions: Conditions
    public let overhead: Overhead
    public let externalServices: [String]
    /// Metrics that could not be measured on this machine, by capability id.
    /// A requirements block that silently omitted them would overstate what was
    /// actually observed (SPEC principle 11).
    public let capabilityGaps: [String]

    /// What else was true while this was measured.
    public struct Conditions: Codable, Sendable, Equatable {
        public let worstThermal: ThermalState
        public let peakSwapOutsPerSecond: Double
        /// True when another workload was materially active during a run, which
        /// makes the numbers less trustworthy.
        public let contended: Bool
        public let contendingCPU: Statistic

        /// Above this, other processes were doing enough work to matter.
        public static let contentionThreshold = 0.25
    }

    /// mac-sitrep's own cost during measurement.
    ///
    /// Measurement perturbs the thing measured, so the profiler accounts for
    /// itself rather than pretending it is free. These figures are *not*
    /// subtracted from the workload's own numbers — the profiler is not in the
    /// workload's process group, so it never inflated them in the first place.
    /// They are disclosed so a reader can judge the system-level impact.
    public struct Overhead: Codable, Sendable, Equatable {
        public let peakFootprintBytes: UInt64
        public let cpuSeconds: Double
        public let sampleCount: Int
        public let sampleIntervalSeconds: Double
    }

    public var allRunsSucceeded: Bool { runs.allSatisfy { $0.exitCode == 0 } }

    /// Runs too short to have been characterized. A profile with any of these
    /// should not be published without saying so.
    public var underObservedRuns: [RunResult] { runs.filter { !$0.wasObserved } }

    public var timedOutRuns: [RunResult] { runs.filter(\.timedOut) }

    public var isTrustworthy: Bool { runs.allSatisfy(\.isUsable) }

    /// Recommended RAM: measured peak plus 25% headroom, rounded to a unit that
    /// suits the magnitude.
    ///
    /// Headroom exists because a machine sized exactly at the peak will swap the
    /// moment anything else runs, and the point of publishing the figure is to
    /// let someone decide whether a workload fits.
    ///
    /// The rounding granularity scales deliberately. Rounding everything up to
    /// whole gigabytes reported "1.0 GB recommended" for a tool whose measured
    /// peak was 2.2 MB — technically true, useless in practice, and corrosive to
    /// the credibility of every other number beside it.
    public var recommendedRAMBytes: UInt64 {
        let withHeadroom = Double(peakRAMBytes.max) * 1.25

        let granularity: Double
        if withHeadroom < Double(64 << 20) {
            granularity = Double(8 << 20)        // under 64 MB → 8 MB steps
        } else if withHeadroom < Double(1 << 30) {
            granularity = Double(64 << 20)       // under 1 GB  → 64 MB steps
        } else {
            granularity = Double(1 << 30)        // 1 GB and up → 1 GB steps
        }

        return UInt64((withHeadroom / granularity).rounded(.up) * granularity)
    }

    // MARK: - Files

    public static func artifactPath(
        in directory: String, project: String, version: String, scenario: String
    ) -> String {
        let safeVersion = version.replacingOccurrences(of: "/", with: "-")
        return "\(directory)/.sitrep/profiles/\(project)/\(safeVersion)-\(scenario).json"
    }

    public func write(to directory: String) throws -> String {
        let path = Self.artifactPath(
            in: directory, project: project, version: version, scenario: scenario
        )
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: URL(fileURLWithPath: path))

        return path
    }

    public static func load(path: String) throws -> Profile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    }
}
