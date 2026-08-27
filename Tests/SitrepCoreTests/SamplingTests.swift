import Darwin
import Foundation
import Testing
@testable import SitrepCore

@Suite("System sampling")
struct SystemSamplerTests {

    /// A short interval keeps the suite fast; correctness of the derivation is
    /// covered by the synthetic tests below, which need no real time at all.
    static let interval: TimeInterval = 0.15

    @Test("Produces a sample with plausible absolute values")
    func sampleHasPlausibleAbsolutes() throws {
        let sample = try #require(SystemSampler.sample(interval: Self.interval))
        let machine = Machine.current()

        #expect(sample.memory.totalBytes == machine.physicalMemoryBytes)
        #expect(sample.memory.usedBytes > 0)
        #expect(sample.memory.usedBytes <= sample.memory.totalBytes)
        #expect(sample.memory.usedFraction > 0 && sample.memory.usedFraction <= 1)

        #expect(sample.disk.totalBytes > 0)
        #expect(sample.disk.freeBytes <= sample.disk.totalBytes)
        #expect(sample.cpu.coreCount == machine.coreCount)
    }

    @Test("Total memory is installed RAM, not a sum of page buckets")
    func totalMemoryIsInstalledRAM() throws {
        // Regression guard: summing active+inactive+wired+compressed+free
        // under-reported a 16 GB Mac as 15 GB, because host_statistics64 also
        // tracks speculative and purgeable pages outside those buckets.
        let sample = try #require(SystemSampler.sample(interval: Self.interval))
        let pages = SystemSampler.read().memoryPages
        let bucketSum = pages.active + pages.inactive + pages.wired
            + pages.compressed + pages.free

        #expect(sample.memory.totalBytes == Machine.current().physicalMemoryBytes)
        #expect(sample.memory.totalBytes >= bucketSum)
    }

    @Test("Used memory is app + wired + compressed, excluding the file cache")
    func usedMemoryMatchesActivityMonitor() throws {
        // Regression guard for ARCHITECTURE #40. The obvious formula —
        // active + wired + compressed — under-reports by the anonymous pages
        // sitting on the inactive queue, which cost a compression or a swap to
        // reclaim and are therefore not free. On a real 16 GB Mac that gap was
        // 1.2 GB and made the figure disagree with Activity Monitor.
        let sample = try #require(SystemSampler.sample(interval: Self.interval))

        #expect(
            sample.memory.usedBytes
                == sample.memory.appMemoryBytes + sample.memory.wiredBytes
                    + sample.memory.compressedBytes
        )

        // Still below top's total − free, which counts the reclaimable cache.
        #expect(sample.memory.usedBytes < sample.memory.totalBytes - sample.memory.freeBytes)

        // And at or above the old formula, since app memory ⊇ active anonymous.
        let oldFormula = sample.memory.activeBytes + sample.memory.wiredBytes
            + sample.memory.compressedBytes
        #expect(sample.memory.usedBytes + (64 << 20) >= oldFormula)
    }

    @Test("Available memory agrees with used")
    func availableAgreesWithUsed() throws {
        let sample = try #require(SystemSampler.sample(interval: Self.interval))
        #expect(sample.memory.availableBytes + sample.memory.usedBytes
            == sample.memory.totalBytes)
    }

    @Test("Rates are non-negative and the interval is recorded")
    func ratesAreNonNegative() throws {
        let sample = try #require(SystemSampler.sample(interval: Self.interval))

        #expect(sample.intervalSeconds >= Self.interval)
        #expect(sample.disk.readBytesPerSecond >= 0)
        #expect(sample.disk.writtenBytesPerSecond >= 0)
        #expect(sample.network.receivedBytesPerSecond >= 0)
        #expect(sample.network.sentBytesPerSecond >= 0)
        #expect(sample.memory.swapOutsPerSecond >= 0)
    }

    @Test("Rejects readings that are not separated in time")
    func rejectsZeroInterval() {
        // Every rate divides by the interval, so a zero gap must fail rather
        // than produce infinities.
        let reading = SystemSampler.read()
        #expect(Sample(from: reading, to: reading) == nil)
    }

    @Test("CPU fractions sum to one and utilization is its complement")
    func cpuFractionsAreCoherent() {
        let before = [
            MachHost.CPUTicks(user: 100, system: 50, idle: 800, nice: 50),
            MachHost.CPUTicks(user: 200, system: 100, idle: 600, nice: 100),
        ]
        let after = [
            MachHost.CPUTicks(user: 200, system: 100, idle: 1600, nice: 100),
            MachHost.CPUTicks(user: 400, system: 200, idle: 1200, nice: 200),
        ]

        let cpu = Sample.deriveCPU(from: before, to: after)

        let sum = cpu.userFraction + cpu.systemFraction + cpu.idleFraction
        #expect(abs(sum - 1.0) < 0.0001)
        #expect(abs(cpu.utilization - (1 - cpu.idleFraction)) < 0.0001)

        // user delta 100+200=300, nice delta 100+200 -> wait: nice counts as user.
        // deltas: user 300, system 150, idle 1400, nice 150. total 2000.
        #expect(abs(cpu.userFraction - 0.225) < 0.0001)   // (300+150)/2000
        #expect(abs(cpu.systemFraction - 0.075) < 0.0001) // 150/2000
        #expect(abs(cpu.idleFraction - 0.70) < 0.0001)    // 1400/2000
    }

    @Test("Idle CPU reports zero utilization")
    func idleCPUReportsZero() {
        let before = [MachHost.CPUTicks(user: 10, system: 10, idle: 100, nice: 0)]
        let after = [MachHost.CPUTicks(user: 10, system: 10, idle: 200, nice: 0)]

        let cpu = Sample.deriveCPU(from: before, to: after)
        #expect(cpu.utilization == 0)
        #expect(cpu.idleFraction == 1)
    }

    @Test("Identical tick readings do not divide by zero")
    func identicalTicksAreSafe() {
        let ticks = [MachHost.CPUTicks(user: 10, system: 10, idle: 100, nice: 0)]
        let cpu = Sample.deriveCPU(from: ticks, to: ticks)

        #expect(cpu.utilization == 0)
        #expect(cpu.idleFraction == 1)
    }

    @Test("Mismatched core counts pair only what both readings have")
    func mismatchedCoreCountsAreSafe() {
        // A core going offline between readings must not crash on an index.
        let before = [MachHost.CPUTicks(user: 10, system: 0, idle: 90, nice: 0)]
        let after = [
            MachHost.CPUTicks(user: 20, system: 0, idle: 180, nice: 0),
            MachHost.CPUTicks(user: 5, system: 0, idle: 95, nice: 0),
        ]

        let cpu = Sample.deriveCPU(from: before, to: after)
        #expect(cpu.utilization > 0)
        #expect(cpu.coreCount == 2)
    }

    @Test("Sample encodes to JSON with the interval and health included")
    func sampleEncodesToJSON() throws {
        let sample = try #require(SystemSampler.sample(interval: Self.interval))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sample)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["intervalSeconds"] != nil)
        #expect(object["memory"] != nil)
        #expect(object["cpu"] != nil)
        #expect(object["thermal"] as? String == sample.thermal.rawValue)
    }
}

@Suite("Process sampling")
struct ProcessSamplerTests {

    @Test("Self appears with a plausible footprint")
    func selfAppearsInSnapshot() throws {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .ram, limit: nil)
        let me = try #require(snapshot.processes.first { $0.pid == getpid() })

        #expect(me.physicalFootprint > 0)
        #expect(me.peakFootprint >= me.physicalFootprint)
        #expect(me.parentPID != nil)
        #expect(me.executablePath?.hasPrefix("/") == true)
    }

    @Test("Unreadable processes are counted, not silently dropped")
    func unreadableProcessesAreDisclosed() {
        // On a normal Mac most processes are root-owned system daemons that
        // proc_pid_rusage refuses without privilege. Reporting a top-N list
        // without saying so would misattribute the machine's memory.
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .ram, limit: nil)

        #expect(snapshot.unreadableProcessCount > 0)
        #expect(
            snapshot.processes.count + snapshot.unreadableProcessCount
                <= ProcessList.pids().count + 50  // slack for churn between reads
        )
    }

    @Test("Sorting by memory is descending and stable")
    func sortingByMemoryIsDescending() {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .ram, limit: 20)
        let footprints = snapshot.processes.map(\.physicalFootprint)

        #expect(footprints == footprints.sorted(by: >))
    }

    @Test("Sorting by CPU is descending")
    func sortingByCPUIsDescending() {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .cpu, limit: 20)
        let utilizations = snapshot.processes.map(\.cpuUtilization)

        #expect(utilizations == utilizations.sorted(by: >))
    }

    @Test("Limit caps the row count")
    func limitCapsRows() {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .ram, limit: 5)
        #expect(snapshot.processes.count <= 5)
    }

    @Test("CPU utilization is non-negative and bounded by core count")
    func cpuUtilizationIsBounded() {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .cpu, limit: nil)
        let cores = Double(Machine.current().coreCount)

        for process in snapshot.processes {
            #expect(process.cpuUtilization >= 0)
            // Per-process utilization is deliberately uncapped at 1.0 — a
            // parallel workload can exceed one core — but it cannot exceed the
            // whole machine.
            #expect(process.cpuUtilization <= cores + 0.5)
        }
    }

    @Test("Readable footprint sums only what was read")
    func readableFootprintSumsProcesses() {
        let snapshot = ProcessSampler.snapshot(interval: 0.1, sort: .ram, limit: 3)
        let expected = snapshot.processes.reduce(UInt64(0)) { $0 + $1.physicalFootprint }

        #expect(snapshot.readableFootprint == expected)
    }
}

@Suite("Health classification")
struct HealthStateTests {

    /// Builds a sample with everything nominal, then lets each test perturb one
    /// dimension. Constructing by hand keeps the classifier under test rather
    /// than whatever the machine happens to be doing.
    static func sample(
        pressure: MemoryPressure.Level? = .normal,
        thermal: ThermalState = .nominal,
        swapOutsPerSecond: Double = 0,
        diskFreeFraction: Double = 0.5,
        memoryUsedFraction: Double = 0.5
    ) -> Sample {
        let total: UInt64 = 16 * 1 << 30
        let used = UInt64(Double(total) * memoryUsedFraction)
        let diskTotal: UInt64 = 500 * 1 << 30

        return Sample(
            timestamp: Date(),
            intervalSeconds: 1,
            memory: .init(
                totalBytes: total, usedBytes: used, activeBytes: used,
                inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0,
                freeBytes: total - used,
                appMemoryBytes: used, cachedFilesBytes: 0,
                swapUsedBytes: 0, swapTotalBytes: 0,
                pressure: pressure, swapOutsPerSecond: swapOutsPerSecond,
                pressureSwapOutsPerSecond: 0
            ),
            cpu: .init(
                utilization: 0.1, userFraction: 0.05,
                systemFraction: 0.05, idleFraction: 0.9, coreCount: 10
            ),
            gpu: nil,
            thermal: thermal,
            disk: .init(
                freeBytes: UInt64(Double(diskTotal) * diskFreeFraction),
                totalBytes: diskTotal,
                readBytesPerSecond: 0, writtenBytesPerSecond: 0
            ),
            network: .init(
                receivedBytesPerSecond: 0, sentBytesPerSecond: 0,
                totalReceivedBytes: 0, totalSentBytes: 0
            )
        )
    }

    @Test("A nominal machine is healthy with no reasons")
    func nominalIsHealthy() {
        let (state, reasons) = HealthState.classify(sample: Self.sample())
        #expect(state == .healthy)
        #expect(reasons.isEmpty)
    }

    @Test("Critical memory pressure is critical")
    func criticalPressureIsCritical() {
        let (state, reasons) = HealthState.classify(sample: Self.sample(pressure: .critical))
        #expect(state == .critical)
        #expect(reasons.contains { $0.contains("pressure") })
    }

    @Test("Warning memory pressure is a warning")
    func warningPressureIsWarning() {
        let (state, _) = HealthState.classify(sample: Self.sample(pressure: .warning))
        #expect(state == .warning)
    }

    @Test("Any swap-out activity trips a warning")
    func swapActivityWarns() {
        // The zero-swap policy is defined on rate, so any sustained swap-out is
        // a violation regardless of swap file size (ARCHITECTURE #6).
        let (state, reasons) = HealthState.classify(sample: Self.sample(swapOutsPerSecond: 0.5))
        #expect(state == .warning)
        #expect(reasons.contains { $0.contains("swapping out") })
    }

    @Test("Thermal throttling is critical, fair is a warning")
    func thermalStatesClassify() {
        #expect(HealthState.classify(sample: Self.sample(thermal: .serious)).state == .critical)
        #expect(HealthState.classify(sample: Self.sample(thermal: .critical)).state == .critical)
        #expect(HealthState.classify(sample: Self.sample(thermal: .fair)).state == .warning)
    }

    @Test("Disk thresholds classify at their boundaries")
    func diskThresholdsClassify() {
        #expect(HealthState.classify(sample: Self.sample(diskFreeFraction: 0.04)).state == .critical)
        #expect(HealthState.classify(sample: Self.sample(diskFreeFraction: 0.08)).state == .warning)
        #expect(HealthState.classify(sample: Self.sample(diskFreeFraction: 0.20)).state == .healthy)
    }

    @Test("Critical outranks warning and keeps both reasons")
    func criticalOutranksWarning() {
        let (state, reasons) = HealthState.classify(
            sample: Self.sample(pressure: .critical, swapOutsPerSecond: 1)
        )
        #expect(state == .critical)
        #expect(reasons.count >= 2, "a critical verdict should not discard warning reasons")
    }

    @Test("Every state has a distinct symbol")
    func statesHaveDistinctSymbols() {
        let symbols = HealthState.allCases.map(\.symbol)
        #expect(Set(symbols).count == HealthState.allCases.count)
    }
}
