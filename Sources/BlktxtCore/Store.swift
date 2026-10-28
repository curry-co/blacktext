import Foundation

/// Everything blktxt keeps, in one SQLite file.
///
/// Each `Store` owns one connection and serializes calls to it, so it is safe to share across threads.
/// The app opens a few (main thread, saves, search) so a long search never blocks a save; SQLite's
/// write-ahead log lets them read and write the same file concurrently.
public final class Store: @unchecked Sendable {
    public let url: URL
    private let db: Database
    private let lock = NSLock()

    public init(url: URL = Paths.databaseURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try Database(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try Schema.migrate(db)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Notes

    private static let summaryColumns = "id, title, created_at, updated_at, word_count, version_count, deleted_at"

    private func summary(from row: Statement) -> NoteSummary {
        NoteSummary(id: row.int64(0),
                    title: row.text(1),
                    createdAt: Date(timeIntervalSince1970: row.double(2)),
                    updatedAt: Date(timeIntervalSince1970: row.double(3)),
                    wordCount: row.int(4),
                    versionCount: row.int(5),
                    deletedAt: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:)))
    }

    private func note(from row: Statement) -> Note {
        let s = summary(from: row)
        return Note(id: s.id, text: row.text(7), title: s.title, createdAt: s.createdAt, updatedAt: s.updatedAt,
                    wordCount: s.wordCount, versionCount: s.versionCount, deletedAt: s.deletedAt)
    }

    @discardableResult
    public func createNote(text: String = "", date: Date = Date()) throws -> NoteID {
        let title = NoteTitle.from(text)
        let words = Int64(WordCount.count(text))
        return try locked {
            let t = date.timeIntervalSince1970
            try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count) VALUES (?, ?, ?, ?, ?)",
                       .double(t), .double(t), .text(text), .text(title), .int(words))
            return db.lastInsertRowID
        }
    }

    public func note(id: NoteID) throws -> Note? {
        try locked {
            let row = try db.prepare("SELECT \(Self.summaryColumns), text FROM notes WHERE id = ?")
            defer { row.reset() }
            try row.bind([.int(id)])
            return try row.step() ? note(from: row) : nil
        }
    }

    public func summary(id: NoteID) throws -> NoteSummary? {
        try locked { try summaryLocked(id) }
    }

    private func summaryLocked(_ id: NoteID) throws -> NoteSummary? {
        let row = try db.prepare("SELECT \(Self.summaryColumns) FROM notes WHERE id = ?")
        defer { row.reset() }
        try row.bind([.int(id)])
        return try row.step() ? summary(from: row) : nil
    }

    /// Saves new text for a note. Returns the updated summary, or nil if nothing changed.
    @discardableResult
    public func updateText(noteID: NoteID, text: String, date: Date = Date()) throws -> NoteSummary? {
        let title = NoteTitle.from(text)
        let words = Int64(WordCount.count(text))
        return try locked {
            try db.run("UPDATE notes SET text = ?, title = ?, word_count = ?, updated_at = ? WHERE id = ? AND text IS NOT ?",
                       .text(text), .text(title), .int(words), .double(date.timeIntervalSince1970), .int(noteID), .text(text))
            guard db.changes > 0 else { return nil }
            return try summaryLocked(noteID)
        }
    }

    /// Notes, most recently edited first, starting after `cursor`.
    public func notes(limit: Int, after cursor: NoteCursor? = nil) throws -> [NoteSummary] {
        try locked {
            let row: Statement
            if let cursor {
                row = try db.prepare("""
                    SELECT \(Self.summaryColumns) FROM notes
                    WHERE deleted_at IS NULL AND (updated_at, id) < (?, ?)
                    ORDER BY updated_at DESC, id DESC LIMIT ?
                    """)
                try row.bind([.double(cursor.updatedAt.timeIntervalSince1970), .int(cursor.id), .int(Int64(limit))])
            } else {
                row = try db.prepare("""
                    SELECT \(Self.summaryColumns) FROM notes
                    WHERE deleted_at IS NULL
                    ORDER BY updated_at DESC, id DESC LIMIT ?
                    """)
                try row.bind([.int(Int64(limit))])
            }
            defer { row.reset() }
            var results: [NoteSummary] = []
            results.reserveCapacity(limit)
            while try row.step() { results.append(summary(from: row)) }
            return results
        }
    }

    /// Notes by offset, for agents that page with numbers.
    public func notes(limit: Int, offset: Int) throws -> [NoteSummary] {
        try locked {
            let row = try db.prepare("""
                SELECT \(Self.summaryColumns) FROM notes
                WHERE deleted_at IS NULL
                ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?
                """)
            defer { row.reset() }
            try row.bind([.int(Int64(limit)), .int(Int64(offset))])
            var results: [NoteSummary] = []
            while try row.step() { results.append(summary(from: row)) }
            return results
        }
    }

    public func deletedNotes(limit: Int = 500) throws -> [NoteSummary] {
        try locked {
            let row = try db.prepare("""
                SELECT \(Self.summaryColumns) FROM notes
                WHERE deleted_at IS NOT NULL
                ORDER BY deleted_at DESC LIMIT ?
                """)
            defer { row.reset() }
            try row.bind([.int(Int64(limit))])
            var results: [NoteSummary] = []
            while try row.step() { results.append(summary(from: row)) }
            return results
        }
    }

    public func noteCount() throws -> Int {
        try locked {
            let row = try db.prepare("SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL")
            defer { row.reset() }
            return try row.step() ? row.int(0) : 0
        }
    }

    public func deletedCount() throws -> Int {
        try locked {
            let row = try db.prepare("SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL")
            defer { row.reset() }
            return try row.step() ? row.int(0) : 0
        }
    }

    /// Moves a note to Recently Deleted.
    public func softDelete(noteID: NoteID, date: Date = Date()) throws {
        try locked {
            try db.run("UPDATE notes SET deleted_at = ? WHERE id = ?", .double(date.timeIntervalSince1970), .int(noteID))
        }
    }

    public func putBack(noteID: NoteID) throws {
        try locked { try db.run("UPDATE notes SET deleted_at = NULL WHERE id = ?", .int(noteID)) }
    }

    /// Removes a note and its versions for good.
    public func hardDelete(noteID: NoteID) throws {
        try locked { try db.run("DELETE FROM notes WHERE id = ?", .int(noteID)) }
    }

    /// Permanently removes notes deleted before `date`. Returns how many.
    @discardableResult
    public func purgeDeleted(before date: Date) throws -> Int {
        try locked {
            try db.run("DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?", .double(date.timeIntervalSince1970))
            return db.changes
        }
    }

    /// Visits every live note, oldest first. Used by export.
    public func forEachNote(_ body: (Note) throws -> Void) throws {
        try locked {
            let row = try db.prepare("SELECT \(Self.summaryColumns), text FROM notes WHERE deleted_at IS NULL ORDER BY created_at, id")
            defer { row.reset() }
            while try row.step() { try body(note(from: row)) }
        }
    }

    /// Bulk import: one note with its history, in one transaction. Used by the benchmark seeder.
    @discardableResult
    public func importNote(text: String, createdAt: Date, updatedAt: Date,
                           versions: [(date: Date, text: String)]) throws -> NoteID {
        let title = NoteTitle.from(text)
        let words = Int64(WordCount.count(text))
        let packed = versions.map { (date: $0.date, words: Int64(WordCount.count($0.text)), body: Compression.pack($0.text)) }
        return try locked {
            try db.transaction {
                try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count, version_count) VALUES (?, ?, ?, ?, ?, ?)",
                           .double(createdAt.timeIntervalSince1970), .double(updatedAt.timeIntervalSince1970),
                           .text(text), .text(title), .int(words), .int(Int64(versions.count)))
                let id = db.lastInsertRowID
                for version in packed {
                    try db.run("INSERT INTO versions (note_id, created_at, word_count, source, compressed, body) VALUES (?, ?, ?, 'user', ?, ?)",
                               .int(id), .double(version.date.timeIntervalSince1970), .int(version.words),
                               .int(version.body.compressed ? 1 : 0), .blob(version.body.data))
                }
                return id
            }
        }
    }

    // MARK: Versions

    /// Saves a snapshot of a note. Skips empty text and text identical to the latest version.
    @discardableResult
    public func addVersion(noteID: NoteID, text: String, source: String = "user", date: Date = Date()) throws -> VersionID? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        let words = Int64(WordCount.count(text))
        let packed = Compression.pack(text)
        return try locked {
            if let latest = try latestVersionTextLocked(noteID), latest == text { return nil }
            return try db.transaction {
                try db.run("INSERT INTO versions (note_id, created_at, word_count, source, compressed, body) VALUES (?, ?, ?, ?, ?, ?)",
                           .int(noteID), .double(date.timeIntervalSince1970), .int(words), .text(source),
                           .int(packed.compressed ? 1 : 0), .blob(packed.data))
                let id = db.lastInsertRowID
                try db.run("UPDATE notes SET version_count = version_count + 1 WHERE id = ?", .int(noteID))
                return id
            }
        }
    }

    /// A note's versions, newest first.
    public func versions(noteID: NoteID) throws -> [VersionSummary] {
        try locked {
            let row = try db.prepare("""
                SELECT id, note_id, created_at, word_count, source FROM versions
                WHERE note_id = ? ORDER BY created_at DESC, id DESC
                """)
            defer { row.reset() }
            try row.bind([.int(noteID)])
            var results: [VersionSummary] = []
            while try row.step() {
                results.append(VersionSummary(id: row.int64(0), noteID: row.int64(1),
                                              createdAt: Date(timeIntervalSince1970: row.double(2)),
                                              wordCount: row.int(3), source: row.text(4)))
            }
            return results
        }
    }

    public func version(id: VersionID) throws -> (summary: VersionSummary, text: String)? {
        try locked {
            let row = try db.prepare("SELECT id, note_id, created_at, word_count, source, compressed, body FROM versions WHERE id = ?")
            defer { row.reset() }
            try row.bind([.int(id)])
            guard try row.step() else { return nil }
            let summary = VersionSummary(id: row.int64(0), noteID: row.int64(1),
                                         createdAt: Date(timeIntervalSince1970: row.double(2)),
                                         wordCount: row.int(3), source: row.text(4))
            return (summary, Compression.unpack(row.blob(6), compressed: row.int(5) != 0))
        }
    }

    public func latestVersionText(noteID: NoteID) throws -> String? {
        try locked { try latestVersionTextLocked(noteID) }
    }

    private func latestVersionTextLocked(_ noteID: NoteID) throws -> String? {
        let row = try db.prepare("SELECT compressed, body FROM versions WHERE note_id = ? ORDER BY created_at DESC, id DESC LIMIT 1")
        defer { row.reset() }
        try row.bind([.int(noteID)])
        guard try row.step() else { return nil }
        return Compression.unpack(row.blob(1), compressed: row.int(0) != 0)
    }

    // MARK: State

    public func value(forKey key: String) -> String? {
        try? locked {
            let row = try db.prepare("SELECT value FROM state WHERE key = ?")
            defer { row.reset() }
            try row.bind([.text(key)])
            return try row.step() ? row.text(0) : nil
        }
    }

    public func setValue(_ value: String?, forKey key: String) {
        try? locked {
            if let value {
                try db.run("INSERT INTO state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           .text(key), .text(value))
            } else {
                try db.run("DELETE FROM state WHERE key = ?", .text(key))
            }
        }
    }

    /// The note open in the app's canvas; nil means a blank canvas.
    public var currentNoteID: NoteID? {
        get { value(forKey: "current_note").flatMap { NoteID($0) } }
        set { setValue(newValue.map(String.init), forKey: "current_note") }
    }

    /// Whether agents may change notes (blktxt → Allow Agents to Edit).
    public var agentsCanEdit: Bool {
        get { value(forKey: "agents_can_edit") != "0" }
        set { setValue(newValue ? "1" : "0", forKey: "agents_can_edit") }
    }

    // MARK: Search

    /// Searches every live note, most recently edited first.
    /// The trigram index narrows candidates; `FindEngine` confirms each one with the exact options.
    public func search(_ query: FindQuery, limit: Int = 100, isCancelled: () -> Bool = { false }) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        _ = try FindEngine.regex(for: query)
        let columns = "\(Self.summaryColumns), text"
        let order = "ORDER BY updated_at DESC, id DESC"
        let sql: String
        let bindings: [SQLValue?]
        if !query.options.regex, query.text.unicodeScalars.count >= 3 {
            let phrase = "\"" + query.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql = "SELECT \(columns) FROM notes WHERE deleted_at IS NULL AND id IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?) \(order)"
            bindings = [.text(phrase)]
        } else if !query.options.regex, query.text.allSatisfy(\.isASCII) {
            let escaped = query.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            sql = "SELECT \(columns) FROM notes WHERE deleted_at IS NULL AND text LIKE ? ESCAPE '\\' \(order)"
            bindings = [.text("%\(escaped)%")]
        } else {
            sql = "SELECT \(columns) FROM notes WHERE deleted_at IS NULL \(order)"
            bindings = []
        }

        return try locked {
            let row = try db.prepare(sql)
            defer { row.reset() }
            try row.bind(bindings)
            var hits: [SearchHit] = []
            while hits.count < limit, !isCancelled(), try row.step() {
                let text = row.text(7) as NSString
                let ranges = try FindEngine.matches(of: query, in: text, limit: 10_000, isCancelled: isCancelled)
                guard !ranges.isEmpty else { continue }
                let snippet = Snippet.make(in: text, matches: ranges)
                hits.append(SearchHit(note: summary(from: row), matchCount: ranges.count,
                                      snippet: snippet.text, snippetMatches: snippet.matches))
            }
            return hits
        }
    }

    // MARK: Agent inbox

    /// Queues an agent edit for the running app to apply.
    public func enqueue(_ op: AgentOp) throws -> Int64 {
        let payload = try op.edit.encodedPayload()
        return try locked {
            try db.run("INSERT INTO inbox (created_at, kind, note_id, payload, source) VALUES (?, ?, ?, ?, ?)",
                       .double(Date().timeIntervalSince1970), .text(op.edit.kind), .from(op.noteID),
                       .text(payload), .text(op.source))
            return db.lastInsertRowID
        }
    }

    public func pendingOps() throws -> [AgentOp] {
        try locked {
            let row = try db.prepare("SELECT id, kind, note_id, payload, source FROM inbox WHERE done_at IS NULL ORDER BY id")
            defer { row.reset() }
            var ops: [AgentOp] = []
            while try row.step() {
                guard let edit = AgentEdit(kind: row.text(1), payload: row.text(3)) else { continue }
                ops.append(AgentOp(id: row.int64(0), noteID: row.optionalInt64(2), edit: edit, source: row.text(4)))
            }
            return ops
        }
    }

    public func complete(opID: Int64, result: AgentResult) throws {
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try locked {
            try db.run("UPDATE inbox SET result = ?, done_at = ? WHERE id = ?",
                       .text(encoded), .double(Date().timeIntervalSince1970), .int(opID))
            // Keep the inbox small: finished ops are only needed until their caller reads them.
            try db.run("DELETE FROM inbox WHERE done_at IS NOT NULL AND done_at < ?",
                       .double(Date().timeIntervalSince1970 - 3600))
        }
    }

    /// The result of a queued op, or nil while it's still pending.
    public func result(opID: Int64) throws -> AgentResult? {
        try locked {
            let row = try db.prepare("SELECT result FROM inbox WHERE id = ? AND done_at IS NOT NULL")
            defer { row.reset() }
            try row.bind([.int(opID)])
            guard try row.step(), let json = row.optionalText(0) else { return nil }
            return try JSONDecoder().decode(AgentResult.self, from: Data(json.utf8))
        }
    }
}

enum Snippet {
    static let before = 40
    static let after = 160

    /// A single line of context around the first match, with match ranges relative to it.
    static func make(in text: NSString, matches: [NSRange]) -> (text: String, matches: [NSRange]) {
        guard let first = matches.first else { return ("", []) }
        var start = max(0, first.location - before)
        let end = min(text.length, first.location + first.length + after)
        // Start on a word boundary when there is one before the match.
        if start > 0 {
            let lead = NSRange(location: start, length: first.location - start)
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: lead)
            if space.location != NSNotFound { start = space.location + space.length }
        }
        let window = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let body = NSMutableString(string: text.substring(with: window))
        for unit in ["\n", "\r", "\t"] {
            body.replaceOccurrences(of: unit, with: " ", options: .literal, range: NSRange(location: 0, length: body.length))
        }
        let prefix = window.location > 0 ? "…" : ""
        let suffix = window.location + window.length < text.length ? "…" : ""
        let shift = (prefix as NSString).length - window.location
        let local = matches.compactMap { match -> NSRange? in
            let overlap = NSIntersectionRange(match, window)
            guard overlap.length > 0 else { return nil }
            return NSRange(location: overlap.location + shift, length: overlap.length)
        }
        return (prefix + (body as String) + suffix, local)
    }
}
