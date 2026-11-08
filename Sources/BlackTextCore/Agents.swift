import CryptoKit
import Foundation
import notify

/// An edit an agent asks for. Applied by the running app, or straight to the database when it isn't running.
public enum AgentEdit: Equatable, Sendable {
    case append(text: String, newParagraph: Bool)
    case replace(find: String, replacement: String, options: FindOptions, all: Bool, preserveCase: Bool)
    /// Asks the app to save what's in the canvas now, so a read sees the latest text.
    case flush

    struct Payload: Codable {
        var text: String?
        var newParagraph: Bool?
        var find: String?
        var replacement: String?
        var matchCase: Bool?
        var wholeWord: Bool?
        var regex: Bool?
        var all: Bool?
        var preserveCase: Bool?
        /// Where the op was aimed when it was asked for (see `AgentOp.pinned`).
        var pinned: Bool?
        var target: String?
    }

    var kind: String {
        switch self {
        case .append: return "append"
        case .replace: return "replace"
        case .flush: return "flush"
        }
    }

    func encodedPayload(pinned: Bool = false, target: String? = nil) throws -> String {
        var payload = Payload()
        if pinned {
            payload.pinned = true
            payload.target = target
        }
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
        self.init(kind: kind, payload: p)
    }

    init?(kind: String, payload p: Payload) {
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
    /// True once the op's target was settled when it was asked for: `targetUID` is that note, or nil for a
    /// blank canvas. A pinned op lands on that note even if the canvas has moved on, or the id was reused,
    /// by the time the app gets to it.
    public var pinned = false
    public var targetUID: String?

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
    /// With `queued`: the request to ask about later (`edit_status`, `blacktext status`).
    public var request: Int64?

    public static func success(noteID: NoteID?, replacements: Int? = nil) -> AgentResult {
        AgentResult(ok: true, noteID: noteID, replacements: replacements)
    }

    public static func failure(_ message: String, noteID: NoteID? = nil) -> AgentResult {
        AgentResult(ok: false, noteID: noteID, error: message)
    }
}

extension Store {
    /// Where an op lands.
    enum Target {
        case note(Note)
        /// The blank canvas: an append makes a new note.
        case blank(makeCurrent: Bool)
    }

    /// Applies an agent edit straight to the database, keeping a version of the text before and after it.
    /// The app uses this for notes that aren't open; the CLI uses it when the app isn't running.
    ///
    /// The note is read, the edit worked out, and the result written only if the note still says what was
    /// read, all in one transaction with the op's completion (so a queued op happens exactly once). If another
    /// writer got there first, it starts over.
    public func applyDirectly(_ op: AgentOp) throws -> AgentResult {
        for _ in 0..<5 {
            do {
                return try applyOnce(op)
            } catch StoreError.conflict {
                continue
            }
        }
        return .failure("The note kept changing while the edit was being made. Try again.", noteID: op.noteID)
    }

    func target(of op: AgentOp) throws -> Result<Target, AgentResultError> {
        let id: NoteID?
        if op.pinned {
            if let uid = op.targetUID {
                guard let found = try noteID(uid: uid) else { return .failure(.init("The note was deleted.")) }
                id = found
            } else {
                return .success(.blank(makeCurrent: currentNoteID == nil))
            }
        } else {
            id = op.noteID ?? currentNoteID
        }
        guard let id else { return .success(.blank(makeCurrent: true)) }
        guard let note = try note(id: id) else {
            // An unpinned op for the canvas whose note is gone: the canvas is blank.
            if op.noteID == nil, !op.pinned { return .success(.blank(makeCurrent: true)) }
            return .failure(.init("No note with id \(id)."))
        }
        if note.deletedAt != nil { return .failure(.init("Note \(note.id) is in Recently Deleted.", noteID: note.id)) }
        return .success(.note(note))
    }

    private func applyOnce(_ op: AgentOp) throws -> AgentResult {
        let target: Target
        switch try self.target(of: op) {
        case .failure(let error): return .failure(error.message, noteID: error.noteID)
        case .success(let found): target = found
        }
        func done(_ result: AgentResult) -> [Int64: AgentResult] { op.id > 0 ? [op.id: result] : [:] }

        switch (op.edit, target) {
        case (.flush, .note(let note)):
            return .success(noteID: note.id)
        case (.flush, .blank):
            return .success(noteID: nil)

        case let (.append(text, _), .blank(makeCurrent)):
            let result = AgentResult.success(noteID: nil)
            let id = try createNote(text: text, versionSource: op.source, completing: done(result))
            if makeCurrent { currentNoteID = id }
            return .success(noteID: id)

        case let (.append(text, newParagraph), .note(note)):
            let updated = NoteEdits.appending(text, to: note.text, newParagraph: newParagraph)
            let result = AgentResult.success(noteID: note.id)
            try commitEdit(noteID: note.id, expected: note.text, text: updated, source: op.source, completing: done(result))
            return result

        case (.replace, .blank):
            return .failure("No note is open in BlackText.")

        case let (.replace(find, replacement, options, all, preserveCase), .note(note)):
            let query = FindQuery(find, options: options)
            let edit = all
                ? try FindEngine.replaceAll(in: note.text, query: query, template: replacement, preserveCase: preserveCase)
                : try FindEngine.replaceFirst(in: note.text, query: query, template: replacement, preserveCase: preserveCase)
            let result = AgentResult.success(noteID: note.id, replacements: edit.count)
            guard edit.count > 0 else { return result }
            try commitEdit(noteID: note.id, expected: note.text, text: edit.text, source: op.source, completing: done(result))
            return result
        }
    }

    /// Settles where an op is aimed now, before it waits in the inbox: the note it names, or the one open in
    /// the canvas (nil for a blank canvas).
    func pin(_ op: AgentOp) throws -> AgentOp {
        var op = op
        op.pinned = true
        if let id = op.noteID {
            op.targetUID = try noteUID(id: id)
        } else if let current = currentNoteID, let note = try note(id: current), note.deletedAt == nil {
            op.noteID = current
            op.targetUID = try noteUID(id: current)
        }
        return op
    }
}

struct AgentResultError: Error {
    var message: String
    var noteID: NoteID?
    init(_ message: String, noteID: NoteID? = nil) {
        self.message = message
        self.noteID = noteID
    }
}

/// How the CLI and the app find each other: a lock file the app holds while it runs,
/// and a Darwin notification that says "the database changed, take a look".
public final class AppLink: @unchecked Sendable {
    public struct LockError: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String {
            "Couldn't open \(path): \(String(cString: strerror(code)))"
        }
    }

    public let lockURL: URL
    /// Scoped to the database, so a test library, or a second library, never wakes an app that's looking after
    /// another one. Names are routing, not security: any process of this user can post one.
    public let changedNotification: String
    private var heldDescriptor: Int32 = -1

    public init(database: URL = Paths.databaseURL) {
        lockURL = Paths.lockURL(for: database)
        let path = database.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        changedNotification = "co.curry.blacktext.changed." + digest
    }

    deinit {
        if heldDescriptor >= 0 { close(heldDescriptor) }
    }

    private func openLock() throws -> Int32 {
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw LockError(path: lockURL.path, code: errno) }
        return fd
    }

    /// App side: take the lock for the life of the process. Waits briefly for a CLI write in progress.
    /// False means another process has it (another copy of the app); throws if the lock can't be opened.
    @discardableResult
    public func holdWhileRunning(timeout: TimeInterval = 2) throws -> Bool {
        let fd = try openLock()
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { close(fd); return false }
            usleep(5_000)
        }
        heldDescriptor = fd
        return true
    }

    /// CLI side: runs `body` while holding the lock if the app isn't running.
    /// Returns nil without running `body` when the app is running. Throws, without running it, if the lock
    /// can't be opened: not knowing isn't the same as the app being closed.
    public func ifAppNotRunning<T>(_ body: () throws -> T) throws -> T? {
        let fd = try openLock()
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// True if the app is running, or if that can't be told.
    public var isAppRunning: Bool {
        (try? ifAppNotRunning { true }) == nil
    }

    public func postChanged() {
        notify_post(changedNotification)
    }
}
