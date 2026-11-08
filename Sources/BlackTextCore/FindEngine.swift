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
    /// Letters, digits, combining marks (which belong to the letter before them) and underscore count as
    /// word characters for "whole word", with or without regex.
    private static let wordBefore = "(?<![\\p{L}\\p{M}\\p{N}_])"
    private static let wordAfter = "(?![\\p{L}\\p{M}\\p{N}_])"

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

    /// Every match of `query` in `text`, in order, up to `limit`. Zero-length regex matches are skipped.
    /// `isCancelled` is asked as the search goes, so a cancelled search stops within a match or so.
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
                // Called for each match and, between matches, as the scan goes (.reportProgress).
                if isCancelled() { stop.pointee = true }
            }
            return results
        }

        var compare: NSString.CompareOptions = [.literal]
        if !query.options.matchCase { compare.insert(.caseInsensitive) }
        let wholeWord = query.options.wholeWord
        var searchRange = whole
        while searchRange.length > 0, !isCancelled() {
            let found = text.range(of: query.text, options: compare, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            var next = found.location + found.length
            if !wholeWord || isWholeWord(found, in: text) {
                results.append(found)
                if results.count >= limit { break }
            } else {
                next = found.location + 1
            }
            searchRange = NSRange(location: next, length: whole.length - next)
        }
        return results
    }

    /// A whole word has no word character (see `wordBefore`) on either side. Characters outside the Basic
    /// Multilingual Plane (emoji, many CJK ideographs) are read whole from their surrogate pair.
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0, isWordCharacter(scalar(endingAt: range.location, in: text)) { return false }
        let end = NSMaxRange(range)
        if end < text.length, isWordCharacter(scalar(startingAt: end, in: text)) { return false }
        return true
    }

    static func isWordCharacter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func pair(_ lead: unichar, _ trail: unichar) -> Unicode.Scalar? {
        Unicode.Scalar(0x10000 + (UInt32(lead) - 0xD800) << 10 + (UInt32(trail) - 0xDC00))
    }

    private static func scalar(startingAt index: Int, in text: NSString) -> Unicode.Scalar? {
        let unit = text.character(at: index)
        if UTF16.isLeadSurrogate(unit), index + 1 < text.length {
            let trail = text.character(at: index + 1)
            if UTF16.isTrailSurrogate(trail) { return pair(unit, trail) }
        }
        return Unicode.Scalar(unit)
    }

    private static func scalar(endingAt index: Int, in text: NSString) -> Unicode.Scalar? {
        let unit = text.character(at: index - 1)
        if UTF16.isTrailSurrogate(unit), index >= 2 {
            let lead = text.character(at: index - 2)
            if UTF16.isLeadSurrogate(lead) { return pair(lead, unit) }
        }
        return Unicode.Scalar(unit)
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

    /// Replaces every match, however many there are. Returns the new text and how many were replaced.
    public static func replaceAll(in text: String, query: FindQuery, template: String,
                                  preserveCase: Bool = false) throws -> (text: String, count: Int) {
        let source = text as NSString
        let ranges = try matches(of: query, in: source, limit: .max)
        guard !ranges.isEmpty else { return (text, 0) }
        let regex = try regex(for: query)
        let output = NSMutableString(capacity: source.length)
        var copied = 0
        for range in ranges {
            output.append(source.substring(with: NSRange(location: copied, length: range.location - copied)))
            output.append(replacement(for: range, in: source, query: query, template: template,
                                      preserveCase: preserveCase, regex: regex))
            copied = NSMaxRange(range)
        }
        output.append(source.substring(from: copied))
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

/// Spellings to look a case-insensitive search up by in an index, so the index finds every note the search
/// itself would. Searching folds case fully (Straße matches "strasse", ﬁ matches "fi"), but the indexes fold
/// one character at a time, so a note spelled with ß or a ligature is only found under that spelling.
enum SearchSpellings {
    /// Characters whose full case folding is plain letters.
    static let expansions: [(letters: String, characters: [Character])] = [
        ("ffi", ["\u{FB03}"]), ("ffl", ["\u{FB04}"]), ("ff", ["\u{FB00}"]), ("fi", ["\u{FB01}"]), ("fl", ["\u{FB02}"]),
        ("ss", ["\u{00DF}", "\u{1E9E}"]), ("st", ["\u{FB05}", "\u{FB06}"]),
    ]
    /// One-letter folds that SQLite's indexes handle but LIKE doesn't: the Kelvin sign and the long s.
    static let singles: [Character: [Character]] = ["k": ["\u{212A}"], "s": ["\u{017F}"]]

    /// Every spelling of `text` that a case-insensitive search would match, or nil if there are too many
    /// to look up, or it has cased letters beyond ASCII whose folding the indexes may not share (then the
    /// caller scans instead). `forLike` adds the one-letter folds and both cases of each character.
    static func of(_ text: String, forLike: Bool = false, limit: Int = 48) -> [String]? {
        let folded = text.folding(options: .caseInsensitive, locale: nil)
        let simple = folded.unicodeScalars.allSatisfy { $0.isASCII || (!$0.properties.isCased && !$0.properties.changesWhenCaseFolded) }
        guard simple else { return nil }
        let characters = Array(folded)
        var spellings: [String] = []
        func walk(_ index: Int, _ prefix: String) -> Bool {
            guard index < characters.count else {
                spellings.append(prefix)
                return spellings.count <= limit
            }
            var options: [(piece: String, length: Int)] = [(String(characters[index]), 1)]
            for (letters, replacements) in expansions where index + letters.count <= characters.count
                && String(characters[index..<index + letters.count]) == letters {
                options += replacements.map { (String($0), letters.count) }
            }
            if forLike, let replacements = singles[characters[index]] { options += replacements.map { (String($0), 1) } }
            for option in options where !walk(index + option.length, prefix + option.piece) { return false }
            return true
        }
        return walk(0, "") ? spellings : nil
    }
}
