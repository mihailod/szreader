import Foundation
import SQLite3

/// Minimal SQLite wrapper.
///
/// System SQLite is used directly rather than a package dependency: it ships
/// with FTS5 on every Apple platform, keeps the module hermetic, and this
/// schema is small enough that an ORM would add more surface than it removes.
/// `Store` is the only consumer, so swapping this out later is contained.
struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

enum SQLValue {
    case text(String)
    case int(Int64)
    /// Needed for timestamps: whole seconds cannot distinguish two events in
    /// the same second, which silently breaks least-recently-used ordering.
    case double(Double)
    case null

    init(_ v: String?) { self = v.map { .text($0) } ?? .null }
    init(_ v: Int?) { self = v.map { .int(Int64($0)) } ?? .null }
}

final class Database {
    fileprivate var handle: OpaquePointer?

    /// Serialises every statement on this connection.
    ///
    /// One sqlite3 handle shared by the UI and the background title backfill:
    /// WAL permits concurrent readers but only one writer, so an import racing
    /// a probe write fails with "database is locked" and the import is lost.
    ///
    /// Recursive by necessity, not preference — these calls nest on one thread
    /// (`scalarInt` calls `query`; `backfillTitles` calls `recordProbe` and
    /// `setTitle` inside its own loop), and a plain lock or a serial queue's
    /// `sync` would deadlock on the re-entry.
    private let lock = NSRecursiveLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// `path` may be ":memory:".
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(description: msg)
        }
        // Defence in depth: the lock serialises this process, but a checkpoint
        // or another connection can still hold a write lock briefly.
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close(handle) }

    private func fail(_ context: String) -> SQLiteError {
        SQLiteError(description: "\(context): \(String(cString: sqlite3_errmsg(handle)))")
    }

    /// Runs `body` as one transaction, holding the connection lock throughout.
    ///
    /// Locking each statement is not enough on its own: two threads can still
    /// interleave *between* BEGIN and COMMIT, and the second BEGIN fails with
    /// "cannot start a transaction within a transaction" — which surfaced as an
    /// import that reported the library could not be written to, and was lost.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN")
            do {
                let out = try body()
                try execute("COMMIT")
                return out
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs one or more statements with no bindings.
    func execute(_ sql: String) throws {
        try locked {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(description: msg)
        }
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                // The statement, not just "run": SQLITE_ERROR is a logic error
                // ("no such column", "no such table"), and without the SQL the
                // message says nothing about which statement is wrong.
                throw fail("run \(sql.prefix(90))")
            }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Streams rows; the closure receives a column accessor.
    func query(_ sql: String, _ args: [SQLValue] = [], _ row: (Row) -> Void) throws {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw fail("query \(sql.prefix(90))") }
                row(Row(stmt: stmt))
            }
        }
    }

    func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        var out = 0
        try query(sql, args) { out = $0.int(0) ?? 0 }
        return out
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw fail("prepare \(sql.prefix(60))")
        }
        // SQLITE_TRANSIENT: sqlite copies the bytes, so Swift's String storage
        // does not have to outlive the bind call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .int(let n):  sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .null:        sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    struct Row {
        let stmt: OpaquePointer?

        func string(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        func int(_ i: Int32) -> Int? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(stmt, i))
        }

        /// For the timestamp columns, which `int` would read to whole seconds
        /// — and two issues opened within the same second must still have an
        /// order, or "most recently opened" shuffles them on every refresh.
        func double(_ i: Int32) -> Double? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(stmt, i)
        }
    }
}
