import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe by itself; `Store` serializes access to it.
final class Database {
    let handle: OpaquePointer
    /// The file it was opened from.
    let path: String
    private var cache: [String: Statement] = [:]

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close(db)
            throw DatabaseError(message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        for statement in cache.values { sqlite3_finalize(statement.raw) }
        sqlite3_close_v2(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// A cached prepared statement, reset and with its bindings cleared.
    func prepare(_ sql: String) throws -> Statement {
        if let statement = cache[sql] {
            statement.reset()
            return statement
        }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &raw, nil) == SQLITE_OK, let raw else {
            throw DatabaseError(message: "\(errorMessage) in: \(sql)")
        }
        let statement = Statement(raw: raw, db: self)
        cache[sql] = statement
        return statement
    }

    /// Prepares, binds and runs a statement that returns no rows.
    func run(_ sql: String, _ values: SQLValue?...) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
        statement.reset()
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue {
    static func from(_ value: Int64?) -> SQLValue? { value.map(SQLValue.int) }
    static func from(_ value: Double?) -> SQLValue? { value.map(SQLValue.double) }
    static func from(_ value: String?) -> SQLValue? { value.map(SQLValue.text) }
}

final class Statement {
    let raw: OpaquePointer
    unowned let db: Database

    init(raw: OpaquePointer, db: Database) {
        self.raw = raw
        self.db = db
    }

    func reset() {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
    }

    func bind(_ values: [SQLValue?]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case nil:
                status = sqlite3_bind_null(raw, index)
            case .int(let v)?:
                status = sqlite3_bind_int64(raw, index, v)
            case .double(let v)?:
                status = sqlite3_bind_double(raw, index, v)
            case .text(var v)?:
                // With its length, so text containing a NUL byte isn't cut short there. Empty text binds
                // "" itself, since a nil pointer would bind NULL.
                status = v.isEmpty ? sqlite3_bind_text(raw, index, "", 0, SQLITE_TRANSIENT) : v.withUTF8 { utf8 in
                    utf8.withMemoryRebound(to: CChar.self) { chars in
                        sqlite3_bind_text(raw, index, chars.baseAddress, Int32(chars.count), SQLITE_TRANSIENT)
                    }
                }
            case .blob(let v)?:
                status = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(raw, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            guard status == SQLITE_OK else { throw DatabaseError(message: db.errorMessage) }
        }
    }

    /// Advances to the next row. Returns false when done.
    func step() throws -> Bool {
        switch sqlite3_step(raw) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(message: db.errorMessage)
        }
    }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(raw, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(raw, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(raw, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(raw, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(raw, column) else { return "" }
        let count = Int(sqlite3_column_bytes(raw, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
    func byteCount(_ column: Int32) -> Int { Int(sqlite3_column_bytes(raw, column)) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }

    func blob(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(raw, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(raw, column)))
    }
}
