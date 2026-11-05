import BlackTextCore
import Foundation

/// Autosave and versioning for the note in the canvas.
///
/// A keystroke only marks the note dirty. A save runs 1 second after typing stops, or at most
/// 5 seconds after the first unsaved change, on a background connection. Idle means no timers.
final class NoteSession {
    enum VersionRule {
        /// Only if 100 words have changed since the last version.
        case ifDue
        /// If anything changed since the last version (leaving a note, ⌘↩, quitting).
        case ifChanged
        /// Always, unless identical to the last version (before Replace All, agent edits).
        case always
        case never
    }

    static let idleDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 5

    private let store: Store
    private let saveStore: Store
    private let queue = DispatchQueue(label: "co.curry.blacktext.save", qos: .userInitiated)

    private(set) var noteID: NoteID?
    private(set) var isDirty = false
    private var policy = VersionPolicy()
    private var firstUnsavedChange: Date?
    private var timer: Timer?

    /// The canvas text, read at save time.
    var text: () -> String = { "" }
    /// Called on the main thread after a save lands, with the note's new summary.
    var onSaved: ((NoteSummary) -> Void)?
    /// Called when an empty note is discarded on leaving it.
    var onDiscarded: ((NoteID) -> Void)?

    init(store: Store, saveStore: Store) {
        self.store = store
        self.saveStore = saveStore
    }

    /// Starts a session for `note` (nil = blank canvas). Call `leave()` on the previous one first.
    func load(_ note: Note?) {
        timer?.invalidate()
        timer = nil
        noteID = note?.id
        isDirty = false
        firstUnsavedChange = nil
        policy.reset()
        store.currentNoteID = noteID
    }

    func record(replacing range: NSRange, in text: NSString, with replacement: String) {
        policy.record(replacing: range, in: text, with: replacement)
    }

    func textDidChange() {
        isDirty = true
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

    /// Writes the canvas if it changed, and a version if the rule says so.
    func save(version rule: VersionRule = .ifDue, source: String = "user", wait: Bool = false) {
        timer?.invalidate()
        timer = nil
        let wantsVersion: Bool
        switch rule {
        case .ifDue: wantsVersion = policy.isDue
        case .ifChanged: wantsVersion = policy.hasChanges
        case .always: wantsVersion = true
        case .never: wantsVersion = false
        }
        guard isDirty || wantsVersion else { return }

        let text = self.text()
        if noteID == nil {
            // A blank canvas becomes a note once it has something in it.
            guard !text.allSatisfy(\.isWhitespace) else { isDirty = false; return }
            noteID = try? store.createNote()
            store.currentNoteID = noteID
        }
        guard let id = noteID else { return }

        let writesText = isDirty
        isDirty = false
        firstUnsavedChange = nil
        if wantsVersion { policy.reset() }

        let saveStore = self.saveStore
        let work: () -> NoteSummary? = {
            var summary: NoteSummary?
            if writesText { summary = try? saveStore.updateText(noteID: id, text: text) }
            if wantsVersion, (try? saveStore.addVersion(noteID: id, text: text, source: source)) != nil {
                summary = try? saveStore.summary(id: id)
            }
            return summary
        }
        if wait {
            if let summary = queue.sync(execute: work) { onSaved?(summary) }
        } else {
            queue.async { [weak self] in
                guard let summary = work() else { return }
                DispatchQueue.main.async { self?.onSaved?(summary) }
            }
        }
    }

    /// Saves before leaving this note, and drops it if it never had anything in it.
    func leave(wait: Bool = false) {
        save(version: .ifChanged, wait: wait)
        guard let id = noteID, text().allSatisfy(\.isWhitespace) else { return }
        let saveStore = self.saveStore
        queue.async { [weak self] in
            guard let summary = try? saveStore.summary(id: id), summary.versionCount == 0 else { return }
            try? saveStore.hardDelete(noteID: id)
            DispatchQueue.main.async { self?.onDiscarded?(id) }
        }
    }

    /// Blocks until queued saves have landed.
    func waitForSaves() {
        queue.sync {}
    }
}
