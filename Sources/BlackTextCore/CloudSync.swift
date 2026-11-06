#if canImport(CloudKit)
import CloudKit
import Foundation
import os

/// Keeps this device's notes in step with the user's other devices through their private iCloud database.
///
/// Apple's `CKSyncEngine` does the scheduling, batching, retries and push notifications. This class
/// only translates between SQLite rows and CloudKit records. Note text and version bodies go in
/// encrypted fields, which are end-to-end encrypted with keys in the user's iCloud Keychain.
///
/// What to send comes from the database's `sync_outbox`, filled by triggers, so edits made by the
/// CLI or agents (even while the app was closed) are sent too.
public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    public static let containerIdentifier = "iCloud.co.curry.blacktext"
    static let zoneID = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)
    static let stateKey = "sync_engine_state"
    /// A record holds at most 1 MB; compressed bodies bigger than this travel as an asset instead.
    static let inlineLimit = 900_000
    /// How many outbox rows to hand the engine at once, so a first upload of years of notes stays small in memory.
    static let queueChunk = 2_000

    /// False for builds without the iCloud entitlement (like `make install`): CloudKit would crash them.
    /// Signed builds set `BlackTextCloudSync` in Info.plist.
    public static var isAvailable: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "BlackTextCloudSync") {
        case let flag as Bool: flag
        case let flag as String: flag == "YES" || flag == "1" || flag == "true"
        default: false
        }
    }

    private let store: Store
    private let deviceName: String
    private let log = Logger(subsystem: "co.curry.blacktext", category: "sync")
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    /// The outbox row each queued record came from, so an edit made while it was sending isn't cleared.
    private var queued: [CKRecord.ID: Int64] = [:]

    /// Runs on the main thread before changes from other devices are written, so the app can save
    /// what's on screen first (that's how an edit in progress is never overwritten).
    public var willApplyRemoteChanges: (@MainActor () -> Void)?
    /// Runs on the main thread with the local ids of notes that changed.
    public var didApplyRemoteChanges: (@MainActor (Set<NoteID>) -> Void)?

    /// `store` should be a connection of its own; sync runs off the main thread.
    public init(store: Store, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
    }

    // MARK: Starting and nudging

    public func start() {
        guard Self.isAvailable, currentEngine() == nil else { return }
        var saved: CKSyncEngine.State.Serialization?
        if let text = store.value(forKey: Self.stateKey), let data = Data(base64Encoded: text) {
            saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        let container = CKContainer(identifier: Self.containerIdentifier)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        lock.withLock { self.engine = engine }
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        localChangesMayExist()
    }

    /// Call after anything writes to the database (a save, the CLI, an agent). Queues what changed
    /// and sends it right away, rather than waiting for the engine's own schedule.
    public func localChangesMayExist() {
        guard let engine = currentEngine() else { return }
        guard let changes = try? store.pendingSyncChanges(limit: Self.queueChunk), !changes.isEmpty else { return }
        var saves: [CKSyncEngine.PendingRecordZoneChange] = []
        var deletes: [CKSyncEngine.PendingRecordZoneChange] = []
        lock.withLock {
            for change in changes {
                let id = Self.recordID(change.kind, change.uid)
                queued[id] = change.outboxID
                if change.isDeletion { deletes.append(.deleteRecord(id)) } else { saves.append(.saveRecord(id)) }
            }
        }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        // A delete supersedes a save still waiting for the same record.
        let superseded = deletes.compactMap { change -> CKSyncEngine.PendingRecordZoneChange? in
            guard case .deleteRecord(let id) = change else { return nil }
            return .saveRecord(id)
        }.filter(pending.contains)
        if !superseded.isEmpty { engine.state.remove(pendingRecordZoneChanges: superseded) }
        let new = (saves + deletes).filter { !pending.contains($0) }
        if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
        Task { try? await engine.sendChanges() }
    }

    /// Fetches now, for a push notification or the app coming to the front.
    public func fetchNow() {
        guard let engine = currentEngine() else { return }
        Task { try? await engine.fetchChanges() }
    }

    private func currentEngine() -> CKSyncEngine? {
        lock.withLock { engine }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                store.setValue(data.base64EncodedString(), forKey: Self.stateKey)
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                // A fresh account: everything here goes up to it. Nothing local is deleted.
                startOver(syncEngine)
            case .signOut:
                try? store.resetSyncState()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            // The user reset BlackText's iCloud data: keep every note and upload again.
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                startOver(syncEngine)
            }

        case .fetchedRecordZoneChanges(let changes):
            await apply(changes)

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, syncEngine: syncEngine)

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            self?.record(for: recordID)
        }
    }

    // MARK: Receiving

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var notes: [(SyncNote, CKRecord)] = []
        var versions: [SyncVersion] = []
        for modification in changes.modifications {
            let record = modification.record
            if let note = Self.note(from: record) {
                notes.append((note, record))
            } else if let version = Self.version(from: record) {
                versions.append(version)
            }
        }
        let deletions = changes.deletions.compactMap { deletion -> String? in
            guard deletion.recordType == RecordType.note else { return nil }
            return Self.parse(deletion.recordID)?.uid
        }
        guard !notes.isEmpty || !versions.isEmpty || !deletions.isEmpty else { return }

        if let willApply = willApplyRemoteChanges { await MainActor.run { willApply() } }

        var changed = Set<NoteID>()
        for (note, record) in notes {
            do {
                let result = try store.applyRemote(note: note, systemFields: Self.systemFields(of: record), thisDevice: deviceName)
                if result != .unchanged(result.noteID) { changed.insert(result.noteID) }
            } catch {
                log.error("Couldn't apply a note: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Notes first, so versions find them.
        for version in versions {
            if let id = try? store.applyRemote(version: version) { changed.insert(id) }
        }
        for uid in deletions {
            if let id = try? store.applyRemoteDeletion(noteUID: uid) { changed.insert(id) }
        }
        // Merging may have produced something to send (a kept local edit, or a version of the other text).
        localChangesMayExist()
        if !changed.isEmpty, let didApply = didApplyRemoteChanges {
            let ids = changed
            await MainActor.run { didApply(ids) }
        }
    }

    // MARK: Sending

    private func record(for id: CKRecord.ID) -> CKRecord? {
        guard let (kind, uid) = Self.parse(id) else { return nil }
        switch kind {
        case .note:
            guard var note = try? store.syncNote(uid: uid) else { return nil }
            note.device = deviceName
            let record = (try? store.systemFields(noteUID: uid)).flatMap(Self.record(fromSystemFields:))
                ?? CKRecord(recordType: RecordType.note, recordID: id)
            Self.fill(record, with: note)
            return record
        case .version:
            guard let version = try? store.syncVersion(uid: uid) else { return nil }
            let record = CKRecord(recordType: RecordType.version, recordID: id)
            Self.fill(record, with: version)
            return record
        }
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
        for record in sent.savedRecords {
            guard let (kind, uid) = Self.parse(record.recordID) else { continue }
            if kind == .note { try? store.setSystemFields(Self.systemFields(of: record), noteUID: uid) }
            markSent(record.recordID)
        }
        for id in sent.deletedRecordIDs {
            if let (kind, uid) = Self.parse(id), kind == .note { try? store.setSystemFields(nil, noteUID: uid) }
            markSent(id)
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needsZone = false
        var changed = Set<NoteID>()
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            guard let (kind, uid) = Self.parse(id) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                // Versions never change: if it's there already, it's the same one.
                guard kind == .note else { markSent(id); continue }
                guard let server = failure.error.serverRecord, let note = Self.note(from: server) else {
                    retry.append(.saveRecord(id)); continue
                }
                if let willApply = willApplyRemoteChanges { await MainActor.run { willApply() } }
                let result = try? store.applyRemote(note: note, systemFields: Self.systemFields(of: server), thisDevice: deviceName)
                if let result { changed.insert(result.noteID) }
                if case .keptLocal = result { retry.append(.saveRecord(id)) } else { markSent(id) }
            case .zoneNotFound:
                needsZone = true
                retry.append(.saveRecord(id))
            case .unknownItem:
                // Deleted on the server while this device still had it: send it again as new.
                if kind == .note { try? store.setSystemFields(nil, noteUID: uid) }
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                break // The engine retries these itself.
            default:
                log.error("Couldn't save a record: \(failure.error.localizedDescription, privacy: .public)")
            }
        }
        for (id, error) in sent.failedRecordDeletes where error.code == .unknownItem {
            markSent(id) // Already gone.
        }
        if needsZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        Self.removeAssetFiles()
        if !changed.isEmpty, let didApply = didApplyRemoteChanges {
            let ids = changed
            await MainActor.run { didApply(ids) }
        }
        // More of a big first upload may be waiting in the outbox.
        if !sent.savedRecords.isEmpty { localChangesMayExist() }
    }

    private func markSent(_ id: CKRecord.ID) {
        let outboxID: Int64? = lock.withLock { queued.removeValue(forKey: id) }
        if let outboxID { try? store.clearSyncChange(outboxID: outboxID) }
    }

    private func startOver(_ engine: CKSyncEngine) {
        try? store.resetSyncState()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        localChangesMayExist()
    }

    // MARK: Records

    enum RecordType {
        static let note = "Note"
        static let version = "Version"
    }

    static func recordID(_ kind: SyncChange.Kind, _ uid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(kind.rawValue)_\(uid)", zoneID: zoneID)
    }

    static func parse(_ id: CKRecord.ID) -> (kind: SyncChange.Kind, uid: String)? {
        let parts = id.recordName.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let kind = SyncChange.Kind(rawValue: String(parts[0])) else { return nil }
        return (kind, String(parts[1]))
    }

    static func fill(_ record: CKRecord, with note: SyncNote) {
        let packed = Compression.pack(note.text)
        setBody(packed, on: record, name: note.uid)
        record["createdAt"] = note.createdAt
        record["editedAt"] = note.editedAt
        record["deletedAt"] = note.deletedAt
        record["device"] = note.device
    }

    static func fill(_ record: CKRecord, with version: SyncVersion) {
        setBody((version.body, version.compressed), on: record, name: version.uid)
        record["createdAt"] = version.createdAt
        record["source"] = version.source
        record["note"] = CKRecord.Reference(recordID: recordID(.note, version.noteUID), action: .deleteSelf)
    }

    /// Small bodies go in an encrypted field; very big ones (over ~900 KB compressed) as an asset.
    private static func setBody(_ packed: (data: Data, compressed: Bool), on record: CKRecord, name: String) {
        record["compressed"] = packed.compressed ? 1 : 0
        if packed.data.count <= inlineLimit {
            record.encryptedValues["body"] = packed.data
            record["bodyAsset"] = nil as CKAsset?
        } else {
            let url = assetDirectory.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
            try? packed.data.write(to: url, options: .atomic)
            record["bodyAsset"] = CKAsset(fileURL: url)
            record.encryptedValues["body"] = nil as Data?
        }
    }

    /// The body bytes as stored (compressed or not), from the encrypted field or the asset.
    private static func body(of record: CKRecord) -> (data: Data, compressed: Bool)? {
        let compressed = (record["compressed"] as? Int64 ?? 0) != 0
        if let inline: Data = record.encryptedValues["body"] { return (inline, compressed) }
        if let asset = record["bodyAsset"] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            return (data, compressed)
        }
        return nil
    }

    static func note(from record: CKRecord) -> SyncNote? {
        guard record.recordType == RecordType.note, let (kind, uid) = parse(record.recordID), kind == .note,
              let body = body(of: record) else { return nil }
        let edited = record["editedAt"] as? Date ?? record.modificationDate ?? Date()
        return SyncNote(uid: uid, text: Compression.unpack(body.data, compressed: body.compressed),
                        createdAt: record["createdAt"] as? Date ?? edited,
                        editedAt: edited,
                        deletedAt: record["deletedAt"] as? Date,
                        device: record["device"] as? String ?? "another device")
    }

    static func version(from record: CKRecord) -> SyncVersion? {
        guard record.recordType == RecordType.version, let (kind, uid) = parse(record.recordID), kind == .version,
              let reference = record["note"] as? CKRecord.Reference,
              let (_, noteUID) = parse(reference.recordID),
              let body = body(of: record) else { return nil }
        return SyncVersion(uid: uid, noteUID: noteUID,
                           createdAt: record["createdAt"] as? Date ?? record.creationDate ?? Date(),
                           source: record["source"] as? String ?? "user",
                           body: body.data, compressed: body.compressed)
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static let assetDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("blacktext-sync", isDirectory: true)

    private static func removeAssetFiles() {
        try? FileManager.default.removeItem(at: assetDirectory)
    }
}
#endif
