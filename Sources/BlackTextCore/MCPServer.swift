import Foundation

/// A Model Context Protocol server over stdio: one JSON-RPC message per line.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let service: AgentService
    let version: String

    public init(service: AgentService, version: String) {
        self.service = service
        self.version = version
    }

    /// Reads requests from stdin until it closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    /// Handles one message. Returns the response line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let message = object as? [String: Any]
        else { return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]) }

        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to something we never send, or junk. Ignore responses, reject the rest.
            return id == nil || message["result"] != nil || message["error"] != nil ? nil
                : encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32600, "message": "Invalid request"]])
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil } // Notifications (initialized, cancelled…) need no answer.

        let result: [String: Any]
        switch method {
        case "initialize":
            result = initialize(params)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.tools]
        case "tools/call":
            result = call(params)
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        if let client = params["clientInfo"] as? [String: Any], let name = client["name"] as? String, !name.isEmpty {
            service.agentName = name
        }
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "blacktext", "title": "BlackText", "version": self.version],
            "instructions": """
                BlackText is the user's plain-text notepad. Notes are plain text, no formatting. \
                "Current" means the note open in the canvas right now. Prefer create_note for new material; \
                use append_to_current only when the user asks you to add to what they're writing. \
                Every edit you make is saved as a version, so nothing is lost.
                """,
        ]
    }

    // MARK: Tools

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static let findFlags: [String: Any] = [
        "match_case": ["type": "boolean", "description": "Case-sensitive. Default false."],
        "whole_word": ["type": "boolean", "description": "Only whole words. Default false."],
        "regex": ["type": "boolean", "description": "Treat the query as a regular expression. Default false."],
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "list_notes",
            "description": "List notes, most recently edited first: id, title (first line), dates, word count.",
            "inputSchema": schema([
                "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Default 20."],
                "offset": ["type": "integer", "minimum": 0, "description": "Skip this many. Default 0."],
            ]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "read_note",
            "description": "Read a note's full text. Omit id to read the note currently open in the canvas.",
            "inputSchema": schema(["id": ["type": "integer", "description": "Note id from list_notes or search."]]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "search",
            "description": "Search all notes. Substring match, case-insensitive by default. Returns notes with a snippet and match count.",
            "inputSchema": schema(findFlags.merging([
                "query": ["type": "string"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."],
            ]) { $1 }, required: ["query"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "list_versions",
            "description": "List a note's saved versions, newest first. Versions are read-only snapshots.",
            "inputSchema": schema(["note_id": ["type": "integer"]], required: ["note_id"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "read_version",
            "description": "Read the full text of one saved version.",
            "inputSchema": schema(["version_id": ["type": "integer"]], required: ["version_id"]),
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "create_note",
            "description": "Create a new note in the sidebar. Does not change what the user is writing.",
            "inputSchema": schema(["text": ["type": "string", "description": "Plain text. No markdown styling is rendered."]], required: ["text"]),
            "annotations": ["readOnlyHint": false, "destructiveHint": false],
        ],
        [
            "name": "append_to_current",
            "description": "Append text to the end of the note open in the canvas. Appears live and can be undone.",
            "inputSchema": schema([
                "text": ["type": "string"],
                "new_paragraph": ["type": "boolean", "description": "Start on a new paragraph. Default true."],
            ], required: ["text"]),
            "annotations": ["readOnlyHint": false, "destructiveHint": false],
        ],
        [
            "name": "replace_in_note",
            "description": "Find and replace in a note (default: the open note). A version is saved first. Returns the number of replacements.",
            "inputSchema": schema(findFlags.merging([
                "note_id": ["type": "integer", "description": "Omit for the note open in the canvas."],
                "find": ["type": "string"],
                "replace": ["type": "string", "description": "With regex, $1-style groups work."],
                "all": ["type": "boolean", "description": "Replace every match. Default true; false replaces the first."],
                "preserve_case": ["type": "boolean", "description": "Coffee→Tea, COFFEE→TEA. Default false."],
            ]) { $1 }, required: ["find", "replace"]),
            "annotations": ["readOnlyHint": false, "destructiveHint": true],
        ],
    ]

    private func call(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let output = try run(tool: name, args: args)
            return ["content": [["type": "text", "text": output]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    private func run(tool: String, args: [String: Any]) throws -> String {
        func int(_ key: String) -> Int64? { (args[key] as? NSNumber)?.int64Value }
        func bool(_ key: String, _ fallback: Bool) -> Bool { (args[key] as? Bool) ?? fallback }
        func string(_ key: String) throws -> String {
            guard let value = args[key] as? String else { throw AgentError.invalid("Missing \"\(key)\".") }
            return value
        }
        let options = FindOptions(matchCase: bool("match_case", false), wholeWord: bool("whole_word", false), regex: bool("regex", false))

        switch tool {
        case "list_notes":
            let notes = try service.listNotes(limit: Int(int("limit") ?? 20), offset: Int(int("offset") ?? 0))
            return json(["notes": notes.map(AgentJSON.summary), "total": try service.store.noteCount()])
        case "read_note":
            return json(AgentJSON.note(try service.readNote(id: int("id"))))
        case "search":
            let hits = try service.search(FindQuery(try string("query"), options: options), limit: Int(int("limit") ?? 20))
            return json(["results": hits.map(AgentJSON.hit)])
        case "list_versions":
            guard let id = int("note_id") else { throw AgentError.invalid("Missing \"note_id\".") }
            return json(["versions": try service.versions(noteID: id).map(AgentJSON.version)])
        case "read_version":
            guard let id = int("version_id") else { throw AgentError.invalid("Missing \"version_id\".") }
            let version = try service.readVersion(id: id)
            var object = AgentJSON.version(version.summary)
            object["text"] = version.text
            return json(object)
        case "create_note":
            return json(["id": try service.createNote(text: try string("text"))])
        case "append_to_current":
            return json(AgentJSON.result(try checked(service.appendToCurrent(text: try string("text"), newParagraph: bool("new_paragraph", true)))))
        case "replace_in_note":
            let result = try service.replace(in: int("note_id"), find: try string("find"), with: try string("replace"),
                                             options: options, all: bool("all", true), preserveCase: bool("preserve_case", false))
            return json(AgentJSON.result(try checked(result)))
        default:
            throw AgentError.invalid("Unknown tool: \(tool)")
        }
    }

    private func checked(_ result: AgentResult) throws -> AgentResult {
        guard result.ok else { throw AgentError.invalid(result.error ?? "The edit failed.") }
        return result
    }

    private func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// JSON shapes shared by MCP and `blacktext --json`.
public enum AgentJSON {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    public static func date(_ date: Date) -> String { dateFormatter.string(from: date) }

    public static func summary(_ note: NoteSummary) -> [String: Any] {
        ["id": note.id, "title": note.title, "created": date(note.createdAt), "updated": date(note.updatedAt),
         "words": note.wordCount, "versions": note.versionCount]
    }

    public static func note(_ note: Note) -> [String: Any] {
        var object = summary(note.summary)
        object["text"] = note.text
        return object
    }

    public static func hit(_ hit: SearchHit) -> [String: Any] {
        var object = summary(hit.note)
        object["matches"] = hit.matchCount
        object["snippet"] = hit.snippet
        return object
    }

    public static func version(_ version: VersionSummary) -> [String: Any] {
        ["id": version.id, "note_id": version.noteID, "created": date(version.createdAt),
         "words": version.wordCount, "by": version.agentName ?? "user"]
    }

    public static func result(_ result: AgentResult) -> [String: Any] {
        var object: [String: Any] = ["ok": result.ok]
        if let id = result.noteID { object["note_id"] = id }
        if let count = result.replacements { object["replacements"] = count }
        if let error = result.error { object["error"] = error }
        if result.queued == true { object["queued"] = true; object["note"] = "BlackText is busy; the edit will apply shortly." }
        return object
    }
}
