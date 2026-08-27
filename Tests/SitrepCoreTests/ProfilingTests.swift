import Darwin
import Foundation
import Testing
@testable import SitrepCore

@Suite("Statistic")
struct StatisticTests {

    @Test("Odd counts take the middle value")
    func oddCountsTakeMiddle() {
        let statistic = Statistic([3, 1, 2])
        #expect(statistic.median == 2)
        #expect(statistic.min == 1)
        #expect(statistic.max == 3)
        #expect(statistic.samples == 3)
    }

    @Test("Even counts average the middle pair")
    func evenCountsAverageMiddle() {
        // Otherwise a two-run profile would arbitrarily favour the lower value.
        #expect(Statistic([10, 20]).median == 15)
        #expect(Statistic([1, 2, 3, 4]).median == 2.5)
    }

    @Test("An empty set is zero rather than a crash")
    func emptySetIsZero() {
        let statistic = Statistic([])
        #expect(statistic.median == 0)
        #expect(statistic.samples == 0)
        #expect(statistic.relativeSpread == 0)
    }

    @Test("Relative spread flags unstable measurements")
    func relativeSpreadFlagsInstability() {
        // The spread is part of the finding: publishing a median from widely
        // varying runs would make a shaky number look authoritative.
        #expect(Statistic([100, 100, 100]).relativeSpread == 0)
        // (max - min) / median = (200 - 100) / 150
        #expect(abs(Statistic([100, 150, 200]).relativeSpread - 0.6667) < 0.001)
    }
}

@Suite("Project config")
struct ProjectConfigTests {

    @Test("Minimal config decodes with empty defaults")
    func minimalConfigDecodes() throws {
        // A project with no external services should not have to say so.
        let json = """
        {"project":"demo","scenarios":[{"name":"default","command":["echo","hi"]}]}
        """
        let config = try JSONDecoder().decode(
            ProjectConfig.self, from: Data(json.utf8)
        )

        #expect(config.project == "demo")
        #expect(config.externalServices.isEmpty)
        #expect(config.budget == nil)
        #expect(config.scenarios.first?.command == ["echo", "hi"])
    }

    @Test("Round-trips through disk")
    func roundTripsThroughDisk() throws {
        let directory = NSTemporaryDirectory() + "sitrep-cfg-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        let original = ProjectConfig(
            project: "demo",
            scenarios: [.init(name: "default", command: ["python3", "x.py"], runs: 3)],
            externalServices: [.init(name: "ollama", executableContains: "ollama")],
            budget: .init(maxRAMBytes: 12 << 30, maxSwapOutsPerSecond: 0, maxCPU: 0.9)
        )
        try original.write(to: directory)

        #expect(try ProjectConfig.load(from: directory) == original)
    }

    @Test("Missing config reports where it looked")
    func missingConfigReportsPath() {
        #expect(throws: ProjectConfig.ConfigError.self) {
            try ProjectConfig.load(from: "/nonexistent-project-dir")
        }
    }

    @Test("Scenario lookup falls back to the first")
    func scenarioLookupFallsBack() {
        let config = ProjectConfig(
            project: "demo",
            scenarios: [
                .init(name: "first", command: ["a"]),
                .init(name: "second", command: ["b"]),
            ]
        )

        #expect(config.scenario(named: nil)?.name == "first")
        #expect(config.scenario(named: "second")?.name == "second")
        #expect(config.scenario(named: "missing") == nil)
    }
}

@Suite("Spawn")
struct SpawnTests {

    @Test("Child lands in its own process group")
    func childGetsOwnProcessGroup() throws {
        // Attribution depends on this entirely: without a distinct group there
        // is no way to tell the workload apart from whatever launched sitrep.
        let child = try Spawn.launch(["/bin/sleep", "2"])
        defer { Spawn.terminateGroup(child.processGroupID) }

        #expect(child.processGroupID == child.pid)
        #expect(ProcessList.processGroupID(pid: child.pid) == child.pid)
        #expect(child.processGroupID != getpgrp(), "must not inherit our group")
    }

    @Test("Poll returns nil while running, then the exit code")
    func pollReportsExit() throws {
        let child = try Spawn.launch(["/bin/sh", "-c", "exit 7"])

        var completion: Spawn.Completion?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let result = Spawn.poll(pid: child.pid) {
                completion = result
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        #expect(completion?.exitCode == 7)
        #expect(completion?.cpuSeconds ?? -1 >= 0, "rusage should come back with the exit")
    }

    @Test("Poll reaps, so a finished child does not look alive forever")
    func pollReapsZombies() throws {
        // Regression guard. An exited child stays a zombie until reaped, and a
        // zombie still answers kill(pid, 0) successfully — a liveness check
        // never goes false and the sampling loop spins forever. That hung the
        // first profiling run.
        let child = try Spawn.launch(["/bin/sh", "-c", "exit 0"])

        var polls = 0
        while Spawn.poll(pid: child.pid) == nil, polls < 500 {
            polls += 1
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(polls < 500, "poll never reported exit — the zombie bug is back")
    }

    @Test("Terminating the group kills the whole tree")
    func terminateGroupKillsDescendants() throws {
        // Signalling the pid alone would orphan children; the group is why we
        // spawn into one.
        let child = try Spawn.launch(
            ["/bin/sh", "-c", "/bin/sleep 30 & /bin/sleep 30"]
        )
        Thread.sleep(forTimeInterval: 0.3)

        Spawn.terminateGroup(child.processGroupID, graceSeconds: 2)
        Thread.sleep(forTimeInterval: 0.3)

        #expect(Spawn.poll(pid: child.pid) != nil || kill(child.pid, 0) != 0)
    }

    @Test("Launching a missing executable throws")
    func missingExecutableThrows() {
        #expect(throws: Spawn.Failure.self) {
            try Spawn.launch(["/definitely/not/a/binary"])
        }
    }

    @Test("Exit codes distinguish signals from status")
    func exitCodesDistinguishSignals() throws {
        let child = try Spawn.launch(["/bin/sleep", "30"])
        Thread.sleep(forTimeInterval: 0.2)
        kill(child.pid, SIGKILL)

        var completion: Spawn.Completion?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let result = Spawn.poll(pid: child.pid) { completion = result; break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // 128 + SIGKILL, the shell convention, so it cannot be confused with a
        // workload that exited 9 on purpose.
        #expect(completion?.exitCode == 128 + SIGKILL)
    }
}

@Suite("Attribution")
struct AttributionTests {

    private func reading(
        pid: pid_t, name: String, path: String?, footprint: UInt64, cpuNanos: UInt64 = 0
    ) -> ProcessReading {
        ProcessReading(
            pid: pid, parentPID: 1, name: name, executablePath: path,
            physicalFootprint: footprint, peakFootprint: footprint,
            diskBytesRead: 0, diskBytesWritten: 0,
            cpuNanoseconds: cpuNanos, timestamp: Date()
        )
    }

    @Test("External delta subtracts the pre-run baseline")
    func externalDeltaSubtractsBaseline() {
        // Without this, profiling against an Ollama instance that already had a
        // model loaded would claim the whole thing as this run's cost.
        let service = ProjectConfig.ExternalService(
            name: "ollama", executableContains: "ollama"
        )
        let attribution = Attribution(
            processGroupID: 999, services: [service], baseline: ["ollama": 200 << 20]
        )

        #expect(attribution.externalDelta(observedPeaks: ["ollama": 700 << 20]) == 500 << 20)
    }

    @Test("A service that shrank contributes zero, not negative")
    func shrinkingServiceContributesZero() {
        let service = ProjectConfig.ExternalService(
            name: "ollama", executableContains: "ollama"
        )
        let attribution = Attribution(
            processGroupID: 999, services: [service], baseline: ["ollama": 900 << 20]
        )

        #expect(attribution.externalDelta(observedPeaks: ["ollama": 100 << 20]) == 0)
    }

    @Test("Service footprints sum across matching processes")
    func serviceFootprintsSumAcrossProcesses() {
        // Ollama runs both a supervisor and a llama-server; the model lives in
        // the latter and both match the declared substring.
        let service = ProjectConfig.ExternalService(
            name: "ollama", executableContains: "ollama"
        )
        let attribution = Attribution(processGroupID: 999, services: [service])

        let snapshot: [pid_t: ProcessReading] = [
            10: reading(pid: 10, name: "ollama", path: "/usr/local/bin/ollama",
                        footprint: 30 << 20),
            11: reading(pid: 11, name: "llama-server",
                        path: "/Applications/Ollama.app/Contents/Resources/llama-server",
                        footprint: 600 << 20),
            12: reading(pid: 12, name: "Safari", path: "/Applications/Safari.app/Safari",
                        footprint: 400 << 20),
        ]

        let observation = attribution.observe(snapshot, previous: [:], elapsed: 1)
        #expect(observation.serviceFootprints["ollama"] == 630 << 20)
    }

    @Test("Matching is case-insensitive and falls back to the name")
    func matchingIsCaseInsensitive() {
        let service = ProjectConfig.ExternalService(
            name: "ollama", executableContains: "OLLAMA"
        )
        let attribution = Attribution(processGroupID: 999, services: [service])

        let snapshot: [pid_t: ProcessReading] = [
            10: reading(pid: 10, name: "ollama", path: nil, footprint: 50 << 20)
        ]

        let observation = attribution.observe(snapshot, previous: [:], elapsed: 1)
        #expect(observation.serviceFootprints["ollama"] == 50 << 20)
    }

    @Test("Non-workload processes count as contention, excluding the profiler")
    func contentionExcludesProfiler() {
        let attribution = Attribution(processGroupID: 999, services: [])
        let nanos: UInt64 = 500_000_000  // 0.5s of CPU over a 1s interval

        let snapshot: [pid_t: ProcessReading] = [
            500: reading(pid: 500, name: "other", path: "/bin/other",
                         footprint: 1 << 20, cpuNanos: nanos),
            getpid(): reading(pid: getpid(), name: "sitrep", path: "/bin/sitrep",
                              footprint: 1 << 20, cpuNanos: nanos),
        ]
        let previous: [pid_t: ProcessReading] = [
            500: reading(pid: 500, name: "other", path: "/bin/other", footprint: 1 << 20),
            getpid(): reading(pid: getpid(), name: "sitrep", path: "/bin/sitrep",
                              footprint: 1 << 20),
        ]

        let observation = attribution.observe(snapshot, previous: previous, elapsed: 1)
        #expect(abs(observation.contendingCPU - 0.5) < 0.01, "profiler must not count itself")
    }

    @Test("Live attribution finds a spawned child by process group")
    func liveAttributionFindsSpawnedChild() throws {
        // End-to-end: the pgid match is what makes everything else work.
        let child = try Spawn.launch(["/bin/sleep", "3"])
        defer { Spawn.terminateGroup(child.processGroupID) }
        Thread.sleep(forTimeInterval: 0.3)

        let attribution = Attribution(processGroupID: child.processGroupID, services: [])
        let observation = attribution.observe(
            ProcessSampler.read().readings, previous: [:], elapsed: 0.3
        )

        #expect(observation.ownFootprint > 0, "spawned child was not attributed")
    }
}

@Suite("Profile artifact")
struct ProfileArtifactTests {

    private func makeProfile(runs: [RunResult]) -> Profile {
        Profile(
            schemaVersion: Profile.schemaVersion,
            project: "demo", scenario: "default", command: ["echo", "hi"],
            version: "v1", generatedAt: Date(), machine: .current(),
            toolVersion: SitrepVersion.current, runs: runs,
            peakRAMBytes: Statistic(runs.map { Double($0.totalPeakRAMBytes) }),
            ownPeakRAMBytes: Statistic(runs.map { Double($0.ownPeakRAMBytes) }),
            externalPeakRAMBytes: Statistic(runs.map { Double($0.externalPeakRAMBytes) }),
            peakCPU: Statistic(runs.map(\.peakCPU)),
            cpuSeconds: Statistic(runs.map(\.cpuSeconds)),
            wallClockSeconds: Statistic(runs.map(\.wallClockSeconds)),
            diskReadBytes: Statistic(runs.map { Double($0.diskReadBytes) }),
            diskWrittenBytes: Statistic(runs.map { Double($0.diskWrittenBytes) }),
            conditions: .init(
                worstThermal: .nominal, peakSwapOutsPerSecond: 0,
                contended: false, contendingCPU: Statistic([0.05])
            ),
            overhead: .init(
                peakFootprintBytes: 5 << 20, cpuSeconds: 0.3,
                sampleCount: 100, sampleIntervalSeconds: 0.05
            ),
            externalServices: [], capabilityGaps: ["thermal.temperature"]
        )
    }

    private func makeRun(
        index: Int = 0, exitCode: Int32 = 0, peak: UInt64 = 400 << 20,
        samples: Int = 40, timedOut: Bool = false
    ) -> RunResult {
        RunResult(
            index: index, exitCode: exitCode, wallClockSeconds: 2.0,
            ownPeakRAMBytes: peak, externalPeakRAMBytes: 0, peakCPU: 1.1,
            cpuSeconds: 1.8,
            diskReadBytes: 1024, diskWrittenBytes: 0, peakSwapOutsPerSecond: 0,
            worstThermal: .nominal, contendingCPU: 0.05, timedOut: timedOut,
            externalSettleTruncated: false, sampleCount: samples
        )
    }

    @Test("Round-trips through JSON on disk")
    func roundTripsThroughDisk() throws {
        let directory = NSTemporaryDirectory() + "sitrep-prof-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let original = makeProfile(runs: [makeRun()])
        let path = try original.write(to: directory)
        let loaded = try Profile.load(path: path)

        #expect(loaded.project == original.project)
        #expect(loaded.peakRAMBytes == original.peakRAMBytes)
        #expect(loaded.capabilityGaps == ["thermal.temperature"])
        #expect(path.contains(".sitrep/profiles/demo/"))
    }

    @Test("Recommended RAM adds headroom and rounds to whole GB at GB scale")
    func recommendedRAMAddsHeadroom() {
        // A machine sized exactly at the peak swaps the moment anything else
        // runs, which defeats the point of publishing the figure.
        let profile = makeProfile(runs: [makeRun(peak: 9 << 30)])

        #expect(profile.recommendedRAMBytes > 9 << 30)
        #expect(profile.recommendedRAMBytes.isMultiple(of: 1 << 30))
        #expect(profile.recommendedRAMBytes == 12 << 30)  // 9 GB × 1.25 → 11.25 → 12
    }

    @Test("Recommended RAM scales its granularity to small workloads")
    func recommendedRAMScalesGranularity() {
        // Rounding everything to whole gigabytes reported "1.0 GB recommended"
        // for a tool measured at 2.2 MB — true, useless, and corrosive to every
        // number printed beside it.
        let tiny = makeProfile(runs: [makeRun(peak: 2_300_000)])
        #expect(tiny.recommendedRAMBytes < 16 << 20, "a 2 MB workload must not recommend 1 GB")
        #expect(tiny.recommendedRAMBytes >= 2_300_000)

        let medium = makeProfile(runs: [makeRun(peak: 400 << 20)])
        #expect(medium.recommendedRAMBytes.isMultiple(of: 64 << 20))
        #expect(medium.recommendedRAMBytes >= 500 << 20)
    }

    @Test("A timed-out run is not treated as under-sampled")
    func timeoutIsDistinctFromUnderSampling() {
        // These were conflated once, producing "fewer than 3 samples" for a run
        // with 31. Each failure has a different fix, so each gets its own signal.
        let profile = makeProfile(runs: [makeRun(exitCode: 124, samples: 31, timedOut: true)])

        #expect(profile.timedOutRuns.count == 1)
        #expect(profile.underObservedRuns.isEmpty, "31 samples is well observed")
        #expect(!profile.isTrustworthy)
    }

    @Test("A short run is flagged as under-observed")
    func shortRunIsFlagged() {
        // A 280 ms workload once reported "0 B peak" purely because nothing was
        // sampled. Reporting that as a measurement would be a confident lie.
        let profile = makeProfile(runs: [makeRun(peak: 0, samples: 0)])

        #expect(profile.underObservedRuns.count == 1)
        #expect(!profile.isTrustworthy)
    }

    @Test("A clean profile is trustworthy")
    func cleanProfileIsTrustworthy() {
        let profile = makeProfile(runs: [makeRun(index: 0), makeRun(index: 1)])

        #expect(profile.isTrustworthy)
        #expect(profile.allRunsSucceeded)
    }
}
