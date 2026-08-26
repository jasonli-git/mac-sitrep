import Darwin
import Foundation

/// Every metric mac-sitrep knows how to look for, and how to look for it.
///
/// Adding a metric anywhere in the project means adding a probe here. That is
/// deliberate: it makes `sitrep doctor` exhaustive by construction, so a
/// capability cannot be silently used somewhere without being disclosed.
public enum CapabilityRegistry {

    /// Path to `pmset`, the sole subprocess dependency (ARCHITECTURE #1).
    static let pmsetPath = "/usr/bin/pmset"

    public static var all: [CapabilityProbe] {
        memory + cpu + gpu + thermal + disk + network + process + power
    }

    /// Probes every capability and assembles the report.
    public static func report() -> CapabilityReport {
        CapabilityReport(
            machine: .current(),
            capabilities: all.map { $0.run() },
            selfFootprint: .current()
        )
    }

    // MARK: - Memory

    static let memory: [CapabilityProbe] = [
        CapabilityProbe(
            id: "memory.statistics",
            title: "System memory statistics",
            category: .memory,
            source: "host_statistics64 / HOST_VM_INFO64"
        ) {
            guard let vm = MachHost.virtualMemory() else {
                return .unavailable(.probeFailed(detail: "host_statistics64 returned an error"))
            }
            let active = UInt64(vm.active_count) * MachHost.pageSize
            let compressed = UInt64(vm.compressor_page_count) * MachHost.pageSize
            return .available(
                sample: "\(Format.bytes(active)) active, \(Format.bytes(compressed)) compressed"
            )
        },

        CapabilityProbe(
            id: "memory.swap",
            title: "Swap usage",
            category: .memory,
            source: "sysctl vm.swapusage"
        ) {
            guard let swap = SwapUsage.read() else {
                return .unavailable(.probeFailed(detail: "vm.swapusage could not be read"))
            }
            return .available(
                sample: "\(Format.bytes(swap.used)) used of \(Format.bytes(swap.total))"
            )
        },

        CapabilityProbe(
            id: "memory.pressure",
            title: "Memory pressure level",
            category: .memory,
            source: "sysctl kern.memorystatus_vm_pressure_level"
        ) {
            guard let level = MemoryPressure.level() else {
                return .unavailable(.probeFailed(detail: "pressure level sysctl unreadable"))
            }
            return .available(sample: level.label)
        },

        CapabilityProbe(
            id: "memory.swap_rate",
            title: "Swap rate counters",
            category: .memory,
            source: "sysctl vm.compressor.swapper.swapouts_total and siblings"
        ) {
            guard let counters = MemoryPressure.swapCounters() else {
                return .unavailable(.probeFailed(detail: "compressor counters unreadable"))
            }
            return .available(
                sample: "\(counters.swapOutsTotal) out "
                    + "(\(counters.swapOutsUnderPressure) under pressure), "
                    + "\(counters.swapInsTotal) in"
            )
        },
    ]

    // MARK: - CPU

    static let cpu: [CapabilityProbe] = [
        CapabilityProbe(
            id: "cpu.load",
            title: "Per-CPU load ticks",
            category: .cpu,
            source: "host_processor_info / PROCESSOR_CPU_LOAD_INFO"
        ) {
            guard let ticks = MachHost.processorTicks(), !ticks.isEmpty else {
                return .unavailable(.probeFailed(detail: "host_processor_info returned no CPUs"))
            }
            return .available(sample: "\(ticks.count) CPUs reporting")
        },
    ]

    // MARK: - GPU

    static let gpu: [CapabilityProbe] = [
        CapabilityProbe(
            id: "gpu.utilization",
            title: "GPU utilization",
            category: .gpu,
            source: "IOKit IOAccelerator / PerformanceStatistics"
        ) {
            guard let statistics = IOKitRegistry.gpuPerformanceStatistics() else {
                return .unavailable(
                    .unsupportedOnThisMac(detail: "no IOAccelerator service exposes statistics")
                )
            }
            guard let utilization = statistics["Device Utilization %"] as? Int else {
                return .unavailable(
                    .probeFailed(detail: "PerformanceStatistics lacks Device Utilization %")
                )
            }
            return .available(sample: "\(utilization)%")
        },

        CapabilityProbe(
            id: "gpu.memory",
            title: "GPU allocated memory",
            category: .gpu,
            source: "IOKit IOAccelerator / PerformanceStatistics"
        ) {
            guard let statistics = IOKitRegistry.gpuPerformanceStatistics(),
                  let allocated = statistics["Alloc system memory"] as? Int
            else {
                return .unavailable(
                    .unsupportedOnThisMac(detail: "accelerator does not report allocated memory")
                )
            }
            return .available(sample: Format.bytes(UInt64(allocated)))
        },
    ]

    // MARK: - Thermal

    static let thermal: [CapabilityProbe] = [
        CapabilityProbe(
            id: "thermal.state",
            title: "Thermal state",
            category: .thermal,
            source: "ProcessInfo.processInfo.thermalState"
        ) {
            let names = ["nominal", "fair", "serious", "critical"]
            let raw = ProcessInfo.processInfo.thermalState.rawValue
            let label = names.indices.contains(raw) ? names[raw] : "unknown(\(raw))"
            return .available(sample: label)
        },

        CapabilityProbe(
            id: "thermal.performance_limit",
            title: "Thermal and performance warning levels",
            category: .thermal,
            source: "pmset -g therm"
        ) {
            do {
                let output = try CommandRunner.run(pmsetPath, ["-g", "therm"])
                // A cool machine reports that nothing has been recorded, which
                // is a successful read, not a missing capability.
                let firstLine = output.split(separator: "\n").first.map(String.init) ?? "no output"
                return .available(sample: firstLine)
            } catch {
                return .unavailable(.probeFailed(detail: "pmset -g therm failed: \(error)"))
            }
        },

        CapabilityProbe(
            id: "thermal.temperature",
            title: "CPU die temperature",
            category: .thermal,
            source: "SMC via powermetrics or private IOHID"
        ) {
            .unavailable(.requiresPrivilege(
                detail: """
                    SMC access requires root or private frameworks. mac-sitrep \
                    never uses root by design (ARCHITECTURE #4), so this is \
                    declined rather than unavailable.
                    """,
                alternative: "thermal.state"
            ))
        },

        CapabilityProbe(
            id: "thermal.fan",
            title: "Fan speed",
            category: .thermal,
            source: "SMC via private IOHID"
        ) {
            .unavailable(.requiresPrivilege(
                detail: "Fan RPM comes from the same root-gated SMC path as die temperature.",
                alternative: "thermal.state"
            ))
        },
    ]

    // MARK: - Disk

    static let disk: [CapabilityProbe] = [
        CapabilityProbe(
            id: "disk.capacity",
            title: "Disk capacity",
            category: .disk,
            source: "statfs(2) on /"
        ) {
            var stats = statfs()
            guard statfs("/", &stats) == 0 else {
                return .unavailable(.probeFailed(detail: "statfs on / failed"))
            }
            let free = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
            let total = UInt64(stats.f_blocks) * UInt64(stats.f_bsize)
            return .available(sample: "\(Format.bytes(free)) free of \(Format.bytes(total))")
        },

        CapabilityProbe(
            id: "disk.io",
            title: "Disk I/O counters",
            category: .disk,
            source: "IOKit IOBlockStorageDriver / Statistics"
        ) {
            guard let stats = IOKitRegistry.blockStorageStatistics() else {
                return .unavailable(
                    .probeFailed(detail: "IOBlockStorageDriver exposed no Statistics")
                )
            }
            return .available(
                sample: "\(Format.bytes(stats.read)) read, \(Format.bytes(stats.written)) written"
            )
        },
    ]

    // MARK: - Network

    static let network: [CapabilityProbe] = [
        CapabilityProbe(
            id: "network.io",
            title: "System-wide network I/O",
            category: .network,
            source: "sysctl NET_RT_IFLIST2 / if_msghdr2"
        ) {
            guard let totals = NetworkInterfaces.totals() else {
                return .unavailable(.probeFailed(detail: "getifaddrs returned no interface data"))
            }
            return .available(
                sample: "\(Format.bytes(totals.received)) in, \(Format.bytes(totals.sent)) out"
            )
        },

        CapabilityProbe(
            id: "network.per_process",
            title: "Per-process network I/O",
            category: .network,
            source: "none"
        ) {
            .unavailable(.noPublicAPI(
                detail: """
                    macOS exposes no per-PID network byte counter at any \
                    privilege level. nettop uses the private \
                    NetworkStatistics framework and still needs root.
                    """,
                alternative: "network.io"
            ))
        },
    ]

    // MARK: - Process

    static let process: [CapabilityProbe] = [
        CapabilityProbe(
            id: "process.list",
            title: "Process enumeration",
            category: .process,
            source: "proc_listpids(3)"
        ) {
            let pids = ProcessList.pids()
            guard !pids.isEmpty else {
                return .unavailable(.probeFailed(detail: "proc_listpids returned nothing"))
            }
            return .available(sample: "\(pids.count) processes")
        },

        CapabilityProbe(
            id: "process.rusage",
            title: "Per-process resource usage",
            category: .process,
            source: "proc_pid_rusage(2) RUSAGE_INFO_V4"
        ) {
            guard let usage = Rusage.current() else {
                return .unavailable(.probeFailed(detail: "proc_pid_rusage failed on self"))
            }
            return .available(
                sample: "footprint \(Format.bytes(usage.physicalFootprint)), "
                    + "peak \(Format.bytes(usage.lifetimePeakFootprint))"
            )
        },

        CapabilityProbe(
            id: "process.tree",
            title: "Process tree and paths",
            category: .process,
            source: "proc_pidinfo PROC_PIDTBSDINFO, proc_pidpath(3)"
        ) {
            guard let parent = ProcessList.parentPID(pid: getpid()) else {
                return .unavailable(.probeFailed(detail: "PROC_PIDTBSDINFO unreadable for self"))
            }
            let name = ProcessList.name(pid: getpid()) ?? "unknown"
            return .available(sample: "self \(name), parent pid \(parent)")
        },

        CapabilityProbe(
            id: "process.other_users",
            title: "Other users' process statistics",
            category: .process,
            source: "proc_pid_rusage(2) as root"
        ) {
            .unavailable(.requiresPrivilege(
                detail: """
                    Reading rusage for processes owned by other users requires \
                    root. On a single-user Mac every workload that matters is \
                    owned by the current user, so this is disclosed rather \
                    than worked around.
                    """,
                alternative: "process.rusage"
            ))
        },
    ]

    // MARK: - Power

    static let power: [CapabilityProbe] = [
        CapabilityProbe(
            id: "power.sleep_wake",
            title: "Sleep, wake, and reboot history",
            category: .power,
            source: "pmset -g log"
        ) {
            guard CommandRunner.isAvailable(pmsetPath) else {
                return .unavailable(.probeFailed(detail: "\(pmsetPath) is not executable"))
            }
            // The log itself is megabytes and is parsed at sampling time, not
            // here; probing only establishes that the tool is reachable.
            return .available(sample: "pmset available; log parsed at sample time")
        },

        CapabilityProbe(
            id: "power.package",
            title: "Package power draw",
            category: .power,
            source: "powermetrics"
        ) {
            .unavailable(.requiresPrivilege(
                detail: "powermetrics requires root for CPU and GPU power counters.",
                alternative: nil
            ))
        },
    ]
}
