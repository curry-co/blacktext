import Foundation
import notify

/// An edit an agent asks for. Applied by the running app, or straight to the database when it isn't running.
public enum AgentEdit: Equatable, Sendable {
    case append(text: String, newParagraph: Bool)
    case replace(find: String, replacement: String, options: FindOptions, all: Bool, preserveCase: Bool)
    /// Asks the app to save what's in the canvas now, so a read sees the latest text.
    case flush

    private struct Payload: Codable {
        var text: String?
        var newParagraph: Bool?
        var find: String?
        var replacement: String?
        var matchCase: Bool?
        var wholeWord: Bool?
        var regex: Bool?
        var all: Bool?
        var preserveCase: Bool?
    }

    var kind: String {
        switch self {
        case .append: return "append"
        case .replace: return "replace"
        case .flush: return "flush"
        }
    }

    func encodedPayload() throws -> String {
        var payload = Payload()
        switch self {
        case let .append(text, newParagraph):
            payload.text = text
            payload.newParagraph = newParagraph
        case let .replace(find, replacement, options, all, preserveCase):
            payload.find = find
            payload.replacement = replacement
            payload.matchCase = options.matchCase
            payload.wholeWord = options.wholeWord
            payload.regex = options.regex
            payload.all = all
            payload.preserveCase = preserveCase
        case .flush:
            break
        }
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    init?(kind: String, payload: String) {
        guard let p = try? JSONDecoder().decode(Payload.self, from: Data(payload.utf8)) else { return nil }
        switch kind {
        case "append":
            self = .append(text: p.text ?? "", newParagraph: p.newParagraph ?? true)
        case "replace":
            self = .replace(find: p.find ?? "", replacement: p.replacement ?? "",
                            options: FindOptions(matchCase: p.matchCase ?? false, wholeWord: p.wholeWord ?? false, regex: p.regex ?? false),
                            all: p.all ?? true, preserveCase: p.preserveCase ?? false)
        case "flush":
            self = .flush
        default:
            return nil
        }
    }
}

public struct AgentOp: Equatable, Sendable {
    public var id: Int64
    /// nil means the note open in the canvas.
    public var noteID: NoteID?
    public var edit: AgentEdit
    /// "agent:<name>"
    public var source: String

    public init(id: Int64 = 0, noteID: NoteID?, edit: AgentEdit, source: String) {
        self.id = id
        self.noteID = noteID
        self.edit = edit
        self.source = source
    }
}

public struct AgentResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var noteID: NoteID?
    public var replacements: Int?
    public var error: String?
    /// The app was running but didn't answer in time; the edit will apply when it does.
    public var queued: Bool?

    public static func success(noteID: NoteID?, replacements: Int? = nil) -> AgentResult {
        AgentResult(ok: true, noteID: noteID, replacements: replacements)
    }

    public static func failure(_ message: String, noteID: NoteID? = nil) -> AgentResult {
        AgentResult(ok: false, noteID: noteID, error: message)
    }
}

extension Store {
    /// Applies an agent edit straight to the database, keeping a version of the text before and after it.
    /// The app uses this for notes that aren't open; the CLI uses it when the app isn't running.
    public func applyDirectly(_ op: AgentOp) throws -> AgentResult {
        let targetID = op.noteID ?? currentNoteID
        let existing = try targetID.flatMap { try note(id: $0) }
        if let existing, existing.deletedAt != nil { return .failure("Note \(existing.id) is in Recently Deleted.", noteID: existing.id) }
        if targetID != nil, existing == nil, op.noteID != nil { return .failure("No note with id \(op.noteID!).") }

        switch op.edit {
        case .flush:
            return .success(noteID: existing?.id)

        case let .append(text, newParagraph):
            guard let existing else {
                let id = try createNote(text: text)
                try addVersion(noteID: id, text: text, source: op.source)
                if op.noteID == nil { currentNoteID = id }
                return .success(noteID: id)
            }
            let updated = NoteEdits.appending(text, to: existing.text, newParagraph: newParagraph)
            try commit(existing, updated, source: op.source)
            return .success(noteID: existing.id)

        case let .replace(find, replacement, options, all, preserveCase):
            guard let existing else { return .failure("No note is open in BlackText.") }
            let query = FindQuery(find, options: options)
            let result = all
                ? try FindEngine.replaceAll(in: existing.text, query: query, template: replacement, preserveCase: preserveCase)
                : try FindEngine.replaceFirst(in: existing.text, query: query, template: replacement, preserveCase: preserveCase)
            if result.count > 0 { try commit(existing, result.text, source: op.source) }
            return .success(noteID: existing.id, replacements: result.count)
        }
    }

    private func commit(_ note: Note, _ text: String, source: String) throws {
        try addVersion(noteID: note.id, text: note.text, source: "user")
        try updateText(noteID: note.id, text: text)
        try addVersion(noteID: note.id, text: text, source: source)
    }
}

/// How the CLI and the app find each other: a lock file the app holds while it runs,
/// and a Darwin notification that says "the database changed, take a look".
public final class AppLink: @unchecked Sendable {
    public static let changedNotification = "co.curry.blacktext.changed"

    public let lockURL: URL
    private var heldDescriptor: Int32 = -1

    public init(database: URL = Paths.databaseURL) {
        lockURL = Paths.lockURL(for: database)
    }

    deinit {
        if heldDescriptor >= 0 { close(heldDescriptor) }
    }

    /// App side: take the lock for the life of the process. Waits briefly for a CLI write in progress.
    @discardableResult
    public func holdWhileRunning(timeout: TimeInterval = 2) -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { close(fd); return false }
            usleep(5_000)
        }
        heldDescriptor = fd
        return true
    }

    /// CLI side: runs `body` while holding the lock if the app isn't running.
    /// Returns nil without running `body` when the app is running.
    public func ifAppNotRunning<T>(_ body: () throws -> T) throws -> T? {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public var isAppRunning: Bool {
        (try? ifAppNotRunning { true }) == nil
    }

    public static func postChanged() {
        notify_post(changedNotification)
    }
}
