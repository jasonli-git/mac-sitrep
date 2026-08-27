import Foundation
import Testing
@testable import SitrepCore

private func makeRun(
    index: Int = 0, peak: UInt64 = 400 << 20, external: UInt64 = 0,
    cpu: Double = 1.1, wall: Double = 2.0, cpuSeconds: Double? = nil,
    swapOuts: Double = 0,
    thermal: ThermalState = .nominal, samples: Int = 40
) -> RunResult {
    RunResult(
        index: index, exitCode: 0, wallClockSeconds: wall,
        ownPeakRAMBytes: peak, externalPeakRAMBytes: external, peakCPU: cpu,
        cpuSeconds: cpuSeconds ?? wall * 0.9,
        diskReadBytes: 1 << 20, diskWrittenBytes: 0,
        peakSwapOutsPerSecond: swapOuts, worstThermal: thermal,
        contendingCPU: 0.05, timedOut: false,
        externalSettleTruncated: false, sampleCount: samples
    )
}

private func makeProfile(
    project: String = "demo", scenario: String = "default",
    version: String = "v1", runs: [RunResult] = [makeRun()],
    externalServices: [String] = [], capabilityGaps: [String] = [],
    contended: Bool = false, thermal: ThermalState = .nominal,
    swapOuts: Double = 0, machine: Machine? = nil
) -> Profile {
    Profile(
        schemaVersion: Profile.schemaVersion,
        project: project, scenario: scenario, command: ["echo", "hi"],
        version: version,
        // Fixed date so rendering is deterministic — the whole point of the
        // block being stable is that it must not depend on when it was rendered.
        generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
        machine: machine ?? .current(),
        toolVersion: "9.9.9", runs: runs,
        peakRAMBytes: Statistic(runs.map { Double($0.totalPeakRAMBytes) }),
        ownPeakRAMBytes: Statistic(runs.map { Double($0.ownPeakRAMBytes) }),
        externalPeakRAMBytes: Statistic(runs.map { Double($0.externalPeakRAMBytes) }),
        peakCPU: Statistic(runs.map(\.peakCPU)),
        cpuSeconds: Statistic(runs.map(\.cpuSeconds)),
        wallClockSeconds: Statistic(runs.map(\.wallClockSeconds)),
        diskReadBytes: Statistic(runs.map { Double($0.diskReadBytes) }),
        diskWrittenBytes: Statistic(runs.map { Double($0.diskWrittenBytes) }),
        conditions: .init(
            worstThermal: thermal, peakSwapOutsPerSecond: swapOuts,
            contended: contended, contendingCPU: Statistic([contended ? 0.4 : 0.05])
        ),
        overhead: .init(
            peakFootprintBytes: 5 << 20, cpuSeconds: 0.3,
            sampleCount: 100, sampleIntervalSeconds: 0.05
        ),
        externalServices: externalServices, capabilityGaps: capabilityGaps
    )
}

@Suite("Markdown rendering")
struct MarkdownRendererTests {

    @Test("Rendering the same artifact twice is byte-identical")
    func renderingIsDeterministic() {
        // If this ever fails, --check reports drift on every run and the CI gate
        // is worthless. Nothing in the renderer may read the clock or the
        // machine — every value comes from the artifact.
        let profile = makeProfile()

        #expect(
            MarkdownRenderer.requirementsBlock(profile)
                == MarkdownRenderer.requirementsBlock(profile)
        )
    }

    @Test("The block carries the profile's date, not today's")
    func blockUsesProfileDate() {
        // 1_780_000_000 is 2026-05-28 UTC, deliberately not today.
        let block = MarkdownRenderer.requirementsBlock(makeProfile())
        #expect(block.contains("2026-05-28"))
        #expect(!block.contains(MarkdownRenderer.isoDay(Date())), "must not use render time")
    }

    @Test("Own and external memory are split only when a service held memory")
    func splitAppearsOnlyWhenRelevant() {
        let without = MarkdownRenderer.requirementsBlock(makeProfile())
        #expect(!without.contains("own processes"), "no service means no split")

        let with = MarkdownRenderer.requirementsBlock(
            makeProfile(
                runs: [makeRun(peak: 11 << 20, external: 416 << 20)],
                externalServices: ["ollama"]
            )
        )
        #expect(with.contains("own processes"))
        #expect(with.contains("ollama"))
    }

    @Test("Capability gaps are disclosed in the published block")
    func capabilityGapsAreDisclosed() {
        // A requirements block that silently omitted unmeasurable metrics would
        // overstate what was actually observed (SPEC principle 11).
        let block = MarkdownRenderer.requirementsBlock(
            makeProfile(capabilityGaps: ["thermal.temperature", "power.package"])
        )

        #expect(block.contains("thermal.temperature"))
        #expect(block.contains("power.package"))
        #expect(block.contains("sitrep doctor"))
    }

    @Test("Contention and instability become caveats")
    func caveatsAppearForSoftMeasurements() {
        let contended = MarkdownRenderer.requirementsBlock(makeProfile(contended: true))
        #expect(contended.contains("soft"))

        let unstable = MarkdownRenderer.requirementsBlock(
            makeProfile(runs: [makeRun(peak: 100 << 20), makeRun(index: 1, peak: 400 << 20)])
        )
        #expect(unstable.contains("varied"))
    }

    @Test("Thermal throttling is called out")
    func throttlingIsCalledOut() {
        let block = MarkdownRenderer.requirementsBlock(makeProfile(thermal: .serious))
        #expect(block.contains("throttling"))
    }

    @Test("A stable measurement omits the range")
    func stableMeasurementOmitsRange() {
        // Printing "400 MB (400 MB – 400 MB)" is noise.
        let block = MarkdownRenderer.requirementsBlock(makeProfile())
        #expect(!block.contains("400 MB _(400 MB"))
    }

    @Test("CPU load is labelled from machine share, not peak")
    func cpuLoadDerivesFromMachineShare() {
        // A percentage of one core cannot carry a label: whether a third of a
        // core is "moderate" depends on how many cores exist. Machine share can.
        #expect(Profile.CPULoad(machineShare: 0.005) == .negligible)
        #expect(Profile.CPULoad(machineShare: 0.05) == .light)
        #expect(Profile.CPULoad(machineShare: 0.20) == .moderate)
        #expect(Profile.CPULoad(machineShare: 0.50) == .heavy)
        #expect(Profile.CPULoad(machineShare: 0.90) == .saturating)
    }

    @Test("A fully occupied core is not called light")
    func oneWholeCoreIsAtLeastModerate() {
        // Measured: one core pinned for two seconds on a 10-core M4 is 9.9% of
        // the machine. A flat 10% light ceiling reported that as "Light", which
        // understates a workload burning a core solid.
        #expect(Profile.CPULoad(machineShare: 1.0 / 10) == .moderate, "one core of ten")
        #expect(Profile.CPULoad(machineShare: 1.0 / 4) == .moderate, "one core of four")
        #expect(Profile.CPULoad(machineShare: 8.0 / 10) == .saturating, "eight cores of ten")
    }

    @Test("A busy single core on a 10-core machine is not called heavy")
    func oneCoreOfTenIsNotHeavy() {
        // The real measured case: `sitrep processes` peaks at 31% of one core
        // but consumes only 0.034 s over 0.575 s wall — 0.06 cores, 0.6% of a
        // 10-core machine. Peak read as a heavy tool; the truth is negligible.
        let profile = makeProfile(runs: [makeRun(cpu: 0.31, wall: 0.575, cpuSeconds: 0.034)])

        #expect(abs(profile.averageCoresUsed - 0.059) < 0.005)
        #expect(profile.machineShare < 0.01)
        #expect(profile.cpuLoad == .negligible)
    }

    @Test("Average cores used is CPU time over wall clock")
    func averageCoresIsExact() {
        // Sampling-independent, unlike peak: both inputs are exact.
        let profile = makeProfile(runs: [makeRun(cpu: 9.9, wall: 2.0)])
        // makeRun sets cpuSeconds = wall * 0.9 = 1.8 -> 1.8 / 2.0 = 0.9 cores
        #expect(abs(profile.averageCoresUsed - 0.9) < 0.001)
    }

    @Test("The label never appears without its number")
    func labelAlwaysCarriesItsNumber() {
        // A word alone invites trust in a judgement whose thresholds the reader
        // cannot see.
        let block = MarkdownRenderer.requirementsBlock(makeProfile())

        #expect(block.contains("CPU load"))
        #expect(block.contains("-core machine"), "the denominator must be stated")
        #expect(block.contains("of one core"), "peak must name its denominator too")
    }

    @Test("Small percentages keep a decimal")
    func smallPercentagesKeepPrecision() {
        // Rounding 0.6% to "1%" nearly doubles it, and machine share for a light
        // tool lives entirely in that range.
        #expect(MarkdownRenderer.percent(0.006) == "0.6%")
        #expect(MarkdownRenderer.percent(0.099) == "9.9%")
        #expect(MarkdownRenderer.percent(0.31) == "31%")
    }

    @Test("CPU time leads, and peak CPU discloses its window")
    func cpuTimeLeadsPeakIsQualified() {
        // Peak CPU is an artifact of the sampling rate as much as of the
        // workload: a 15 ms burst read through a 50 ms window reports about a
        // third of its real intensity. The exact figure goes first, and the
        // sampled one says what window produced it.
        let block = MarkdownRenderer.requirementsBlock(makeProfile())

        #expect(block.contains("| CPU time |"))
        #expect(block.contains("ms window"))
        #expect(
            block.range(of: "| CPU time |")!.lowerBound
                < block.range(of: "Peak CPU")!.lowerBound,
            "the exact figure should come before the sampled one"
        )
    }

    @Test("Zero swap says so in words")
    func zeroSwapIsExplicit() {
        #expect(MarkdownRenderer.requirementsBlock(makeProfile()).contains("no swapping"))
        #expect(
            MarkdownRenderer.requirementsBlock(makeProfile(swapOuts: 2.5)).contains("2.5/s")
        )
    }
}

@Suite("Readme injection")
struct ReadmeInjectorTests {

    let hand = """
    # My Project

    Hand-written prose that must survive.

    ## Usage
    """

    @Test("Appends a section when the file has no markers")
    func appendsWhenNoMarkers() throws {
        let block = "### Resource Requirements\n\nStuff."
        let (result, outcome) = try ReadmeInjector.apply(block: block, to: hand)

        #expect(outcome == .appended)
        #expect(result.hasPrefix(hand), "hand-written content must be untouched")
        #expect(result.contains(ReadmeInjector.startMarker))
        #expect(result.contains(ReadmeInjector.endMarker))
    }

    @Test("Replacing is idempotent")
    func replacingIsIdempotent() throws {
        let block = "### Resource Requirements\n\nStuff."
        let (once, _) = try ReadmeInjector.apply(block: block, to: hand)
        let (twice, outcome) = try ReadmeInjector.apply(block: block, to: once)

        #expect(once == twice)
        #expect(outcome == .unchanged)
    }

    @Test("Only the marked region changes")
    func onlyMarkedRegionChanges() throws {
        let block = "### Resource Requirements\n\nOld."
        let (withOld, _) = try ReadmeInjector.apply(block: block, to: hand)
        let (withNew, outcome) = try ReadmeInjector.apply(
            block: "### Resource Requirements\n\nNew.", to: withOld
        )

        #expect(outcome == .replaced)
        #expect(withNew.hasPrefix(hand))
        #expect(withNew.contains("New."))
        #expect(!withNew.contains("Old."))
    }

    @Test("Content after the end marker survives replacement")
    func contentAfterMarkersSurvives() throws {
        let document = """
        # Title

        \(ReadmeInjector.startMarker)
        old content
        \(ReadmeInjector.endMarker)

        ## A section that comes after, and must not be eaten.
        """
        let (result, _) = try ReadmeInjector.apply(block: "new content", to: document)

        #expect(result.contains("must not be eaten"))
        #expect(result.contains("new content"))
        #expect(!result.contains("old content"))
    }

    @Test("Unbalanced markers are refused, not guessed at")
    func unbalancedMarkersAreRefused() {
        // Rewriting a file whose markers we cannot interpret risks destroying
        // someone's hand-written content, so this fails loudly instead.
        let orphanStart = "# T\n\(ReadmeInjector.startMarker)\ncontent"
        #expect(throws: ReadmeInjector.InjectionError.self) {
            try ReadmeInjector.apply(block: "x", to: orphanStart)
        }

        let orphanEnd = "# T\ncontent\n\(ReadmeInjector.endMarker)"
        #expect(throws: ReadmeInjector.InjectionError.self) {
            try ReadmeInjector.apply(block: "x", to: orphanEnd)
        }
    }

    @Test("Duplicated marker pairs are refused")
    func duplicatedMarkersAreRefused() {
        let block = "\(ReadmeInjector.startMarker)\na\n\(ReadmeInjector.endMarker)"
        #expect(throws: ReadmeInjector.InjectionError.self) {
            try ReadmeInjector.apply(block: "x", to: block + "\n" + block)
        }
    }

    @Test("An end marker before a start marker is refused")
    func reversedMarkersAreRefused() {
        let reversed = "\(ReadmeInjector.endMarker)\nmiddle\n\(ReadmeInjector.startMarker)"
        #expect(throws: ReadmeInjector.InjectionError.self) {
            try ReadmeInjector.apply(block: "x", to: reversed)
        }
    }

    @Test("The drift gate agrees with what injection would do")
    func driftGateMatchesInjection() throws {
        // --check and --inject must share one implementation. A gate that
        // compared against a subtly different renderer would report drift that
        // does not exist.
        let directory = NSTemporaryDirectory() + "sitrep-inj-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = directory + "/README.md"
        try hand.write(toFile: path, atomically: true, encoding: .utf8)

        let block = MarkdownRenderer.requirementsBlock(makeProfile())
        #expect(try !ReadmeInjector.isUpToDate(block: block, at: path))

        _ = try ReadmeInjector.inject(block: block, into: path)
        #expect(try ReadmeInjector.isUpToDate(block: block, at: path))

        // A hand-edit inside the block must be detected.
        var edited = try String(contentsOfFile: path, encoding: .utf8)
        edited = edited.replacingOccurrences(of: "Peak RAM", with: "Peek RAM")
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try !ReadmeInjector.isUpToDate(block: block, at: path))
    }

    @Test("A document that documents the markers is not confused by them")
    func markersMentionedInProseAreIgnored() throws {
        // Caught by this project's own README: the Usage section explains the
        // marker syntax in a sentence, and a naive substring count read that as
        // a second start marker and refused to inject. Markers only count when
        // they are alone on a line.
        let document = """
        # Project

        Injection replaces the region between \(ReadmeInjector.startMarker) and
        its matching end marker, leaving the rest alone.

        \(ReadmeInjector.startMarker)
        old
        \(ReadmeInjector.endMarker)
        """

        let (result, outcome) = try ReadmeInjector.apply(block: "new", to: document)
        #expect(outcome == .replaced)
        #expect(result.contains("new"))
        #expect(result.contains("its matching end marker"), "prose must survive")
    }

    @Test("An indented marker still counts")
    func indentedMarkerCounts() throws {
        let document = "# T\n\n  \(ReadmeInjector.startMarker)\n  old\n  \(ReadmeInjector.endMarker)"
        let (_, outcome) = try ReadmeInjector.apply(block: "new", to: document)

        #expect(outcome == .replaced)
    }

    @Test("A missing file reports its path")
    func missingFileReportsPath() {
        #expect(throws: ReadmeInjector.InjectionError.self) {
            try ReadmeInjector.inject(block: "x", into: "/nonexistent/README.md")
        }
    }
}

@Suite("Badge")
struct BadgeTests {

    @Test("Badge carries the median peak and shields.io schema")
    func badgeCarriesMedianPeak() throws {
        let badge = BadgeRenderer.peakRAM(makeProfile(runs: [makeRun(peak: 400 << 20)]))

        #expect(badge.label == "peak RAM")
        #expect(badge.message == "400 MB")
        #expect(try BadgeRenderer.json(badge).contains("\"schemaVersion\" : 1"))
    }

    @Test("Colour tracks the fraction of this machine used")
    func colourTracksFraction() {
        // The reader's machine is unknown, so the only honest scale is the one
        // the measurement was taken on (SPEC non-goals).
        #expect(BadgeRenderer.color(fraction: 0.1) == "brightgreen")
        #expect(BadgeRenderer.color(fraction: 0.4) == "green")
        #expect(BadgeRenderer.color(fraction: 0.6) == "yellow")
        #expect(BadgeRenderer.color(fraction: 0.9) == "orange")
    }
}

@Suite("Profile comparison")
struct ProfileComparisonTests {

    @Test("A large memory increase is a regression")
    func memoryIncreaseIsRegression() {
        let comparison = ProfileComparison(
            baseline: makeProfile(version: "v1", runs: [makeRun(peak: 300 << 20)]),
            candidate: makeProfile(version: "v2", runs: [makeRun(peak: 500 << 20)])
        )

        let peak = comparison.changes.first { $0.metric == "peak RAM" }
        #expect(peak?.isRegression == true)
        #expect(comparison.regressions.count >= 1)
    }

    @Test("A decrease is an improvement, not a regression")
    func decreaseIsImprovement() {
        let comparison = ProfileComparison(
            baseline: makeProfile(version: "v1", runs: [makeRun(peak: 500 << 20)]),
            candidate: makeProfile(version: "v2", runs: [makeRun(peak: 300 << 20)])
        )

        #expect(comparison.regressions.isEmpty)
        #expect(!comparison.improvements.isEmpty)
    }

    @Test("Small changes are noise, not findings")
    func smallChangesAreNoise() {
        // Run-to-run variation must not read as a regression, or the signal is
        // useless.
        let comparison = ProfileComparison(
            baseline: makeProfile(version: "v1", runs: [makeRun(peak: 400 << 20)]),
            candidate: makeProfile(
                version: "v2", runs: [makeRun(peak: UInt64(Double(400 << 20) * 1.03))]
            )
        )

        #expect(comparison.regressions.isEmpty)
        #expect(comparison.improvements.isEmpty)
    }

    @Test("Newly introduced swap is flagged separately")
    func newSwapIsFlagged() {
        // A percentage against a zero baseline says nothing; going from no
        // swapping to any swapping is a categorical change.
        let comparison = ProfileComparison(
            baseline: makeProfile(version: "v1", swapOuts: 0),
            candidate: makeProfile(version: "v2", swapOuts: 3.0)
        )

        #expect(comparison.swapNewlyIntroduced)
    }

    @Test("Comparing across machines warns")
    func crossMachineComparisonWarns() {
        // This would be exactly the cross-machine extrapolation the project
        // refuses to do (SPEC non-goals).
        let other = Machine(
            hardwareModel: "Mac14,2", cpuBrand: "Apple M2",
            physicalMemoryBytes: 8 << 30, coreCount: 8,
            osVersion: "26.0.0", osBuild: "XXXX"
        )
        let comparison = ProfileComparison(
            baseline: makeProfile(version: "v1"),
            candidate: makeProfile(version: "v2", machine: other)
        )

        #expect(comparison.warnings.contains { $0.contains("not comparable") })
    }

    @Test("Comparing different scenarios warns")
    func differentScenariosWarn() {
        let comparison = ProfileComparison(
            baseline: makeProfile(scenario: "small", version: "v1"),
            candidate: makeProfile(scenario: "large", version: "v2")
        )

        #expect(comparison.warnings.contains { $0.contains("different scenarios") })
    }
}

@Suite("Fit prediction")
struct FitPredictionTests {

    /// Builds a sample with a given amount of memory committed to running work.
    ///
    /// Parameterized on *used* rather than free/inactive because available is
    /// now derived as total − used (ARCHITECTURE #40), so used is the only knob
    /// that changes the prediction.
    private func sample(usedGB: Double, totalGB: Double = 16) -> Sample {
        let total = UInt64(totalGB * Double(1 << 30))
        let used = UInt64(usedGB * Double(1 << 30))

        return Sample(
            timestamp: Date(), intervalSeconds: 1,
            memory: .init(
                totalBytes: total, usedBytes: used, activeBytes: used,
                inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0,
                freeBytes: total - used,
                appMemoryBytes: used, cachedFilesBytes: 0,
                swapUsedBytes: 0, swapTotalBytes: 0,
                pressure: .normal, swapOutsPerSecond: 0, pressureSwapOutsPerSecond: 0
            ),
            cpu: .init(
                utilization: 0.1, userFraction: 0.05, systemFraction: 0.05,
                idleFraction: 0.9, coreCount: 10
            ),
            gpu: nil, thermal: .nominal,
            disk: .init(
                freeBytes: 100 << 30, totalBytes: 500 << 30,
                readBytesPerSecond: 0, writtenBytesPerSecond: 0
            ),
            network: .init(
                receivedBytesPerSecond: 0, sentBytesPerSecond: 0,
                totalReceivedBytes: 0, totalSentBytes: 0
            )
        )
    }

    @Test("A workload well under available memory fits")
    func comfortableWorkloadFits() {
        let prediction = FitPrediction(
            profile: makeProfile(runs: [makeRun(peak: 1 << 30)]),
            sample: sample(usedGB: 8)
        )

        #expect(prediction.verdict == .fits)
        #expect(prediction.headroomBytes > 0)
    }

    @Test("A workload larger than available memory will swap")
    func oversizedWorkloadWillSwap() {
        let prediction = FitPrediction(
            profile: makeProfile(runs: [makeRun(peak: 12 << 30)]),
            sample: sample(usedGB: 14)
        )

        #expect(prediction.verdict == .willSwap)
        #expect(prediction.headroomBytes < 0)
        #expect(prediction.explanation.contains("short by"))
    }

    @Test("A near-exact fit is called tight, not comfortable")
    func nearExactFitIsTight() {
        // Sizing exactly at the peak means anything else starting pushes it into
        // swap, which is worth saying rather than reporting a clean pass.
        let prediction = FitPrediction(
            profile: makeProfile(runs: [makeRun(peak: UInt64(3.9 * Double(1 << 30)))]),
            sample: sample(usedGB: 12)   // 4 GB available, needs 3.9
        )

        #expect(prediction.verdict == .tight)
    }

    @Test("Available is total minus used, agreeing with the status display")
    func availableAgreesWithUsed() {
        // Not free + inactive: `inactive` holds anonymous pages that cost a
        // swap to reclaim, so counting them as available overstates what a new
        // workload can actually get (ARCHITECTURE #40).
        let s = sample(usedGB: 8)
        let prediction = FitPrediction(profile: makeProfile(), sample: s)

        #expect(prediction.availableBytes == s.memory.availableBytes)
        #expect(prediction.availableBytes + s.memory.usedBytes == s.memory.totalBytes)
    }
}

@Suite("Artifact discovery")
struct ArtifactDiscoveryTests {

    @Test("Artifacts are found and ordered newest first")
    func artifactsAreOrderedNewestFirst() throws {
        let directory = NSTemporaryDirectory() + "sitrep-disc-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        // Distinct generatedAt values; write order is deliberately reversed to
        // prove ordering comes from the artifact, not the filesystem.
        for (offset, version) in [(0.0, "v1"), (100.0, "v2")] {
            var profile = makeProfile(version: version)
            profile = Profile(
                schemaVersion: profile.schemaVersion, project: profile.project,
                scenario: profile.scenario, command: profile.command,
                version: version,
                generatedAt: Date(timeIntervalSince1970: 1_780_000_000 + offset),
                machine: profile.machine, toolVersion: profile.toolVersion,
                runs: profile.runs, peakRAMBytes: profile.peakRAMBytes,
                ownPeakRAMBytes: profile.ownPeakRAMBytes,
                externalPeakRAMBytes: profile.externalPeakRAMBytes,
                peakCPU: profile.peakCPU, cpuSeconds: profile.cpuSeconds,
                wallClockSeconds: profile.wallClockSeconds,
                diskReadBytes: profile.diskReadBytes,
                diskWrittenBytes: profile.diskWrittenBytes,
                conditions: profile.conditions, overhead: profile.overhead,
                externalServices: profile.externalServices,
                capabilityGaps: profile.capabilityGaps
            )
            _ = try profile.write(to: directory)
        }

        let all = try Profile.all(in: directory, project: "demo")
        #expect(all.count == 2)
        #expect(all.first?.version == "v2", "newest first")

        #expect(try Profile.latest(in: directory, project: "demo")?.version == "v2")
        #expect(
            try Profile.matching(version: "v1", in: directory, project: "demo")?.version == "v1"
        )
        #expect(Profile.knownProjects(in: directory) == ["demo"])
    }

    @Test("An empty directory yields nothing rather than failing")
    func emptyDirectoryYieldsNothing() throws {
        #expect(try Profile.all(in: "/nonexistent", project: "demo").isEmpty)
        #expect(try Profile.latest(in: "/nonexistent", project: "demo") == nil)
        #expect(Profile.knownProjects(in: "/nonexistent").isEmpty)
    }
}
