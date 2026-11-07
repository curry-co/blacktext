import Foundation

// TODO(core): move to BlackTextCore. New on iOS (not in the Mac app yet); the Mac needs the same
// thing for live canvas updates when sync changes the open note.

/// Keeps the cursor in the right place when the open note is replaced by a newer copy of itself.
enum TextDiff {
    /// The span that differs: everything between the longest common prefix and the longest
    /// common suffix, in UTF-16 units, as it is in `old` and in `new`.
    static func changedRanges(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
        let oldLength = old.length
        let newLength = new.length
        var a = [unichar](repeating: 0, count: oldLength)
        var b = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&a, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&b, range: NSRange(location: 0, length: newLength))

        let shorter = min(oldLength, newLength)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[oldLength - 1 - suffix] == b[newLength - 1 - suffix] { suffix += 1 }
        return (NSRange(location: prefix, length: oldLength - suffix - prefix),
                NSRange(location: prefix, length: newLength - suffix - prefix))
    }

    /// Where `range` (a selection in `old`) belongs in `new`. Text before the change keeps its
    /// place, text after it shifts, and a cursor inside the change lands at its end.
    static func map(_ range: NSRange, from old: NSString, to new: NSString) -> NSRange {
        let changed = changedRanges(from: old, to: new)
        func map(_ position: Int) -> Int {
            if position <= changed.old.location { return position }
            if position >= NSMaxRange(changed.old) { return position - changed.old.length + changed.new.length }
            return NSMaxRange(changed.new)
        }
        let start = min(map(range.location), new.length)
        let end = min(max(start, map(NSMaxRange(range))), new.length)
        return NSRange(location: start, length: end - start)
    }
}
