import Foundation

/// Database schema and migrations.
///
/// History is disposable by design — it describes one machine and can be
/// rebuilt by simply running longer — so migrations favour clarity over
/// preserving every past row. A destructive migration is acceptable here in a
/// way it would not be for the committed profile artifacts, which are the
/// published source of truth (ARCHITECTURE #7).
public enum Schema {

    /// Bumped whenever the DDL below changes.
    public static let version = 2

    public static func migrate(_ database: Database) throws {
        try database.execute(
            "CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)"
        )

        let current = try readVersion(database)
        guard current != Self.version else { return }

        if current == 0 {
            try database.transaction {
                try createTables(database)
                let statement = try database.prepare(
                    "INSERT INTO schema_version(version) VALUES(?)"
                )
                statement.bind(1, Self.version)
                try statement.run()
            }
        } else if current == 1 {
            try migrateV1toV2(database)
        } else {
            throw Database.Failure.step(
                "database is at schema version \(current), expected \(Self.version); "
                    + "delete the file to rebuild"
            )
        }
    }

    /// v1 → v2: the definition of `mem_used` changed.
    ///
    /// Until 2026-08-27 used memory was `active + wired + compressed`, which
    /// under-reported by the anonymous pages sitting on the inactive queue
    /// (ARCHITECTURE #40). Rows written under the old definition are not
    /// comparable with new ones, and a `history --since 7d` spanning the change
    /// would silently average two different quantities together — exactly the
    /// kind of invisible wrongness this project exists to prevent.
    ///
    /// So the system samples are dropped rather than migrated: there is no
    /// arithmetic that recovers the missing pages after the fact. Machine
    /// identity, events, and the daemon's own self-measurements are unaffected
    /// and survive. An event records why the gap exists.
    static func migrateV1toV2(_ database: Database) throws {
        try database.transaction {
            try database.execute("DELETE FROM sample")

            let event = try database.prepare(
                "INSERT INTO event(ts, kind, detail) VALUES(?, 'schema_migration', ?)"
            )
            event.bind(1, Date().timeIntervalSince1970)
            event.bind(
                2,
                "schema v1 → v2: system samples cleared because the definition of "
                    + "used memory changed to match Activity Monitor"
            )
            try event.run()

            let version = try database.prepare("UPDATE schema_version SET version = ?")
            version.bind(1, Self.version)
            try version.run()
        }
    }

    static func readVersion(_ database: Database) throws -> Int {
        let statement = try database.prepare("SELECT version FROM schema_version LIMIT 1")
        defer { statement.reset() }
        return try statement.step() ? statement.int(0) : 0
    }

    static func createTables(_ database: Database) throws {
        try database.execute(
            """
            CREATE TABLE machine(
                id           INTEGER PRIMARY KEY,
                hw_model     TEXT NOT NULL,
                cpu_brand    TEXT NOT NULL,
                ram_bytes    INTEGER NOT NULL,
                core_count   INTEGER NOT NULL,
                os_version   TEXT NOT NULL,
                os_build     TEXT NOT NULL,
                first_seen   REAL NOT NULL,
                last_seen    REAL NOT NULL,
                UNIQUE(hw_model, cpu_brand, ram_bytes, core_count, os_version, os_build)
            )
            """
        )

        // One table for every resolution, discriminated by `resolution`, rather
        // than a table per tier. Queries spanning tiers stay a single SELECT,
        // and retention is a DELETE with a WHERE clause.
        //
        // Rolled-up rows carry both an average and a max for the values where a
        // peak matters: an hour averaged to 30% CPU hides a minute at 100%, and
        // the peak is usually the interesting part. Levels (pressure, thermal,
        // health) store the *worst* seen in the window for the same reason.
        try database.execute(
            """
            CREATE TABLE sample(
                ts                    REAL NOT NULL,
                resolution            TEXT NOT NULL,
                interval_seconds      REAL NOT NULL,
                sample_count          INTEGER NOT NULL DEFAULT 1,

                mem_total             INTEGER NOT NULL,
                mem_used              INTEGER NOT NULL,
                mem_used_max          INTEGER NOT NULL,
                mem_active            INTEGER NOT NULL,
                mem_wired             INTEGER NOT NULL,
                mem_compressed        INTEGER NOT NULL,
                mem_free              INTEGER NOT NULL,
                swap_used             INTEGER NOT NULL,
                swap_outs_per_sec     REAL NOT NULL,
                swap_outs_per_sec_max REAL NOT NULL,
                pressure              INTEGER,

                cpu_util              REAL NOT NULL,
                cpu_util_max          REAL NOT NULL,
                cpu_user              REAL NOT NULL,
                cpu_system            REAL NOT NULL,

                gpu_util              REAL,
                gpu_mem_alloc         INTEGER,

                thermal               TEXT NOT NULL,

                disk_free             INTEGER NOT NULL,
                disk_read_per_sec     REAL NOT NULL,
                disk_write_per_sec    REAL NOT NULL,

                net_rx_per_sec        REAL NOT NULL,
                net_tx_per_sec        REAL NOT NULL,

                health                TEXT NOT NULL,
                PRIMARY KEY(ts, resolution)
            )
            """
        )
        try database.execute(
            "CREATE INDEX idx_sample_resolution_ts ON sample(resolution, ts)"
        )

        // Executable paths are long and repeat on every tick; storing them once
        // keeps process history from dominating the file.
        try database.execute(
            """
            CREATE TABLE path(
                id   INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE
            )
            """
        )

        // Only the top consumers per tick are stored — see ARCHITECTURE #22.
        try database.execute(
            """
            CREATE TABLE process_sample(
                ts             REAL NOT NULL,
                pid            INTEGER NOT NULL,
                ppid           INTEGER,
                name           TEXT NOT NULL,
                path_id        INTEGER REFERENCES path(id),
                footprint      INTEGER NOT NULL,
                peak_footprint INTEGER NOT NULL,
                cpu_util       REAL NOT NULL,
                disk_read      INTEGER NOT NULL,
                disk_written   INTEGER NOT NULL,
                PRIMARY KEY(ts, pid)
            )
            """
        )
        try database.execute("CREATE INDEX idx_process_sample_ts ON process_sample(ts)")
        try database.execute(
            "CREATE INDEX idx_process_sample_name ON process_sample(name, ts)"
        )

        // Discrete things that happened, as distinct from sampled levels. This
        // is what lets a gap in the sample timeline be explained rather than
        // mysterious.
        try database.execute(
            """
            CREATE TABLE event(
                id     INTEGER PRIMARY KEY,
                ts     REAL NOT NULL,
                kind   TEXT NOT NULL,
                detail TEXT
            )
            """
        )
        try database.execute("CREATE INDEX idx_event_ts ON event(ts)")

        // Self-observability gets its own table rather than a row in
        // process_sample: the budget verdict is part of the record, and
        // SPEC principle 6 makes this non-optional rather than incidental.
        try database.execute(
            """
            CREATE TABLE daemon_sample(
                ts             REAL NOT NULL PRIMARY KEY,
                footprint      INTEGER NOT NULL,
                peak_footprint INTEGER NOT NULL,
                cpu_util       REAL NOT NULL,
                within_budget  INTEGER NOT NULL
            )
            """
        )
    }
}
