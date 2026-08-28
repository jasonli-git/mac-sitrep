import Foundation

/// Compares two profiles of the same project.
///
/// This is what makes a resource regression detectable by the tool rather than
/// by the machine getting slow.
public struct ProfileComparison: Sendable {

    /// Change beyond which a difference is called a regression rather than
    /// noise. Set above the spread a stable measurement typically shows, so
    /// run-to-run variation does not read as a regression.
    public static let significantChange = 0.10

    public let baseline: Profile
    public let candidate: Profile
    public let changes: [Change]

    public struct Change: Sendable {
        public let metric: String
        public let before: Double
        public let after: Double
        public let format: @Sendable (Double) -> String
        /// True when an increase is bad. Wall clock and RAM going up is a
        /// regression; nothing here improves by growing.
        public let higherIsWorse: Bool

        public var delta: Double { after - before }

        public var relativeChange: Double {
            before == 0 ? (after == 0 ? 0 : 1) : (after - before) / before
        }

        public var isSignificant: Bool {
            abs(relativeChange) >= ProfileComparison.significantChange
        }

        public var isRegression: Bool {
            isSignificant && (higherIsWorse ? delta > 0 : delta < 0)
        }

        public var isImprovement: Bool {
            isSignificant && !isRegression
        }
    }

    public init(baseline: Profile, candidate: Profile) {
        self.baseline = baseline
        self.candidate = candidate

        let bytes: @Sendable (Double) -> String = { Format.bytes(UInt64(max(0, $0))) }
        let percent: @Sendable (Double) -> String = { Format.percent($0) }
        let seconds: @Sendable (Double) -> String = { Format.seconds($0) }

        // Medians rather than peaks: a single unlucky run should not read as a
        // regression, which is the whole reason profiles carry a distribution.
        changes = [
            Change(
                metric: "peak RAM", before: baseline.peakRAMBytes.median,
                after: candidate.peakRAMBytes.median, format: bytes, higherIsWorse: true
            ),
            // CPU time before peak: it is exact, where peak is an artifact of
            // the sampling window as much as of the workload.
            Change(
                metric: "cpu time", before: baseline.cpuSeconds.median,
                after: candidate.cpuSeconds.median, format: seconds, higherIsWorse: true
            ),
            Change(
                metric: "peak CPU", before: baseline.peakCPU.median,
                after: candidate.peakCPU.median, format: percent, higherIsWorse: true
            ),
            Change(
                metric: "wall clock", before: baseline.wallClockSeconds.median,
                after: candidate.wallClockSeconds.median, format: seconds, higherIsWorse: true
            ),
            Change(
                metric: "disk read", before: baseline.diskReadBytes.median,
                after: candidate.diskReadBytes.median, format: bytes, higherIsWorse: true
            ),
        ]
    }

    public var regressions: [Change] { changes.filter(\.isRegression) }
    public var improvements: [Change] { changes.filter(\.isImprovement) }

    /// Swap appearing where there was none is called out separately from the
    /// numeric comparisons: going from zero to any swapping is a categorical
    /// change, and a percentage against a zero baseline says nothing useful.
    public var swapNewlyIntroduced: Bool {
        baseline.conditions.peakSwapOutsPerSecond == 0
            && candidate.conditions.peakSwapOutsPerSecond > 0
    }

    /// Whether the two profiles are comparable at all.
    ///
    /// Comparing across machines would be exactly the cross-machine
    /// extrapolation the project refuses to do (SPEC non-goals), and comparing
    /// different scenarios compares different work.
    public var warnings: [String] {
        var warnings: [String] = []

        if baseline.machine.hardwareModel != candidate.machine.hardwareModel
            || baseline.machine.physicalMemoryBytes != candidate.machine.physicalMemoryBytes {
            warnings.append(
                "measured on different machines (\(baseline.machine.hardwareModel) vs "
                    + "\(candidate.machine.hardwareModel)) — not comparable"
            )
        }
        if baseline.scenario != candidate.scenario {
            warnings.append(
                "different scenarios (\(baseline.scenario) vs \(candidate.scenario))"
            )
        }
        if baseline.command != candidate.command {
            warnings.append("the command changed between these profiles")
        }
        if !baseline.isTrustworthy || !candidate.isTrustworthy {
            warnings.append("at least one profile has runs that were not cleanly measured")
        }
        return warnings
    }
}

/// Predicts whether a workload fits in memory available right now.
///
/// The inverse of publishing requirements, and what makes them actionable rather
/// than decorative: a number in a README only matters if something can answer
/// "will this fit?" from it.
public struct FitPrediction: Sendable {

    public enum Verdict: String, Sendable {
        case fits
        case tight
        case willSwap

        public var symbol: String {
            switch self {
            case .fits: "🟢"
            case .tight: "🟡"
            case .willSwap: "🔴"
            }
        }
    }

    public let profile: Profile
    public let availableBytes: UInt64
    public let requiredBytes: UInt64
    public let verdict: Verdict

    /// Headroom below which a fit is called tight rather than comfortable.
    public static let tightMargin = 0.15

    public init(profile: Profile, sample: Sample) {
        self.profile = profile

        // Everything not already committed to running work. Defined as
        // total − used so it agrees with what `sitrep` displays.
        //
        // The earlier definition, free + inactive, was wrong in the same way the
        // old `used` was: `inactive` holds anonymous pages that belong to
        // processes, and reclaiming those costs a compression or a swap. They
        // are not available (ARCHITECTURE #40).
        availableBytes = sample.memory.availableBytes
        requiredBytes = UInt64(profile.peakRAMBytes.max)

        if requiredBytes > availableBytes {
            verdict = .willSwap
        } else if Double(availableBytes - requiredBytes) / Double(availableBytes)
            < Self.tightMargin {
            verdict = .tight
        } else {
            verdict = .fits
        }
    }

    public var headroomBytes: Int64 {
        Int64(availableBytes) - Int64(requiredBytes)
    }

    public var explanation: String {
        switch verdict {
        case .fits:
            "\(Format.bytes(availableBytes)) available, needs "
                + "\(Format.bytes(requiredBytes)) — fits with "
                + "\(Format.bytes(UInt64(max(0, headroomBytes)))) to spare."
        case .tight:
            "\(Format.bytes(availableBytes)) available, needs "
                + "\(Format.bytes(requiredBytes)) — fits, but with little headroom. "
                + "Anything else starting up may push this into swap."
        case .willSwap:
            "\(Format.bytes(availableBytes)) available, needs "
                + "\(Format.bytes(requiredBytes)) — short by "
                + "\(Format.bytes(UInt64(abs(headroomBytes)))). This will swap."
        }
    }
}

// MARK: - Finding artifacts

extension Profile {

    /// Every profile artifact stored for a project, newest first.
    public static func all(in directory: String, project: String) throws -> [Profile] {
        let root = "\(directory)/.sitrep/profiles/\(project)"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }

        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { try? Profile.load(path: "\(root)/\($0)") }
            .sorted { $0.generatedAt > $1.generatedAt }
    }

    /// The most recent artifact, optionally restricted to one scenario.
    public static func latest(
        in directory: String, project: String, scenario: String? = nil
    ) throws -> Profile? {
        let profiles = try all(in: directory, project: project)
        guard let scenario else { return profiles.first }
        return profiles.first { $0.scenario == scenario }
    }

    /// The scenario a command should use when the caller named none.
    ///
    /// `sitrep run` defaults to the config's *first* scenario; the
    /// artifact-reading commands (`export`, `compare`, `can-i-run`) must agree,
    /// or the same project answers differently depending on which scenario
    /// happened to be profiled most recently. That disagreement is not
    /// cosmetic: `export --check`'s suggested remedy would overwrite the
    /// published block with whichever scenario was measured last.
    ///
    /// Resolution order: the config's first scenario when a config for this
    /// project exists; else the only scenario present in the artifacts; else
    /// refuse and name the choices rather than guess. `nil` means no artifacts
    /// exist at all, which callers already report as their own error.
    public static func defaultScenario(
        in directory: String, project: String
    ) throws -> String? {
        if let config = try? ProjectConfig.load(from: directory),
           config.project == project,
           let first = config.scenarios.first {
            return first.name
        }

        var seen: Set<String> = []
        var scenarios: [String] = []
        for profile in try all(in: directory, project: project)
        where seen.insert(profile.scenario).inserted {
            scenarios.append(profile.scenario)
        }

        guard scenarios.count > 1 else { return scenarios.first }
        throw DiscoveryError.ambiguousScenario(
            project: project, scenarios: scenarios.sorted()
        )
    }

    public enum DiscoveryError: Error, CustomStringConvertible {
        case ambiguousScenario(project: String, scenarios: [String])

        public var description: String {
            switch self {
            case let .ambiguousScenario(project, scenarios):
                "\(project) has profiles for more than one scenario and no config "
                    + "to pick a default — pass --scenario "
                    + "(\(scenarios.joined(separator: ", ")))"
            }
        }
    }

    /// Finds an artifact by version label.
    public static func matching(
        version: String, in directory: String, project: String, scenario: String? = nil
    ) throws -> Profile? {
        try all(in: directory, project: project).first {
            $0.version == version && (scenario == nil || $0.scenario == scenario)
        }
    }

    /// Project names that have artifacts in `directory`.
    public static func knownProjects(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: "\(directory)/.sitrep/profiles"
        ))?.sorted() ?? []
    }
}
