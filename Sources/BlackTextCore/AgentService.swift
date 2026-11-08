import Foundation

public enum AgentError: Error, CustomStringConvertible {
    case readOnly
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .readOnly: return "BlackText is set to read-only for agents (BlackText → Allow Agents to Edit)."
        case .notFound(let what): return what
        case .invalid(let why): return why
        }
    }
}

/// What agents can do, shared by the `blacktext` CLI and its MCP server.
/// Reads go to the database. Edits go through the app when it's running, so they never clobber typing.
public final class AgentService {
    public let store: Store
    public let link: AppLink
    /// Recorded on every version an agent makes, e.g. "agent:claude-code".
    public var source: String
    /// How long to wait for the running app to apply an edit.
    public var appTimeout: TimeInterval = 3

    public init(store: Store, link: AppLink, agentName: String = "cli") {
        self.store = store
        self.link = link
        self.source = "agent:" + agentName
    }

    public var agentName: String {
        get { String(source.dropFirst("agent:".count)) }
        set { source = "agent:" + Self.sanitize(newValue) }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        return String(cleaned.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Most edits that may wait in the inbox for the app at once.
    public static let maxPendingOps = 100
    /// Longest text an agent may send in one call.
    public static let maxTextLength = 10_000_000

    // MARK: Reads

    public func listNotes(limit: Int = 20, offset: Int = 0) throws -> [NoteSummary] {
        try store.notes(limit: max(1, min(limit, 500)), offset: max(0, offset))
    }

    /// A note, and whether it's known to include everything typed in the app.
    public struct NoteRead {
        public var note: Note
        /// False when this is the open note and the running app didn't confirm it had saved the canvas, so
        /// the last few seconds of typing may be missing.
        public var isCurrent: Bool
    }

    /// A note's full text. `nil` means the note open in the canvas, saved first if the app is running.
    public func readNote(id: NoteID?) throws -> Note {
        try read(id: id).note
    }

    public func read(id: NoteID?) throws -> NoteRead {
        var isCurrent = true
        if id == nil, link.isAppRunning {
            // Saving the canvas isn't an edit, so it's asked for even when agents may only read.
            let flushed = try sendToApp(AgentOp(noteID: nil, edit: .flush, source: source), timeout: appTimeout)
            isCurrent = flushed.ok && flushed.queued != true
        }
        guard let noteID = id ?? store.currentNoteID else { throw AgentError.notFound("No note is open in BlackText (the canvas is blank).") }
        guard let note = try store.note(id: noteID), note.deletedAt == nil else { throw AgentError.notFound("No note with id \(noteID).") }
        return NoteRead(note: note, isCurrent: isCurrent)
    }

    /// What became of an edit that was still queued when the call returned (`AgentResult.request`).
    /// nil while the app hasn't got to it.
    public func status(request: Int64) throws -> AgentResult? {
        guard request > 0, try store.hasOp(id: request) else {
            throw AgentError.notFound("No edit request \(request). Finished requests are kept for an hour.")
        }
        return try store.result(opID: request)
    }

    public func search(_ query: FindQuery, limit: Int = 20) throws -> [SearchHit] {
        do {
            return try store.search(query, limit: max(1, min(limit, 200)))
        } catch FindError.invalidPattern {
            throw AgentError.invalid("Invalid regular expression: \(query.text)")
        }
    }

    public func versions(noteID: NoteID) throws -> [VersionSummary] {
        guard try store.summary(id: noteID) != nil else { throw AgentError.notFound("No note with id \(noteID).") }
        return try store.versions(noteID: noteID)
    }

    public func readVersion(id: VersionID) throws -> (summary: VersionSummary, text: String) {
        guard let version = try store.version(id: id) else { throw AgentError.notFound("No version with id \(id).") }
        return version
    }

    // MARK: Edits

    /// Adds a note to the sidebar. Never touches the canvas.
    public func createNote(text: String) throws -> NoteID {
        try checkMayEdit()
        try check(text)
        let id = try store.createNote(text: text, versionSource: source)
        link.postChanged()
        return id
    }

    public func appendToCurrent(text: String, newParagraph: Bool = true) throws -> AgentResult {
        try check(text)
        return try perform(AgentOp(noteID: nil, edit: .append(text: text, newParagraph: newParagraph), source: source))
    }

    private func check(_ text: String) throws {
        guard !text.isEmpty else { throw AgentError.invalid("Text is empty.") }
        guard text.utf8.count <= Self.maxTextLength else { throw AgentError.invalid("Text is too long (over 10 MB).") }
    }

    /// Fails closed: if the setting can't be read, agents can't edit.
    private func checkMayEdit() throws {
        guard store.agentsCanEdit else { throw AgentError.readOnly }
    }

    public func replace(in noteID: NoteID?, find: String, with replacement: String, options: FindOptions,
                        all: Bool = true, preserveCase: Bool = false) throws -> AgentResult {
        guard !find.isEmpty else { throw AgentError.invalid("Nothing to find.") }
        guard find.utf8.count + replacement.utf8.count <= Self.maxTextLength else { throw AgentError.invalid("Text is too long (over 10 MB).") }
        do {
            _ = try FindEngine.regex(for: FindQuery(find, options: options))
        } catch {
            throw AgentError.invalid("Invalid regular expression: \(find)")
        }
        let edit = AgentEdit.replace(find: find, replacement: replacement, options: options, all: all, preserveCase: preserveCase)
        return try perform(AgentOp(noteID: noteID, edit: edit, source: source))
    }

    private func perform(_ op: AgentOp) throws -> AgentResult {
        try checkMayEdit()
        if let direct = try link.ifAppNotRunning({ try store.applyDirectly(op) }) {
            if direct.ok { link.postChanged() }
            return direct
        }
        return try sendToApp(op, timeout: appTimeout)
    }

    /// Queues an op for the running app and waits for its answer. The op is pinned to the note it's aimed at
    /// now. If the app doesn't answer in time, the result says it's queued and gives the request to ask about.
    private func sendToApp(_ op: AgentOp, timeout: TimeInterval) throws -> AgentResult {
        guard try store.pendingOpCount() < Self.maxPendingOps else {
            throw AgentError.invalid("BlackText has too many edits waiting. Try again once it has caught up.")
        }
        let pinned = try store.pin(op)
        let id = try store.enqueue(pinned)
        link.postChanged()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try store.result(opID: id) { return result }
            usleep(15_000)
        }
        var pending = AgentResult.success(noteID: pinned.noteID)
        pending.queued = true
        pending.request = id
        return pending
    }
}
