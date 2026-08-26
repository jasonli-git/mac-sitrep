import Foundation

/// Aggregates old samples into coarser tiers and prunes what has aged out.
///
/// Without this the "lightweight telemetry" of SPEC §19 grows without bound and
/// the monitor becomes the disk problem it exists to detect. At 10-second raw
/// sampling that is 8,640 rows a day, which is fine for two days and not fine
/// for a year.
public enum Rollup {

    /// How long each tier is kept.
    public struct Retention: Sendable {
        public let raw: TimeInterval
        public let minute: TimeInterval
        public let hour: TimeInterval

        public static let `default` = Retention(
            raw: 48 * 3600,
            minute: 30 * 24 * 3600,
            hour: 365 * 24 * 3600
        )
    }

    /// Rolls raw → minute → hour, then prunes each tier past its retention.
    ///
    /// Idempotent: rolling up a window that has already been rolled replaces the
    /// same rows, because the aggregate row's timestamp is the deterministic
    /// start of its bucket.
    public static func run(
        store: SampleStore,
        retention: Retention = .default,
        now: Date = Date()
    ) throws {
        try aggregate(
            store: store, from: .raw, to: .minute, bucketSeconds: 60,
            olderThan: now.addingTimeInterval(-retention.raw)
        )
        try aggregate(
            store: store, from: .minute, to: .hour, bucketSeconds: 3600,
            olderThan: now.addingTimeInterval(-retention.minute)
        )

        try prune(store: store, resolution: .raw, before: now.addingTimeInterval(-retention.raw))
        try prune(
            store: store, resolution: .minute, before: now.addingTimeInterval(-retention.minute)
        )
        try prune(store: store, resolution: .hour, before: now.addingTimeInterval(-retention.hour))

        // Process history is pruned but never rolled up. Aggregating per-process
        // rows across a window would have to pick which processes survive, and
        // any choice loses the detail the rows existed for. Beyond the raw
        // window, the system-level tiers carry the story.
        try pruneProcesses(store: store, before: now.addingTimeInterval(-retention.raw))
    }

    /// Aggregates one tier into the next for rows older than `olderThan`.
    ///
    /// Averages rates, takes the max of the peak columns, and takes the *worst*
    /// of the level columns. Averaging a level would be meaningless — the mean
    /// of "normal" and "critical" is not a state — and averaging a peak would
    /// hide exactly the spike worth keeping.
    static func aggregate(
        store: SampleStore,
        from source: SampleStore.Resolution,
        to destination: SampleStore.Resolution,
        bucketSeconds: Int,
        olderThan: Date
    ) throws {
        let database = store.connection

        try database.transaction {
            try database.execute(
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
                SELECT
                    CAST(ts / \(bucketSeconds) AS INTEGER) * \(bucketSeconds),
                    '\(destination.rawValue)',
                    \(bucketSeconds),
                    SUM(sample_count),
                    MAX(mem_total),
                    CAST(AVG(mem_used) AS INTEGER),
                    MAX(mem_used_max),
                    CAST(AVG(mem_active) AS INTEGER),
                    CAST(AVG(mem_wired) AS INTEGER),
                    CAST(AVG(mem_compressed) AS INTEGER),
                    CAST(AVG(mem_free) AS INTEGER),
                    CAST(AVG(swap_used) AS INTEGER),
                    AVG(swap_outs_per_sec),
                    MAX(swap_outs_per_sec_max),
                    MAX(pressure),
                    AVG(cpu_util),
                    MAX(cpu_util_max),
                    AVG(cpu_user),
                    AVG(cpu_system),
                    AVG(gpu_util),
                    CAST(AVG(gpu_mem_alloc) AS INTEGER),
                    -- Worst thermal state in the bucket, ranked explicitly:
                    -- text ordering would put 'critical' before 'nominal'.
                    (SELECT thermal FROM sample inner_t
                     WHERE inner_t.resolution = outer_s.resolution
                       AND CAST(inner_t.ts / \(bucketSeconds) AS INTEGER)
                           = CAST(outer_s.ts / \(bucketSeconds) AS INTEGER)
                     ORDER BY CASE thermal
                        WHEN 'critical' THEN 0 WHEN 'serious' THEN 1
                        WHEN 'fair' THEN 2 ELSE 3 END
                     LIMIT 1),
                    CAST(AVG(disk_free) AS INTEGER),
                    AVG(disk_read_per_sec),
                    AVG(disk_write_per_sec),
                    AVG(net_rx_per_sec),
                    AVG(net_tx_per_sec),
                    (SELECT health FROM sample inner_h
                     WHERE inner_h.resolution = outer_s.resolution
                       AND CAST(inner_h.ts / \(bucketSeconds) AS INTEGER)
                           = CAST(outer_s.ts / \(bucketSeconds) AS INTEGER)
                     ORDER BY CASE health
                        WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END
                     LIMIT 1)
                FROM sample outer_s
                WHERE resolution = '\(source.rawValue)' AND ts < \(olderThan.timeIntervalSince1970)
                GROUP BY CAST(ts / \(bucketSeconds) AS INTEGER)
                """
            )
        }
    }

    static func prune(
        store: SampleStore, resolution: SampleStore.Resolution, before: Date
    ) throws {
        let statement = try store.connection.prepare(
            "DELETE FROM sample WHERE resolution = ? AND ts < ?"
        )
        statement.bind(1, resolution.rawValue).bind(2, before.timeIntervalSince1970)
        try statement.run()
    }

    static func pruneProcesses(store: SampleStore, before: Date) throws {
        let statement = try store.connection.prepare("DELETE FROM process_sample WHERE ts < ?")
        statement.bind(1, before.timeIntervalSince1970)
        try statement.run()

        // Paths outlive the rows that referenced them; drop the orphans so the
        // dictionary table does not grow forever with every binary ever run.
        try store.connection.execute(
            """
            DELETE FROM path WHERE id NOT IN (
                SELECT DISTINCT path_id FROM process_sample WHERE path_id IS NOT NULL
            )
            """
        )
    }
}
