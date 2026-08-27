import Foundation
import Testing
@testable import SitrepCore

/// Creates a throwaway database per test. Real SQLite on disk rather than a
/// fake: the C-API binding, the DDL, and the aggregation SQL are the things
/// under test, and a mock would exercise none of them.
private func withStore<T>(_ body: (SampleStore) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "sitrep-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }

    let store = try SampleStore.open(path: directory + "/history.db")
    return try body(store)
}

/// A sample with controllable values, for tests that need known inputs.
private func makeSample(
    at date: Date,
    memoryUsed: UInt64 = 8 << 30,
    cpu: Double = 0.25,
    swapOuts: Double = 0,
    thermal: ThermalState = .nominal,
    interval: Double = 10
) -> Sample {
    Sample(
        timestamp: date,
        intervalSeconds: interval,
        memory: .init(
            totalBytes: 16 << 30, usedBytes: memoryUsed, activeBytes: memoryUsed,
            inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0,
            freeBytes: (16 << 30) - memoryUsed,
            appMemoryBytes: memoryUsed, cachedFilesBytes: 0,
            swapUsedBytes: 0, swapTotalBytes: 0,
            pressure: .normal, swapOutsPerSecond: swapOuts, pressureSwapOutsPerSecond: 0
        ),
        cpu: .init(
            utilization: cpu, userFraction: cpu * 0.6,
            systemFraction: cpu * 0.4, idleFraction: 1 - cpu, coreCount: 10
        ),
        gpu: .init(utilization: 0.1, allocatedBytes: 1 << 30, inUseBytes: 1 << 29),
        thermal: thermal,
        disk: .init(
            freeBytes: 100 << 30, totalBytes: 500 << 30,
            readBytesPerSecond: 1000, writtenBytesPerSecond: 500
        ),
        network: .init(
            receivedBytesPerSecond: 100, sentBytesPerSecond: 50,
            totalReceivedBytes: 1 << 30, totalSentBytes: 1 << 29
        )
    )
}

@Suite("Database")
struct DatabaseTests {

    @Test("Migration creates the schema and is idempotent")
    func migrationIsIdempotent() throws {
        let directory = NSTemporaryDirectory() + "sitrep-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/history.db"

        let first = try SampleStore.open(path: path)
        #expect(try Schema.readVersion(first.connection) == Schema.version)

        // Reopening must not attempt to recreate tables.
        let second = try SampleStore.open(path: path)
        #expect(try Schema.readVersion(second.connection) == Schema.version)
    }

    @Test("A v1 database migrates by clearing incomparable samples")
    func v1MigratesByClearingSamples() throws {
        // The v1 → v2 change redefined used memory, so old rows cannot be mixed
        // with new ones. Samples are dropped; events and machine identity are not.
        try withStore { store in
            try store.insert(makeSample(at: Date().addingTimeInterval(-60)), health: .healthy)
            try store.record(.daemonStart, detail: "before migration")
            #expect(try store.sampleCount(resolution: .raw) == 1)

            try store.connection.execute("UPDATE schema_version SET version = 1")
            try Schema.migrate(store.connection)

            #expect(try Schema.readVersion(store.connection) == Schema.version)
            #expect(try store.sampleCount(resolution: .raw) == 0, "samples cleared")

            let events = try store.events(since: Date().addingTimeInterval(-600))
            #expect(events.contains { $0.kind == "daemon_start" }, "events survive")
            #expect(events.contains { $0.kind == "schema_migration" }, "the gap is explained")
        }
    }

    @Test("Large UInt64 values survive the round trip")
    func largeUnsignedValuesRoundTrip() throws {
        // SQLite has no unsigned type; values are stored by bit pattern. A
        // naive Int64 cast would corrupt anything above Int64.max.
        try withStore { store in
            let huge: UInt64 = 18_000_000_000_000_000_000
            let statement = try store.connection.prepare("SELECT ?")
            statement.bind(1, huge)
            #expect(try statement.step())
            #expect(statement.uint64(0) == huge)
        }
    }

    @Test("A failing transaction rolls back")
    func transactionRollsBack() throws {
        try withStore { store in
            struct Boom: Error {}

            #expect(throws: Boom.self) {
                try store.connection.transaction {
                    try store.record(.daemonStart, detail: "should not survive")
                    throw Boom()
                }
            }

            let events = try store.events(since: Date().addingTimeInterval(-60))
            #expect(events.isEmpty)
        }
    }
}

@Suite("Sample store")
struct SampleStoreTests {

    @Test("A sample round-trips into a summary")
    func sampleRoundTrips() throws {
        try withStore { store in
            let now = Date()
            try store.insert(makeSample(at: now, memoryUsed: 9 << 30, cpu: 0.4), health: .healthy)

            let summary = try #require(try store.summary(since: now.addingTimeInterval(-60)))
            #expect(summary.sampleCount == 1)
            #expect(summary.memoryUsedPeak == 9 << 30)
            #expect(abs(summary.cpuPeak - 0.4) < 0.0001)
        }
    }

    @Test("Worst health is ranked by severity, not alphabetically")
    func worstHealthIsRankedBySeverity() throws {
        // 'critical' < 'healthy' < 'warning' as text, so a plain ORDER BY would
        // return the wrong answer for two of the three cases.
        try withStore { store in
            let start = Date().addingTimeInterval(-300)
            try store.insert(makeSample(at: start), health: .healthy)
            try store.insert(makeSample(at: start.addingTimeInterval(10)), health: .warning)
            try store.insert(makeSample(at: start.addingTimeInterval(20)), health: .healthy)

            let summary = try #require(try store.summary(since: start.addingTimeInterval(-60)))
            #expect(summary.worstHealth == .warning)
        }
    }

    @Test("Worst thermal state is ranked by severity")
    func worstThermalIsRankedBySeverity() throws {
        try withStore { store in
            let start = Date().addingTimeInterval(-300)
            try store.insert(makeSample(at: start, thermal: .nominal), health: .healthy)
            try store.insert(
                makeSample(at: start.addingTimeInterval(10), thermal: .serious), health: .healthy
            )
            try store.insert(
                makeSample(at: start.addingTimeInterval(20), thermal: .fair), health: .healthy
            )

            let summary = try #require(try store.summary(since: start.addingTimeInterval(-60)))
            #expect(summary.worstThermal == .serious)
        }
    }

    @Test("Batch insert writes every sample")
    func batchInsertWritesAll() throws {
        try withStore { store in
            let start = Date().addingTimeInterval(-600)
            let batch = (0..<50).map {
                (sample: makeSample(at: start.addingTimeInterval(Double($0) * 10)),
                 health: HealthState.healthy)
            }
            try store.insert(batch)

            #expect(try store.sampleCount(resolution: .raw) == 50)
        }
    }

    @Test("Machine is recorded once and updated on reopen")
    func machineIsDeduplicated() throws {
        try withStore { store in
            let machine = Machine.current()
            let first = try store.recordMachine(machine)
            let second = try store.recordMachine(machine)

            #expect(first == second, "the same machine should not create a second row")
            #expect(first > 0)
        }
    }

    @Test("Process samples aggregate by name")
    func processSamplesAggregate() throws {
        try withStore { store in
            let now = Date()
            let process = ProcessSample(
                pid: 1234, parentPID: 1, name: "ollama",
                executablePath: "/usr/local/bin/ollama",
                physicalFootprint: 4 << 30, peakFootprint: 6 << 30,
                diskBytesRead: 100, diskBytesWritten: 50, cpuUtilization: 1.5
            )
            // Past timestamps: topProcesses defaults `until` to now, so rows
            // stamped in the future would be filtered out.
            try store.insertProcesses([process], at: now.addingTimeInterval(-20))
            try store.insertProcesses([process], at: now.addingTimeInterval(-10))

            let totals = try store.topProcesses(since: now.addingTimeInterval(-60))
            let ollama = try #require(totals.first { $0.name == "ollama" })
            #expect(ollama.peakFootprint == 6 << 30)
            #expect(ollama.observations == 2)
        }
    }

    @Test("Daemon self-measurement records budget breaches")
    func daemonCostRecordsBreaches() throws {
        try withStore { store in
            let now = Date()
            try store.insertDaemonSample(
                footprint: 20 << 20, peak: 30 << 20, cpuUtilization: 0.005,
                at: now.addingTimeInterval(-20)
            )
            try store.insertDaemonSample(
                footprint: 200 << 20, peak: 200 << 20, cpuUtilization: 0.5,
                at: now.addingTimeInterval(-10)
            )

            let cost = try #require(try store.daemonCost(since: now.addingTimeInterval(-60)))
            #expect(cost.sampleCount == 2)
            #expect(cost.breachCount == 1)
            #expect(!cost.withinBudget)
        }
    }

    @Test("Read-only open fails cleanly when no history exists")
    func readOnlyOpenFailsCleanly() {
        #expect(throws: (any Error).self) {
            try SampleStore.openReadOnly(path: "/nonexistent/path/history.db")
        }
    }
}

@Suite("Rollup")
struct RollupTests {

    @Test("Aggregation averages rates and keeps peaks")
    func aggregationAveragesAndKeepsPeaks() throws {
        try withStore { store in
            // Six samples inside one minute bucket, with a single CPU spike.
            let bucketStart = Date(timeIntervalSince1970: 1_700_000_040)
            for index in 0..<6 {
                let cpu = index == 3 ? 0.9 : 0.1
                try store.insert(
                    makeSample(
                        at: bucketStart.addingTimeInterval(Double(index) * 10),
                        memoryUsed: UInt64(index + 1) << 30, cpu: cpu
                    ),
                    health: .healthy
                )
            }

            try Rollup.aggregate(
                store: store, from: .raw, to: .minute, bucketSeconds: 60,
                olderThan: bucketStart.addingTimeInterval(3600)
            )

            #expect(try store.sampleCount(resolution: .minute) == 1)

            let statement = try store.connection.prepare(
                """
                SELECT cpu_util, cpu_util_max, mem_used, mem_used_max, sample_count
                FROM sample WHERE resolution = 'minute'
                """
            )
            #expect(try statement.step())

            // Average of five 0.1s and one 0.9 is ~0.233; the peak must survive.
            #expect(abs(statement.double(0) - 0.2333) < 0.01)
            #expect(abs(statement.double(1) - 0.9) < 0.0001)
            #expect(statement.uint64(3) == 6 << 30, "peak memory must not be averaged away")
            #expect(statement.int(4) == 6)
        }
    }

    @Test("Aggregation keeps the worst level, not the average")
    func aggregationKeepsWorstLevel() throws {
        try withStore { store in
            let bucketStart = Date(timeIntervalSince1970: 1_700_000_040)
            try store.insert(makeSample(at: bucketStart, thermal: .nominal), health: .healthy)
            try store.insert(
                makeSample(at: bucketStart.addingTimeInterval(10), thermal: .serious),
                health: .critical
            )
            try store.insert(
                makeSample(at: bucketStart.addingTimeInterval(20), thermal: .nominal),
                health: .healthy
            )

            try Rollup.aggregate(
                store: store, from: .raw, to: .minute, bucketSeconds: 60,
                olderThan: bucketStart.addingTimeInterval(3600)
            )

            let statement = try store.connection.prepare(
                "SELECT thermal, health FROM sample WHERE resolution = 'minute'"
            )
            #expect(try statement.step())
            #expect(statement.string(0) == "serious", "worst thermal must survive rollup")
            #expect(statement.string(1) == "critical", "worst health must survive rollup")
        }
    }

    @Test("Aggregation is idempotent")
    func aggregationIsIdempotent() throws {
        try withStore { store in
            let bucketStart = Date(timeIntervalSince1970: 1_700_000_040)
            for index in 0..<6 {
                try store.insert(
                    makeSample(at: bucketStart.addingTimeInterval(Double(index) * 10)),
                    health: .healthy
                )
            }

            for _ in 0..<3 {
                try Rollup.aggregate(
                    store: store, from: .raw, to: .minute, bucketSeconds: 60,
                    olderThan: bucketStart.addingTimeInterval(3600)
                )
            }

            // The bucket timestamp is deterministic, so repeats replace rather
            // than accumulate.
            #expect(try store.sampleCount(resolution: .minute) == 1)
        }
    }

    @Test("Pruning removes aged rows and keeps recent ones")
    func pruningRemovesAgedRows() throws {
        try withStore { store in
            let now = Date()
            try store.insert(makeSample(at: now.addingTimeInterval(-72 * 3600)), health: .healthy)
            try store.insert(makeSample(at: now.addingTimeInterval(-1 * 3600)), health: .healthy)
            #expect(try store.sampleCount(resolution: .raw) == 2)

            try Rollup.prune(
                store: store, resolution: .raw, before: now.addingTimeInterval(-48 * 3600)
            )
            #expect(try store.sampleCount(resolution: .raw) == 1)
        }
    }

    @Test("Pruning processes drops orphaned paths")
    func pruningDropsOrphanedPaths() throws {
        try withStore { store in
            let old = Date().addingTimeInterval(-72 * 3600)
            try store.insertProcesses(
                [ProcessSample(
                    pid: 99, parentPID: 1, name: "old", executablePath: "/bin/old",
                    physicalFootprint: 1 << 20, peakFootprint: 1 << 20,
                    diskBytesRead: 0, diskBytesWritten: 0, cpuUtilization: 0
                )],
                at: old
            )

            try Rollup.pruneProcesses(store: store, before: Date().addingTimeInterval(-48 * 3600))

            let statement = try store.connection.prepare("SELECT COUNT(*) FROM path")
            #expect(try statement.step())
            #expect(statement.int(0) == 0, "paths with no referencing rows should be dropped")
        }
    }

    @Test("Full rollup run leaves the database consistent")
    func fullRunIsConsistent() throws {
        try withStore { store in
            let now = Date()
            for hoursAgo in [72.0, 60.0, 50.0, 10.0, 1.0] {
                try store.insert(
                    makeSample(at: now.addingTimeInterval(-hoursAgo * 3600)), health: .healthy
                )
            }

            try Rollup.run(store: store, now: now)

            // Rows older than 48 h are gone from raw but preserved as minutes.
            #expect(try store.sampleCount(resolution: .raw) == 2)
            #expect(try store.sampleCount(resolution: .minute) > 0)
        }
    }
}
