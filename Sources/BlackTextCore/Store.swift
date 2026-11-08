import Foundation

/// Everything BlackText keeps, in one SQLite file.
///
/// Each `Store` owns one connection and serializes calls to it, so it is safe to share across threads.
/// The app opens a few (main thread, saves, search) so a long search never blocks a save; SQLite's
/// write-ahead log lets them read and write the same file concurrently.
public final class Store: @unchecked Sendable {
    public let url: URL
    let db: Database
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

    /// Tests only: makes every statement on this connection call `fault` with its SQL first (nil to stop).
    func injectFault(_ fault: ((String) throws -> Void)?) {
        lock.lock()
        db.fault = fault
        lock.unlock()
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Notes

    static let summaryColumns = "id, title, created_at, updated_at, word_count, version_count, deleted_at"

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

    /// A new note. With `versionSource`, its first version is saved with it; `completing` records agent ops
    /// as done in the same transaction, so an op that creates a note happens exactly once.
    @discardableResult
    public func createNote(text: String = "", date: Date = Date(), versionSource: String? = nil,
                           completing completions: [Int64: AgentResult] = [:]) throws -> NoteID {
        let title = NoteTitle.from(text)
        let words = WordCount.count(text)
        return try locked {
            try db.transaction {
                let t = date.timeIntervalSince1970
                try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count) VALUES (?, ?, ?, ?, ?)",
                           .double(t), .double(t), .text(text), .text(title), .int(Int64(words)))
                let id = db.lastInsertRowID
                if let versionSource {
                    try insertVersionLocked(noteID: id, text: text, source: versionSource, date: date, words: words)
                }
                try completeLocked(completions, noteID: id)
                return id
            }
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

    func summaryLocked(_ id: NoteID) throws -> NoteSummary? {
        let row = try db.prepare("SELECT \(Self.summaryColumns) FROM notes WHERE id = ?")
        defer { row.reset() }
        try row.bind([.int(id)])
        return try row.step() ? summary(from: row) : nil
    }

    /// Saves new text for a note. Returns the updated summary, or nil if nothing changed.
    @discardableResult
    public func updateText(noteID: NoteID, text: String, date: Date = Date()) throws -> NoteSummary? {
        try saveText(noteID: noteID, text: text, date: date)
    }

    /// Saves a note's text, and a version of it when `versionSource` is given, in one transaction, so the
    /// two land together or not at all. `completing` records agent ops as done in the same transaction.
    ///
    /// Emptying a note first keeps what it said as a version, so clearing it can always be undone from its
    /// history. `base` is the text the caller last saw stored: if something else (sync, usually) has written
    /// since, that text is kept as a version before it's replaced. Throws `StoreError.noteNotFound` or
    /// `.noteDeleted` rather than write where nobody will see it. Returns the updated summary, or nil if
    /// nothing changed.
    @discardableResult
    public func saveText(noteID: NoteID, text: String, versionSource: String? = nil, base: String? = nil,
                         completing completions: [Int64: AgentResult] = [:], date: Date = Date()) throws -> NoteSummary? {
        let title = NoteTitle.from(text)
        let words = WordCount.count(text)
        // Compress outside the lock so a big note never holds up other readers.
        let packed = versionSource == nil ? nil : Compression.pack(text)
        return try locked {
            try db.transaction {
                let old = try liveTextLocked(noteID)
                var changed = false
                if !old.utf8.elementsEqual(text.utf8) {
                    if let base, !old.utf8.elementsEqual(base.utf8) {
                        // Written underneath the canvas since it last saw the note: keep it.
                        try insertVersionLocked(noteID: noteID, text: old, source: "device:another device", date: date)
                    } else if text.allSatisfy(\.isWhitespace), !old.allSatisfy(\.isWhitespace) {
                        try insertVersionLocked(noteID: noteID, text: old, source: "user", date: date)
                    }
                    try db.run("UPDATE notes SET text = ?, title = ?, word_count = ?, updated_at = ? WHERE id = ?",
                               .text(text), .text(title), .int(Int64(words)), .double(date.timeIntervalSince1970), .int(noteID))
                    changed = true
                }
                if let versionSource,
                   try insertVersionLocked(noteID: noteID, text: text, source: versionSource, date: date, packed: packed, words: words) != nil {
                    changed = true
                }
                try completeLocked(completions, noteID: noteID)
                return changed ? try summaryLocked(noteID) : nil
            }
        }
    }

    /// An agent's edit, all or nothing: a version of the text it replaces (as the user's), the new text, and a
    /// version of that by the agent. Throws `StoreError.conflict` if the note no longer says `expected`, so an
    /// edit worked out from an old read never overwrites a newer one.
    @discardableResult
    public func commitEdit(noteID: NoteID, expected: String, text: String, source: String,
                           completing completions: [Int64: AgentResult] = [:], date: Date = Date()) throws -> NoteSummary? {
        let title = NoteTitle.from(text)
        let words = WordCount.count(text)
        return try locked {
            try db.transaction {
                guard try liveTextLocked(noteID).utf8.elementsEqual(expected.utf8) else { throw StoreError.conflict(noteID) }
                try insertVersionLocked(noteID: noteID, text: expected, source: "user", date: date)
                try db.run("UPDATE notes SET text = ?, title = ?, word_count = ?, updated_at = ? WHERE id = ?",
                           .text(text), .text(title), .int(Int64(words)), .double(date.timeIntervalSince1970), .int(noteID))
                try insertVersionLocked(noteID: noteID, text: text, source: source, date: date, words: words)
                try completeLocked(completions, noteID: noteID)
                return try summaryLocked(noteID)
            }
        }
    }

    /// The text of a note that exists and isn't deleted.
    private func liveTextLocked(_ noteID: NoteID) throws -> String {
        let row = try db.prepare("SELECT text, deleted_at FROM notes WHERE id = ?")
        defer { row.reset() }
        try row.bind([.int(noteID)])
        guard try row.step() else { throw StoreError.noteNotFound(noteID) }
        guard row.isNull(1) else { throw StoreError.noteDeleted(noteID) }
        return row.text(0)
    }

    public enum Discarded: Equatable, Sendable {
        /// It never had anything in it, so it's gone.
        case removed
        /// It's empty now but has history, so it's in Recently Deleted.
        case movedToRecentlyDeleted
    }

    /// Leaving an empty note: removes it if it never had anything in it, otherwise moves it to Recently
    /// Deleted with its history. Returns nil, changing nothing, if it has text (or is already deleted).
    public func discardIfBlank(noteID: NoteID, date: Date = Date()) throws -> Discarded? {
        try locked {
            try db.transaction {
                let row = try db.prepare("SELECT text, version_count FROM notes WHERE id = ? AND deleted_at IS NULL")
                try row.bind([.int(noteID)])
                guard try row.step() else { row.reset(); return nil }
                let blank = row.text(0).allSatisfy(\.isWhitespace)
                let versions = row.int(1)
                row.reset()
                guard blank else { return nil }
                if versions == 0 {
                    try db.run("DELETE FROM notes WHERE id = ?", .int(noteID))
                    return .removed
                }
                try db.run("UPDATE notes SET deleted_at = ? WHERE id = ?", .double(date.timeIntervalSince1970), .int(noteID))
                return .movedToRecentlyDeleted
            }
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
        // Compress outside the lock so a big note never holds up other readers.
        let packed = Compression.pack(text)
        let words = WordCount.count(text)
        return try locked {
            try db.transaction {
                try insertVersionLocked(noteID: noteID, text: text, source: source, date: date, packed: packed, words: words)
            }
        }
    }

    /// The body of `addVersion`, for callers already holding the lock inside a transaction.
    @discardableResult
    func insertVersionLocked(noteID: NoteID, text: String, source: String, date: Date,
                             packed: (data: Data, compressed: Bool)? = nil, words: Int? = nil) throws -> VersionID? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        // An unreadable latest version counts as different, so this one is still kept.
        if let latest = try? latestVersionTextLocked(noteID), latest == text { return nil }
        let packed = packed ?? Compression.pack(text)
        try db.run("INSERT INTO versions (note_id, created_at, word_count, source, compressed, body) VALUES (?, ?, ?, ?, ?, ?)",
                   .int(noteID), .double(date.timeIntervalSince1970), .int(Int64(words ?? WordCount.count(text))), .text(source),
                   .int(packed.compressed ? 1 : 0), .blob(packed.data))
        let id = db.lastInsertRowID
        try db.run("UPDATE notes SET version_count = version_count + 1 WHERE id = ?", .int(noteID))
        return id
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
            return (summary, try Compression.unpack(row.blob(6), compressed: row.int(5) != 0))
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
        return try Compression.unpack(row.blob(1), compressed: row.int(0) != 0)
    }

    // MARK: State

    public func value(forKey key: String) -> String? {
        try? storedValue(forKey: key)
    }

    /// Like `value(forKey:)`, but a database error is an error, not "not set".
    public func storedValue(forKey key: String) throws -> String? {
        try locked {
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

    /// Whether agents may change notes (BlackText → Allow Agents to Edit). On by default; off if the
    /// setting can't be read, since a broken database shouldn't hand agents permission.
    public var agentsCanEdit: Bool {
        get {
            do {
                return try storedValue(forKey: "agents_can_edit") != "0"
            } catch {
                return false
            }
        }
        set { setValue(newValue ? "1" : "0", forKey: "agents_can_edit") }
    }

    // MARK: Search

    /// Searches every live note, most recently edited first.
    ///
    /// Two passes keep this fast at any size. First the newest notes are read directly, which fills
    /// the results almost at once for common words. If that isn't enough, older notes are streamed
    /// from an index (trigram for substrings, words for whole words), newest first, stopping at
    /// `limit`; each candidate is confirmed with `FindEngine` using the exact options.
    public func search(_ query: FindQuery, limit: Int = 100, scanBudget: Int = 2_000_000,
                       isCancelled: () -> Bool = { false }) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        _ = try FindEngine.regex(for: query)
        let columns = "\(Self.summaryColumns), text"
        let order = "ORDER BY updated_at DESC, id DESC"

        return try locked {
            var hits: [SearchHit] = []
            func consider(_ row: Statement) throws {
                let text = row.text(7) as NSString
                let ranges = try FindEngine.matches(of: query, in: text, limit: 10_000, isCancelled: isCancelled)
                guard !ranges.isEmpty else { return }
                let snippet = Snippet.make(in: text, matches: ranges)
                hits.append(SearchHit(note: summary(from: row), matchCount: ranges.count,
                                      snippet: snippet.text, snippetMatches: snippet.matches))
            }

            // Pass 1: the newest notes, read directly.
            var cursor: NoteCursor?
            var scanned = 0
            let recent = try db.prepare("SELECT \(columns) FROM notes WHERE deleted_at IS NULL \(order)")
            defer { recent.reset() }
            while hits.count < limit, scanned < scanBudget, !isCancelled() {
                guard try recent.step() else { return hits }
                try consider(recent)
                scanned += recent.byteCount(7)
                cursor = NoteCursor(updatedAt: Date(timeIntervalSince1970: recent.double(3)), id: recent.int64(0))
            }
            recent.reset()
            guard hits.count < limit, !isCancelled(), let cursor else { return hits }

            // Pass 2: older notes. An index streams candidates newest-created first, so nothing is
            // gathered up front; the hits found are then put in edit order.
            let older = "deleted_at IS NULL AND (updated_at, id) < (?, ?)"
            let after: [SQLValue?] = [.double(cursor.updatedAt.timeIntervalSince1970), .int(cursor.id)]
            var bindings = after
            let sql: String
            let index: (table: String, match: String)?
            if let phrase = Self.wordPhrase(for: query) {
                index = ("notes_words", phrase)
            } else if !query.options.regex, query.text.unicodeScalars.count >= 3 {
                index = ("notes_fts", Self.quoted(query.text))
            } else {
                index = nil
            }
            if let index {
                let prefixed = Self.summaryColumns.split(separator: ",").map { "n." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
                sql = """
                    SELECT \(prefixed), n.text FROM \(index.table) f JOIN notes n ON n.id = f.rowid
                    WHERE \(index.table) MATCH ? AND n.deleted_at IS NULL AND (n.updated_at, n.id) < (?, ?)
                    ORDER BY f.rowid DESC
                    """
                bindings = [.text(index.match)] + after
            } else if !query.options.regex, query.text.allSatisfy(\.isASCII) {
                // Too short for the trigram index: let SQLite skip non-matches (LIKE ignores ASCII case).
                let escaped = query.text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                sql = "SELECT \(columns) FROM notes WHERE \(older) AND text LIKE ? ESCAPE '\\' \(order)"
                bindings.append(.text("%\(escaped)%"))
            } else {
                sql = "SELECT \(columns) FROM notes WHERE \(older) \(order)"
            }
            let row = try db.prepare(sql)
            defer { row.reset() }
            try row.bind(bindings)
            let firstOlder = hits.count
            while hits.count < limit, !isCancelled(), try row.step() {
                try consider(row)
            }
            hits[firstOlder...].sort { ($0.note.updatedAt, $0.note.id) > ($1.note.updatedAt, $1.note.id) }
            return hits
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// For whole-word searches: the query's words as an FTS phrase, or nil if it has none.
    static func wordPhrase(for query: FindQuery) -> String? {
        guard query.options.wholeWord, !query.options.regex else { return nil }
        let words = query.text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return quoted(words.joined(separator: " "))
    }

    // MARK: Agent inbox

    /// Queues an agent edit for the running app to apply.
    public func enqueue(_ op: AgentOp) throws -> Int64 {
        let payload = try op.edit.encodedPayload(pinned: op.pinned, target: op.targetUID)
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
                guard let payload = try? JSONDecoder().decode(AgentEdit.Payload.self, from: Data(row.text(3).utf8)),
                      let edit = AgentEdit(kind: row.text(1), payload: payload) else { continue }
                var op = AgentOp(id: row.int64(0), noteID: row.optionalInt64(2), edit: edit, source: row.text(4))
                op.pinned = payload.pinned ?? false
                op.targetUID = payload.target
                ops.append(op)
            }
            return ops
        }
    }

    public func pendingOpCount() throws -> Int {
        try locked {
            let row = try db.prepare("SELECT COUNT(*) FROM inbox WHERE done_at IS NULL")
            defer { row.reset() }
            return try row.step() ? row.int(0) : 0
        }
    }

    func hasOp(id: Int64) throws -> Bool {
        try locked {
            let row = try db.prepare("SELECT 1 FROM inbox WHERE id = ?")
            defer { row.reset() }
            try row.bind([.int(id)])
            return try row.step()
        }
    }

    public func complete(opID: Int64, result: AgentResult) throws {
        try locked { try db.transaction { try completeLocked([opID: result]) } }
    }

    /// Records ops as done, for callers holding the lock inside a transaction. A result without a note gets
    /// `noteID`, the note the op ended up changing.
    func completeLocked(_ completions: [Int64: AgentResult], noteID: NoteID? = nil) throws {
        guard !completions.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for (opID, result) in completions where opID > 0 {
            var result = result
            if result.noteID == nil { result.noteID = noteID }
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            try db.run("UPDATE inbox SET result = ?, done_at = ? WHERE id = ? AND done_at IS NULL", .text(encoded), .double(now), .int(opID))
        }
        // Keep the inbox small: finished ops are only needed until their caller reads them.
        try db.run("DELETE FROM inbox WHERE done_at IS NOT NULL AND done_at < ?", .double(now - 3600))
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

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case noteNotFound(NoteID)
    case noteDeleted(NoteID)
    /// The note changed between reading it and writing the edit.
    case conflict(NoteID)

    public var description: String {
        switch self {
        case .noteNotFound(let id): return "No note with id \(id)."
        case .noteDeleted(let id): return "Note \(id) is in Recently Deleted."
        case .conflict(let id): return "Note \(id) changed while the edit was being made."
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
