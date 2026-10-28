import BlktxtCore
import Foundation

let usage = """
blktxt — the command line for BlackText. One page, plain text, nothing added.

Usage:
  blktxt list [-n COUNT]                 Recent notes, most recently edited first
  blktxt cat [ID]                        Print a note (default: the one open in BlackText)
  blktxt search QUERY [-n COUNT] [--case] [--word] [--regex]
  blktxt new [TEXT…]                     New note from TEXT, or from stdin
  blktxt append [TEXT…]                  Append to the open note (TEXT or stdin)
  blktxt replace FIND REPLACE [--note ID] [--first] [--case] [--word] [--regex] [--preserve-case]
  blktxt versions ID                     A note's saved versions
  blktxt version ID                      Print one version
  blktxt open                            Open BlackText
  blktxt mcp                             Run the MCP server on stdio, for AI agents
  blktxt mcp-config                      Print the MCP config to paste into an agent app

Add --json to list, cat, search and versions for machine-readable output.

"""

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        var iterator = raw.makeIterator()
        let takesValue: Set<String> = ["-n", "--note"]
        while let arg = iterator.next() {
            if takesValue.contains(arg) {
                values[arg] = iterator.next()
            } else if arg.hasPrefix("--") || (arg.hasPrefix("-") && arg.count == 2) {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }

    var findOptions: FindOptions {
        FindOptions(matchCase: flags.contains("--case"), wholeWord: flags.contains("--word"), regex: flags.contains("--regex"))
    }

    var json: Bool { flags.contains("--json") }

    func count(default value: Int) -> Int { values["-n"].flatMap(Int.init) ?? value }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

func printJSON(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

/// Text from the arguments, or from stdin when it's piped in.
func inputText(_ args: [String]) throws -> String {
    if !args.isEmpty { return args.joined(separator: " ") }
    guard isatty(STDIN_FILENO) == 0 else { throw CLIError(description: "No text given. Pass it as an argument or pipe it in.") }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}

func noteID(_ string: String?) throws -> NoteID? {
    guard let string else { return nil }
    if string == "current" { return nil }
    guard let id = NoteID(string) else { throw CLIError(description: "Not a note id: \(string)") }
    return id
}

let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy h:mm a"
    return formatter
}()

func line(for note: NoteSummary) -> String {
    let id = String(note.id).leftPadded(to: 6)
    let words = "\(note.wordCount) w".leftPadded(to: 9)
    return "\(id)  \(dateFormatter.string(from: note.updatedAt).leftPadded(to: 21))  \(words)  \(note.title.isEmpty ? "(empty)" : note.title)"
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

func executablePath() -> String {
    let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

func report(_ result: AgentResult) throws {
    guard result.ok else { throw CLIError(description: result.error ?? "The edit failed.") }
    if result.queued == true { FileHandle.standardError.write(Data("BlackText is busy; the edit will apply shortly.\n".utf8)) }
}

func run() throws {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard !raw.isEmpty else { print(usage, terminator: ""); return }
    let command = raw.removeFirst()
    let args = Arguments(raw)

    if ["help", "-h", "--help"].contains(command) { print(usage, terminator: ""); return }
    if ["version", "--version", "-v"].contains(command) && args.positional.isEmpty { print(Blktxt.version); return }
    if command == "open" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", Paths.bundleIdentifier]
        try process.run()
        process.waitUntilExit()
        return
    }
    if command == "mcp-config" {
        printJSON(["mcpServers": ["blktxt": ["command": executablePath(), "args": ["mcp"]]]])
        return
    }

    let store = try Store()
    let service = AgentService(store: store, link: AppLink(database: store.url), agentName: "cli")

    switch command {
    case "mcp":
        MCPServer(service: service, version: Blktxt.version).run()

    case "list", "ls":
        let notes = try service.listNotes(limit: args.count(default: 20))
        if args.json { printJSON(notes.map(AgentJSON.summary)); return }
        notes.forEach { print(line(for: $0)) }

    case "cat", "read":
        let note = try service.readNote(id: try noteID(args.positional.first))
        if args.json { printJSON(AgentJSON.note(note)); return }
        print(note.text, terminator: note.text.hasSuffix("\n") ? "" : "\n")

    case "search", "find":
        guard let query = args.positional.first else { throw CLIError(description: "Usage: blktxt search QUERY") }
        let hits = try service.search(FindQuery(query, options: args.findOptions), limit: args.count(default: 20))
        if args.json { printJSON(hits.map(AgentJSON.hit)); return }
        for hit in hits {
            print(line(for: hit.note) + "  (\(hit.matchCount))")
            print("        " + hit.snippet)
        }

    case "new":
        let id = try service.createNote(text: try inputText(args.positional))
        print(id)

    case "append":
        try report(service.appendToCurrent(text: try inputText(args.positional)))

    case "replace":
        guard args.positional.count == 2 else { throw CLIError(description: "Usage: blktxt replace FIND REPLACE") }
        let result = try service.replace(in: try noteID(args.values["--note"]), find: args.positional[0], with: args.positional[1],
                                         options: args.findOptions, all: !args.flags.contains("--first"),
                                         preserveCase: args.flags.contains("--preserve-case"))
        try report(result)
        print("\(result.replacements ?? 0) replaced")

    case "versions":
        guard let id = try noteID(args.positional.first) else { throw CLIError(description: "Usage: blktxt versions ID") }
        let versions = try service.versions(noteID: id)
        if args.json { printJSON(versions.map(AgentJSON.version)); return }
        for version in versions {
            let by = version.agentName.map { "  by \($0)" } ?? ""
            print("\(String(version.id).leftPadded(to: 6))  \(dateFormatter.string(from: version.createdAt).leftPadded(to: 21))  \("\(version.wordCount) w".leftPadded(to: 9))\(by)")
        }

    case "version":
        guard let raw = args.positional.first, let id = VersionID(raw) else { throw CLIError(description: "Usage: blktxt version ID") }
        let version = try service.readVersion(id: id)
        print(version.text, terminator: version.text.hasSuffix("\n") ? "" : "\n")

    default:
        throw CLIError(description: "Unknown command: \(command)\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("blktxt: \(error)\n".utf8))
    exit(1)
}
