import Darwin
import Foundation

/// Composes the `Support` readers into system readings and samples.
///
/// Every source is optional: a machine without an accelerator, or a sysctl that
/// disappears in a future macOS, degrades that field to `nil` rather than
/// failing the whole read. `sitrep doctor` is where such a gap gets explained;
/// sampling should keep working around it.
public enum SystemSampler {

    /// Default gap between the two readings a one-shot `Sample` needs.
    ///
    /// A compromise. Shorter is snappier but makes CPU utilization noisy, since
    /// scheduler quanta start to dominate the tick delta. Longer is steadier but
    /// makes the CLI feel slow. 500 ms reads as instant and averages out most of
    /// the jitter.
    public static let defaultInterval: TimeInterval = 0.5

    /// One instantaneous read of every source. Cheap, no sleeping.
    ///
    /// This is what the daemon calls on each tick, holding the previous reading
    /// to delta against.
    public static func read() -> SystemReading {
        let pageSize = MachHost.pageSize

        let pages: SystemReading.MemoryPages
        if let vm = MachHost.virtualMemory() {
            pages = SystemReading.MemoryPages(
                active: UInt64(vm.active_count) * pageSize,
                inactive: UInt64(vm.inactive_count) * pageSize,
                wired: UInt64(vm.wire_count) * pageSize,
                compressed: UInt64(vm.compressor_page_count) * pageSize,
                free: UInt64(vm.free_count) * pageSize
            )
        } else {
            pages = SystemReading.MemoryPages(
                active: 0, inactive: 0, wired: 0, compressed: 0, free: 0
            )
        }

        var diskFree: UInt64 = 0
        var diskTotal: UInt64 = 0
        var statistics = statfs()
        if statfs("/", &statistics) == 0 {
            diskFree = UInt64(statistics.f_bavail) * UInt64(statistics.f_bsize)
            diskTotal = UInt64(statistics.f_blocks) * UInt64(statistics.f_bsize)
        }

        let diskIO = IOKitRegistry.blockStorageStatistics()
        let network = NetworkInterfaces.totals()

        var gpu: SystemReading.GPUReading?
        if let statistics = IOKitRegistry.gpuPerformanceStatistics(),
           let utilization = statistics["Device Utilization %"] as? Int {
            gpu = SystemReading.GPUReading(
                utilizationPercent: utilization,
                allocatedBytes: UInt64(statistics["Alloc system memory"] as? Int ?? 0),
                inUseBytes: UInt64(statistics["In use system memory"] as? Int ?? 0)
            )
        }

        return SystemReading(
            timestamp: Date(),
            physicalMemoryBytes: Sysctl.integer("hw.memsize")
                ?? ProcessInfo.processInfo.physicalMemory,
            memoryPages: pages,
            swap: SwapUsage.read(),
            pressure: MemoryPressure.level(),
            thermal: .current(),
            diskFreeBytes: diskFree,
            diskTotalBytes: diskTotal,
            gpu: gpu,
            cpuTicks: MachHost.processorTicks() ?? [],
            diskBytesRead: diskIO?.read,
            diskBytesWritten: diskIO?.written,
            networkBytesReceived: network?.received,
            networkBytesSent: network?.sent,
            swapCounters: MemoryPressure.swapCounters()
        )
    }

    /// Takes two readings `interval` apart and derives a sample.
    ///
    /// Blocks for `interval`. That cost is unavoidable for a one-shot command:
    /// CPU, disk, and network figures are cumulative counters, so there is no
    /// way to report a current rate from a single read.
    public static func sample(interval: TimeInterval = defaultInterval) -> Sample? {
        let first = read()
        Thread.sleep(forTimeInterval: interval)
        let second = read()

        return Sample(from: first, to: second)
    }
}
