import BlackTextCore
import Foundation

let usage = """
blacktext — the command line for BlackText. One page, plain text, nothing added.

Usage:
  blacktext list [-n COUNT]                 Recent notes, most recently edited first
  blacktext cat [ID]                        Print a note (default: the one open in BlackText)
  blacktext search QUERY [-n COUNT] [--case] [--word] [--regex]
  blacktext new [TEXT…]                     New note from TEXT, or from stdin
  blacktext append [TEXT…]                  Append to the open note (TEXT or stdin)
  blacktext replace FIND REPLACE [--note ID] [--first] [--case] [--word] [--regex] [--preserve-case]
  blacktext versions ID                     A note's saved versions
  blacktext version ID                      Print one version
  blacktext status REQUEST                  What became of an edit that was still queued
  blacktext open                            Open BlackText
  blacktext mcp                             Run the MCP server on stdio, for AI agents
  blacktext mcp-config                      Print the MCP config to paste into an agent app

Add --json to list, cat, search and versions for machine-readable output.
Put -- before text that starts with a dash: blacktext append -- "-30 degrees"

"""

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
    try CommandLineArguments.noteID(string)
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

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func report(_ result: AgentResult) throws {
    guard result.ok else { throw CLIError(description: result.error ?? "The edit failed.") }
    if result.queued == true {
        let ask = result.request.map { " To see what became of it: blacktext status \($0)" } ?? ""
        warn("BlackText hasn't applied the edit yet; it will when it can.\(ask)")
    }
}

func run() throws {
    var raw = Array(CommandLine.arguments.dropFirst())
    guard !raw.isEmpty else { print(usage, terminator: ""); return }
    let command = raw.removeFirst()
    let args = try CommandLineArguments(raw)

    if ["help", "-h", "--help"].contains(command) { print(usage, terminator: ""); return }
    if ["version", "--version", "-v"].contains(command) && args.positional.isEmpty { print(BlackText.version); return }
    if command == "open" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", Paths.bundleIdentifier]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError(description: "Couldn't open BlackText.") }
        return
    }
    if command == "mcp-config" {
        printJSON(["mcpServers": ["blacktext": ["command": executablePath(), "args": ["mcp"]]]])
        return
    }

    let store = try Store()
    let service = AgentService(store: store, link: AppLink(database: store.url), agentName: "cli")

    switch command {
    case "mcp":
        MCPServer(service: service, version: BlackText.version).run()

    case "list", "ls":
        let notes = try service.listNotes(limit: try args.count(default: 20))
        if args.json { printJSON(notes.map(AgentJSON.summary)); return }
        notes.forEach { print(line(for: $0)) }

    case "cat", "read":
        let read = try service.read(id: try noteID(args.positional.first))
        let note = read.note
        if !read.isCurrent { warn("BlackText didn't confirm it had saved the open note; the last few seconds of typing may be missing.") }
        if args.json { printJSON(AgentJSON.note(note)); return }
        print(note.text, terminator: note.text.hasSuffix("\n") ? "" : "\n")

    case "search", "find":
        guard let query = args.positional.first else { throw CLIError(description: "Usage: blacktext search QUERY") }
        let hits = try service.search(FindQuery(query, options: args.findOptions), limit: try args.count(default: 20))
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
        guard args.positional.count == 2 else { throw CLIError(description: "Usage: blacktext replace FIND REPLACE") }
        let result = try service.replace(in: try noteID(args.values["--note"]), find: args.positional[0], with: args.positional[1],
                                         options: args.findOptions, all: !args.flags.contains("--first"),
                                         preserveCase: args.flags.contains("--preserve-case"))
        try report(result)
        print("\(result.replacements ?? 0) replaced")

    case "versions":
        guard let id = try noteID(args.positional.first) else { throw CLIError(description: "Usage: blacktext versions ID") }
        let versions = try service.versions(noteID: id)
        if args.json { printJSON(versions.map(AgentJSON.version)); return }
        for version in versions {
            let by = version.origin.map { "  \($0)" } ?? ""
            print("\(String(version.id).leftPadded(to: 6))  \(dateFormatter.string(from: version.createdAt).leftPadded(to: 21))  \("\(version.wordCount) w".leftPadded(to: 9))\(by)")
        }

    case "status":
        guard let raw = args.positional.first, let request = Int64(raw), request > 0 else {
            throw CLIError(description: "Usage: blacktext status REQUEST")
        }
        guard let result = try service.status(request: request) else { print("queued"); return }
        if args.json { printJSON(AgentJSON.result(result)); return }
        guard result.ok else { throw CLIError(description: result.error ?? "The edit failed.") }
        print(result.replacements.map { "done, \($0) replaced" } ?? "done")

    case "version":
        guard let raw = args.positional.first, let id = VersionID(raw), id > 0 else { throw CLIError(description: "Usage: blacktext version ID") }
        let version = try service.readVersion(id: id)
        print(version.text, terminator: version.text.hasSuffix("\n") ? "" : "\n")

    default:
        throw CLIError(description: "Unknown command: \(command)\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("blacktext: \(error)\n".utf8))
    exit(1)
}
