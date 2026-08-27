import ArgumentParser
import Foundation
import SitrepCore

/// Profiles a workload and writes the artifact.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Profile a workload and record what it costs.",
        discussion: """
        Runs the scenario several times, measures the process group it creates \
        plus any declared external services, and writes a JSON artifact under \
        .sitrep/profiles/.

        Measures the process *group*, not the parent chain, so work that \
        outlives an intermediate parent is still attributed. Declared services \
        like Ollama are measured as their increase over a pre-run baseline, \
        since the memory a model occupies lives in the daemon rather than in \
        the command you ran.

        A command given after -- overrides the scenario's command.
        """
    )

    @Option(name: .long, help: "Project directory containing .sitrep/project.json.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Scenario to run. Defaults to the first.")
    var scenario: String?

    @Option(name: .long, help: "Number of runs. More runs, tighter median.")
    var runs: Int?

    // Named --label, not --version: the latter collides with ArgumentParser's
    // built-in --version flag, so the same word meant two different things
    // depending on where it appeared.
    @Option(name: .long, help: "Version label for the artifact. Defaults to the git description.")
    var label: String?

    @Flag(name: .long, help: "Emit the profile as JSON instead of writing it.")
    var json = false

    @Flag(name: .long, help: "Measure without writing an artifact.")
    var dryRun = false

    @Option(name: .long, help: "Seconds before a run is killed. Guards against a hanging workload.")
    var timeout: Double = ProfileRun.defaultTimeout

    // `.postTerminator`, not `.captureForPassthrough`: the latter swallows
    // `--help` and every other flag, so `sitrep run --help` tried to launch a
    // program called "--help". Only arguments after `--` are the workload.
    @Argument(parsing: .postTerminator, help: "Command to run, after --.")
    var command: [String] = []

    func validate() throws {
        if let runs, runs < 1 {
            throw ValidationError("--runs must be at least 1")
        }
    }

    func run() throws {
        let config = try ProjectConfig.load(from: directory)

        guard var target = config.scenario(named: scenario) else {
            throw ProjectConfig.ConfigError.noSuchScenario(
                scenario ?? "<default>", available: config.scenarios.map(\.name)
            )
        }

        if !command.isEmpty {
            target = ProjectConfig.Scenario(
                name: target.name, command: command,
                runs: target.runs, workingDirectory: target.workingDirectory
            )
        }

        let versionLabel = label ?? Self.gitDescription(in: directory)

        // Progress goes to stderr so --json stays pipeable.
        let profile = try ProfileRun.profile(
            config: config, scenario: target, version: versionLabel, runs: runs,
            timeout: timeout,
            report: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(profile), as: UTF8.self))
        } else {
            print("")
            print(Self.render(profile))

            if !dryRun {
                let path = try profile.write(to: directory)
                print("")
                print("wrote \(path)")
            }
        }

        // A profile of a failing workload measures the failure, not the work.
        if !profile.allRunsSucceeded {
            let failed = profile.runs.filter { $0.exitCode != 0 }.count
            FileHandle.standardError.write(
                Data("warning: \(failed) of \(profile.runs.count) runs exited non-zero\n".utf8)
            )
            throw ExitCode(1)
        }
    }

    static func render(_ profile: Profile) -> String {
        var lines: [String] = []

        lines.append("\(profile.project) · \(profile.scenario) · \(profile.version)")
        lines.append(profile.machine.summary)
        lines.append("")

        func row(_ label: String, _ measurement: Statistic, _ format: (Double) -> String) -> String {
            let padded = label + String(repeating: " ", count: max(0, 16 - label.count))
            let spread = measurement.min == measurement.max
                ? ""
                : "  (\(format(measurement.min)) – \(format(measurement.max)))"
            return padded + format(measurement.median) + spread
        }

        let bytes: (Double) -> String = { Format.bytes(UInt64(max(0, $0))) }
        let percent: (Double) -> String = { Format.percent($0) }

        let timedOut = profile.timedOutRuns.count
        if timedOut > 0 {
            lines.append("⚠️  \(timedOut) of \(profile.runs.count) runs hit the time limit")
            lines.append("    A timed-out run measured a hang, not the work. Numbers below")
            lines.append("    describe a killed process — raise --timeout or fix the workload.")
            lines.append("")
        }

        if !profile.underObservedRuns.isEmpty {
            let count = profile.underObservedRuns.count
            lines.append("⚠️  \(count) of \(profile.runs.count) runs finished too fast to measure")
            lines.append("    (fewer than \(ProfileRun.minimumUsefulSamples) samples at "
                + "\(Format.seconds(ProfileRun.sampleInterval)))")
            lines.append("    Peak figures below are unreliable — profile a longer workload.")
            lines.append("")
        }

        lines.append("MEASURED  median of \(profile.runs.count) runs")
        lines.append("  " + row("peak RAM", profile.peakRAMBytes, bytes))
        if profile.externalPeakRAMBytes.max > 0 {
            lines.append("  " + row("  own tree", profile.ownPeakRAMBytes, bytes))
            lines.append("  " + row("  external", profile.externalPeakRAMBytes, bytes))
        }
        lines.append("  " + row("peak CPU", profile.peakCPU, percent))
        lines.append("  " + row("wall clock", profile.wallClockSeconds, Format.seconds))
        lines.append("  " + row("disk read", profile.diskReadBytes, bytes))
        lines.append("  " + row("disk write", profile.diskWrittenBytes, bytes))
        lines.append("")
        lines.append("  recommended RAM  \(Format.bytes(profile.recommendedRAMBytes))")

        lines.append("")
        lines.append("CONDITIONS")
        lines.append("  thermal        worst \(profile.conditions.worstThermal.rawValue)")
        lines.append(
            "  swap-outs      peak "
                + String(format: "%.1f", profile.conditions.peakSwapOutsPerSecond) + "/s"
        )
        lines.append(
            "  contention     "
                + (profile.conditions.contended
                    ? "YES — other work used \(Format.percent(profile.conditions.contendingCPU.median)) CPU; treat these numbers as soft"
                    : "clean (\(Format.percent(profile.conditions.contendingCPU.median)) other CPU)")
        )

        // A wide spread means the measurement is unstable; publishing the median
        // without saying so would make a shaky number look authoritative.
        if profile.peakRAMBytes.relativeSpread > 0.2 {
            lines.append(
                "  stability      peak RAM varied "
                    + Format.percent(profile.peakRAMBytes.relativeSpread)
                    + " across runs — consider more runs"
            )
        }

        lines.append("")
        lines.append("MAC-SITREP OVERHEAD")
        lines.append("  peak footprint \(Format.bytes(profile.overhead.peakFootprintBytes))")
        lines.append("  cpu time       \(Format.seconds(profile.overhead.cpuSeconds))")
        lines.append("  samples        \(profile.overhead.sampleCount)"
            + " at \(Format.seconds(profile.overhead.sampleIntervalSeconds))")

        return lines.joined(separator: "\n")
    }

    /// Version label from git, falling back to a date when there is no repo.
    ///
    /// A profile without a version cannot be compared against another, so a
    /// label is always produced rather than left empty.
    static func gitDescription(in directory: String) -> String {
        if let described = try? CommandRunner.run(
            "/usr/bin/git",
            ["-C", directory, "describe", "--tags", "--always", "--dirty"]
        ), !described.isEmpty {
            return described
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "untagged-\(formatter.string(from: Date()))"
    }
}

/// Creates a starter config.
struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a starter .sitrep/project.json."
    )

    @Option(name: .long, help: "Project directory.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Project name. Defaults to the directory name.")
    var name: String?

    func run() throws {
        let path = ProjectConfig.path(in: directory)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw CleanExit.message("\(path) already exists.")
        }

        let projectName = name ?? URL(fileURLWithPath: directory).lastPathComponent
        let config = ProjectConfig(
            project: projectName,
            scenarios: [
                ProjectConfig.Scenario(
                    name: "default",
                    command: ["echo", "replace this with your workload"],
                    runs: ProfileRun.defaultRuns
                )
            ],
            externalServices: []
        )
        try config.write(to: directory)

        print("wrote \(path)")
        print("")
        print("Edit the scenario command, then:  sitrep run")
        print("")
        print("If your workload uses a local model server, declare it so its")
        print("memory is attributed — the model lives in the daemon, not in")
        print("the command you run:")
        print("""

          "externalServices": [
            { "name": "ollama", "executableContains": "ollama" }
          ]
        """)
    }
}
