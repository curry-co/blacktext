import Foundation

/// Word counting shared by the editor, the store and the versioning rule.
/// A word is a run of non-whitespace characters.
public enum WordCount {
    public static func isSpace(_ unit: unichar) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    public static func count(_ text: String) -> Int {
        var words = 0
        var inWord = false
        for unit in text.utf16 {
            if isSpace(unit) {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return words
    }

    /// Number of words that begin inside `range` of `text`, given the character just before it.
    /// Typing "hello world" one key at a time counts 2; deleting it counts 2.
    public static func wordStarts(in text: NSString, range: NSRange, precededBy previous: unichar?) -> Int {
        guard range.length > 0 else { return 0 }
        var buffer = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&buffer, range: range)
        return wordStarts(in: buffer, precededBy: previous)
    }

    public static func wordStarts(in units: [unichar], precededBy previous: unichar?) -> Int {
        var words = 0
        var inWord = previous.map { !isSpace($0) } ?? false
        for unit in units {
            if isSpace(unit) {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return words
    }
}

public enum NoteTitle {
    public static let maxLength = 120

    /// The first line that has any non-whitespace in it, trimmed.
    public static func from(_ text: String) -> String {
        var line = Substring("")
        var remainder = Substring(text)
        while !remainder.isEmpty {
            if let newline = remainder.firstIndex(where: { $0.isNewline }) {
                line = remainder[..<newline]
                remainder = remainder[remainder.index(after: newline)...]
            } else {
                line = remainder
                remainder = ""
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(maxLength)) }
        }
        return ""
    }
}

/// Decides when the editor saves a version: after about 100 words have been typed or deleted.
/// Counting words changed (not net words) means rewriting a paragraph in place still makes versions.
public struct VersionPolicy: Sendable {
    public static let wordThreshold = 100

    public private(set) var wordsChanged = 0
    /// True once anything changed since the last version.
    public private(set) var hasChanges = false

    public init() {}

    public var isDue: Bool { wordsChanged >= Self.wordThreshold }

    /// Records an edit that replaces `range` of `text` (before the edit) with `replacement`.
    public mutating func record(replacing range: NSRange, in text: NSString, with replacement: String) {
        let previous: unichar? = range.location > 0 ? text.character(at: range.location - 1) : nil
        let deleted = WordCount.wordStarts(in: text, range: range, precededBy: previous)
        let inserted = WordCount.wordStarts(in: Array(replacement.utf16), precededBy: previous)
        wordsChanged += deleted + inserted
        if range.length > 0 || !replacement.isEmpty { hasChanges = true }
    }

    public mutating func reset() {
        wordsChanged = 0
        hasChanges = false
    }
}

/// How agent text joins the end of a note.
public enum NoteEdits {
    /// What to insert before `addition` so it starts a new paragraph (or follows directly).
    public static func separator(appendingTo existing: String, newParagraph: Bool) -> String {
        guard newParagraph, !existing.isEmpty else { return "" }
        if existing.hasSuffix("\n\n") { return "" }
        if existing.hasSuffix("\n") { return "\n" }
        return "\n\n"
    }

    public static func appending(_ addition: String, to existing: String, newParagraph: Bool) -> String {
        existing + separator(appendingTo: existing, newParagraph: newParagraph) + addition
    }
}
