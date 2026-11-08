#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation
import os

/// Keeps this device's notes in step with the user's other devices through their private iCloud database.
///
/// Apple's `CKSyncEngine` does the scheduling, batching, retries and push notifications. This class
/// only translates between SQLite rows and CloudKit records. Note text and version bodies go in
/// encrypted fields, or as an asset when too big for one (see `setBody`). CloudKit encrypts both in
/// transit and on Apple's servers, and end to end for people who turn on Advanced Data Protection.
///
/// What to send comes from the database's `sync_outbox`, filled by triggers, so edits made by the
/// CLI or agents (even while the app was closed) are sent too. A record's send clears only the outbox row
/// it was built from, so an edit made while it was on its way is sent next. Changes iCloud refuses for
/// good are set aside, not dropped. Changes from iCloud that can't be written here are fetched again,
/// and ones this build can't read are kept for a later one.
///
/// Sync stops, and waits for the user, when they delete or reset BlackText's iCloud data, or sign in to
/// a different account: the notes here are kept, and nothing is sent until they choose.
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
        isAvailable(flag: Bundle.main.object(forInfoDictionaryKey: "BlackTextCloudSync"),
                    databaseOverridden: Paths.isDatabaseOverridden)
    }

    /// A database picked with `BLACKTEXT_DB` (benchmarks, screenshots, experiments) never syncs, even in a
    /// signed build: its notes would go up to the signed-in account, and that account's notes would come down into it.
    static func isAvailable(flag: Any?, databaseOverridden: Bool) -> Bool {
        guard !databaseOverridden else { return false }
        return switch flag {
        case let flag as Bool: flag
        case let flag as String: flag == "YES" || flag == "1" || flag == "true"
        default: false
        }
    }

    /// Where sync stands, for the app to show.
    public struct Status: Equatable, Sendable {
        /// Set while sync is stopped and waiting for the user.
        public var suspension: SyncSuspension?
        /// Changes waiting to be sent, including `failed` ones.
        public var pending = 0
        /// Changes iCloud refused; retried on the next launch, or when the note changes again.
        public var failed = 0
        public var lastError: String?
        public var lastSent: Date?
        public var lastFetched: Date?
    }

    public enum FetchOutcome: Sendable {
        case newData, noData, failed
    }

    private let store: Store
    private let deviceName: String
    private let log = Logger(subsystem: "co.curry.blacktext", category: "sync")
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    /// For each record handed to the engine, the outbox row it was built from: its send clears that row
    /// and nothing newer.
    private var tokens: [CKRecord.ID: Int64] = [:]
    /// Asset files written for records on their way, removed once their send is over.
    private var assetFiles: [CKRecord.ID: [URL]] = [:]
    /// Set when a change from iCloud couldn't be written here: the engine's progress stops being saved, and
    /// it's restarted from the last saved point, so the change is fetched again.
    private var holdingCheckpoint = false
    private var restartDelay: TimeInterval = 5
    private var lastError: String?
    private var lastSent: Date?
    private var lastFetched: Date?
    private var applied = 0
    private let work = DispatchQueue(label: "co.curry.blacktext.sync", qos: .utility)
    private var nudgeScheduled = false

    /// Runs on the main thread before changes from other devices are written, so the app can save
    /// what's on screen first (that's how an edit in progress is never overwritten).
    public var willApplyRemoteChanges: (@MainActor () -> Void)?
    /// Runs on the main thread with the local ids of notes that changed.
    public var didApplyRemoteChanges: (@MainActor (Set<NoteID>) -> Void)?
    /// Runs on the main thread when the status changes, including when sync stops for the user to decide.
    public var onStatusChange: (@MainActor (Status) -> Void)?

    /// `store` should be a connection of its own; sync runs off the main thread.
    public init(store: Store, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
    }

    // MARK: Starting and nudging

    public func start() {
        guard Self.isAvailable, currentEngine() == nil else { return }
        if let suspension = store.syncSuspension {
            publishStatus()
            // Back on the account these notes sync with? Then nothing needs deciding.
            if suspension == .otherAccount { checkAccount(liftingSuspension: true) }
            return
        }
        // Each launch gives changes iCloud refused another try.
        try? store.retryFailedSyncChanges()
        startEngine()
        checkAccount(liftingSuspension: false)
    }

    private func startEngine() {
        var saved: CKSyncEngine.State.Serialization?
        if let text = store.value(forKey: Self.stateKey), let data = Data(base64Encoded: text) {
            saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        // Nothing is on its way yet, so files left by an earlier run can go.
        Self.removeAssetDirectory()
        let container = CKContainer(identifier: Self.containerIdentifier)
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        lock.withLock {
            self.engine = engine
            holdingCheckpoint = false
            tokens = [:]
            assetFiles = [:]
        }
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        work.async { [weak self] in self?.retryUnreadable() }
        localChangesMayExist()
    }

    /// The user chose to sync again after it stopped (`Status.suspension`): everything here is sent to the
    /// account this device is signed in to, and that account's notes come down.
    public func resume() {
        guard let suspension = store.syncSuspension else { return }
        try? store.resetSyncState()
        store.setValue(nil, forKey: Self.stateKey)
        if suspension == .otherAccount { store.syncAccount = nil }
        store.syncSuspension = nil
        publishStatus()
        start()
    }

    /// Call after anything writes to the database (a save, the CLI, an agent). Queues what changed and
    /// sends it right away, rather than waiting for the engine's own schedule. Returns at once; the outbox
    /// is read off the calling thread, and calls close together are read once.
    public func localChangesMayExist() {
        let scheduled: Bool = lock.withLock {
            defer { nudgeScheduled = true }
            return nudgeScheduled
        }
        guard !scheduled else { return }
        work.async { [weak self] in self?.queueLocalChanges() }
    }

    private func queueLocalChanges() {
        lock.withLock { nudgeScheduled = false }
        guard let engine = currentEngine() else { return }
        guard let changes = try? store.pendingSyncChanges(limit: Self.queueChunk), !changes.isEmpty else {
            publishStatus()
            return
        }
        var saves: [CKSyncEngine.PendingRecordZoneChange] = []
        var deletes: [CKSyncEngine.PendingRecordZoneChange] = []
        lock.withLock {
            for change in changes {
                let id = Self.recordID(change.kind, change.uid)
                if change.isDeletion {
                    // Deletions aren't built by `record(for:)`, so their row is noted here.
                    tokens[id] = change.outboxID
                    deletes.append(.deleteRecord(id))
                } else {
                    saves.append(.saveRecord(id))
                }
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
        publishStatus()
        // Detached: this also runs inside engine callbacks, and CloudKit forbids awaiting it from there.
        Task.detached { try? await engine.sendChanges() }
    }

    /// Fetches now, for the app coming to the front.
    public func fetchNow() {
        guard let engine = currentEngine() else { return }
        Task.detached { try? await engine.fetchChanges() }
    }

    /// Fetches and waits, for a push that woke the app: says whether anything changed, as the push's
    /// completion handler wants to know.
    public func fetchChanges() async -> FetchOutcome {
        guard let engine = currentEngine() else { return .failed }
        let before = lock.withLock { applied }
        do {
            try await engine.fetchChanges()
        } catch {
            return .failed
        }
        return lock.withLock { applied } > before ? .newData : .noData
    }

    public var status: Status {
        let backlog = try? store.syncBacklog()
        let suspension = store.syncSuspension
        return lock.withLock {
            Status(suspension: suspension, pending: backlog?.pending ?? 0, failed: backlog?.failed ?? 0,
                   lastError: lastError ?? backlog?.lastError, lastSent: lastSent, lastFetched: lastFetched)
        }
    }

    private func publishStatus() {
        guard let onStatusChange else { return }
        let status = self.status
        Task { @MainActor in onStatusChange(status) }
    }

    private func currentEngine() -> CKSyncEngine? {
        lock.withLock { engine }
    }

    // MARK: Accounts, and stopping for the user

    /// Notes which account these notes sync with the first time it's known, and stops if it's another.
    private func checkAccount(liftingSuspension: Bool) {
        Task.detached { [weak self] in
            guard let id = try? await CKContainer(identifier: Self.containerIdentifier).userRecordID() else { return }
            self?.accountIs(id.recordName, liftingSuspension: liftingSuspension)
        }
    }

    private func accountIs(_ name: String, liftingSuspension: Bool) {
        guard let known = store.syncAccount else {
            store.syncAccount = name
            return
        }
        if known == name {
            guard liftingSuspension, store.syncSuspension == .otherAccount else { return }
            store.syncSuspension = nil
            publishStatus()
            start()
        } else if let engine = currentEngine() {
            Task { await suspend(.otherAccount, engine: engine) }
        }
    }

    /// Stops syncing until the user turns it back on (`resume`). After a purge or reset, Apple asks apps
    /// to drop the data they cached from iCloud and not send it back: the outbox and CloudKit's bookkeeping
    /// go, and the notes, which are the user's own copy, stay.
    private func suspend(_ reason: SyncSuspension, engine: CKSyncEngine) async {
        guard currentEngine() === engine else { return }
        store.syncSuspension = reason
        if reason != .otherAccount { try? store.forgetCloudCache() }
        lock.withLock {
            self.engine = nil
            tokens = [:]
            assetFiles = [:]
        }
        await engine.cancelOperations()
        Self.removeAssetDirectory()
        log.notice("Sync stopped: \(reason.rawValue, privacy: .public)")
        publishStatus()
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine that was stopped or replaced may still finish what it was doing; ignore it.
        guard syncEngine === currentEngine() else { return }
        switch event {
        case .stateUpdate(let update):
            guard !lock.withLock({ holdingCheckpoint }) else { return }
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                store.setValue(data.base64EncodedString(), forKey: Self.stateKey)
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user):
                if let known = store.syncAccount, known != user.recordName {
                    await suspend(.otherAccount, engine: syncEngine)
                } else {
                    // The account these notes sync with (or the first one): everything here goes up to it.
                    store.syncAccount = user.recordName
                    startOver(syncEngine)
                }
            case .switchAccounts(_, let user):
                if store.syncAccount == user.recordName {
                    startOver(syncEngine)
                } else {
                    // Never move one account's notes into another's without asking.
                    await suspend(.otherAccount, engine: syncEngine)
                }
            case .signOut:
                // Nothing local is deleted; it all goes up again when this account signs back in.
                try? store.resetSyncState()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                switch deletion.reason {
                case .deleted:
                    // Deleted by a device, not the user: put it back, with everything here.
                    startOver(syncEngine)
                case .purged:
                    await suspend(.purged, engine: syncEngine)
                    return
                case .encryptedDataReset:
                    await suspend(.encryptedDataReset, engine: syncEngine)
                    return
                @unknown default:
                    await suspend(.purged, engine: syncEngine)
                    return
                }
            }

        case .fetchedRecordZoneChanges(let changes):
            await apply(changes, engine: syncEngine)

        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, syncEngine: syncEngine)

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                note(error: failure.error, "Couldn't create the iCloud zone")
            }

        case .didFetchChanges:
            lock.withLock { lastFetched = Date() }
            publishStatus()

        case .didSendChanges:
            lock.withLock { lastSent = Date() }
            publishStatus()

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === currentEngine() else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let gone = Collected()
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] recordID in
            guard let self else { return nil }
            switch self.record(for: recordID) {
            case .record(let record):
                return record
            case .gone:
                gone.append(.saveRecord(recordID))
                return nil
            case .unavailable:
                return nil
            }
        }
        // Records that aren't here any more have nothing to send; stop asking for them.
        let obsolete = gone.items
        if !obsolete.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: obsolete) }
        return batch
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        func append(_ change: CKSyncEngine.PendingRecordZoneChange) { lock.withLock { changes.append(change) } }
        var items: [CKSyncEngine.PendingRecordZoneChange] { lock.withLock { changes } }
    }

    // MARK: Receiving

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) async {
        var notes: [(SyncNote, CKRecord)] = []
        var versions: [(SyncVersion, CKRecord)] = []
        var failed = false
        for modification in changes.modifications {
            let record = modification.record
            if let note = Self.note(from: record) {
                notes.append((note, record))
            } else if let version = Self.version(from: record), (try? version.text) != nil {
                versions.append((version, record))
            } else {
                // Damaged, or from a newer build: leave this device's copy as it is, and keep the record.
                do {
                    try keepUnreadable(record)
                } catch {
                    failed = true
                    log.error("Couldn't keep \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        var noteDeletions: [String] = []
        var versionDeletions: [String] = []
        for deletion in changes.deletions {
            guard let (kind, uid) = Self.parse(deletion.recordID) else { continue }
            try? store.forgetUnreadable(recordName: deletion.recordID.recordName)
            switch kind {
            case .note: noteDeletions.append(uid)
            case .version: versionDeletions.append(uid)
            }
        }
        guard !notes.isEmpty || !versions.isEmpty || !noteDeletions.isEmpty || !versionDeletions.isEmpty else {
            if failed { holdCheckpointAndRestart(engine) }
            return
        }

        if let willApply = willApplyRemoteChanges { await MainActor.run { willApply() } }

        var changed = Set<NoteID>()
        for (note, record) in notes {
            do {
                let result = try store.applyRemote(note: note, systemFields: Self.systemFields(of: record), thisDevice: deviceName)
                if result != .unchanged(result.noteID) { changed.insert(result.noteID) }
                try? store.forgetUnreadable(recordName: record.recordID.recordName)
            } catch {
                failed = true
                log.error("Couldn't apply \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Notes first, so versions find them.
        for (version, record) in versions {
            do {
                if let id = try store.applyRemote(version: version) { changed.insert(id) }
                try? store.forgetUnreadable(recordName: record.recordID.recordName)
            } catch {
                failed = true
                log.error("Couldn't apply \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        for uid in noteDeletions {
            do {
                if let id = try store.applyRemoteDeletion(noteUID: uid) { changed.insert(id) }
            } catch {
                failed = true
                log.error("Couldn't apply a deletion: \(error.localizedDescription, privacy: .public)")
            }
        }
        for uid in versionDeletions {
            do {
                if let id = try store.applyRemoteDeletion(versionUID: uid) { changed.insert(id) }
            } catch {
                failed = true
                log.error("Couldn't apply a deletion: \(error.localizedDescription, privacy: .public)")
            }
        }
        if failed {
            holdCheckpointAndRestart(engine)
        } else {
            lock.withLock { restartDelay = 5 }
        }
        lock.withLock { applied += 1 }
        // Merging may have produced something to send (a kept local edit, or a version of the other text).
        localChangesMayExist()
        if !changed.isEmpty, let didApply = didApplyRemoteChanges {
            let ids = changed
            await MainActor.run { didApply(ids) }
        }
    }

    /// A change from iCloud couldn't be written here (a full disk, say). The engine would carry on past it
    /// and save its place, so the change would never come again. Instead its place isn't saved from now on,
    /// and in a while it starts again from the last saved place, fetching the change again. Applying a
    /// change twice is harmless.
    private func holdCheckpointAndRestart(_ engine: CKSyncEngine) {
        let delay: TimeInterval = lock.withLock {
            guard !holdingCheckpoint else { return 0 }
            holdingCheckpoint = true
            defer { restartDelay = min(restartDelay * 3, 600) }
            return restartDelay
        }
        guard delay > 0 else { return }
        lock.withLock { lastError = "Some changes from iCloud couldn't be saved here; trying again." }
        publishStatus()
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.currentEngine() === engine else { return }
            await engine.cancelOperations()
            guard self.currentEngine() === engine else { return }
            self.lock.withLock { self.engine = nil }
            self.startEngine()
        }
    }

    /// Keeps a record this build couldn't read, with its asset's bytes (CloudKit's file is temporary).
    private func keepUnreadable(_ record: CKRecord) throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        let asset = (record["bodyAsset"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        try store.keepUnreadable(Store.UnreadableRecord(recordName: record.recordID.recordName, recordType: record.recordType,
                                                        record: archived, asset: asset))
        log.error("Couldn't read \(record.recordID.recordName, privacy: .public); kept it for a later version")
    }

    /// Records kept because an earlier build couldn't read them: this one may.
    private func retryUnreadable() {
        guard let kept = try? store.unreadableRecords(), !kept.isEmpty else { return }
        var changed = Set<NoteID>()
        var notes: [(SyncNote, CKRecord, Store.UnreadableRecord)] = []
        var versions: [(SyncVersion, Store.UnreadableRecord)] = []
        var files: [URL] = []
        for item in kept {
            guard let (record, file) = Self.unarchive(item) else { continue }
            if let file { files.append(file) }
            if let note = Self.note(from: record) {
                notes.append((note, record, item))
            } else if let version = Self.version(from: record), (try? version.text) != nil {
                versions.append((version, item))
            }
        }
        for (note, record, item) in notes {
            guard let result = try? store.applyRemote(note: note, systemFields: Self.systemFields(of: record), thisDevice: deviceName)
            else { continue }
            if result != .unchanged(result.noteID) { changed.insert(result.noteID) }
            try? store.forgetUnreadable(recordName: item.recordName)
        }
        for (version, item) in versions {
            do {
                if let id = try store.applyRemote(version: version) { changed.insert(id) }
            } catch {
                continue
            }
            try? store.forgetUnreadable(recordName: item.recordName)
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
        guard !changed.isEmpty, let didApply = didApplyRemoteChanges else { return }
        let ids = changed
        Task { @MainActor in didApply(ids) }
    }

    static func unarchive(_ item: Store.UnreadableRecord) -> (CKRecord, URL?)? {
        guard let record = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: item.record) else { return nil }
        guard let bytes = item.asset else { return (record, nil) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blacktext-kept-\(UUID().uuidString)")
        guard (try? bytes.write(to: url)) != nil else { return (record, nil) }
        record["bodyAsset"] = CKAsset(fileURL: url)
        return (record, url)
    }

    // MARK: Sending

    enum Built {
        case record(CKRecord)
        /// Not in the database any more: nothing to send.
        case gone
        /// Couldn't be read just now: try again later.
        case unavailable
    }

    private func record(for id: CKRecord.ID) -> Built {
        guard let (kind, uid) = Self.parse(id) else { return .gone }
        do {
            let record: CKRecord
            let token: Int64?
            let file: URL?
            switch kind {
            case .note:
                guard let found = try store.syncNoteToSend(uid: uid) else { return gone(kind, uid) }
                var note = found.note
                note.device = deviceName
                record = (try store.systemFields(noteUID: uid)).flatMap(Self.record(fromSystemFields:))
                    ?? CKRecord(recordType: RecordType.note, recordID: id)
                file = try Self.fill(record, with: note)
                token = found.outboxID
            case .version:
                guard let found = try store.syncVersionToSend(uid: uid) else { return gone(kind, uid) }
                record = CKRecord(recordType: RecordType.version, recordID: id)
                file = try Self.fill(record, with: found.version)
                token = found.outboxID
            }
            lock.withLock {
                tokens[id] = token
                if let file { assetFiles[id, default: []].append(file) }
            }
            return .record(record)
        } catch {
            log.error("Couldn't prepare \(id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    /// A save for a record that's no longer here (its deletion, if any, is a separate row).
    private func gone(_ kind: SyncChange.Kind, _ uid: String) -> Built {
        try? store.clearObsoleteSyncSave(kind: kind, uid: uid)
        return .gone
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
            removeAssetFiles(for: id)
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
            case let code where Self.isTransient(code):
                if code == .quotaExceeded { note(error: failure.error, "iCloud storage is full") }
            default:
                markFailed(id, failure.error)
            }
        }
        for (id, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem: markSent(id) // Already gone.
            case let code where Self.isTransient(code): break
            default: markFailed(id, error)
            }
        }
        if needsZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        if !changed.isEmpty, let didApply = didApplyRemoteChanges {
            let ids = changed
            await MainActor.run { didApply(ids) }
        }
        // More may be waiting in the outbox: a big first upload, or an edit made while these were on their way.
        if !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty || !retry.isEmpty { localChangesMayExist() }
        publishStatus()
    }

    /// Errors CloudKit's engine retries by itself, or that clear up on their own.
    static func isTransient(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
             .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable, .batchRequestFailed,
             .limitExceeded, .quotaExceeded:
            return true
        default:
            return false
        }
    }

    private func markSent(_ id: CKRecord.ID) {
        let outboxID: Int64? = lock.withLock { tokens.removeValue(forKey: id) }
        if let outboxID { try? store.clearSyncChange(outboxID: outboxID) }
        removeAssetFiles(for: id)
    }

    /// iCloud refused a change for good: keep it in the outbox, set aside with the reason, so it neither
    /// holds up everything behind it nor disappears.
    private func markFailed(_ id: CKRecord.ID, _ error: CKError) {
        let outboxID: Int64? = lock.withLock { tokens.removeValue(forKey: id) }
        if let outboxID { try? store.markSyncChangeFailed(outboxID: outboxID, error: error.localizedDescription) }
        removeAssetFiles(for: id)
        note(error: error, "Couldn't send \(id.recordName)")
    }

    private func note(error: Error, _ what: String) {
        log.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        lock.withLock { lastError = "\(what): \(error.localizedDescription)" }
    }

    private func startOver(_ engine: CKSyncEngine) {
        try? store.resetSyncState()
        lock.withLock { tokens = [:] }
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

    /// Fills a note record. Returns the asset file written for a very big body, if any.
    @discardableResult
    static func fill(_ record: CKRecord, with note: SyncNote) throws -> URL? {
        let packed = Compression.pack(note.text)
        let file = try setBody(packed, on: record, name: note.uid)
        record["createdAt"] = note.createdAt
        record["editedAt"] = note.editedAt
        record["deletedAt"] = note.deletedAt
        record["device"] = note.device
        return file
    }

    /// Fills a version record. Its reference to the note doesn't own it: CloudKit lets a record own at
    /// most 750 others, and a note can have more versions than that. So a note's versions are deleted one
    /// by one when it is (older versions still say `.deleteSelf`, and go with the note).
    @discardableResult
    static func fill(_ record: CKRecord, with version: SyncVersion) throws -> URL? {
        let file = try setBody((version.body, version.compressed), on: record, name: version.uid)
        record["createdAt"] = version.createdAt
        record["source"] = version.source
        record["note"] = CKRecord.Reference(recordID: recordID(.note, version.noteUID), action: .none)
        return file
    }

    /// Small bodies go in an encrypted field. Very big ones (over ~900 KB compressed) travel as an asset,
    /// in a file of their own for this send. CloudKit protects the two alike: encrypted in transit and on
    /// its servers, and end to end with Advanced Data Protection, which covers encrypted fields and all assets.
    private static func setBody(_ packed: (data: Data, compressed: Bool), on record: CKRecord, name: String) throws -> URL? {
        record["compressed"] = packed.compressed ? 1 : 0
        // Some earlier builds sealed assets themselves, with the key here. Nothing sent now uses it.
        record.encryptedValues["bodyKey"] = nil as Data?
        if packed.data.count <= inlineLimit {
            record.encryptedValues["body"] = packed.data
            record["bodyAsset"] = nil as CKAsset?
            return nil
        }
        record.encryptedValues["body"] = nil as Data?
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let url = assetDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try packed.data.write(to: url, options: .atomic)
        record["bodyAsset"] = CKAsset(fileURL: url)
        return url
    }

    /// The body bytes as stored (compressed or not), from the encrypted field or the asset.
    /// Nil when a sealed asset from an earlier build was tampered with or its key is wrong.
    private static func body(of record: CKRecord) -> (data: Data, compressed: Bool)? {
        let compressed = (record["compressed"] as? Int64 ?? 0) != 0
        if let inline: Data = record.encryptedValues["body"] { return (inline, compressed) }
        guard let asset = record["bodyAsset"] as? CKAsset, let url = asset.fileURL,
              let stored = try? Data(contentsOf: url) else { return nil }
        // Assets come as they are, except from the builds that sealed them with AES-GCM and kept the key in `bodyKey`.
        guard let key: Data = record.encryptedValues["bodyKey"] else { return (stored, compressed) }
        guard let box = try? AES.GCM.SealedBox(combined: stored),
              let data = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return (data, compressed)
    }

    static func note(from record: CKRecord) -> SyncNote? {
        guard record.recordType == RecordType.note, let (kind, uid) = parse(record.recordID), kind == .note,
              let body = body(of: record),
              let text = try? Compression.unpack(body.data, compressed: body.compressed) else { return nil }
        let edited = record["editedAt"] as? Date ?? record.modificationDate ?? Date()
        return SyncNote(uid: uid, text: text,
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

    private static func removeAssetDirectory() {
        try? FileManager.default.removeItem(at: assetDirectory)
    }

    private func removeAssetFiles(for id: CKRecord.ID) {
        let files = lock.withLock { assetFiles.removeValue(forKey: id) } ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
#endif
