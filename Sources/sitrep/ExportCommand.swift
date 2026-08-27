import ArgumentParser
import Foundation
import SitrepCore

/// Publishes a measured requirements block.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render a profile as a publishable requirements block.",
        discussion: """
        Renders from the committed JSON artifact, never from live measurement, \
        so the same artifact always produces the same block. That is what makes \
        --check usable as a CI gate.

        With --inject, only the region between the sitrep markers is touched; \
        the rest of the file is left byte-for-byte alone. If the file has no \
        markers, a section is appended.

        With --check, nothing is written and the command exits non-zero when the \
        file would change — so CI can prove the published numbers still match \
        the committed artifact without needing a Mac to re-measure.
        """
    )

    @Argument(help: "Project name. Defaults to the one in .sitrep/project.json.")
    var project: String?

    @Option(name: .long, help: "Project directory.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Scenario to publish. Defaults to the most recent.")
    var scenario: String?

    @Option(name: .long, help: "Version label to publish. Defaults to the most recent.")
    var version: String?

    @Option(name: .long, help: "File to inject the block into.")
    var inject: String?

    @Flag(name: .long, help: "Exit non-zero if the target file is out of date. Writes nothing.")
    var check = false

    @Option(name: .long, help: "Write shields.io badge JSON to this path.")
    var badge: String?

    func validate() throws {
        if check && inject == nil {
            throw ValidationError("--check needs --inject to say which file to check.")
        }
    }

    func run() throws {
        let profile = try Self.resolveProfile(
            directory: directory, project: project, scenario: scenario, version: version
        )
        let block = MarkdownRenderer.requirementsBlock(profile)

        if let badge {
            try BadgeRenderer.json(BadgeRenderer.peakRAM(profile))
                .write(toFile: badge, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("wrote badge \(badge)\n".utf8))
        }

        guard let inject else {
            print(block)
            return
        }

        if check {
            guard try ReadmeInjector.isUpToDate(block: block, at: inject) else {
                FileHandle.standardError.write(
                    Data(
                        """
                        \(inject) is out of date with \
                        .sitrep/profiles/\(profile.project)/\(profile.version)-\
                        \(profile.scenario).json
                        Run: sitrep export --inject \(inject)

                        """.utf8
                    )
                )
                throw ExitCode(1)
            }
            print("\(inject) is up to date.")
            return
        }

        let outcome = try ReadmeInjector.inject(block: block, into: inject)
        print("\(inject): \(outcome.summary)")
    }

    /// Picks the artifact to publish.
    ///
    /// Resolving the project name from config when it is omitted means the
    /// common case inside a project directory needs no arguments at all.
    static func resolveProfile(
        directory: String, project: String?, scenario: String?, version: String?
    ) throws -> Profile {
        let name: String
        if let project {
            name = project
        } else if let config = try? ProjectConfig.load(from: directory) {
            name = config.project
        } else {
            let known = Profile.knownProjects(in: directory)
            throw ValidationError(
                known.isEmpty
                    ? "no profiles found under \(directory)/.sitrep/profiles — run 'sitrep run' first"
                    : "name a project: \(known.joined(separator: ", "))"
            )
        }

        if let version {
            guard let profile = try Profile.matching(
                version: version, in: directory, project: name, scenario: scenario
            ) else {
                throw ValidationError("no profile for \(name) at version \(version)")
            }
            return profile
        }

        guard let profile = try Profile.latest(
            in: directory, project: name, scenario: scenario
        ) else {
            throw ValidationError(
                "no profiles for \(name) — run 'sitrep run' to measure one"
            )
        }
        return profile
    }
}

/// Diffs two profiles of the same project.
struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two profiles and report regressions.",
        discussion: """
        Compares medians rather than peaks, so one unlucky run does not read as \
        a regression. Warns when the two profiles are not really comparable — \
        different machines, scenarios, or commands.
        """
    )

    @Argument(help: "Baseline version label.")
    var baseline: String

    @Argument(help: "Candidate version label.")
    var candidate: String

    @Option(name: .long, help: "Project name. Defaults to .sitrep/project.json.")
    var project: String?

    @Option(name: .long, help: "Project directory.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Scenario to compare.")
    var scenario: String?

    @Flag(name: .long, help: "Exit non-zero when a regression is found.")
    var failOnRegression = false

    func run() throws {
        let name = try project
            ?? ProjectConfig.load(from: directory).project

        guard let before = try Profile.matching(
            version: baseline, in: directory, project: name, scenario: scenario
        ) else {
            throw ValidationError("no profile for \(name) at \(baseline)")
        }
        guard let after = try Profile.matching(
            version: candidate, in: directory, project: name, scenario: scenario
        ) else {
            throw ValidationError("no profile for \(name) at \(candidate)")
        }

        let comparison = ProfileComparison(baseline: before, candidate: after)
        print(Self.render(comparison))

        if failOnRegression && (!comparison.regressions.isEmpty || comparison.swapNewlyIntroduced) {
            throw ExitCode(1)
        }
    }

    static func render(_ comparison: ProfileComparison) -> String {
        var lines: [String] = []

        lines.append("\(comparison.baseline.project) · "
            + "\(comparison.baseline.version) → \(comparison.candidate.version)")
        lines.append("")

        for warning in comparison.warnings {
            lines.append("⚠️  \(warning)")
        }
        if !comparison.warnings.isEmpty { lines.append("") }

        for change in comparison.changes {
            let arrow = change.isRegression ? "▲" : (change.isImprovement ? "▼" : " ")
            let label = change.metric
                + String(repeating: " ", count: max(0, 14 - change.metric.count))
            let percent = change.relativeChange == 0
                ? "     —"
                : String(format: "%+6.1f%%", change.relativeChange * 100)

            lines.append(
                "  \(arrow) \(label)\(change.format(change.before)) → "
                    + "\(change.format(change.after))   \(percent)"
            )
        }

        if comparison.swapNewlyIntroduced {
            lines.append("")
            lines.append("🔴 swap was newly introduced — this workload did not swap before")
        }

        lines.append("")
        if comparison.regressions.isEmpty && !comparison.swapNewlyIntroduced {
            lines.append(comparison.improvements.isEmpty
                ? "No significant change."
                : "\(comparison.improvements.count) improvement(s), no regressions.")
        } else {
            lines.append("\(comparison.regressions.count) regression(s) beyond "
                + "\(Format.percent(ProfileComparison.significantChange)).")
        }

        return lines.joined(separator: "\n")
    }
}

/// Predicts whether a workload fits right now.
struct CanIRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "can-i-run",
        abstract: "Predict whether a profiled workload fits in available memory.",
        discussion: """
        Compares a project's measured peak against memory available on this \
        machine right now. Available means free plus inactive pages — what the \
        kernel can hand over without swapping.

        This is a claim about *this* machine only. mac-sitrep does not predict \
        across hardware.
        """
    )

    @Argument(help: "Project name. Defaults to .sitrep/project.json.")
    var project: String?

    @Option(name: .long, help: "Project directory.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Scenario to check.")
    var scenario: String?

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let name = try project ?? ProjectConfig.load(from: directory).project

        guard let profile = try Profile.latest(
            in: directory, project: name, scenario: scenario
        ) else {
            throw ValidationError("no profiles for \(name) — run 'sitrep run' first")
        }
        guard let sample = SystemSampler.sample(interval: 0.2) else {
            throw CleanExit.message("could not read memory state; try 'sitrep doctor'")
        }

        let prediction = FitPrediction(profile: profile, sample: sample)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = Payload(
                project: name,
                scenario: profile.scenario,
                verdict: prediction.verdict.rawValue,
                availableBytes: prediction.availableBytes,
                requiredBytes: prediction.requiredBytes,
                headroomBytes: prediction.headroomBytes,
                machine: profile.machine.hardwareModel
            )
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            return
        }

        print("\(prediction.verdict.symbol) \(name) · \(profile.scenario) · \(profile.version)")
        print("   \(prediction.explanation)")

        // A prediction from an untrustworthy profile is an untrustworthy
        // prediction; saying so is cheaper than being quietly wrong.
        if !profile.isTrustworthy {
            print("")
            print("   Note: this profile has runs that were not cleanly measured.")
        }

        if prediction.verdict == .willSwap {
            throw ExitCode(1)
        }
    }

    private struct Payload: Encodable {
        let project: String
        let scenario: String
        let verdict: String
        let availableBytes: UInt64
        let requiredBytes: UInt64
        let headroomBytes: Int64
        let machine: String
    }
}
