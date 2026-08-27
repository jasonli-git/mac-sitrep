import Darwin
import Foundation

/// Executes a scenario and measures what it cost.
public enum ProfileRun {

    /// How often the workload is sampled.
    ///
    /// The collector's 10-second cadence would miss a short run entirely, so the
    /// profiler samples for itself. 50 ms rather than something coarser because
    /// a workload that finishes in 300 ms would otherwise yield one sample or
    /// none — and a peak derived from one sample of a process caught mid-startup
    /// is not a measurement. Overhead at this rate is still negligible: a
    /// three-run profile costs roughly 5 MB and hundredths of a second of CPU,
    /// disclosed in every artifact.
    public static let sampleInterval: TimeInterval = 0.05

    /// Below this many samples, a run has not been observed well enough to
    /// publish. Reported rather than silently averaged in.
    public static let minimumUsefulSamples = 3

    /// Full process-table scans happen every Nth sample.
    ///
    /// A full scan discovers processes that joined the workload's group and
    /// measures contention from everything else; between scans only known group
    /// members and declared services are read. Scanning ~800 processes twenty
    /// times a second cost the profiler ~13% CPU, which is enough to distort the
    /// CPU-bound workloads it exists to measure.
    static let fullScanEveryNSamples = 5

    /// Time spent watching external services before the workload starts.
    ///
    /// Long enough to see a steady baseline rather than one arbitrary instant.
    public static let settleInterval: TimeInterval = 1.0

    /// How long a declared service must stop growing before it counts as
    /// settled.
    ///
    /// An inference server keeps loading after the client that asked it to
    /// returns: profiling `ollama run` against a cold model captured 349 MB
    /// while the server eventually settled at 628 MB, because the wrapped
    /// command had already exited.
    ///
    /// A fixed post-run window has no principled length — how long a model takes
    /// to load depends on the model. So the profiler watches until the service's
    /// footprint stops rising, which is a claim it can actually defend: *we
    /// watched until it stopped growing*.
    ///
    /// Only external services are followed. The spawned group is gone, and
    /// anything of it still running would be a leak rather than part of the
    /// measurement.
    public static let externalStableFor: TimeInterval = 2.0

    /// Hard cap on the settle wait, so a service that grows forever cannot hang
    /// the profile. Hitting it is recorded, not hidden.
    public static let externalSettleCap: TimeInterval = 30.0

    /// Pause between repeated runs, so one run's teardown does not land inside
    /// the next run's measurement.
    public static let interRunInterval: TimeInterval = 1.0

    public static let defaultRuns = 5

    /// Longest a single run may take before it is terminated.
    ///
    /// A profiler that can hang forever is a bad profiler. This is not
    /// theoretical: `ollama run` inherits stdin, and with stdin attached to a
    /// pipe that never closes it slept for seventeen minutes instead of
    /// answering. The run is killed at the *group* level and recorded as a
    /// timeout rather than silently producing a partial measurement.
    public static let defaultTimeout: TimeInterval = 300

    /// Progress callback, so the CLI can report without this module knowing
    /// about output formatting.
    public typealias Reporter = (String) -> Void

    /// Runs `scenario` `runs` times and assembles a profile.
    public static func profile(
        config: ProjectConfig,
        scenario: ProjectConfig.Scenario,
        version: String,
        runs requestedRuns: Int? = nil,
        timeout: TimeInterval = defaultTimeout,
        report: Reporter = { _ in }
    ) throws -> Profile {
        let runCount = requestedRuns ?? scenario.runs ?? defaultRuns
        var results: [RunResult] = []

        let startFootprint = Rusage.current()
        var totalSamples = 0

        for index in 0..<runCount {
            report("run \(index + 1)/\(runCount): \(scenario.command.joined(separator: " "))")

            let (result, samples) = try execute(
                scenario: scenario, services: config.externalServices,
                index: index, timeout: timeout
            )
            results.append(result)
            totalSamples += samples

            report(
                "  \(Format.seconds(result.wallClockSeconds))"
                    + " · peak \(Format.bytes(result.totalPeakRAMBytes))"
                    + " · cpu \(Format.seconds(result.cpuSeconds))"
                    + " (peak \(Format.percent(result.peakCPU)))"
                    + (result.exitCode == 0 ? "" : " · EXIT \(result.exitCode)")
                    + (result.timedOut ? " · TIMED OUT" : "")
                    + (result.wasObserved ? "" : " · only \(result.sampleCount) samples")
            )

            if index < runCount - 1 {
                Thread.sleep(forTimeInterval: interRunInterval)
            }
        }

        let endFootprint = Rusage.current()
        let overhead = Profile.Overhead(
            peakFootprintBytes: endFootprint.map {
                max($0.lifetimePeakFootprint, $0.physicalFootprint)
            } ?? 0,
            cpuSeconds: (endFootprint?.cpuSeconds ?? 0) - (startFootprint?.cpuSeconds ?? 0),
            sampleCount: totalSamples,
            sampleIntervalSeconds: sampleInterval
        )

        let contending = Statistic(results.map(\.contendingCPU))
        let conditions = Profile.Conditions(
            worstThermal: results.map(\.worstThermal).max(by: thermalSeverity) ?? .nominal,
            peakSwapOutsPerSecond: results.map(\.peakSwapOutsPerSecond).max() ?? 0,
            contended: contending.max > Profile.Conditions.contentionThreshold,
            contendingCPU: contending
        )

        return Profile(
            schemaVersion: Profile.schemaVersion,
            project: config.project,
            scenario: scenario.name,
            command: scenario.command,
            version: version,
            generatedAt: Date(),
            machine: .current(),
            toolVersion: SitrepVersion.current,
            runs: results,
            peakRAMBytes: Statistic(results.map { Double($0.totalPeakRAMBytes) }),
            ownPeakRAMBytes: Statistic(results.map { Double($0.ownPeakRAMBytes) }),
            externalPeakRAMBytes: Statistic(results.map { Double($0.externalPeakRAMBytes) }),
            peakCPU: Statistic(results.map(\.peakCPU)),
            cpuSeconds: Statistic(results.map(\.cpuSeconds)),
            wallClockSeconds: Statistic(results.map(\.wallClockSeconds)),
            diskReadBytes: Statistic(results.map { Double($0.diskReadBytes) }),
            diskWrittenBytes: Statistic(results.map { Double($0.diskWrittenBytes) }),
            conditions: conditions,
            overhead: overhead,
            externalServices: config.externalServices.map(\.name),
            capabilityGaps: CapabilityRegistry.report().unavailable.map(\.id)
        )
    }

    /// One execution: settle, spawn, sample until exit, aggregate.
    static func execute(
        scenario: ProjectConfig.Scenario,
        services: [ProjectConfig.ExternalService],
        index: Int,
        timeout: TimeInterval
    ) throws -> (RunResult, sampleCount: Int) {

        // Settle: watch declared services before starting, so only their
        // increase is attributed to this run.
        let baseline = Attribution.measureBaseline(
            services: services, duration: settleInterval, interval: sampleInterval
        )

        let child = try Spawn.launch(
            scenario.command, workingDirectory: scenario.workingDirectory
        )

        let attribution = Attribution(
            processGroupID: child.processGroupID, services: services, baseline: baseline
        )

        let started = Date()

        // Baseline the process table immediately, before the first sleep.
        // Without this the first sampling interval has nothing to delta against
        // and reports zero CPU — which for a short run is exactly where the
        // work happens. A 1.1 s workload doing its allocation in the first
        // 300 ms reported 0% peak CPU until this was added.
        var previous = ProcessSampler.read().readings
        var previousAt = started

        var ownPeak: UInt64 = 0
        var ownKernelPeak: UInt64 = 0
        var peakCPU = 0.0
        var diskRead: UInt64 = 0
        var diskWritten: UInt64 = 0
        var servicePeaks: [String: UInt64] = [:]
        var peakSwapOuts = 0.0
        var worstThermal = ThermalState.nominal
        var contendingTotal = 0.0
        var contendingSamples = 0
        var sampleCount = 0
        var knownMembers: Set<pid_t> = []
        var timedOut = false

        var previousSystem = SystemSampler.read()

        var exitCode: Int32 = -1
        var cpuSeconds = 0.0
        while true {
            Thread.sleep(forTimeInterval: sampleInterval)

            // Poll before sampling so the final sample is taken while the
            // process is still alive, then the loop exits.
            if let completion = Spawn.poll(pid: child.pid) {
                exitCode = completion.exitCode
                cpuSeconds = completion.cpuSeconds
                break
            }

            if Date().timeIntervalSince(started) > timeout {
                Spawn.terminateGroup(child.processGroupID)
                exitCode = 124  // the timeout(1) convention
                timedOut = true
                break
            }

            let now = Date()
            sampleCount += 1

            // Full scan periodically to pick up new group members and measure
            // contention; targeted reads in between to stay cheap.
            let isFullScan = sampleCount % fullScanEveryNSamples == 1
            let snapshot: [pid_t: ProcessReading]
            if isFullScan {
                snapshot = ProcessSampler.read().readings
                knownMembers = Set(
                    snapshot.keys.filter {
                        ProcessList.processGroupID(pid: $0) == child.processGroupID
                    }
                )
            } else {
                snapshot = ProcessSampler.read(pids: knownMembers)
            }

            let observation = attribution.observe(
                snapshot, previous: previous, elapsed: now.timeIntervalSince(previousAt)
            )

            ownPeak = max(ownPeak, observation.ownFootprint)
            ownKernelPeak = max(ownKernelPeak, observation.ownKernelPeak)
            peakCPU = max(peakCPU, observation.ownCPU)
            diskRead = max(diskRead, observation.ownDiskRead)
            diskWritten = max(diskWritten, observation.ownDiskWritten)
            // Contention is only meaningful from a full scan; a targeted read
              // sees nothing outside the workload and would dilute the average
              // toward zero.
            if isFullScan {
                contendingTotal += observation.contendingCPU
                contendingSamples += 1
            }

            for (name, footprint) in observation.serviceFootprints {
                servicePeaks[name] = max(servicePeaks[name] ?? 0, footprint)
            }

            let system = SystemSampler.read()
            if let sample = Sample(from: previousSystem, to: system) {
                peakSwapOuts = max(peakSwapOuts, sample.memory.swapOutsPerSecond)
                if thermalSeverity(worstThermal, sample.thermal) { worstThermal = sample.thermal }
            }
            previousSystem = system

            previous = snapshot
            previousAt = now
        }

        let wallClock = Date().timeIntervalSince(started)

        // Follow declared services past the command's exit until they stop
        // growing, so a server still loading its model is measured rather than
        // caught mid-climb.
        var settleTruncated = false
        if !services.isEmpty {
            let cap = Date().addingTimeInterval(externalSettleCap)
            var lastGrowth = Date()

            while Date() < cap {
                Thread.sleep(forTimeInterval: 0.25)

                let snapshot = ProcessSampler.read().readings
                let observation = attribution.observe(snapshot, previous: [:], elapsed: 0)

                for (name, footprint) in observation.serviceFootprints
                where footprint > (servicePeaks[name] ?? 0) {
                    servicePeaks[name] = footprint
                    lastGrowth = Date()
                }

                if Date().timeIntervalSince(lastGrowth) >= externalStableFor { break }
            }
            settleTruncated = Date() >= cap
        }

        return (
            RunResult(
                index: index,
                exitCode: exitCode,
                wallClockSeconds: wallClock,
                // The kernel's high-water mark catches growth between our
                // samples, so it is never worse than the observed peak and
                // usually better for a short-lived process.
                ownPeakRAMBytes: max(ownPeak, ownKernelPeak),
                externalPeakRAMBytes: attribution.externalDelta(observedPeaks: servicePeaks),
                peakCPU: peakCPU,
                cpuSeconds: cpuSeconds,
                diskReadBytes: diskRead,
                diskWrittenBytes: diskWritten,
                peakSwapOutsPerSecond: peakSwapOuts,
                worstThermal: worstThermal,
                contendingCPU: contendingSamples > 0
                    ? contendingTotal / Double(contendingSamples) : 0,
                timedOut: timedOut,
                externalSettleTruncated: settleTruncated,
                sampleCount: sampleCount
            ),
            sampleCount
        )
    }

    /// True when `b` is worse than `a`.
    static func thermalSeverity(_ a: ThermalState, _ b: ThermalState) -> Bool {
        func rank(_ state: ThermalState) -> Int {
            switch state {
            case .nominal: 0
            case .fair: 1
            case .serious: 2
            case .critical: 3
            }
        }
        return rank(b) > rank(a)
    }
}
