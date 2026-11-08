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
        // Request ids are strings or numbers (not true/false, which JSON parsing also hands over as numbers).
        let validID = id.map { $0 is String || ($0 is NSNumber && !Self.isBoolean($0)) } ?? true
        guard let method = message["method"] as? String, message["jsonrpc"] as? String == "2.0", validID else {
            // A response to something we never send, or junk. Ignore responses, reject the rest.
            if message["method"] == nil, message["result"] != nil || message["error"] != nil { return nil }
            if id == nil, message["method"] is String { return nil }
            return encode(["jsonrpc": "2.0", "id": validID ? (id ?? NSNull()) : NSNull(),
                           "error": ["code": -32600, "message": "Invalid request"]])
        }
        guard let id else { return nil } // Notifications (initialized, cancelled…) need no answer.
        let params: [String: Any]
        switch message["params"] {
        case nil, is NSNull: params = [:]
        case let object as [String: Any]: params = object
        default: return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Invalid params"]])
        }

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
            "name": "edit_status",
            "description": "What became of an edit that was still queued (\"queued\": true) when it returned. Pass its request.",
            "inputSchema": schema(["request": ["type": "integer", "minimum": 1]], required: ["request"]),
            "annotations": ["readOnlyHint": true],
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
        do {
            guard let name = params["name"] as? String else { throw AgentError.invalid("Missing tool name.") }
            let output = try run(tool: name, args: try ToolArguments(params["arguments"], for: name))
            return ["content": [["type": "text", "text": output]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A tool's arguments, checked against its schema: no unknown names, and each value the right type.
    /// A value that's there but wrong is an error, never quietly read as "not given" (which for a note id
    /// would mean the open note).
    struct ToolArguments {
        let values: [String: Any]

        init(_ raw: Any?, for tool: String) throws {
            switch raw {
            case nil, is NSNull: values = [:]
            case let object as [String: Any]: values = object
            default: throw AgentError.invalid("Arguments must be an object.")
            }
            guard let spec = MCPServer.tools.first(where: { $0["name"] as? String == tool }) else {
                throw AgentError.invalid("Unknown tool: \(tool)")
            }
            let schema = spec["inputSchema"] as? [String: Any]
            let allowed = Set((schema?["properties"] as? [String: Any] ?? [:]).keys)
            if let unknown = Set(values.keys).subtracting(allowed).sorted().first {
                throw AgentError.invalid("Unknown argument \"\(unknown)\" for \(tool).")
            }
            for key in schema?["required"] as? [String] ?? [] where values[key] == nil || values[key] is NSNull {
                throw AgentError.invalid("Missing \"\(key)\".")
            }
        }

        private func present(_ key: String) -> Any? {
            guard let value = values[key], !(value is NSNull) else { return nil }
            return value
        }

        /// A whole number in `range`, or nil if not given.
        func integer(_ key: String, in range: ClosedRange<Int64>) throws -> Int64? {
            guard let value = present(key) else { return nil }
            guard let number = value as? NSNumber, !MCPServer.isBoolean(number) else {
                throw AgentError.invalid("\"\(key)\" must be a whole number.")
            }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) < 9_007_199_254_740_992 else {
                throw AgentError.invalid("\"\(key)\" must be a whole number.")
            }
            let integer = Int64(double)
            guard range.contains(integer) else {
                throw AgentError.invalid("\"\(key)\" must be between \(range.lowerBound) and \(range.upperBound).")
            }
            return integer
        }

        /// A note or version id, or nil if not given.
        func id(_ key: String) throws -> Int64? {
            try integer(key, in: 1...Int64.max)
        }

        func bool(_ key: String, _ fallback: Bool) throws -> Bool {
            guard let value = present(key) else { return fallback }
            guard MCPServer.isBoolean(value), let bool = value as? Bool else { throw AgentError.invalid("\"\(key)\" must be true or false.") }
            return bool
        }

        func string(_ key: String) throws -> String {
            guard let value = present(key) else { throw AgentError.invalid("Missing \"\(key)\".") }
            guard let string = value as? String else { throw AgentError.invalid("\"\(key)\" must be a string.") }
            return string
        }
    }

    private func run(tool: String, args: ToolArguments) throws -> String {
        func options() throws -> FindOptions {
            FindOptions(matchCase: try args.bool("match_case", false), wholeWord: try args.bool("whole_word", false),
                        regex: try args.bool("regex", false))
        }

        switch tool {
        case "list_notes":
            let notes = try service.listNotes(limit: Int(try args.integer("limit", in: 1...500) ?? 20),
                                              offset: Int(try args.integer("offset", in: 0...Int64(Int32.max)) ?? 0))
            return json(["notes": notes.map(AgentJSON.summary), "total": try service.store.noteCount()])
        case "read_note":
            let read = try service.read(id: try args.id("id"))
            var object = AgentJSON.note(read.note)
            if !read.isCurrent {
                object["stale"] = true
                object["note"] = "BlackText didn't confirm it had saved the open note, so the last few seconds of typing may be missing."
            }
            return json(object)
        case "search":
            let hits = try service.search(FindQuery(try args.string("query"), options: try options()),
                                          limit: Int(try args.integer("limit", in: 1...200) ?? 20))
            return json(["results": hits.map(AgentJSON.hit)])
        case "list_versions":
            guard let id = try args.id("note_id") else { throw AgentError.invalid("Missing \"note_id\".") }
            return json(["versions": try service.versions(noteID: id).map(AgentJSON.version)])
        case "read_version":
            guard let id = try args.id("version_id") else { throw AgentError.invalid("Missing \"version_id\".") }
            let version = try service.readVersion(id: id)
            var object = AgentJSON.version(version.summary)
            object["text"] = version.text
            return json(object)
        case "create_note":
            return json(["id": try service.createNote(text: try args.string("text"))])
        case "append_to_current":
            let result = try service.appendToCurrent(text: try args.string("text"), newParagraph: try args.bool("new_paragraph", true))
            return json(AgentJSON.result(try checked(result)))
        case "replace_in_note":
            let result = try service.replace(in: try args.id("note_id"), find: try args.string("find"), with: try args.string("replace"),
                                             options: try options(), all: try args.bool("all", true),
                                             preserveCase: try args.bool("preserve_case", false))
            return json(AgentJSON.result(try checked(result)))
        case "edit_status":
            guard let request = try args.id("request") else { throw AgentError.invalid("Missing \"request\".") }
            guard let result = try service.status(request: request) else {
                return json(["request": request, "queued": true, "note": "BlackText hasn't applied this edit yet."])
            }
            return json(AgentJSON.result(result))
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
        if result.queued == true {
            object["queued"] = true
            if let request = result.request {
                object["request"] = request
                object["note"] = "BlackText hasn't applied this edit yet. Call edit_status with this request to see what became of it."
            } else {
                object["note"] = "BlackText is busy; the edit will apply shortly."
            }
        }
        return object
    }
}
