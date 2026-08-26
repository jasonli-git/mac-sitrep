import Darwin
import Foundation
import Testing
@testable import SitrepCore

/// The registry is the contract: every metric the project uses must be probed
/// here, so `doctor` is exhaustive by construction rather than by diligence.
@Suite("Capability registry")
struct CapabilityRegistryTests {

    /// Locked to ARCHITECTURE.md's capability table. If a metric is added to
    /// the project without a probe, this fails — which is the point.
    static let expectedIDs: Set<String> = [
        "memory.statistics", "memory.swap", "memory.pressure", "memory.swap_rate",
        "cpu.load",
        "gpu.utilization", "gpu.memory",
        "thermal.state", "thermal.performance_limit", "thermal.temperature", "thermal.fan",
        "disk.capacity", "disk.io",
        "network.io", "network.per_process",
        "process.list", "process.rusage", "process.tree", "process.other_users",
        "power.sleep_wake", "power.package",
    ]

    @Test("Every documented capability is registered")
    func registryCoversDocumentedCapabilities() {
        let actual = Set(CapabilityRegistry.all.map(\.id))
        #expect(actual == Self.expectedIDs)
    }

    @Test("Capability ids are unique")
    func idsAreUnique() {
        let ids = CapabilityRegistry.all.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test("Every probe declares a non-empty source")
    func probesNameTheirSource() {
        // The source is what makes a claim auditable. A probe without one
        // cannot be checked against the OS.
        for probe in CapabilityRegistry.all {
            #expect(!probe.source.isEmpty, "\(probe.id) declares no source")
            #expect(!probe.title.isEmpty, "\(probe.id) declares no title")
        }
    }

    @Test("No probe fails unexpectedly on this machine")
    func noUnexpectedProbeFailures() {
        let report = CapabilityRegistry.report()
        let failures = report.failures.map { "\($0.id): \($0.status)" }

        #expect(failures.isEmpty, "unexpected probe failures: \(failures)")
    }

    @Test("Root-gated metrics report a reason, never absence")
    func rootGatedMetricsExplainThemselves() {
        let report = CapabilityRegistry.report()
        let gated = ["thermal.temperature", "thermal.fan", "power.package", "process.other_users"]

        for id in gated {
            guard let capability = report.capabilities.first(where: { $0.id == id }) else {
                Issue.record("\(id) is missing from the report entirely")
                continue
            }
            guard case let .unavailable(reason) = capability.status else {
                Issue.record("\(id) claims to be available without root")
                continue
            }
            #expect(reason.kind == "requires_privilege", "\(id) has the wrong reason kind")
            #expect(!reason.summary.isEmpty, "\(id) gives no explanation")
        }
    }

    @Test("Per-process network reports no-public-API, not merely privilege")
    func perProcessNetworkIsImpossibleNotGated() {
        // The distinction matters: root would not unlock this, so reporting it
        // as privilege-gated would imply a workaround that does not exist.
        let report = CapabilityRegistry.report()
        let capability = report.capabilities.first { $0.id == "network.per_process" }

        guard case let .unavailable(reason)? = capability?.status else {
            Issue.record("network.per_process should be unavailable")
            return
        }
        #expect(reason.kind == "no_public_api")
        #expect(reason.alternative == "network.io")
    }

    @Test("Unavailable capabilities point at an alternative where one exists")
    func gapsSuggestAlternatives() {
        let report = CapabilityRegistry.report()

        for capability in report.unavailable {
            guard case let .unavailable(reason) = capability.status else { continue }
            if let alternative = reason.alternative {
                let exists = report.capabilities.contains { $0.id == alternative }
                #expect(exists, "\(capability.id) points at unknown capability \(alternative)")
            }
        }
    }

    @Test("Available and unavailable partition the full set")
    func partitionIsComplete() {
        let report = CapabilityRegistry.report()
        #expect(report.available.count + report.unavailable.count == report.capabilities.count)
        #expect(report.capabilities.count == Self.expectedIDs.count)
    }

    @Test("Only probe failures count as failures")
    func onlyProbeFailuresCountAsFailures() {
        // `doctor` exits non-zero on failures, so this classification is what
        // decides whether a root-gated gap trips a scripted health check. It
        // must not: declining to use root is expected, a broken read is not.
        func capability(_ id: String, _ status: Capability.Status) -> Capability {
            Capability(id: id, title: id, category: .memory, source: "test", status: status)
        }

        let report = CapabilityReport(
            machine: .current(),
            capabilities: [
                capability("ok", .available(sample: "fine")),
                capability("gated", .unavailable(.requiresPrivilege(detail: "d", alternative: nil))),
                capability("impossible", .unavailable(.noPublicAPI(detail: "d", alternative: nil))),
                capability("absent", .unavailable(.unsupportedOnThisMac(detail: "d"))),
                capability("broken", .unavailable(.probeFailed(detail: "d"))),
            ],
            selfFootprint: nil
        )

        #expect(report.failures.map(\.id) == ["broken"])
        #expect(report.available.count == 1)
        #expect(report.unavailable.count == 4)
    }

    @Test("Report encodes to scriptable JSON")
    func reportEncodesToJSON() throws {
        let data = try JSONEncoder().encode(CapabilityRegistry.report())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let capabilities = try #require(object?["capabilities"] as? [[String: Any]])
        #expect(capabilities.count == Self.expectedIDs.count)

        // Available entries carry a sample; unavailable ones carry a reason.
        for entry in capabilities {
            let available = try #require(entry["available"] as? Bool)
            if available {
                #expect(entry["sample"] != nil, "\(entry["id"] ?? "?") available without a sample")
            } else {
                #expect(entry["reason"] != nil, "\(entry["id"] ?? "?") unavailable without a reason")
                #expect(entry["detail"] != nil)
            }
        }
    }
}

/// These assert against real kernel reads. The point of the milestone is that
/// availability is established by probing, so the tests probe too.
@Suite("Measurement sources")
struct MeasurementSourceTests {

    @Test("Virtual memory statistics are plausible")
    func virtualMemoryIsPlausible() throws {
        let vm = try #require(MachHost.virtualMemory())
        let machine = Machine.current()

        // Resident categories cannot exceed installed RAM. A page-size or
        // width mistake would blow through this immediately.
        let resident = (UInt64(vm.active_count) + UInt64(vm.inactive_count)
            + UInt64(vm.wire_count)) * MachHost.pageSize
        #expect(resident > 0)
        #expect(resident <= machine.physicalMemoryBytes)
    }

    @Test("Page size matches the hardware page size")
    func pageSizeAgreesWithSysctl() throws {
        // Apple Silicon uses 16 KB pages; a compile-time PAGE_SIZE constant
        // would say 4 KB and quietly divide every memory figure by four.
        let fromSysctl: UInt64 = try #require(Sysctl.integer("hw.pagesize"))
        #expect(MachHost.pageSize == fromSysctl)
    }

    @Test("Processor ticks are reported for every logical CPU")
    func processorTicksCoverAllCPUs() throws {
        let ticks = try #require(MachHost.processorTicks())
        #expect(ticks.count == Machine.current().coreCount)
        #expect(ticks.allSatisfy { $0.total > 0 })
    }

    @Test("Swap usage is internally consistent")
    func swapUsageIsConsistent() throws {
        let swap = try #require(SwapUsage.read())
        #expect(swap.used <= swap.total)
    }

    @Test("Memory pressure resolves to a known level")
    func memoryPressureResolves() throws {
        let level = try #require(MemoryPressure.level())
        #expect([.normal, .warning, .critical].contains(level))
    }

    @Test("Swap counters read from keys that exist")
    func swapCountersResolve() throws {
        // Regression guard: the first implementation used
        // vm.compressor.swapouts_pressure, which does not exist — the real key
        // has a `.swapper.` component. The probe caught it; this keeps it caught.
        let counters = try #require(MemoryPressure.swapCounters())
        #expect(counters.swapOutsUnderPressure <= counters.swapOutsTotal)
    }

    @Test("Self rusage reports a plausible footprint")
    func selfRusageIsPlausible() throws {
        let usage = try #require(Rusage.current())

        #expect(usage.physicalFootprint > 0)
        #expect(usage.physicalFootprint < Machine.current().physicalMemoryBytes)
        #expect(usage.cpuSeconds > 0)

        // Deliberately NOT asserting lifetimePeak >= physicalFootprint. The
        // kernel refreshes the high-water mark at accounting boundaries, so it
        // can lag the live value during growth — this assertion failed on an
        // M4 with peak 4,800,824 against footprint 4,833,592. Raw values are
        // reported as the kernel gives them; deriving a monotonic peak is the
        // caller's job (ARCHITECTURE #17). They should still be close.
        let difference = Double(abs(
            Int64(usage.lifetimePeakFootprint) - Int64(usage.physicalFootprint)
        ))
        #expect(difference / Double(usage.physicalFootprint) < 0.5)
    }

    @Test("Process enumeration includes this process")
    func processListIncludesSelf() {
        let pids = ProcessList.pids()

        #expect(pids.count > 1)
        #expect(pids.contains(getpid()))
    }

    @Test("Process identity resolves for self")
    func processIdentityResolvesForSelf() throws {
        let pid = getpid()

        let path = try #require(ProcessList.path(pid: pid))
        #expect(path.hasPrefix("/"))
        #expect(ProcessList.parentPID(pid: pid) != nil)
        #expect(ProcessList.name(pid: pid) == URL(fileURLWithPath: path).lastPathComponent)
    }

    @Test("Network totals exclude loopback and are non-zero")
    func networkTotalsAreReal() throws {
        // Loopback alone would still produce non-zero counters, so this also
        // guards the 64-bit read path: 32-bit counters would have wrapped.
        let totals = try #require(NetworkInterfaces.totals())
        #expect(totals.received > 0 || totals.sent > 0)
    }

    @Test("GPU statistics expose utilization")
    func gpuStatisticsAreReadable() throws {
        let statistics = try #require(IOKitRegistry.gpuPerformanceStatistics())
        let utilization = try #require(statistics["Device Utilization %"] as? Int)

        #expect((0...100).contains(utilization))
    }

    @Test("Block storage counters are monotonic and non-zero")
    func blockStorageCountersAreReadable() throws {
        let statistics = try #require(IOKitRegistry.blockStorageStatistics())
        #expect(statistics.read > 0)
    }
}

@Suite("Self footprint")
struct SelfFootprintTests {

    @Test("mac-sitrep measures itself within its declared budget")
    func selfFootprintIsWithinBudget() throws {
        let footprint = try #require(SelfFootprint.current())

        #expect(footprint.peakFootprint >= footprint.physicalFootprint)
        let peak = Format.bytes(footprint.peakFootprint)
        let budget = Format.bytes(SelfBudget.memoryBytes)
        #expect(
            footprint.withinMemoryBudget,
            "peak \(peak) exceeds the \(budget) budget — correct the budget in SPEC.md rather than hiding the measurement"
        )
    }

    @Test("Reported peak is never below the live footprint")
    func reportedPeakIsMonotonic() throws {
        // Regression guard for ARCHITECTURE #17. SelfFootprint takes the max of
        // the kernel's high-water mark and the live value, so this invariant
        // holds by construction even though the raw kernel fields do not
        // guarantee it.
        let footprint = try #require(SelfFootprint.current())
        #expect(footprint.peakFootprint >= footprint.physicalFootprint)
    }

    @Test("Budget verdict uses peak, not instantaneous footprint")
    func budgetVerdictUsesPeak() {
        // A process that already spiked must not report itself compliant
        // because it has since shrunk.
        let spiked = SelfFootprint(
            physicalFootprint: 1 << 20,
            peakFootprint: SelfBudget.memoryBytes + 1,
            cpuSeconds: 0.1
        )
        #expect(!spiked.withinMemoryBudget)
    }
}

@Suite("Formatting")
struct FormatTests {

    @Test("Bytes render in binary units")
    func bytesRenderInBinaryUnits() {
        #expect(Format.bytes(0) == "0 B")
        #expect(Format.bytes(512) == "512 B")
        #expect(Format.bytes(1 << 20) == "1.0 MB")
        #expect(Format.bytes(9_663_676_416) == "9.0 GB")
        #expect(Format.bytes(16 * (1 << 30)) == "16 GB")
    }

    @Test("Seconds lose precision as magnitude grows")
    func secondsScalePrecision() {
        #expect(Format.seconds(0.005) == "0.005 s")
        #expect(Format.seconds(1.5) == "1.50 s")
        #expect(Format.seconds(120) == "120 s")
    }
}
