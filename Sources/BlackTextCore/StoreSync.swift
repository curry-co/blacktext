import Foundation

/// A record waiting to be sent to iCloud.
public struct SyncChange: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case note, version }
    /// The outbox row. A newer change to the same record replaces the row and gets a new id; ids are never
    /// reused, so clearing this one can never clear a newer change.
    public var outboxID: Int64
    public var kind: Kind
    public var uid: String
    public var isDeletion: Bool
}

/// A note as it travels between devices.
public struct SyncNote: Equatable, Sendable {
    public var uid: String
    public var text: String
    public var createdAt: Date
    public var editedAt: Date
    public var deletedAt: Date?
    /// The device that last edited it, shown on the version kept when two devices disagree.
    public var device: String

    public init(uid: String, text: String, createdAt: Date, editedAt: Date, deletedAt: Date?, device: String) {
        self.uid = uid
        self.text = text
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.device = device
    }
}

/// A version as it travels between devices. Versions never change once made.
public struct SyncVersion: Equatable, Sendable {
    public var uid: String
    public var noteUID: String
    public var createdAt: Date
    public var source: String
    /// The body as stored: LZFSE-compressed when `compressed`.
    public var body: Data
    public var compressed: Bool

    public init(uid: String, noteUID: String, createdAt: Date, source: String, body: Data, compressed: Bool) {
        self.uid = uid
        self.noteUID = noteUID
        self.createdAt = createdAt
        self.source = source
        self.body = body
        self.compressed = compressed
    }

    /// Throws when the body can't be read (see `Compression.unpack`).
    public var text: String { get throws { try Compression.unpack(body, compressed: compressed) } }
}

/// Why sync stopped and waits for the user before it sends or fetches anything again.
public enum SyncSuspension: String, Sendable {
    /// The user deleted BlackText's data from iCloud (Settings → iCloud). Apple asks apps not to send it back.
    case purged
    /// The user reset their encrypted iCloud data.
    case encryptedDataReset
    /// This device is signed in to a different iCloud account from the one these notes sync with.
    case otherAccount
    /// The notes were put back from a backup, whose sync bookkeeping is from another time.
    case restoredBackup

    public var explanation: String {
        switch self {
        case .purged:
            return "BlackText's data was deleted from iCloud. The notes on this device are all still here, but they won't be sent to iCloud again unless you turn sync back on."
        case .encryptedDataReset:
            return "Your encrypted iCloud data was reset. The notes on this device are all still here, but they won't be sent to iCloud again unless you turn sync back on."
        case .otherAccount:
            return "This device is signed in to a different iCloud account. Your notes stay on this device and nothing is sent until you choose to sync them with this account."
        case .restoredBackup:
            return "These notes were restored from a backup. Nothing is sent to iCloud until you turn sync on; then they're merged with what's there, and where a note differs, both texts are kept."
        }
    }
}

/// What applying a note from another device did.
public enum RemoteNoteResult: Equatable, Sendable {
    case inserted(NoteID)
    case updated(NoteID)
    /// Both devices changed it and this device's edit is newer, so it still has to be sent.
    case keptLocal(NoteID)
    case unchanged(NoteID)

    public var noteID: NoteID {
        switch self {
        case .inserted(let id), .updated(let id), .keptLocal(let id), .unchanged(let id): id
        }
    }
}

extension VersionSummary {
    /// For versions kept when two devices edited a note at once: the device whose text it was.
    public var deviceName: String? {
        source.hasPrefix("device:") ? String(source.dropFirst("device:".count)) : nil
    }

    /// Where a version came from, for showing beside it: "by claude-code" for an agent's edit, "from iPhone"
    /// for text kept when two devices edited the note at once. Nil for the user's own versions.
    public var origin: String? {
        agentName.map { "by \($0)" } ?? deviceName.map { "from \($0)" }
    }
}

extension Store {
    // MARK: Outbox

    /// Records waiting to be sent, oldest change first. Changes that failed for good are left out until
    /// they're retried (see `retryFailedSyncChanges`) or the record changes again.
    public func pendingSyncChanges(limit: Int = 500, after outboxID: Int64 = 0) throws -> [SyncChange] {
        try locked {
            let row = try db.prepare("SELECT id, kind, uid, deleted FROM sync_outbox WHERE id > ? AND failed_at IS NULL ORDER BY id LIMIT ?")
            defer { row.reset() }
            try row.bind([.int(outboxID), .int(Int64(limit))])
            var changes: [SyncChange] = []
            while try row.step() {
                guard let kind = SyncChange.Kind(rawValue: row.text(1)) else { continue }
                changes.append(SyncChange(outboxID: row.int64(0), kind: kind, uid: row.text(2), isDeletion: row.int(3) != 0))
            }
            return changes
        }
    }

    /// Marks a change as sent. If the record changed again since, its row has a new id and stays.
    public func clearSyncChange(outboxID: Int64) throws {
        try locked { try db.run("DELETE FROM sync_outbox WHERE id = ?", .int(outboxID)) }
    }

    /// Drops a queued save for a record that isn't here any more. A queued deletion for it stays.
    public func clearObsoleteSyncSave(kind: SyncChange.Kind, uid: String) throws {
        try locked {
            try db.run("DELETE FROM sync_outbox WHERE kind = ? AND uid = ? AND deleted = 0", .text(kind.rawValue), .text(uid))
        }
    }

    /// The outbox row waiting for a record, if any.
    public func pendingSyncChange(kind: SyncChange.Kind, uid: String) throws -> Int64? {
        try locked { try outboxIDLocked(kind: kind, uid: uid) }
    }

    /// Sets a change aside after iCloud refused it for good, with the reason. It stays in the outbox, so it
    /// isn't lost, but stops holding up the rest.
    public func markSyncChangeFailed(outboxID: Int64, error: String) throws {
        try locked {
            try db.run("UPDATE sync_outbox SET failed_at = ?, error = ? WHERE id = ?",
                       .double(Date().timeIntervalSince1970), .text(error), .int(outboxID))
        }
    }

    /// Puts changes that failed back in line.
    public func retryFailedSyncChanges() throws {
        try locked { try db.run("UPDATE sync_outbox SET failed_at = NULL, error = NULL WHERE failed_at IS NOT NULL") }
    }

    /// How many changes are waiting to be sent, and how many of those failed.
    public func syncBacklog() throws -> (pending: Int, failed: Int, lastError: String?) {
        try locked {
            let row = try db.prepare("SELECT COUNT(*), COUNT(failed_at), (SELECT error FROM sync_outbox WHERE failed_at IS NOT NULL ORDER BY failed_at DESC LIMIT 1) FROM sync_outbox")
            defer { row.reset() }
            guard try row.step() else { return (0, 0, nil) }
            return (row.int(0), row.int(1), row.optionalText(2))
        }
    }

    /// Forgets what came from iCloud and isn't a note yet, and everything waiting to go to it, after the user
    /// deleted or reset their iCloud data. The notes and their history stay: they're the user's, and this is
    /// the copy that matters. Nothing is queued to be sent.
    public func forgetCloudCache() throws {
        try locked {
            try db.transaction {
                try db.execute("""
                    DELETE FROM sync_records;
                    DELETE FROM sync_outbox;
                    DELETE FROM sync_orphans;
                    DELETE FROM state WHERE key = 'sync_engine_state';
                    """)
            }
        }
    }

    /// Why sync is stopped, if it is. Kept in the database, so it holds across launches.
    public var syncSuspension: SyncSuspension? {
        get { value(forKey: "sync_suspended").flatMap(SyncSuspension.init(rawValue:)) }
        set { setValue(newValue?.rawValue, forKey: "sync_suspended") }
    }

    /// The iCloud account (its user record name) these notes sync with.
    public var syncAccount: String? {
        get { value(forKey: "sync_account") }
        set { setValue(newValue, forKey: "sync_account") }
    }

    /// Forgets everything CloudKit told us and queues every note and version to be sent again.
    /// Used when the iCloud account changes or the user's iCloud data was reset.
    public func resetSyncState() throws {
        try locked {
            try db.transaction {
                try db.execute("""
                    DELETE FROM sync_records;
                    DELETE FROM sync_outbox;
                    INSERT INTO sync_outbox (kind, uid) SELECT 'note', uid FROM notes;
                    INSERT INTO sync_outbox (kind, uid) SELECT 'version', uid FROM versions;
                    """)
            }
        }
    }

    // MARK: Reading records to send

    /// A note to send, with the outbox row it was read alongside (from the same snapshot), so the send's
    /// acknowledgement clears exactly that change. nil if the note isn't here.
    public func syncNoteToSend(uid: String) throws -> (note: SyncNote, outboxID: Int64?)? {
        try locked {
            try db.read {
                guard let note = try syncNoteLocked(uid: uid) else { return nil }
                return (note, try outboxIDLocked(kind: .note, uid: uid))
            }
        }
    }

    public func syncVersionToSend(uid: String) throws -> (version: SyncVersion, outboxID: Int64?)? {
        try locked {
            try db.read {
                guard let version = try syncVersionLocked(uid: uid) else { return nil }
                return (version, try outboxIDLocked(kind: .version, uid: uid))
            }
        }
    }

    private func outboxIDLocked(kind: SyncChange.Kind, uid: String) throws -> Int64? {
        let row = try db.prepare("SELECT id FROM sync_outbox WHERE kind = ? AND uid = ?")
        defer { row.reset() }
        try row.bind([.text(kind.rawValue), .text(uid)])
        return try row.step() ? row.int64(0) : nil
    }

    public func syncNote(uid: String) throws -> SyncNote? {
        try locked { try syncNoteLocked(uid: uid) }
    }

    private func syncNoteLocked(uid: String) throws -> SyncNote? {
        let row = try db.prepare("SELECT text, created_at, updated_at, deleted_at FROM notes WHERE uid = ?")
        defer { row.reset() }
        try row.bind([.text(uid)])
        guard try row.step() else { return nil }
        return SyncNote(uid: uid, text: row.text(0),
                        createdAt: Date(timeIntervalSince1970: row.double(1)),
                        editedAt: Date(timeIntervalSince1970: row.double(2)),
                        deletedAt: row.optionalDouble(3).map(Date.init(timeIntervalSince1970:)),
                        device: "")
    }

    public func syncVersion(uid: String) throws -> SyncVersion? {
        try locked { try syncVersionLocked(uid: uid) }
    }

    private func syncVersionLocked(uid: String) throws -> SyncVersion? {
        let row = try db.prepare("""
            SELECT n.uid, v.created_at, v.source, v.body, v.compressed
            FROM versions v JOIN notes n ON n.id = v.note_id WHERE v.uid = ?
            """)
        defer { row.reset() }
        try row.bind([.text(uid)])
        guard try row.step() else { return nil }
        return SyncVersion(uid: uid, noteUID: row.text(0), createdAt: Date(timeIntervalSince1970: row.double(1)),
                           source: row.text(2), body: row.blob(3), compressed: row.int(4) != 0)
    }

    public func noteID(uid: String) throws -> NoteID? {
        try locked { try noteIDLocked(uid: uid) }
    }

    public func noteUID(id: NoteID) throws -> String? {
        try locked {
            let row = try db.prepare("SELECT uid FROM notes WHERE id = ?")
            defer { row.reset() }
            try row.bind([.int(id)])
            return try row.step() ? row.optionalText(0) : nil
        }
    }

    // MARK: CloudKit bookkeeping

    public func systemFields(noteUID: String) throws -> Data? {
        try locked {
            let row = try db.prepare("SELECT system_fields FROM sync_records WHERE uid = ?")
            defer { row.reset() }
            try row.bind([.text(noteUID)])
            return try row.step() ? row.blob(0) : nil
        }
    }

    public func setSystemFields(_ data: Data?, noteUID: String) throws {
        try locked { try setSystemFieldsLocked(data, noteUID: noteUID) }
    }

    // MARK: Applying changes from other devices

    /// Writes a note that changed on another device.
    ///
    /// If this device also changed it and hasn't sent that yet, the most recently edited text wins
    /// and the other is kept as a version marked with its device, so nothing is ever lost.
    public func applyRemote(note remote: SyncNote, systemFields: Data?, thisDevice: String) throws -> RemoteNoteResult {
        let title = NoteTitle.from(remote.text)
        let words = Int64(WordCount.count(remote.text))
        let deleted: SQLValue? = .from(remote.deletedAt?.timeIntervalSince1970)
        return try locked {
            try db.transaction {
                if let systemFields { try setSystemFieldsLocked(systemFields, noteUID: remote.uid) }

                let row = try db.prepare("SELECT id, text, updated_at, deleted_at FROM notes WHERE uid = ?")
                try row.bind([.text(remote.uid)])
                guard try row.step() else {
                    row.reset()
                    try db.run("""
                        INSERT INTO notes (uid, created_at, updated_at, text, title, word_count, deleted_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, .text(remote.uid), .double(remote.createdAt.timeIntervalSince1970),
                        .double(remote.editedAt.timeIntervalSince1970), .text(remote.text), .text(title), .int(words), deleted)
                    let id = db.lastInsertRowID
                    try adoptOrphansLocked(noteUID: remote.uid, noteID: id)
                    try clearOutboxLocked(kind: .note, uid: remote.uid)
                    return .inserted(id)
                }
                let id = row.int64(0)
                let localText = row.text(1)
                let localEditedAt = Date(timeIntervalSince1970: row.double(2))
                let localDeletedAt = row.optionalDouble(3)
                row.reset()

                let editedHere = try pendingLocked(kind: .note, uid: remote.uid)
                if editedHere {
                    if localText == remote.text { return .keptLocal(id) }
                    if localEditedAt >= remote.editedAt {
                        // This device's edit is newer: keep it, and keep theirs as a version.
                        try insertVersionLocked(noteID: id, text: remote.text, source: "device:\(remote.device)", date: Date())
                        return .keptLocal(id)
                    }
                    // Theirs is newer: keep this device's text as a version, then take theirs.
                    try insertVersionLocked(noteID: id, text: localText, source: "device:\(thisDevice)", date: Date())
                }

                try db.run("""
                    UPDATE notes SET text = ?, title = ?, word_count = ?, created_at = ?, updated_at = ?, deleted_at = ?
                    WHERE id = ?
                    """, .text(remote.text), .text(title), .int(words), .double(remote.createdAt.timeIntervalSince1970),
                    .double(remote.editedAt.timeIntervalSince1970), deleted, .int(id))
                // The update queued this note to be sent back; it came from there, so it doesn't need to be.
                try clearOutboxLocked(kind: .note, uid: remote.uid)
                // Moving to or from Recently Deleted is a change too, even with the same text.
                let sameDeletion = localDeletedAt == remote.deletedAt?.timeIntervalSince1970
                return localText == remote.text && sameDeletion && !editedHere ? .unchanged(id) : .updated(id)
            }
        }
    }

    /// Adds a version made on another device. Returns its note's id, or nil if the note hasn't arrived
    /// yet (the version waits for it) or the version was already here.
    @discardableResult
    public func applyRemote(version remote: SyncVersion) throws -> NoteID? {
        // A body this build can't read is stored nowhere, so it can never be restored as empty text.
        let words = Int64(WordCount.count(try remote.text))
        return try locked {
            try db.transaction {
                let exists = try db.prepare("SELECT 1 FROM versions WHERE uid = ?")
                defer { exists.reset() }
                try exists.bind([.text(remote.uid)])
                if try exists.step() { return nil }

                guard let noteID = try noteIDLocked(uid: remote.noteUID) else {
                    try db.run("""
                        INSERT OR IGNORE INTO sync_orphans (uid, note_uid, created_at, word_count, source, compressed, body)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, .text(remote.uid), .text(remote.noteUID), .double(remote.createdAt.timeIntervalSince1970),
                        .int(words), .text(remote.source), .int(remote.compressed ? 1 : 0), .blob(remote.body))
                    return nil
                }
                try db.run("""
                    INSERT INTO versions (uid, note_id, created_at, word_count, source, compressed, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, .text(remote.uid), .int(noteID), .double(remote.createdAt.timeIntervalSince1970), .int(words),
                    .text(remote.source), .int(remote.compressed ? 1 : 0), .blob(remote.body))
                try db.run("UPDATE notes SET version_count = version_count + 1 WHERE id = ?", .int(noteID))
                try clearOutboxLocked(kind: .version, uid: remote.uid)
                return noteID
            }
        }
    }

    /// Removes a note deleted for good on another device. If this device has unsent edits to it,
    /// they win: the note stays and will be sent again as a new record.
    @discardableResult
    public func applyRemoteDeletion(noteUID: String) throws -> NoteID? {
        try locked {
            try db.transaction {
                try db.run("DELETE FROM sync_records WHERE uid = ?", .text(noteUID))
                try db.run("DELETE FROM sync_orphans WHERE note_uid = ?", .text(noteUID))
                guard let id = try noteIDLocked(uid: noteUID) else { return nil }
                if try pendingLocked(kind: .note, uid: noteUID) { return nil }
                let versions = try db.prepare("SELECT uid FROM versions WHERE note_id = ? AND uid IS NOT NULL")
                try versions.bind([.int(id)])
                var versionUIDs: [String] = []
                while try versions.step() { versionUIDs.append(versions.text(0)) }
                versions.reset()
                try db.run("DELETE FROM notes WHERE id = ?", .int(id))
                // Its versions go with it here. The device that removed it sends their deletions (or iCloud
                // removes them along with it), so neither the note nor its versions are sent back.
                try clearOutboxLocked(kind: .note, uid: noteUID)
                for uid in versionUIDs { try clearOutboxLocked(kind: .version, uid: uid) }
                return id
            }
        }
    }

    /// Removes a version deleted on another device (its note was removed there). Returns its note's id, or
    /// nil if it wasn't here. The deletion came from iCloud, so it isn't sent back.
    @discardableResult
    public func applyRemoteDeletion(versionUID: String) throws -> NoteID? {
        try locked {
            try db.transaction {
                try db.run("DELETE FROM sync_orphans WHERE uid = ?", .text(versionUID))
                let row = try db.prepare("SELECT note_id FROM versions WHERE uid = ?")
                try row.bind([.text(versionUID)])
                guard try row.step() else { row.reset(); return nil }
                let noteID = row.int64(0)
                row.reset()
                try db.run("DELETE FROM versions WHERE uid = ?", .text(versionUID))
                try db.run("UPDATE notes SET version_count = max(0, version_count - 1) WHERE id = ?", .int(noteID))
                try clearOutboxLocked(kind: .version, uid: versionUID)
                return noteID
            }
        }
    }

    // MARK: Records this build couldn't read

    public struct UnreadableRecord: Equatable, Sendable {
        public var recordName: String
        public var recordType: String
        /// The whole record, archived.
        public var record: Data
        /// The bytes of its body asset, if it had one (CloudKit's own copy is temporary).
        public var asset: Data?
    }

    /// Keeps a record from iCloud that couldn't be read (damaged, or from a newer BlackText), so it isn't
    /// lost when sync moves past it. A later version of the record replaces it.
    public func keepUnreadable(_ record: UnreadableRecord) throws {
        try locked {
            try db.run("""
                INSERT INTO sync_unreadable (record_name, record_type, record, asset, received_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(record_name) DO UPDATE SET record_type = excluded.record_type, record = excluded.record,
                    asset = excluded.asset, received_at = excluded.received_at
                """, .text(record.recordName), .text(record.recordType), .blob(record.record),
                       record.asset.map(SQLValue.blob), .double(Date().timeIntervalSince1970))
        }
    }

    public func unreadableRecords() throws -> [UnreadableRecord] {
        try locked {
            let row = try db.prepare("SELECT record_name, record_type, record, asset FROM sync_unreadable ORDER BY received_at")
            defer { row.reset() }
            var records: [UnreadableRecord] = []
            while try row.step() {
                records.append(UnreadableRecord(recordName: row.text(0), recordType: row.text(1), record: row.blob(2),
                                                asset: row.isNull(3) ? nil : row.blob(3)))
            }
            return records
        }
    }

    public func forgetUnreadable(recordName: String) throws {
        try locked { try db.run("DELETE FROM sync_unreadable WHERE record_name = ?", .text(recordName)) }
    }

    // MARK: Helpers (call with the lock held)

    func noteIDLocked(uid: String) throws -> NoteID? {
        let row = try db.prepare("SELECT id FROM notes WHERE uid = ?")
        defer { row.reset() }
        try row.bind([.text(uid)])
        return try row.step() ? row.int64(0) : nil
    }

    private func pendingLocked(kind: SyncChange.Kind, uid: String) throws -> Bool {
        let row = try db.prepare("SELECT 1 FROM sync_outbox WHERE kind = ? AND uid = ? AND deleted = 0")
        defer { row.reset() }
        try row.bind([.text(kind.rawValue), .text(uid)])
        return try row.step()
    }

    private func clearOutboxLocked(kind: SyncChange.Kind, uid: String) throws {
        try db.run("DELETE FROM sync_outbox WHERE kind = ? AND uid = ?", .text(kind.rawValue), .text(uid))
    }

    private func setSystemFieldsLocked(_ data: Data?, noteUID: String) throws {
        if let data {
            try db.run("INSERT INTO sync_records (uid, system_fields) VALUES (?, ?) ON CONFLICT(uid) DO UPDATE SET system_fields = excluded.system_fields",
                       .text(noteUID), .blob(data))
        } else {
            try db.run("DELETE FROM sync_records WHERE uid = ?", .text(noteUID))
        }
    }

    /// Versions that arrived before their note join it now. They came from iCloud, so they aren't sent back.
    private func adoptOrphansLocked(noteUID: String, noteID: NoteID) throws {
        try db.run("""
            INSERT OR IGNORE INTO versions (uid, note_id, created_at, word_count, source, compressed, body)
            SELECT uid, ?, created_at, word_count, source, compressed, body FROM sync_orphans WHERE note_uid = ?
            """, .int(noteID), .text(noteUID))
        let adopted = db.changes
        guard adopted > 0 else { return }
        try db.run("UPDATE notes SET version_count = version_count + ? WHERE id = ?", .int(Int64(adopted)), .int(noteID))
        try db.run("""
            DELETE FROM sync_outbox WHERE kind = 'version' AND uid IN (SELECT uid FROM sync_orphans WHERE note_uid = ?)
            """, .text(noteUID))
        try db.run("DELETE FROM sync_orphans WHERE note_uid = ?", .text(noteUID))
    }
}
