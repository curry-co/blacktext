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

    @Test func aVersionThatDoesNotDecodeIsNotStored() throws {
        let id = try store.createNote(text: "kept")
        let uid = try #require(try store.noteUID(id: id))
        let garbled = SyncVersion(uid: "garbled", noteUID: uid, createdAt: Date(), source: "user",
                                  body: Data([0x01, 0x02, 0x03, 0x04]), compressed: true)
        #expect(throws: (any Error).self) { try store.applyRemote(version: garbled) }
        #expect(try store.versions(noteID: id).isEmpty)

        let orphan = SyncVersion(uid: "orphan", noteUID: "missing", createdAt: Date(), source: "user",
                                 body: Data([0x01, 0x02, 0x03, 0x04]), compressed: true)
        #expect(throws: (any Error).self) { try store.applyRemote(version: orphan) }
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
import CryptoKit

@Suite struct CloudRecordTests {
    @Test func onlySignedBuildsOnTheirOwnDatabaseSync() {
        #expect(CloudSync.isAvailable(flag: true, databaseOverridden: false))
        #expect(CloudSync.isAvailable(flag: "YES", databaseOverridden: false))
        #expect(CloudSync.isAvailable(flag: "1", databaseOverridden: false))
        #expect(!CloudSync.isAvailable(flag: nil, databaseOverridden: false), "make install has no flag")
        #expect(!CloudSync.isAvailable(flag: "NO", databaseOverridden: false))
        // A benchmark or screenshot database must never meet the signed-in iCloud account.
        #expect(!CloudSync.isAvailable(flag: true, databaseOverridden: true))
        #expect(!CloudSync.isAvailable(flag: "YES", databaseOverridden: true))
    }

    @Test func notesRoundTripThroughRecordsWithEncryptedText() throws {
        let note = SyncNote(uid: "abc", text: String(repeating: "coffee, black. ", count: 100),
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000), editedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            deletedAt: nil, device: "Mac")
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, note.uid))
        try CloudSync.fill(record, with: note)
        #expect(record["body"] == nil, "the text only lives in the encrypted field")
        #expect(record.encryptedValues["body"] as Data? != nil)
        #expect(CloudSync.note(from: record) == note)
    }

    /// About 2.9 MB of text that LZFSE can't shrink below the inline limit.
    static let hugeText: String = {
        var generator = SystemRandomNumberGenerator()
        return (0..<400_000).map { _ in String(UInt32.random(in: 0...UInt32.max, using: &generator), radix: 36) }.joined(separator: " ")
    }()

    static func hugeRecord(_ uid: String) throws -> CKRecord {
        let note = SyncNote(uid: uid, text: hugeText, createdAt: Date(), editedAt: Date(), deletedAt: nil, device: "Mac")
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, uid))
        try CloudSync.fill(record, with: note)
        return record
    }

    static func assetData(_ record: CKRecord) throws -> Data {
        try Data(contentsOf: try #require((record["bodyAsset"] as? CKAsset)?.fileURL))
    }

    @Test func hugeNotesTravelAsAnAsset() throws {
        let record = try Self.hugeRecord("big")
        #expect(record.encryptedValues["body"] as Data? == nil)
        #expect(record.encryptedValues["bodyKey"] as Data? == nil, "CloudKit protects assets as well as encrypted fields")
        #expect(try Self.assetData(record) == Compression.pack(Self.hugeText).data)
        #expect(CloudSync.note(from: record)?.text == Self.hugeText)
    }

    /// A record as builds from 201d2bc wrote a huge body: AES-GCM in the asset, its key in an encrypted field.
    static func encryptedAssetRecord(_ uid: String) throws -> (record: CKRecord, asset: URL) {
        let packed = Compression.pack(hugeText)
        let key = SymmetricKey(size: .bits256)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-\(UUID().uuidString)")
        try #require(try AES.GCM.seal(packed.data, using: key).combined).write(to: url)
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, uid))
        record["compressed"] = packed.compressed ? 1 : 0
        record["editedAt"] = Date()
        record["bodyAsset"] = CKAsset(fileURL: url)
        record.encryptedValues["bodyKey"] = key.withUnsafeBytes { Data($0) }
        return (record, url)
    }

    @Test func encryptedAssetsFromEarlierBuildsStillRead() throws {
        let (record, url) = try Self.encryptedAssetRecord("sealed")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CloudSync.note(from: record)?.text == Self.hugeText)
    }

    @Test func aTamperedEncryptedAssetIsRejected() throws {
        let (record, url) = try Self.encryptedAssetRecord("tampered")
        defer { try? FileManager.default.removeItem(at: url) }
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

    /// A body this build can't read (damaged, or a format from a newer build) must never become empty text.
    @Test func aNoteWhoseBodyDoesNotDecodeIsSkipped() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "garbled"))
        record["compressed"] = 1
        record["editedAt"] = Date()
        record.encryptedValues["body"] = Data([0x01, 0x02, 0x03, 0x04])
        #expect(CloudSync.note(from: record) == nil)

        record["compressed"] = 0
        record.encryptedValues["body"] = Data([0x61, 0xFF, 0x62])
        #expect(CloudSync.note(from: record) == nil, "not UTF-8")
    }

    @Test func shrinkingANoteDropsTheAssetAndKey() throws {
        let record = try Self.hugeRecord("shrinks")
        try CloudSync.fill(record, with: SyncNote(uid: "shrinks", text: "short now", createdAt: Date(), editedAt: Date(), deletedAt: nil, device: "Mac"))
        #expect(record["bodyAsset"] as? CKAsset == nil)
        #expect(record.encryptedValues["bodyKey"] as Data? == nil)
        #expect(CloudSync.note(from: record)?.text == "short now")
    }

    @Test func versionsPointAtTheirNote() throws {
        let version = SyncVersion(uid: "v1", noteUID: "n1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  source: "agent:claude", body: Data("draft".utf8), compressed: false)
        let record = CKRecord(recordType: CloudSync.RecordType.version, recordID: CloudSync.recordID(.version, version.uid))
        try CloudSync.fill(record, with: version)
        // Not owned: a note may have more than the 750 records CloudKit lets one record own.
        #expect((record["note"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
        #expect(CloudSync.version(from: record) == version)
    }

    @Test func eachSendOfAHugeNoteHasItsOwnAssetFile() throws {
        let note = SyncNote(uid: "big", text: Self.hugeText, createdAt: Date(), editedAt: Date(), deletedAt: nil, device: "Mac")
        let first = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "big"))
        let second = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "big"))
        let one = try #require(try CloudSync.fill(first, with: note))
        let two = try #require(try CloudSync.fill(second, with: note))
        defer { for file in [one, two] { try? FileManager.default.removeItem(at: file) } }
        #expect(one != two, "a retry mustn't overwrite or delete the file an earlier send is still using")
        #expect(FileManager.default.fileExists(atPath: one.path))
    }

    /// A record this build can't read is kept whole (encrypted fields too, and its asset's bytes) so a
    /// later build can read it.
    @Test func unreadableRecordsAreKeptWhole() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "later"))
        record["compressed"] = 0
        record["editedAt"] = Date(timeIntervalSince1970: 1_800_000_000)
        record.encryptedValues["body"] = Data("from a newer build".utf8)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        let kept = Store.UnreadableRecord(recordName: record.recordID.recordName, recordType: record.recordType, record: archived,
                                          asset: Data("asset bytes".utf8))
        let store = try Store(url: temporaryDatabase())
        try store.keepUnreadable(kept)
        let stored = try #require(try store.unreadableRecords().first)
        #expect(stored == kept)
        let (restored, file) = try #require(CloudSync.unarchive(stored))
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        #expect(CloudSync.note(from: restored)?.text == "from a newer build")
        let asset = try #require((restored["bodyAsset"] as? CKAsset)?.fileURL)
        #expect(try Data(contentsOf: asset) == Data("asset bytes".utf8))
        try store.forgetUnreadable(recordName: stored.recordName)
        #expect(try store.unreadableRecords().isEmpty)
    }

    @Test func onlyRealFailuresSetAChangeAside() {
        #expect(CloudSync.isTransient(.networkUnavailable))
        #expect(CloudSync.isTransient(.quotaExceeded), "it'll go once there's room")
        #expect(!CloudSync.isTransient(.invalidArguments))
        #expect(!CloudSync.isTransient(.permissionFailure))
    }

    @Test func systemFieldsRoundTrip() throws {
        let record = CKRecord(recordType: CloudSync.RecordType.note, recordID: CloudSync.recordID(.note, "abc"))
        let restored = try #require(CloudSync.record(fromSystemFields: CloudSync.systemFields(of: record)))
        #expect(restored.recordID == record.recordID)
    }
}
#endif
