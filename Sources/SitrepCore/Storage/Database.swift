import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` tells SQLite to copy a bound string rather than borrow it.
///
/// It is a macro in C and so not imported. Without the copy, SQLite would hold a
/// pointer into Swift-managed memory that may be gone by the time the statement
/// steps.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A SQLite connection.
///
/// Hand-written against the C API rather than a wrapper like GRDB, per the
/// Apple-only dependency policy (ARCHITECTURE #2). The surface is deliberately
/// small — open, execute, prepare, transact — because everything this project
/// stores is append-and-aggregate.
public final class Database {

    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String)

        public var description: String {
            switch self {
            case let .open(message): "could not open database: \(message)"
            case let .prepare(message, sql): "could not prepare statement: \(message) — \(sql)"
            case let .step(message): "statement failed: \(message)"
            }
        }
    }

    private let handle: OpaquePointer

    /// Opens (creating if needed) the database at `path`.
    ///
    /// WAL is set because the daemon writes continuously while the CLI reads:
    /// in WAL mode readers never block the writer and vice versa, which is what
    /// lets `sitrep history` work without an IPC layer (ARCHITECTURE #21).
    /// `synchronous=NORMAL` trades a crash-window of the last commit for far
    /// fewer fsyncs — the correct trade for telemetry that is disposable by
    /// design, and it keeps the monitor from generating the disk I/O it reports.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw Failure.open(message)
        }
        self.handle = handle

        // Busy timeout matters even with WAL: a rollup holding a write lock can
        // briefly block another writer, and failing outright would lose samples.
        sqlite3_busy_timeout(handle, 5_000)

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Opens a read-only connection, for callers that must not modify history.
    public init(readOnlyPath path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw Failure.open(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { sqlite3_close(handle) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs SQL that returns no rows.
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.step("\(errorMessage) — \(sql)")
        }
    }

    /// Prepares a statement for binding and stepping.
    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw Failure.prepare(errorMessage, sql: sql)
        }
        return Statement(handle: statement, database: self)
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    ///
    /// The daemon batches roughly a minute of samples into one transaction. A
    /// commit per sample would fsync every few seconds, which for a tool that
    /// reports disk I/O would be self-defeating.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // Best-effort rollback: if this also fails the connection is
            // already unusable and the original error is the informative one.
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Total bytes on disk, including the write-ahead log and shared-memory
    /// index.
    ///
    /// Summing the sidecars matters: in WAL mode the main file can sit at 4 KB
    /// while the `-wal` holds hundreds of KB not yet checkpointed. Reporting
    /// only the main file would have mac-sitrep under-stating its own disk
    /// footprint by an order of magnitude, which is precisely the dishonesty
    /// SPEC principle 6 exists to prevent.
    public static func totalSizeOnDisk(path: String) -> UInt64 {
        [path, path + "-wal", path + "-shm"].reduce(into: UInt64(0)) { total, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            total += (attributes?[.size] as? UInt64) ?? 0
        }
    }
}

/// A prepared statement.
public final class Statement {
    private let handle: OpaquePointer
    private let database: Database

    init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    // MARK: Binding — 1-indexed, matching SQLite's convention.

    @discardableResult
    public func bind(_ index: Int32, _ value: Double) -> Statement {
        sqlite3_bind_double(handle, index, value)
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Int64) -> Statement {
        sqlite3_bind_int64(handle, index, value)
        return self
    }

    /// Binds a `UInt64` by bit pattern.
    ///
    /// SQLite has no unsigned integer type. Byte counters can exceed `Int64.max`
    /// in principle, so the bits are preserved rather than clamped and reversed
    /// on read. Verified round-tripping 18e18.
    @discardableResult
    public func bind(_ index: Int32, _ value: UInt64) -> Statement {
        sqlite3_bind_int64(handle, index, Int64(bitPattern: value))
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Int) -> Statement {
        sqlite3_bind_int64(handle, index, Int64(value))
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: String) -> Statement {
        sqlite3_bind_text(handle, index, value, -1, transient)
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, _ value: Bool) -> Statement {
        sqlite3_bind_int64(handle, index, value ? 1 : 0)
        return self
    }

    @discardableResult
    public func bindNull(_ index: Int32) -> Statement {
        sqlite3_bind_null(handle, index)
        return self
    }

    @discardableResult
    public func bind(_ index: Int32, optional value: Double?) -> Statement {
        value.map { bind(index, $0) } ?? bindNull(index)
    }

    @discardableResult
    public func bind(_ index: Int32, optional value: UInt64?) -> Statement {
        value.map { bind(index, $0) } ?? bindNull(index)
    }

    @discardableResult
    public func bind(_ index: Int32, optional value: Int?) -> Statement {
        value.map { bind(index, $0) } ?? bindNull(index)
    }

    // MARK: Reading — 0-indexed, matching SQLite's column convention.

    public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    public func uint64(_ column: Int32) -> UInt64 {
        UInt64(bitPattern: sqlite3_column_int64(handle, column))
    }

    public func string(_ column: Int32) -> String {
        guard let text = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: text)
    }

    public func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    public func optionalInt(_ column: Int32) -> Int? {
        isNull(column) ? nil : int(column)
    }

    public func optionalDouble(_ column: Int32) -> Double? {
        isNull(column) ? nil : double(column)
    }

    public func optionalUInt64(_ column: Int32) -> UInt64? {
        isNull(column) ? nil : uint64(column)
    }

    // MARK: Execution

    /// Steps once. Returns true if a row is available.
    @discardableResult
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Database.Failure.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Steps to completion, for statements that return no rows.
    public func run() throws {
        while try step() {}
        reset()
    }

    /// Iterates every row, calling `body` for each.
    public func forEachRow(_ body: (Statement) throws -> Void) throws {
        while try step() { try body(self) }
        reset()
    }

    /// Clears bindings and rewinds, so the statement can be reused. Reusing one
    /// prepared statement across a batch is what makes the daemon's per-tick
    /// write cost negligible.
    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }
}
