import Foundation
import SQLite3

/// A thin wrapper over the system SQLite: prepared statements, bound values, rows. Not thread-safe by itself;
/// MemoryStore serialises access.
final class SQLite {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw Failure(message: "cannot open \(path)")
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    struct Row {
        fileprivate let stmt: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func string(_ i: Int32) -> String? { isNull(i) ? nil : String(cString: sqlite3_column_text(stmt, i)) }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        for (i, a) in args.enumerated() {
            let ix = Int32(i + 1)
            switch a {
            case nil, is NSNull: sqlite3_bind_null(stmt, ix)
            case let v as String: sqlite3_bind_text(stmt, ix, v, -1, SQLite.transient)
            case let v as Int: sqlite3_bind_int64(stmt, ix, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, ix, v)
            case let v as Double: sqlite3_bind_double(stmt, ix, v)
            case let v as Bool: sqlite3_bind_int64(stmt, ix, v ? 1 : 0)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, ix, $0.baseAddress, Int32(v.count), SQLite.transient) }
            default: sqlite3_bind_text(stmt, ix, "\(a!)", -1, SQLite.transient)
            }
        }
        return stmt
    }

    /// Runs a statement and returns the number of rows it changed.
    @discardableResult
    func exec(_ sql: String, _ args: [Any?] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    func scalar(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        try query(sql, args) { $0.int(0) }.first ?? 0
    }

    var lastRowId: Int64 { sqlite3_last_insert_rowid(db) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
