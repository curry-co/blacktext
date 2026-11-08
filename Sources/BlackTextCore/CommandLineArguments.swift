import Foundation

/// The `blacktext` command's arguments: words, flags, and options that take a value (`-n COUNT`, `--note ID`).
///
/// Anything it doesn't know is an error rather than a guess: a missing value, an unknown flag, or a note id
/// that isn't one. Everything after `--` is a word, so text can start with a dash.
public struct CommandLineArguments: Equatable {
    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public static let options: Set<String> = ["-n", "--note"]
    public static let flagNames: Set<String> = ["--json", "--case", "--word", "--regex", "--first", "--preserve-case"]

    public var positional: [String] = []
    public var flags: Set<String> = []
    public var values: [String: String] = [:]

    public init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()
        var literal = false
        while let arg = iterator.next() {
            if literal {
                positional.append(arg)
            } else if arg == "--" {
                literal = true
            } else if Self.options.contains(arg) {
                guard let value = iterator.next() else { throw Invalid(description: "\(arg) needs a value.") }
                values[arg] = value
            } else if arg.count > 1, arg.hasPrefix("-") {
                guard Self.flagNames.contains(arg) else {
                    throw Invalid(description: "Unknown option \(arg). To pass text that starts with a dash, put -- before it.")
                }
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }

    public var findOptions: FindOptions {
        FindOptions(matchCase: flags.contains("--case"), wholeWord: flags.contains("--word"), regex: flags.contains("--regex"))
    }

    public var json: Bool { flags.contains("--json") }

    /// `-n COUNT`: a whole number from 1 up.
    public func count(default value: Int) throws -> Int {
        guard let raw = values["-n"] else { return value }
        guard let count = Int(raw), count > 0 else { throw Invalid(description: "-n needs a number from 1 up, not \(raw).") }
        return count
    }

    /// A note id as typed: a number from 1 up, or "current" (nil) for the note open in BlackText.
    public static func noteID(_ string: String?) throws -> NoteID? {
        guard let string, string != "current" else { return nil }
        guard let id = NoteID(string), id > 0 else { throw Invalid(description: "Not a note id: \(string)") }
        return id
    }
}
