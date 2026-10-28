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

/// What agents can do, shared by the `blktxt` CLI and its MCP server.
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

    // MARK: Reads

    public func listNotes(limit: Int = 20, offset: Int = 0) throws -> [NoteSummary] {
        try store.notes(limit: max(1, min(limit, 500)), offset: max(0, offset))
    }

    /// A note's full text. `nil` means the note open in the canvas (saved first if the app is running).
    public func readNote(id: NoteID?) throws -> Note {
        if id == nil, link.isAppRunning { _ = try sendToApp(AgentOp(noteID: nil, edit: .flush, source: source), timeout: 1) }
        guard let noteID = id ?? store.currentNoteID else { throw AgentError.notFound("No note is open in BlackText (the canvas is blank).") }
        guard let note = try store.note(id: noteID), note.deletedAt == nil else { throw AgentError.notFound("No note with id \(noteID).") }
        return note
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
        guard store.agentsCanEdit else { throw AgentError.readOnly }
        guard !text.isEmpty else { throw AgentError.invalid("Text is empty.") }
        let id = try store.createNote(text: text)
        try store.addVersion(noteID: id, text: text, source: source)
        AppLink.postChanged()
        return id
    }

    public func appendToCurrent(text: String, newParagraph: Bool = true) throws -> AgentResult {
        guard !text.isEmpty else { throw AgentError.invalid("Text is empty.") }
        return try perform(AgentOp(noteID: nil, edit: .append(text: text, newParagraph: newParagraph), source: source))
    }

    public func replace(in noteID: NoteID?, find: String, with replacement: String, options: FindOptions,
                        all: Bool = true, preserveCase: Bool = false) throws -> AgentResult {
        guard !find.isEmpty else { throw AgentError.invalid("Nothing to find.") }
        do {
            _ = try FindEngine.regex(for: FindQuery(find, options: options))
        } catch {
            throw AgentError.invalid("Invalid regular expression: \(find)")
        }
        let edit = AgentEdit.replace(find: find, replacement: replacement, options: options, all: all, preserveCase: preserveCase)
        return try perform(AgentOp(noteID: noteID, edit: edit, source: source))
    }

    private func perform(_ op: AgentOp) throws -> AgentResult {
        guard store.agentsCanEdit else { throw AgentError.readOnly }
        if let direct = try link.ifAppNotRunning({ try store.applyDirectly(op) }) {
            return direct
        }
        return try sendToApp(op, timeout: appTimeout)
    }

    /// Queues an op for the running app and waits for its answer.
    private func sendToApp(_ op: AgentOp, timeout: TimeInterval) throws -> AgentResult {
        let id = try store.enqueue(op)
        AppLink.postChanged()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try store.result(opID: id) { return result }
            usleep(15_000)
        }
        var pending = AgentResult.success(noteID: op.noteID)
        pending.queued = true
        return pending
    }
}
