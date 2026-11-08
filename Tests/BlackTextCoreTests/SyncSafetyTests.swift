import Foundation
import Testing
@testable import BlackTextCore

/// The sync fixes from the hardening plan's phase 2, on the database side (CloudKit isn't needed).
@Suite struct SyncSafetyTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    private func pending() throws -> [SyncChange] { try store.pendingSyncChanges(limit: 1000) }

    private func sendAll() throws {
        for change in try pending() { try store.clearSyncChange(outboxID: change.outboxID) }
    }

    /// The outbox row a send was built from must be the only one its acknowledgement clears, even when a
    /// newer edit's row would otherwise get the same id (SQLite reuses the highest one after a delete).
    @Test func anAcknowledgementNeverClearsANewerEdit() throws {
        let id = try store.createNote(text: "v1")
        let sent = try #require(try pending().first)
        // While v1 is on its way, its row goes (a merge with the server's copy clears it), and then
        // another edit is queued.
        try store.clearSyncChange(outboxID: sent.outboxID)
        try store.updateText(noteID: id, text: "v2, typed while v1 was sending")
        // v1's acknowledgement arrives.
        try store.clearSyncChange(outboxID: sent.outboxID)
        #expect(try pending().count == 1)
    }

    @Test func removingANoteQueuesItsVersionsForDeletion() throws {
        let id = try store.createNote(text: "a note")
        try store.addVersion(noteID: id, text: "a note")
        let versionUID = try #require(try pending().first { $0.kind == .version }?.uid)
        try sendAll()
        try store.hardDelete(noteID: id)
        let deletions = try pending()
        #expect(deletions.allSatisfy { $0.isDeletion })
        #expect(Set(deletions.map(\.kind)) == [.note, .version])
        #expect(deletions.contains { $0.uid == versionUID })
    }

    @Test func upgradingKeepsEveryQueuedChangeAndDeletion() throws {
        let url = temporaryDatabase()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(path: url.path)
        try db.execute("PRAGMA foreign_keys = ON")
        try Schema.migrate(db, to: 3)
        try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count) VALUES (1, 1, 'kept', 'kept', 1)")
        try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count) VALUES (1, 1, 'gone', 'gone', 1)")
        try db.run("DELETE FROM notes WHERE text = 'gone'")
        let before = try Store.outboxRows(db)
        #expect(before.count == 2)
        #expect(before.contains { $0.deleted })
        try Schema.migrate(db)

        #expect(try Store.outboxRows(db) == before)
        // From now on, a row's id is never handed out again.
        let highest = try #require(before.map(\.id).max())
        try db.run("DELETE FROM sync_outbox WHERE id = ?", .int(highest))
        try db.run("UPDATE notes SET text = 'kept, edited' WHERE text = 'kept'")
        let after = try Store.outboxRows(db).map(\.id).max() ?? 0
        #expect(after > highest)
    }

    @Test func aSendIsBuiltWithTheRowItClears() throws {
        let id = try store.createNote(text: "v1")
        let uid = try #require(try store.noteUID(id: id))
        let built = try #require(try store.syncNoteToSend(uid: uid))
        #expect(built.note.text == "v1")
        #expect(built.outboxID == (try pending().first?.outboxID))
        try store.updateText(noteID: id, text: "v2")
        try store.clearSyncChange(outboxID: try #require(built.outboxID))
        #expect(try store.syncNoteToSend(uid: uid)?.outboxID != nil, "v2 is still to send")
    }

    @Test func aChangeICloudRefusesIsSetAsideNotDropped() throws {
        let id = try store.createNote(text: "refused")
        let first = try #require(try pending().first)
        try store.markSyncChangeFailed(outboxID: first.outboxID, error: "Invalid arguments")
        #expect(try pending().isEmpty, "it no longer holds up what's behind it")
        let backlog = try store.syncBacklog()
        #expect(backlog.pending == 1)
        #expect(backlog.failed == 1)
        #expect(backlog.lastError == "Invalid arguments")
        try store.retryFailedSyncChanges()
        #expect(try pending().map(\.outboxID) == [first.outboxID])

        // A new edit replaces a set-aside change, and is sent normally.
        try store.markSyncChangeFailed(outboxID: first.outboxID, error: "Invalid arguments")
        try store.updateText(noteID: id, text: "refused, then fixed")
        #expect(try pending().count == 1)
    }

    @Test func aSaveForSomethingThatIsGoneIsDroppedButItsDeletionStays() throws {
        let id = try store.createNote(text: "x")
        let uid = try #require(try store.noteUID(id: id))
        try store.hardDelete(noteID: id)
        try store.clearObsoleteSyncSave(kind: .note, uid: uid)
        #expect(try pending().map(\.isDeletion) == [true])
    }

    @Test func aRemoteVersionDeletionRemovesIt() throws {
        let id = try store.createNote(text: "a note")
        try store.addVersion(noteID: id, text: "a note")
        let version = try #require(try store.versions(noteID: id).first)
        let uid = try #require(try pending().first { $0.kind == .version }?.uid)
        try sendAll()
        #expect(try store.applyRemoteDeletion(versionUID: uid) == id)
        #expect(try store.version(id: version.id) == nil)
        #expect(try store.summary(id: id)?.versionCount == 0)
        #expect(try pending().isEmpty, "it came from iCloud, so it isn't sent back")
    }

    /// After the user deletes BlackText's iCloud data: nothing cached from iCloud or waiting to go back to
    /// it is kept, but every note is, and sync stays off across launches until they say otherwise.
    @Test func forgettingTheCloudKeepsTheNotes() throws {
        let id = try store.createNote(text: "mine")
        try store.addVersion(noteID: id, text: "mine")
        try store.setSystemFields(Data([1]), noteUID: try #require(try store.noteUID(id: id)))
        store.setValue("engine state", forKey: "sync_engine_state")
        try store.forgetCloudCache()
        store.syncSuspension = .purged
        #expect(try pending().isEmpty)
        #expect(try store.note(id: id)?.text == "mine")
        #expect(try store.versions(noteID: id).count == 1)
        #expect(store.value(forKey: "sync_engine_state") == nil)

        let reopened = try Store(url: store.url)
        #expect(reopened.syncSuspension == .purged)
        reopened.syncSuspension = nil
        #expect(reopened.syncSuspension == nil)
    }

    @Test func aRemoteDeleteIsReportedAsAChange() throws {
        let id = try store.createNote(text: "same text")
        let uid = try #require(try store.noteUID(id: id))
        try sendAll()
        let deleted = SyncNote(uid: uid, text: "same text", createdAt: Date(), editedAt: Date(), deletedAt: Date(), device: "iPhone")
        #expect(try store.applyRemote(note: deleted, systemFields: nil, thisDevice: "Mac") == .updated(id))
        #expect(try store.note(id: id)?.deletedAt != nil)
    }
}

/// Typing in the canvas while a change from another device lands underneath it.
@MainActor @Suite struct RemoteChangeUnderTheCanvasTests {
    final class Canvas { var text = "" }

    @Test func typingOverAChangeFromAnotherDeviceKeepsTheirText() throws {
        let store = try Store(url: temporaryDatabase())
        let sync = try Store(url: store.url)
        let session = NoteSession(store: store, saveStore: try Store(url: store.url))
        let canvas = Canvas()
        session.text = { canvas.text }

        let id = try store.createNote(text: "ours")
        let uid = try #require(try store.noteUID(id: id))
        for change in try store.pendingSyncChanges() { try store.clearSyncChange(outboxID: change.outboxID) }
        session.load(try store.note(id: id))
        canvas.text = "ours"

        // Sync writes the other device's text; before the canvas reloads, an autosave writes what's on screen.
        let theirs = SyncNote(uid: uid, text: "theirs", createdAt: Date(), editedAt: Date().addingTimeInterval(10), deletedAt: nil, device: "iPhone")
        _ = try sync.applyRemote(note: theirs, systemFields: nil, thisDevice: "Mac")
        canvas.text = "ours, typed on"
        session.textDidChange()
        session.save(wait: true)

        #expect(try store.note(id: id)?.text == "ours, typed on")
        let kept = try store.versions(noteID: id).compactMap { try store.version(id: $0.id)?.text }
        #expect(kept.contains("theirs"))
    }
}

extension Store {
    struct OutboxRow: Equatable {
        var id: Int64
        var kind: String
        var uid: String
        var deleted: Bool
    }

    static func outboxRows(_ db: Database) throws -> [OutboxRow] {
        let row = try db.prepare("SELECT id, kind, uid, deleted FROM sync_outbox ORDER BY id")
        defer { row.reset() }
        var rows: [OutboxRow] = []
        while try row.step() { rows.append(OutboxRow(id: row.int64(0), kind: row.text(1), uid: row.text(2), deleted: row.int(3) != 0)) }
        return rows
    }
}

@Suite struct BackupTests {
    /// A backup has everything (history and Recently Deleted too), and if it's ever put back it doesn't
    /// sync until the user says so: its sync bookkeeping is from another time.
    @Test func aBackupIsCompleteAndDoesNotSyncUntilAsked() throws {
        let store = try Store(url: temporaryDatabase())
        let id = try store.createNote(text: "kept", versionSource: "user")
        let gone = try store.createNote(text: "in Recently Deleted")
        try store.softDelete(noteID: gone)
        try store.setSystemFields(Data([1]), noteUID: try #require(try store.noteUID(id: id)))
        let url = temporaryDatabase().deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.writeBackup(to: url)

        let restored = try Store(url: url)
        #expect(try restored.note(id: id)?.text == "kept")
        #expect(try restored.versions(noteID: id).count == 1)
        #expect(try restored.deletedCount() == 1)
        #expect(restored.syncSuspension == .restoredBackup)
        #expect(try restored.systemFields(noteUID: try #require(try restored.noteUID(id: id))) == nil)
        #expect(store.syncSuspension == nil, "the library itself is untouched")
    }
}
