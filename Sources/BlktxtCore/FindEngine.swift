import Foundation

public struct FindOptions: Equatable, Hashable, Sendable {
    public var matchCase = false
    public var wholeWord = false
    public var regex = false

    public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public struct FindQuery: Equatable, Hashable, Sendable {
    public var text: String
    public var options: FindOptions

    public init(_ text: String, options: FindOptions = FindOptions()) {
        self.text = text
        self.options = options
    }

    public var isEmpty: Bool { text.isEmpty }
}

public enum FindError: Error, Equatable {
    case invalidPattern
}

/// Find and replace over UTF-16 ranges, so results map directly onto NSTextView.
public enum FindEngine {
    /// Letters, digits and underscore count as word characters for "whole word".
    private static let wordBefore = "(?<![\\p{L}\\p{N}_])"
    private static let wordAfter = "(?![\\p{L}\\p{N}_])"

    /// A compiled matcher for regex queries; nil for plain text, which uses a faster literal scan.
    public static func regex(for query: FindQuery) throws -> NSRegularExpression? {
        let options = query.options
        guard options.regex else { return nil }
        var pattern = query.text
        if options.wholeWord { pattern = wordBefore + "(?:" + pattern + ")" + wordAfter }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.matchCase { flags.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw FindError.invalidPattern
        }
    }

    /// Every match of `query` in `text`, in order. Zero-length regex matches are skipped.
    public static func matches(of query: FindQuery, in text: NSString, limit: Int = 500_000,
                               isCancelled: () -> Bool = { false }) throws -> [NSRange] {
        guard !query.isEmpty, text.length > 0 else { return [] }
        var results: [NSRange] = []
        let whole = NSRange(location: 0, length: text.length)

        if let regex = try regex(for: query) {
            regex.enumerateMatches(in: text as String, options: [.reportProgress], range: whole) { match, _, stop in
                if let range = match?.range, range.length > 0 {
                    results.append(range)
                    if results.count >= limit { stop.pointee = true }
                }
                if results.count % 512 == 0, isCancelled() { stop.pointee = true }
            }
            return results
        }

        var compare: NSString.CompareOptions = [.literal]
        if !query.options.matchCase { compare.insert(.caseInsensitive) }
        let wholeWord = query.options.wholeWord
        var searchRange = whole
        var scanned = 0
        while searchRange.length > 0 {
            let found = text.range(of: query.text, options: compare, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            var next = found.location + found.length
            if !wholeWord || isWholeWord(found, in: text) {
                results.append(found)
                if results.count >= limit { break }
            } else {
                next = found.location + 1
            }
            scanned += 1
            if scanned % 512 == 0, isCancelled() { break }
            searchRange = NSRange(location: next, length: whole.length - next)
        }
        return results
    }

    /// Letters, digits and underscore are word characters; a whole word has neither on either side.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        func isWordCharacter(_ unit: unichar) -> Bool {
            if unit == 0x5F { return true }
            guard let scalar = UnicodeScalar(unit) else { return true } // half of a surrogate pair: a letter, not a boundary
            return CharacterSet.alphanumerics.contains(scalar)
        }
        if range.location > 0, isWordCharacter(text.character(at: range.location - 1)) { return false }
        let end = NSMaxRange(range)
        if end < text.length, isWordCharacter(text.character(at: end)) { return false }
        return true
    }

    /// The text that replaces the match at `range`.
    /// For regex queries, `template` may use `$1`-style groups; otherwise it is literal.
    public static func replacement(for range: NSRange, in text: NSString, query: FindQuery,
                                   template: String, preserveCase: Bool,
                                   regex: NSRegularExpression?) -> String {
        var result = template
        if query.options.regex, let regex,
           let match = regex.firstMatch(in: text as String, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range) {
            result = regex.replacementString(for: match, in: text as String, offset: 0, template: template)
        }
        if preserveCase { result = applyCase(of: text.substring(with: range), to: result) }
        return result
    }

    /// Replaces every match. Returns the new text and how many matches were replaced.
    public static func replaceAll(in text: String, query: FindQuery, template: String,
                                  preserveCase: Bool = false) throws -> (text: String, count: Int) {
        let source = text as NSString
        let ranges = try matches(of: query, in: source)
        guard !ranges.isEmpty else { return (text, 0) }
        let regex = try regex(for: query)
        let output = NSMutableString(string: source)
        for range in ranges.reversed() {
            let piece = replacement(for: range, in: source, query: query, template: template,
                                    preserveCase: preserveCase, regex: regex)
            output.replaceCharacters(in: range, with: piece)
        }
        return (output as String, ranges.count)
    }

    /// Replaces only the first match.
    public static func replaceFirst(in text: String, query: FindQuery, template: String,
                                    preserveCase: Bool = false) throws -> (text: String, count: Int) {
        let source = text as NSString
        guard let range = try matches(of: query, in: source, limit: 1).first else { return (text, 0) }
        let piece = replacement(for: range, in: source, query: query, template: template,
                                preserveCase: preserveCase, regex: try regex(for: query))
        return (source.replacingCharacters(in: range, with: piece), 1)
    }

    /// Gives `replacement` the capitalization pattern of `source`:
    /// COFFEE → TEA, Coffee → Tea, coffee → tea. Mixed case leaves the replacement as typed.
    public static func applyCase(of source: String, to replacement: String) -> String {
        let letters = source.filter(\.isLetter)
        guard let first = letters.first else { return replacement }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        if letters.allSatisfy(\.isLowercase) { return replacement.lowercased() }
        if first.isUppercase, letters.dropFirst().allSatisfy(\.isLowercase) {
            guard let head = replacement.first else { return replacement }
            return head.uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
