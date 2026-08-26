import Foundation

/// Reads and writes history.
///
/// The one place SQL lives outside `Schema`. Callers deal in model types; if the
/// store were ever replaced, this is the seam.
public final class SampleStore {

    /// Retention tier. Rolled-up rows share the `sample` table, discriminated by
    /// this value.
    public enum Resolution: String, Sendable, CaseIterable {
        case raw
        case minute
        case hour
    }

    public enum EventKind: String, Sendable {
        case daemonStart = "daemon_start"
        case daemonStop = "daemon_stop"
        case healthChange = "health_change"
        case budgetExceeded = "budget_exceeded"
        case sleep
        case wake
        case boot
    }

    private let database: Database
    public let path: String

    public init(database: Database, path: String) {
        self.database = database
        self.path = path
    }

    /// Opens (creating if needed) the store at `path` and migrates it.
    public static func open(path: String) throws -> SampleStore {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let database = try Database(path: path)
        try Schema.migrate(database)
        return SampleStore(database: database, path: path)
    }

    /// Opens the store read-only, for the CLI.
    ///
    /// Read-only means a `sitrep history` invocation can never corrupt what the
    /// daemon is writing, and it fails cleanly when no daemon has ever run.
    public static func openReadOnly(path: String) throws -> SampleStore {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Database.Failure.open("no history at \(path); is the daemon installed?")
        }
        return SampleStore(database: try Database(readOnlyPath: path), path: path)
    }

    public var databaseSizeBytes: UInt64 { Database.totalSizeOnDisk(path: path) }

    // MARK: - Writing

    /// Records the machine, returning its row id.
    public func recordMachine(_ machine: Machine, at date: Date = Date()) throws -> Int {
        let timestamp = date.timeIntervalSince1970

        let insert = try database.prepare(
            """
            INSERT INTO machine(
                hw_model, cpu_brand, ram_bytes, core_count, os_version, os_build,
                first_seen, last_seen)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(hw_model, cpu_brand, ram_bytes, core_count, os_version, os_build)
            DO UPDATE SET last_seen = excluded.last_seen
            """
        )
        insert
            .bind(1, machine.hardwareModel)
            .bind(2, machine.cpuBrand)
            .bind(3, machine.physicalMemoryBytes)
            .bind(4, machine.coreCount)
            .bind(5, machine.osVersion)
            .bind(6, machine.osBuild)
            .bind(7, timestamp)
            .bind(8, timestamp)
        try insert.run()

        let select = try database.prepare(
            """
            SELECT id FROM machine
            WHERE hw_model = ? AND cpu_brand = ? AND ram_bytes = ? AND core_count = ?
              AND os_version = ? AND os_build = ?
            """
        )
        select
            .bind(1, machine.hardwareModel)
            .bind(2, machine.cpuBrand)
            .bind(3, machine.physicalMemoryBytes)
            .bind(4, machine.coreCount)
            .bind(5, machine.osVersion)
            .bind(6, machine.osBuild)
        defer { select.reset() }

        return try select.step() ? select.int(0) : 0
    }

    /// Inserts one sample at the given resolution.
    ///
    /// For raw rows the average and max columns are equal; the distinction only
    /// becomes meaningful after a rollup.
    public func insert(
        _ sample: Sample,
        resolution: Resolution = .raw,
        health: HealthState
    ) throws {
        let statement = try preparedSampleInsert()
        bind(sample, resolution: resolution, health: health, into: statement)
        try statement.run()
    }

    /// Inserts many samples in a single transaction with one prepared statement.
    public func insert(
        _ samples: [(sample: Sample, health: HealthState)],
        resolution: Resolution = .raw
    ) throws {
        guard !samples.isEmpty else { return }

        try database.transaction {
            let statement = try preparedSampleInsert()
            for entry in samples {
                bind(entry.sample, resolution: resolution, health: entry.health, into: statement)
                try statement.run()
            }
        }
    }

    private func preparedSampleInsert() throws -> Statement {
        try database.prepare(
            """
            INSERT OR REPLACE INTO sample(
                ts, resolution, interval_seconds, sample_count,
                mem_total, mem_used, mem_used_max, mem_active, mem_wired,
                mem_compressed, mem_free, swap_used, swap_outs_per_sec,
                swap_outs_per_sec_max, pressure,
                cpu_util, cpu_util_max, cpu_user, cpu_system,
                gpu_util, gpu_mem_alloc, thermal,
                disk_free, disk_read_per_sec, disk_write_per_sec,
                net_rx_per_sec, net_tx_per_sec, health)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        )
    }

    private func bind(
        _ sample: Sample, resolution: Resolution, health: HealthState, into statement: Statement
    ) {
        statement
            .bind(1, sample.timestamp.timeIntervalSince1970)
            .bind(2, resolution.rawValue)
            .bind(3, sample.intervalSeconds)
            .bind(4, 1)
            .bind(5, sample.memory.totalBytes)
            .bind(6, sample.memory.usedBytes)
            .bind(7, sample.memory.usedBytes)
            .bind(8, sample.memory.activeBytes)
            .bind(9, sample.memory.wiredBytes)
            .bind(10, sample.memory.compressedBytes)
            .bind(11, sample.memory.freeBytes)
            .bind(12, sample.memory.swapUsedBytes)
            .bind(13, sample.memory.swapOutsPerSecond)
            .bind(14, sample.memory.swapOutsPerSecond)
            .bind(15, optional: sample.memory.pressure?.rawValue)
            .bind(16, sample.cpu.utilization)
            .bind(17, sample.cpu.utilization)
            .bind(18, sample.cpu.userFraction)
            .bind(19, sample.cpu.systemFraction)
            .bind(20, optional: sample.gpu?.utilization)
            .bind(21, optional: sample.gpu?.allocatedBytes)
            .bind(22, sample.thermal.rawValue)
            .bind(23, sample.disk.freeBytes)
            .bind(24, sample.disk.readBytesPerSecond)
            .bind(25, sample.disk.writtenBytesPerSecond)
            .bind(26, sample.network.receivedBytesPerSecond)
            .bind(27, sample.network.sentBytesPerSecond)
            .bind(28, health.rawValue)
    }

    /// Stores the top consumers for one tick.
    public func insertProcesses(_ processes: [ProcessSample], at date: Date) throws {
        guard !processes.isEmpty else { return }
        let timestamp = date.timeIntervalSince1970

        try database.transaction {
            let pathInsert = try database.prepare(
                "INSERT OR IGNORE INTO path(path) VALUES(?)"
            )
            let pathSelect = try database.prepare("SELECT id FROM path WHERE path = ?")
            let insert = try database.prepare(
                """
                INSERT OR REPLACE INTO process_sample(
                    ts, pid, ppid, name, path_id, footprint, peak_footprint,
                    cpu_util, disk_read, disk_written)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """
            )

            for process in processes {
                var pathID: Int?
                if let path = process.executablePath {
                    pathInsert.bind(1, path)
                    try pathInsert.run()
                    pathSelect.bind(1, path)
                    if try pathSelect.step() { pathID = pathSelect.int(0) }
                    pathSelect.reset()
                }

                insert
                    .bind(1, timestamp)
                    .bind(2, Int(process.pid))
                    .bind(3, optional: process.parentPID.map(Int.init))
                    .bind(4, process.name)
                    .bind(5, optional: pathID)
                    .bind(6, process.physicalFootprint)
                    .bind(7, process.peakFootprint)
                    .bind(8, process.cpuUtilization)
                    .bind(9, process.diskBytesRead)
                    .bind(10, process.diskBytesWritten)
                try insert.run()
            }
        }
    }

    /// Records mac-sitrep's own consumption.
    public func insertDaemonSample(
        footprint: UInt64, peak: UInt64, cpuUtilization: Double, at date: Date
    ) throws {
        let statement = try database.prepare(
            """
            INSERT OR REPLACE INTO daemon_sample(
                ts, footprint, peak_footprint, cpu_util, within_budget)
            VALUES(?,?,?,?,?)
            """
        )
        let withinBudget = peak <= SelfBudget.memoryBytes
            && cpuUtilization <= SelfBudget.cpuFraction
        statement
            .bind(1, date.timeIntervalSince1970)
            .bind(2, footprint)
            .bind(3, peak)
            .bind(4, cpuUtilization)
            .bind(5, withinBudget)
        try statement.run()
    }

    public func record(
        _ kind: EventKind, detail: String? = nil, at date: Date = Date()
    ) throws {
        let statement = try database.prepare(
            "INSERT INTO event(ts, kind, detail) VALUES(?,?,?)"
        )
        statement.bind(1, date.timeIntervalSince1970).bind(2, kind.rawValue)
        if let detail { statement.bind(3, detail) } else { statement.bindNull(3) }
        try statement.run()
    }

    // MARK: - Reading

    /// Aggregate over a window, spanning whatever resolutions cover it.
    public struct Summary: Sendable, Encodable {
        public let since: Date
        public let until: Date
        public let sampleCount: Int
        public let memoryUsedAverage: UInt64
        public let memoryUsedPeak: UInt64
        public let cpuAverage: Double
        public let cpuPeak: Double
        public let swapOutsPeak: Double
        public let worstHealth: HealthState
        public let worstThermal: ThermalState
    }

    public func summary(since: Date, until: Date = Date()) throws -> Summary? {
        let statement = try database.prepare(
            """
            SELECT COUNT(*), AVG(mem_used), MAX(mem_used_max), AVG(cpu_util),
                   MAX(cpu_util_max), MAX(swap_outs_per_sec_max),
                   MIN(ts), MAX(ts)
            FROM sample WHERE ts >= ? AND ts <= ?
            """
        )
        statement.bind(1, since.timeIntervalSince1970).bind(2, until.timeIntervalSince1970)
        defer { statement.reset() }

        guard try statement.step(), statement.int(0) > 0 else { return nil }

        return Summary(
            since: Date(timeIntervalSince1970: statement.double(6)),
            until: Date(timeIntervalSince1970: statement.double(7)),
            sampleCount: statement.int(0),
            memoryUsedAverage: UInt64(max(0, statement.double(1))),
            memoryUsedPeak: statement.uint64(2),
            cpuAverage: statement.double(3),
            cpuPeak: statement.double(4),
            swapOutsPeak: statement.double(5),
            worstHealth: try worstHealth(since: since, until: until),
            worstThermal: try worstThermal(since: since, until: until)
        )
    }

    /// Worst health seen in a window.
    ///
    /// Ordered in SQL by an explicit severity rank rather than alphabetically —
    /// `critical` sorts before `healthy` and `warning` as text, which would
    /// silently return the wrong answer.
    private func worstHealth(since: Date, until: Date) throws -> HealthState {
        let statement = try database.prepare(
            """
            SELECT health FROM sample WHERE ts >= ? AND ts <= ?
            ORDER BY CASE health
                WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END
            LIMIT 1
            """
        )
        statement.bind(1, since.timeIntervalSince1970).bind(2, until.timeIntervalSince1970)
        defer { statement.reset() }

        guard try statement.step() else { return .healthy }
        return HealthState(rawValue: statement.string(0)) ?? .healthy
    }

    private func worstThermal(since: Date, until: Date) throws -> ThermalState {
        let statement = try database.prepare(
            """
            SELECT thermal FROM sample WHERE ts >= ? AND ts <= ?
            ORDER BY CASE thermal
                WHEN 'critical' THEN 0 WHEN 'serious' THEN 1
                WHEN 'fair' THEN 2 ELSE 3 END
            LIMIT 1
            """
        )
        statement.bind(1, since.timeIntervalSince1970).bind(2, until.timeIntervalSince1970)
        defer { statement.reset() }

        guard try statement.step() else { return .nominal }
        return ThermalState(rawValue: statement.string(0)) ?? .nominal
    }

    /// The processes that held the most memory in a window.
    public struct ProcessTotal: Sendable, Encodable {
        public let name: String
        public let peakFootprint: UInt64
        public let averageFootprint: UInt64
        public let peakCPU: Double
        public let observations: Int
    }

    public func topProcesses(
        since: Date, until: Date = Date(), limit: Int = 10
    ) throws -> [ProcessTotal] {
        let statement = try database.prepare(
            """
            SELECT name, MAX(peak_footprint), AVG(footprint), MAX(cpu_util), COUNT(*)
            FROM process_sample WHERE ts >= ? AND ts <= ?
            GROUP BY name ORDER BY MAX(peak_footprint) DESC LIMIT ?
            """
        )
        statement
            .bind(1, since.timeIntervalSince1970)
            .bind(2, until.timeIntervalSince1970)
            .bind(3, limit)

        var results: [ProcessTotal] = []
        try statement.forEachRow { row in
            results.append(
                ProcessTotal(
                    name: row.string(0),
                    peakFootprint: row.uint64(1),
                    averageFootprint: UInt64(max(0, row.double(2))),
                    peakCPU: row.double(3),
                    observations: row.int(4)
                )
            )
        }
        return results
    }

    public struct EventRecord: Sendable, Encodable {
        public let timestamp: Date
        public let kind: String
        public let detail: String?
    }

    public func events(since: Date, until: Date = Date()) throws -> [EventRecord] {
        let statement = try database.prepare(
            "SELECT ts, kind, detail FROM event WHERE ts >= ? AND ts <= ? ORDER BY ts"
        )
        statement.bind(1, since.timeIntervalSince1970).bind(2, until.timeIntervalSince1970)

        var results: [EventRecord] = []
        try statement.forEachRow { row in
            results.append(
                EventRecord(
                    timestamp: Date(timeIntervalSince1970: row.double(0)),
                    kind: row.string(1),
                    detail: row.isNull(2) ? nil : row.string(2)
                )
            )
        }
        return results
    }

    /// mac-sitrep's own cost over a window — SPEC principle 6.
    public struct DaemonCost: Sendable, Encodable {
        public let peakFootprint: UInt64
        public let averageFootprint: UInt64
        public let peakCPU: Double
        public let averageCPU: Double
        public let sampleCount: Int
        public let breachCount: Int

        public var withinBudget: Bool { breachCount == 0 }
    }

    public func daemonCost(since: Date, until: Date = Date()) throws -> DaemonCost? {
        let statement = try database.prepare(
            """
            SELECT MAX(peak_footprint), AVG(footprint), MAX(cpu_util), AVG(cpu_util),
                   COUNT(*), SUM(CASE WHEN within_budget = 0 THEN 1 ELSE 0 END)
            FROM daemon_sample WHERE ts >= ? AND ts <= ?
            """
        )
        statement.bind(1, since.timeIntervalSince1970).bind(2, until.timeIntervalSince1970)
        defer { statement.reset() }

        guard try statement.step(), statement.int(4) > 0 else { return nil }

        return DaemonCost(
            peakFootprint: statement.uint64(0),
            averageFootprint: UInt64(max(0, statement.double(1))),
            peakCPU: statement.double(2),
            averageCPU: statement.double(3),
            sampleCount: statement.int(4),
            breachCount: statement.int(5)
        )
    }

    public func sampleCount(resolution: Resolution) throws -> Int {
        let statement = try database.prepare(
            "SELECT COUNT(*) FROM sample WHERE resolution = ?"
        )
        statement.bind(1, resolution.rawValue)
        defer { statement.reset() }
        return try statement.step() ? statement.int(0) : 0
    }

    /// Exposes the connection to `Rollup`, which owns its own aggregation SQL.
    var connection: Database { database }
}
