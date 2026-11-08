import Foundation

/// Autosave and versioning for the note in the canvas.
///
/// A keystroke only marks the note dirty. A save runs 1 second after typing stops, or at most
/// 5 seconds after the first unsaved change, on a background connection. Idle means no timers.
///
/// Each change to the canvas gets a number, and the note only counts as saved once a write of that change
/// (or a later one) has landed. A write that fails leaves the note dirty, puts a copy of the text in
/// `Recovered` next to the database, and is retried. Nothing here treats a failure as a save.
///
/// Use it from the main thread.
public final class NoteSession {
    public enum VersionRule {
        /// Only if 100 words have changed since the last version.
        case ifDue
        /// If anything changed since the last version (leaving a note, ⌘↩, quitting).
        case ifChanged
        /// Always, unless identical to the last version (before Replace All, agent edits).
        case always
        case never
    }

    /// Where the canvas stands after a save that was waited for.
    public enum Outcome: Equatable {
        /// The database has everything in the canvas.
        case saved
        /// It doesn't. `recoveryCopy` is where the canvas text was written instead, if that worked.
        case failed(message: String, recoveryCopy: URL?)

        public var isSaved: Bool { self == .saved }
    }

    public static let idleDelay: TimeInterval = 1
    public static let maxDelay: TimeInterval = 5
    /// Waits before each automatic retry of a failed save. After the last, saves wait for the next change.
    static let retryDelays: [TimeInterval] = [1, 2, 5, 10, 30]

    private let store: Store
    private let saveStore: Store
    private let queue = DispatchQueue(label: "co.curry.blacktext.save", qos: .userInitiated)

    public private(set) var noteID: NoteID?
    private var policy = VersionPolicy()
    private var firstUnsavedChange: Date?
    private var timer: Timer?

    // Change numbers: the latest change, the latest handed to the save queue, and the latest known landed.
    private var edits = 0
    private var queued = 0
    private var saved = 0
    /// A version a failed save still owes, with its source.
    private var owedVersion: String?
    /// Agent ops whose edits are in the canvas. Each is recorded as done by the save that stores its edit, so
    /// a crash before that save leaves it to be applied again, never applied twice.
    private var owedCompletions: [Int64: AgentResult] = [:]
    /// Bumped by `load`, so a late result for the previous note doesn't change this one's state.
    private var generation = 0
    private var attempts = 0
    private var settled = 0
    private let mailbox = Mailbox()
    /// Notes recreated by saves (old id → new), so later saves already queued for the old one follow.
    private let redirects = Redirects()
    private var failure: (message: String, copy: URL?)?
    private var retryTimer: Timer?
    private var retries = 0
    private var recoveryName: String?

    /// The canvas text, read at save time.
    public var text: () -> String = { "" }
    /// Called on the main thread after a save lands, with the note's new summary.
    public var onSaved: ((NoteSummary) -> Void)?
    /// Called when an empty note is discarded on leaving it.
    public var onDiscarded: ((NoteID) -> Void)?
    /// The note was deleted or removed while the canvas still had unsaved changes, so they were saved as a
    /// new note instead: (the old note, the new one). The canvas is the new note now.
    public var onRecreated: ((NoteID, NoteID) -> Void)?
    /// Saving started failing, or works again.
    public var onOutcomeChanged: ((Outcome) -> Void)?

    public init(store: Store, saveStore: Store) {
        self.store = store
        self.saveStore = saveStore
    }

    /// True while the database hasn't got everything in the canvas.
    public var isDirty: Bool { saved != edits }

    public var outcome: Outcome {
        failure.map { .failed(message: $0.message, recoveryCopy: $0.copy) } ?? .saved
    }

    /// Starts a session for `note` (nil = blank canvas). Call `leave()` on the previous one first: whatever it
    /// hadn't saved is dropped here.
    public func load(_ note: Note?) {
        drain()
        timer?.invalidate()
        timer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
        noteID = note?.id
        edits = 0
        queued = 0
        saved = 0
        owedVersion = nil
        owedCompletions = [:]
        firstUnsavedChange = nil
        policy.reset()
        retries = 0
        recoveryName = nil
        let wasFailing = failure != nil
        failure = nil
        if wasFailing { onOutcomeChanged?(.saved) }
        store.currentNoteID = noteID
    }

    public func record(replacing range: NSRange, in text: NSString, with replacement: String) {
        policy.record(replacing: range, in: text, with: replacement)
    }

    public func textDidChange() {
        edits += 1
        let now = Date()
        if firstUnsavedChange == nil { firstUnsavedChange = now }
        let fireAt = min(now.addingTimeInterval(Self.idleDelay), firstUnsavedChange!.addingTimeInterval(Self.maxDelay))
        if let timer, timer.isValid {
            timer.fireDate = fireAt
        } else {
            let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
                self?.timer = nil
                self?.save()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Writes the canvas if it changed, and a version if the rule says so. With `wait`, returns once every
    /// save started so far has landed or failed, whether or not this call had anything new to write, so the
    /// outcome is the database's real state. `completing` records an agent op whose edit is in the canvas as
    /// done, in the same transaction as the save that stores it.
    @discardableResult
    public func save(version rule: VersionRule = .ifDue, source: String = "user", wait: Bool = false,
                     completing op: (id: Int64, result: AgentResult)? = nil) -> Outcome {
        timer?.invalidate()
        timer = nil
        if let op, op.id > 0 { owedCompletions[op.id] = op.result }
        var versionSource: String?
        switch rule {
        case .ifDue: if policy.isDue { versionSource = source }
        case .ifChanged: if policy.hasChanges { versionSource = source }
        case .always: versionSource = source
        case .never: break
        }
        if versionSource == nil, rule != .never { versionSource = owedVersion }

        let needsWrite = queued != edits
        guard needsWrite || versionSource != nil || !owedCompletions.isEmpty else { return finish(wait: wait) }

        let text = self.text()
        let change = edits
        if noteID == nil {
            // A blank canvas becomes a note once it has something in it.
            guard !text.allSatisfy(\.isWhitespace) else {
                queued = change
                saved = change
                return finish(wait: wait)
            }
            do {
                noteID = try store.createNote()
                store.currentNoteID = noteID
            } catch {
                fail(error)
                return finish(wait: wait)
            }
        }
        guard let id = noteID else { return finish(wait: wait) }

        queued = change
        firstUnsavedChange = nil
        if versionSource != nil { policy.reset() }
        attempts += 1
        let attempt = Attempt(number: attempts, generation: generation, noteID: id, change: change,
                              versionSource: versionSource, completions: Array(owedCompletions.keys))
        let completions = owedCompletions
        let saveStore = self.saveStore
        let mailbox = self.mailbox
        let redirects = self.redirects
        queue.async { [weak self] in
            let result = Result {
                try Self.write(text, to: id, in: saveStore, versionSource: versionSource, completing: completions, redirects: redirects)
            }
            mailbox.post(attempt, result)
            DispatchQueue.main.async { self?.drain() }
        }
        return finish(wait: wait)
    }

    /// Saves before leaving this note, and drops it if it's empty: removed if it never had anything in it,
    /// otherwise to Recently Deleted with its history. Waits, and returns where the canvas stands; if it
    /// failed, the caller decides whether leaving is safe.
    @discardableResult
    public func leave() -> Outcome {
        let outcome = save(version: .ifChanged, wait: true)
        guard outcome.isSaved, let id = noteID, text().allSatisfy(\.isWhitespace) else { return outcome }
        let saveStore = self.saveStore
        let discarded = (try? queue.sync { try saveStore.discardIfBlank(noteID: id) }) ?? nil
        if discarded != nil { onDiscarded?(id) }
        return outcome
    }

    /// Blocks until queued saves have landed or failed, and returns where the canvas stands.
    @discardableResult
    public func waitForSaves() -> Outcome {
        finish(wait: true)
    }

    // MARK: Results

    private struct Attempt {
        var number: Int
        var generation: Int
        var noteID: NoteID
        var change: Int
        var versionSource: String?
        var completions: [Int64]
    }

    private enum Written {
        case saved(NoteSummary?)
        /// The note was gone, so the text went into this new one.
        case recreated(NoteID, NoteSummary?)
    }

    /// Only touched on the save queue.
    private final class Redirects: @unchecked Sendable {
        var map: [NoteID: NoteID] = [:]
    }

    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Attempt, Result<Written, Error>)] = []

        func post(_ attempt: Attempt, _ result: Result<Written, Error>) {
            lock.lock()
            items.append((attempt, result))
            lock.unlock()
        }

        func take() -> [(Attempt, Result<Written, Error>)] {
            lock.lock()
            defer { lock.unlock() }
            let taken = items
            items = []
            return taken
        }
    }

    /// Runs on the save queue.
    private static func write(_ text: String, to id: NoteID, in store: Store, versionSource: String?,
                              completing completions: [Int64: AgentResult], redirects: Redirects) throws -> Written {
        let target = redirects.map[id] ?? id
        do {
            return .saved(try store.saveText(noteID: target, text: text, versionSource: versionSource, completing: completions))
        } catch StoreError.noteNotFound, StoreError.noteDeleted {
            // Deleted on another device (or removed) under unsaved typing: keep the typing as a note of its own.
            let newID = try store.createNote(text: text, versionSource: versionSource ?? "user", completing: completions)
            redirects.map[id] = newID
            return .recreated(newID, try store.summary(id: newID))
        }
    }

    private func finish(wait: Bool) -> Outcome {
        if wait {
            queue.sync {}
            drain()
        }
        return outcome
    }

    /// Applies results that have come back, oldest first.
    private func drain() {
        for (attempt, result) in mailbox.take().sorted(by: { $0.0.number < $1.0.number }) where attempt.number > settled {
            settled = attempt.number
            settle(attempt, result)
        }
    }

    private func settle(_ attempt: Attempt, _ result: Result<Written, Error>) {
        switch result {
        case .success(let written):
            var summary: NoteSummary?
            var recreated: NoteID?
            switch written {
            case .saved(let s): summary = s
            case .recreated(let id, let s): (recreated, summary) = (id, s)
            }
            if let summary { onSaved?(summary) }
            guard attempt.generation == generation else {
                if let recreated { onRecreated?(attempt.noteID, recreated) }
                return
            }
            if let recreated, noteID == attempt.noteID {
                noteID = recreated
                store.currentNoteID = recreated
            }
            saved = max(saved, attempt.change)
            if attempt.versionSource != nil { owedVersion = nil }
            for id in attempt.completions { owedCompletions[id] = nil }
            if let recreated { onRecreated?(attempt.noteID, recreated) }
            if failure != nil, attempt.number == attempts { recover() }

        case .failure(let error):
            guard attempt.generation == generation else { return }
            // The newest write failed, so the next save writes again.
            if attempt.number == attempts { queued = saved }
            if let source = attempt.versionSource, owedVersion == nil { owedVersion = source }
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let message = String(describing: error)
        var copy = failure?.copy
        do {
            copy = try writeRecoveryCopy(text())
        } catch {
            // Keep whatever copy there was; the message says the save failed either way.
        }
        let changed = failure?.message != message || failure?.copy != copy
        failure = (message, copy)
        if changed { onOutcomeChanged?(outcome) }
        scheduleRetry()
    }

    private func recover() {
        if let copy = failure?.copy { try? FileManager.default.removeItem(at: copy) }
        failure = nil
        retries = 0
        retryTimer?.invalidate()
        retryTimer = nil
        recoveryName = nil
        onOutcomeChanged?(.saved)
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard retries < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retries]
        retries += 1
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.save()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Recovery copies

    /// Where text goes when the database won't take it: a `Recovered` folder next to the database.
    public var recoveryFolder: URL {
        saveStore.url.deletingLastPathComponent().appendingPathComponent("Recovered", isDirectory: true)
    }

    /// Writes the canvas to this session's recovery file (one per note opened), replacing the last copy.
    private func writeRecoveryCopy(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        let name = recoveryName ?? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let what = noteID.map { "note \($0)" } ?? "new note"
            return "Unsaved \(what) \(formatter.string(from: Date())).txt"
        }()
        recoveryName = name
        let url = recoveryFolder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}
