import Foundation
import Testing
@testable import BlackTextCore

@Suite struct SyncTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    private func pending() throws -> [SyncChange] { try store.pendingSyncChanges(limit: 1000) }

    private func remote(_ uid: String, _ text: String, edited: Date, device: String = "iPhone",
                        deleted: Date? = nil) -> SyncNote {
        SyncNote(uid: uid, text: text, createdAt: edited.addingTimeInterval(-60), editedAt: edited, deletedAt: deleted, device: device)
    }

    // MARK: Outbox

    @Test func everyWriteIsQueuedOncePerRecord() throws {
        let id = try store.createNote(text: "first")
        let uid = try #require(try store.noteUID(id: id))
        #expect(uid.count == 32)
        #expect(try pending().map(\.uid) == [uid])

        try store.updateText(noteID: id, text: "second")
        try store.updateText(noteID: id, text: "third")
        #expect(try pending().count == 1, "a newer change replaces the queued one")

        try store.addVersion(noteID: id, text: "third")
        #expect(try pending().map(\.kind) == [.note, .version])
    }

    @Test func clearingAnOldChangeKeepsANewerOne() throws {
        let id = try store.createNote(text: "first")
        let queued = try #require(try pending().first)
        try store.updateText(noteID: id, text: "edited while sending")
        try store.clearSyncChange(outboxID: queued.outboxID)
        #expect(try pending().count == 1)
    }

    @Test func deletingANoteQueuesADeletion() throws {
        let id = try store.createNote(text: "gone soon")
        let uid = try #require(try store.noteUID(id: id))
        try store.softDelete(noteID: id)
        #expect(try pending().first?.isDeletion == false, "Recently Deleted is just a field")
        try store.hardDelete(noteID: id)
        #expect(try pending() == [SyncChange(outboxID: try pending()[0].outboxID, kind: .note, uid: uid, isDeletion: true)])
    }

    @Test func upgradingAnExistingDatabaseGivesEveryNoteAUidAndQueuesIt() throws {
        let url = temporaryDatabase()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(path: url.path)
        try Schema.migrate(db, to: 2)
        try db.run("INSERT INTO notes (created_at, updated_at, text, title, word_count) VALUES (1, 1, 'old note', 'old note', 2)")
        try db.run("INSERT INTO versions (note_id, created_at, word_count, body) VALUES (1, 1, 2, x'6f6c64')")
        try Schema.migrate(db)

        let upgraded = try Store(url: url)
        let changes = try upgraded.pendingSyncChanges()
        #expect(changes.map(\.kind) == [.note, .version])
        #expect(try upgraded.syncNote(uid: changes[0].uid)?.text == "old note")
        #expect(try upgraded.syncVersion(uid: changes[1].uid)?.noteUID == changes[0].uid)
    }

    // MARK: Applying remote changes

    @Test func aNewRemoteNoteIsAddedAndNotSentBack() throws {
        let edited = Date(timeIntervalSince1970: 1_800_000_000)
        let result = try store.applyRemote(note: remote("abc", "from the phone", edited: edited), systemFields: Data([1]), thisDevice: "Mac")
        guard case .inserted(let id) = result else { Issue.record("expected insert, got \(result)"); return }
        let note = try #require(try store.note(id: id))
        #expect(note.text == "from the phone")
        #expect(note.title == "from the phone")
        #expect(note.updatedAt == edited)
        #expect(try pending().isEmpty)
        #expect(try store.systemFields(noteUID: "abc") == Data([1]))
    }

    @Test func aRemoteEditReplacesAnUnchangedLocalNote() throws {
        let id = try store.createNote(text: "draft")
        let uid = try #require(try store.noteUID(id: id))
        try store.clearSyncChange(outboxID: try pending()[0].outboxID) // sent

        let result = try store.applyRemote(note: remote(uid, "draft, finished on the phone", edited: Date().addingTimeInterval(5)),
                                           systemFields: nil, thisDevice: "Mac")
        #expect(result == .updated(id))
        #expect(try store.note(id: id)?.text == "draft, finished on the phone")
        #expect(try store.versions(noteID: id).isEmpty)
        #expect(try pending().isEmpty)
    }

    @Test func whenBothChangedTheNewerTextWinsAndTheOlderBecomesAVersion() throws {
        let id = try store.createNote(text: "typed on the Mac")
        let uid = try #require(try store.noteUID(id: id))

        // The phone's edit is newer.
        let result = try store.applyRemote(note: remote(uid, "typed on the phone", edited: Date().addingTimeInterval(30)),
                                           systemFields: nil, thisDevice: "Mac")
        #expect(result == .updated(id))
        #expect(try store.note(id: id)?.text == "typed on the phone")
        let kept = try #require(try store.versions(noteID: id).first)
        #expect(kept.deviceName == "Mac")
        #expect(try store.version(id: kept.id)?.text == "typed on the Mac")
        #expect(try pending().map(\.kind) == [.version], "the kept text is sent; the note isn't sent back")
    }

    @Test func whenBothChangedAndThisDeviceIsNewerItKeepsItsText() throws {
        let id = try store.createNote(text: "typed on the Mac, later")
        let uid = try #require(try store.noteUID(id: id))

        let result = try store.applyRemote(note: remote(uid, "typed on the phone, earlier", edited: Date().addingTimeInterval(-30)),
                                           systemFields: nil, thisDevice: "Mac")
        #expect(result == .keptLocal(id))
        #expect(try store.note(id: id)?.text == "typed on the Mac, later")
        let kept = try #require(try store.versions(noteID: id).first)
        #expect(kept.deviceName == "iPhone")
        #expect(Set(try pending().map(\.kind)) == [.note, .version])
    }

    @Test func versionsThatArriveBeforeTheirNoteWaitForIt() throws {
        let body = Data("an older draft".utf8)
        let version = SyncVersion(uid: "v1", noteUID: "n1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  source: "user", body: body, compressed: false)
        #expect(try store.applyRemote(version: version) == nil)

        let result = try store.applyRemote(note: remote("n1", "the note", edited: Date()), systemFields: nil, thisDevice: "Mac")
        let versions = try store.versions(noteID: result.noteID)
        #expect(versions.count == 1)
        #expect(try store.summary(id: result.noteID)?.versionCount == 1)
        #expect(try store.version(id: versions[0].id)?.text == "an older draft")
        #expect(try pending().isEmpty)
        #expect(try store.applyRemote(version: version) == nil, "the same version twice is ignored")
    }

    @Test func aRemoteDeletionRemovesTheNoteUnlessItWasEditedHere() throws {
        let kept = try store.createNote(text: "edited here")
        let keptUID = try #require(try store.noteUID(id: kept))
        #expect(try store.applyRemoteDeletion(noteUID: keptUID) == nil)
        #expect(try store.note(id: kept) != nil)

        let gone = try store.applyRemote(note: remote("x", "purged elsewhere", edited: Date()), systemFields: nil, thisDevice: "Mac")
        try store.addVersion(noteID: gone.noteID, text: "purged elsewhere")
        try store.clearSyncChange(outboxID: try pending().last!.outboxID)
        #expect(try store.applyRemoteDeletion(noteUID: "x") == gone.noteID)
        #expect(try store.note(id: gone.noteID) == nil)
        #expect(try pending().allSatisfy { $0.uid == keptUID })
    }

    @Test func recentlyDeletedSyncsBothWays() throws {
        let id = try store.createNote(text: "put back later")
        let uid = try #require(try store.noteUID(id: id))
        try store.clearSyncChange(outboxID: try pending()[0].outboxID)
        let edited = try #require(try store.note(id: id)).updatedAt

        _ = try store.applyRemote(note: remote(uid, "put back later", edited: edited, deleted: Date()), systemFields: nil, thisDevice: "Mac")
        #expect(try store.note(id: id)?.deletedAt != nil)
        _ = try store.applyRemote(note: remote(uid, "put back later", edited: edited, deleted: nil), systemFields: nil, thisDevice: "Mac")
        #expect(try store.note(id: id)?.deletedAt == nil)
    }

    @Test func resettingQueuesEverythingAgain() throws {
        let id = try store.createNote(text: "one")
        try store.addVersion(noteID: id, text: "one")
        for change in try pending() { try store.clearSyncChange(outboxID: change.outboxID) }
        try store.resetSyncState()
        #expect(try pending().count == 2)
    }
}

#if canImport(CloudKit)
import CloudKit

@Suite struct CloudRecordTests {
    @Test func notesRoundTripThroughRecordsWithEncryptedText() throws {
        let note = SyncNote(uid: "abc", text: String(repeating: "coffee, black. ", count: 100),
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000), editedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            deletedAt: nil, device: "Mac")
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, note.uid))
        CloudSync.fill(record, with: note)
        #expect(record["body"] == nil, "the text only lives in the encrypted field")
        #expect(record.encryptedValues["body"] as Data? != nil)
        #expect(CloudSync.note(from: record) == note)
    }

    /// About 2.9 MB of text that LZFSE can't shrink below the inline limit.
    static let hugeText: String = {
        var generator = SystemRandomNumberGenerator()
        return (0..<400_000).map { _ in String(UInt32.random(in: 0...UInt32.max, using: &generator), radix: 36) }.joined(separator: " ")
    }()

    static func hugeRecord(_ uid: String) -> CKRecord {
        let note = SyncNote(uid: uid, text: hugeText, createdAt: Date(), editedAt: Date(), deletedAt: nil, device: "Mac")
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, uid))
        CloudSync.fill(record, with: note)
        return record
    }

    static func assetData(_ record: CKRecord) throws -> Data {
        try Data(contentsOf: try #require((record["bodyAsset"] as? CKAsset)?.fileURL))
    }

    @Test func hugeNotesTravelAsAnEncryptedAsset() throws {
        let record = Self.hugeRecord("big")
        let packed = Compression.pack(Self.hugeText).data
        let stored = try Self.assetData(record)
        #expect(record.encryptedValues["body"] as Data? == nil)
        #expect((record.encryptedValues["bodyKey"] as Data?)?.count == 32)
        #expect(stored.count == packed.count + 28, "nonce, ciphertext and tag")
        #expect(stored.range(of: packed.prefix(64)) == nil, "the asset holds no plaintext")
        #expect(stored.range(of: Data(Self.hugeText.prefix(64).utf8)) == nil)
        #expect(CloudSync.note(from: record)?.text == Self.hugeText)
    }

    @Test func eachHugeBodyGetsItsOwnKey() throws {
        let one = Self.hugeRecord("one"), two = Self.hugeRecord("two")
        #expect(one.encryptedValues["bodyKey"] as Data? != two.encryptedValues["bodyKey"] as Data?)
    }

    @Test func aTamperedAssetIsRejected() throws {
        let record = Self.hugeRecord("tampered")
        let url = try #require((record["bodyAsset"] as? CKAsset)?.fileURL)
        var stored = try Data(contentsOf: url)
        stored[stored.count / 2] ^= 0x01
        try stored.write(to: url)
        #expect(CloudSync.note(from: record) == nil)
    }

    @Test func unencryptedAssetsFromEarlierBuildsStillRead() throws {
        let packed = Compression.pack(Self.hugeText)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try packed.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "legacy"))
        record["compressed"] = packed.compressed ? 1 : 0
        record["editedAt"] = Date()
        record["bodyAsset"] = CKAsset(fileURL: url)
        #expect(CloudSync.note(from: record)?.text == Self.hugeText)
    }

    @Test func shrinkingANoteDropsTheAssetAndKey() throws {
        let record = Self.hugeRecord("shrinks")
        CloudSync.fill(record, with: SyncNote(uid: "shrinks", text: "short now", createdAt: Date(), editedAt: Date(), deletedAt: nil, device: "Mac"))
        #expect(record["bodyAsset"] as? CKAsset == nil)
        #expect(record.encryptedValues["bodyKey"] as Data? == nil)
        #expect(CloudSync.note(from: record)?.text == "short now")
    }

    @Test func versionsPointAtTheirNote() throws {
        let version = SyncVersion(uid: "v1", noteUID: "n1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  source: "agent:claude", body: Data("draft".utf8), compressed: false)
        let record = CKRecord(recordType: CloudSync.RecordType.version, recordID: CloudSync.recordID(.version, version.uid))
        CloudSync.fill(record, with: version)
        #expect((record["note"] as? CKRecord.Reference)?.action == .deleteSelf)
        #expect(CloudSync.version(from: record) == version)
    }

    @Test func systemFieldsRoundTrip() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "abc"))
        let restored = try #require(CloudSync.record(fromSystemFields: CloudSync.systemFields(of: record)))
        #expect(restored.recordID == record.recordID)
    }
}
#endif
