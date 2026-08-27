import Foundation

/// One instantaneous read of every system source.
///
/// Deliberately raw. Several of these fields — CPU ticks, disk and network byte
/// totals, swap counters — are **cumulative since boot**, so a single reading
/// cannot answer "what is happening now". Deriving a rate needs two readings and
/// the time between them, which is what ``Sample`` does.
///
/// The split exists because the one-shot CLI and the daemon need different
/// things from the same sources. The CLI takes two readings a few hundred
/// milliseconds apart and throws the first away. The daemon holds the previous
/// reading in memory and deltas against it on every tick, never sleeping. Both
/// use this type.
public struct SystemReading: Sendable {
    public let timestamp: Date

    // Absolute — meaningful from a single read.
    public let physicalMemoryBytes: UInt64
    public let memoryPages: MemoryPages
    public let swap: SwapUsage.Snapshot?
    public let pressure: MemoryPressure.Level?
    public let thermal: ThermalState
    public let diskFreeBytes: UInt64
    public let diskTotalBytes: UInt64
    public let gpu: GPUReading?

    // Cumulative since boot — meaningless without a second read.
    public let cpuTicks: [MachHost.CPUTicks]
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    public let networkBytesReceived: UInt64?
    public let networkBytesSent: UInt64?
    public let swapCounters: MemoryPressure.SwapCounters?

    /// Page counts straight from `host_statistics64`, in bytes.
    public struct MemoryPages: Sendable, Equatable {
        public let active: UInt64
        public let inactive: UInt64
        public let wired: UInt64
        public let compressed: UInt64
        public let free: UInt64
        /// Anonymous pages — memory owned by processes, not backed by a file.
        public let anonymous: UInt64
        /// File-backed pages: the disk cache.
        public let fileBacked: UInt64
        /// Pages an app has told the kernel it may discard without writing back.
        public let purgeable: UInt64

        /// Memory attributable to running applications.
        ///
        /// Matches Activity Monitor's "App Memory" — anonymous pages minus what
        /// apps have marked discardable.
        public var appMemory: UInt64 { anonymous >= purgeable ? anonymous - purgeable : 0 }

        /// The disk cache, which the kernel reclaims on demand.
        public var cachedFiles: UInt64 { fileBacked + purgeable }

        /// Memory that cannot be reclaimed without compressing or swapping:
        /// app memory + wired + compressed.
        ///
        /// This matches Activity Monitor's "Memory Used", which means a reader
        /// can cross-check it against a tool they already trust.
        ///
        /// It is still deliberately smaller than `top`'s total − free, which
        /// counts the file cache and reads ~15 GB on a 16 GB Mac — implying a
        /// crisis that is not happening.
        ///
        /// The subtlety, and the reason this was wrong until 2026-08-27: the
        /// obvious formula is `active + wired + compressed`, but `inactive` is
        /// not uniformly reclaimable. It holds both file-backed pages (free to
        /// drop) *and* anonymous pages that belong to processes and are dirty.
        /// Reclaiming the latter costs a compression or a swap, so excluding
        /// them understated used memory by 1.2 GB on a real 16 GB machine and
        /// made the number disagree with Activity Monitor for no good reason.
        /// See ARCHITECTURE #40, which supersedes #18.
        public var used: UInt64 { appMemory + wired + compressed }
    }

    public struct GPUReading: Sendable, Equatable {
        public let utilizationPercent: Int
        public let allocatedBytes: UInt64
        public let inUseBytes: UInt64
    }
}

/// A derived view of the machine over an interval, carrying rates.
///
/// This is what gets displayed, serialized to `--json`, and — from Milestone 3 —
/// persisted. Absolute values pass through from the later reading; anything
/// cumulative becomes a per-second rate.
public struct Sample: Sendable, Encodable {
    public let timestamp: Date

    /// Seconds between the two readings this was derived from. Reported because
    /// a rate is uninterpretable without it, and short intervals are noisy.
    public let intervalSeconds: Double

    public let memory: Memory
    public let cpu: CPU
    public let gpu: GPU?
    public let thermal: ThermalState
    public let disk: Disk
    public let network: Network

    public var health: HealthState { HealthState(sample: self) }

    public struct Memory: Sendable, Encodable, Equatable {
        public let totalBytes: UInt64
        public let usedBytes: UInt64
        public let activeBytes: UInt64
        public let inactiveBytes: UInt64
        public let wiredBytes: UInt64
        public let compressedBytes: UInt64
        public let freeBytes: UInt64
        /// Activity Monitor's "App Memory".
        public let appMemoryBytes: UInt64
        /// Activity Monitor's "Cached Files" — reclaimable on demand.
        public let cachedFilesBytes: UInt64

        public let swapUsedBytes: UInt64
        public let swapTotalBytes: UInt64
        public let pressure: MemoryPressure.Level?

        /// Swap-out events per second over the interval.
        ///
        /// This, not ``swapUsedBytes``, is what the zero-swap policy is defined
        /// on. The swap *file* is sticky once macOS grows it and does not return
        /// to zero without a reboot, so a level-based policy would read as
        /// permanently violated (ARCHITECTURE #6).
        public let swapOutsPerSecond: Double

        /// Swap-outs per second attributable to memory pressure specifically.
        /// A machine swapping for other reasons is not necessarily short of RAM.
        public let pressureSwapOutsPerSecond: Double

        public var usedFraction: Double {
            totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
        }

        /// Memory obtainable without compressing or swapping: everything that is
        /// not already committed to running work.
        ///
        /// Defined as total − used so it stays consistent with ``usedBytes``.
        /// The earlier definition, free + inactive, counted anonymous inactive
        /// pages as available when reclaiming those costs a swap.
        public var availableBytes: UInt64 {
            totalBytes > usedBytes ? totalBytes - usedBytes : 0
        }
    }

    public struct CPU: Sendable, Encodable, Equatable {
        /// Busy fraction across all cores, 0...1.
        public let utilization: Double
        public let userFraction: Double
        public let systemFraction: Double
        public let idleFraction: Double
        public let coreCount: Int
    }

    public struct GPU: Sendable, Encodable, Equatable {
        public let utilization: Double
        public let allocatedBytes: UInt64
        public let inUseBytes: UInt64
    }

    public struct Disk: Sendable, Encodable, Equatable {
        public let freeBytes: UInt64
        public let totalBytes: UInt64
        public let readBytesPerSecond: Double
        public let writtenBytesPerSecond: Double

        public var freeFraction: Double {
            totalBytes == 0 ? 0 : Double(freeBytes) / Double(totalBytes)
        }
    }

    public struct Network: Sendable, Encodable, Equatable {
        public let receivedBytesPerSecond: Double
        public let sentBytesPerSecond: Double
        public let totalReceivedBytes: UInt64
        public let totalSentBytes: UInt64
    }
}

// MARK: - Derivation

extension Sample {

    /// Derives a sample from two readings.
    ///
    /// Returns `nil` if the readings are not separated in time, since every rate
    /// would divide by zero. Counter deltas are clamped at zero: the kernel's
    /// cumulative counters should only rise, but an interface disappearing
    /// between readings can make a total drop, and a negative "rate" would be
    /// nonsense rather than informative.
    public init?(from previous: SystemReading, to current: SystemReading) {
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return nil }

        func rate(_ later: UInt64?, _ earlier: UInt64?) -> Double {
            guard let later, let earlier, later >= earlier else { return 0 }
            return Double(later - earlier) / interval
        }

        timestamp = current.timestamp
        intervalSeconds = interval
        thermal = current.thermal

        let pages = current.memoryPages
        memory = Memory(
            // Installed RAM from hw.memsize, not the sum of the page buckets
            // above: host_statistics64 also tracks speculative and purgeable
            // pages that those five categories do not cover, so summing them
            // under-reports total memory by roughly a gigabyte on a 16 GB Mac.
            totalBytes: current.physicalMemoryBytes,
            usedBytes: pages.used,
            activeBytes: pages.active,
            inactiveBytes: pages.inactive,
            wiredBytes: pages.wired,
            compressedBytes: pages.compressed,
            freeBytes: pages.free,
            appMemoryBytes: pages.appMemory,
            cachedFilesBytes: pages.cachedFiles,
            swapUsedBytes: current.swap?.used ?? 0,
            swapTotalBytes: current.swap?.total ?? 0,
            pressure: current.pressure,
            swapOutsPerSecond: rate(
                current.swapCounters?.swapOutsTotal, previous.swapCounters?.swapOutsTotal
            ),
            pressureSwapOutsPerSecond: rate(
                current.swapCounters?.swapOutsUnderPressure,
                previous.swapCounters?.swapOutsUnderPressure
            )
        )

        cpu = Self.deriveCPU(from: previous.cpuTicks, to: current.cpuTicks)

        gpu = current.gpu.map {
            GPU(
                utilization: Double($0.utilizationPercent) / 100,
                allocatedBytes: $0.allocatedBytes,
                inUseBytes: $0.inUseBytes
            )
        }

        disk = Disk(
            freeBytes: current.diskFreeBytes,
            totalBytes: current.diskTotalBytes,
            readBytesPerSecond: rate(current.diskBytesRead, previous.diskBytesRead),
            writtenBytesPerSecond: rate(current.diskBytesWritten, previous.diskBytesWritten)
        )

        network = Network(
            receivedBytesPerSecond: rate(
                current.networkBytesReceived, previous.networkBytesReceived
            ),
            sentBytesPerSecond: rate(current.networkBytesSent, previous.networkBytesSent),
            totalReceivedBytes: current.networkBytesReceived ?? 0,
            totalSentBytes: current.networkBytesSent ?? 0
        )
    }

    /// CPU utilization from the tick delta across all cores.
    ///
    /// Ticks are per-core and cumulative; summing deltas across cores and
    /// dividing by the summed total gives machine-wide utilization where 1.0
    /// means every core saturated. Reporting per-core percentages that can sum
    /// to 1000% is the `top` convention and is more confusing than useful here.
    static func deriveCPU(
        from previous: [MachHost.CPUTicks], to current: [MachHost.CPUTicks]
    ) -> CPU {
        // Core count can change between readings if a core is offlined; zip
        // pairs only what both readings have rather than crashing on the index.
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0

        for (before, after) in zip(previous, current) {
            user &+= UInt64(after.user &- before.user)
            system &+= UInt64(after.system &- before.system)
            idle &+= UInt64(after.idle &- before.idle)
            nice &+= UInt64(after.nice &- before.nice)
        }

        let total = user + system + idle + nice
        guard total > 0 else {
            return CPU(
                utilization: 0, userFraction: 0, systemFraction: 0,
                idleFraction: 1, coreCount: current.count
            )
        }

        let divisor = Double(total)
        // Nice time is user time at a different priority, so it counts as user.
        let userFraction = Double(user + nice) / divisor
        let systemFraction = Double(system) / divisor
        let idleFraction = Double(idle) / divisor

        return CPU(
            utilization: 1 - idleFraction,
            userFraction: userFraction,
            systemFraction: systemFraction,
            idleFraction: idleFraction,
            coreCount: current.count
        )
    }
}

extension MemoryPressure.Level: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}
