import Foundation
import Testing
@testable import BlktxtCore

@Suite struct WordCountTests {
    @Test func countsRunsOfNonWhitespace() {
        #expect(WordCount.count("") == 0)
        #expect(WordCount.count("   ") == 0)
        #expect(WordCount.count("hello") == 1)
        #expect(WordCount.count("hello, world") == 2)
        #expect(WordCount.count("  two\n\nlines\there ") == 3)
        #expect(WordCount.count("emoji 🙂 counts") == 3)
    }

    @Test func typingOneKeyAtATimeCountsEachWordOnce() {
        var policy = VersionPolicy()
        let text = NSMutableString()
        for character in "hello world again" {
            let range = NSRange(location: text.length, length: 0)
            policy.record(replacing: range, in: text, with: String(character))
            text.replaceCharacters(in: range, with: String(character))
        }
        #expect(policy.wordsChanged == 3)
    }

    @Test func backspacingCountsDeletedWords() {
        var policy = VersionPolicy()
        let text = NSMutableString(string: "one two three")
        while text.length > 0 {
            let range = NSRange(location: text.length - 1, length: 1)
            policy.record(replacing: range, in: text, with: "")
            text.replaceCharacters(in: range, with: "")
        }
        #expect(policy.wordsChanged == 3)
    }

    @Test func rewritingInPlaceStillReachesTheThreshold() {
        // Net word count never moves, but 100 words were deleted and 100 typed.
        var policy = VersionPolicy()
        let original = Array(repeating: "word", count: 50).joined(separator: " ")
        let text = NSMutableString(string: original)
        policy.record(replacing: NSRange(location: 0, length: text.length), in: text, with: original)
        #expect(policy.wordsChanged == 100)
        #expect(policy.isDue)
        policy.reset()
        #expect(!policy.isDue)
        #expect(!policy.hasChanges)
    }

    @Test func typingInsideAWordIsNotANewWord() {
        var policy = VersionPolicy()
        let text = NSMutableString(string: "hllo")
        policy.record(replacing: NSRange(location: 1, length: 0), in: text, with: "e")
        #expect(policy.wordsChanged == 0)
        #expect(policy.hasChanges)
    }
}

@Suite struct TitleTests {
    @Test func firstNonEmptyLineTrimmed() {
        #expect(NoteTitle.from("") == "")
        #expect(NoteTitle.from("\n\n   \n  Hello there  \nsecond") == "Hello there")
        #expect(NoteTitle.from("one line") == "one line")
        #expect(NoteTitle.from(String(repeating: "a", count: 500)).count == NoteTitle.maxLength)
    }
}

@Suite struct NoteEditsTests {
    @Test func appendStartsANewParagraph() {
        #expect(NoteEdits.appending("b", to: "", newParagraph: true) == "b")
        #expect(NoteEdits.appending("b", to: "a", newParagraph: true) == "a\n\nb")
        #expect(NoteEdits.appending("b", to: "a\n", newParagraph: true) == "a\n\nb")
        #expect(NoteEdits.appending("b", to: "a\n\n", newParagraph: true) == "a\n\nb")
        #expect(NoteEdits.appending(" b", to: "a", newParagraph: false) == "a b")
    }
}

@Suite struct DateBucketTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    @Test func groupsLikeNotes() {
        let now = date("2026-10-28 15:00")
        #expect(DateBucket(date("2026-10-28 00:05"), now: now, calendar: calendar) == .today)
        #expect(DateBucket(date("2026-10-27 23:59"), now: now, calendar: calendar) == .yesterday)
        #expect(DateBucket(date("2026-10-22 09:00"), now: now, calendar: calendar) == .previous7Days)
        #expect(DateBucket(date("2026-10-05 09:00"), now: now, calendar: calendar) == .previous30Days)
        #expect(DateBucket(date("2026-04-12 16:31"), now: now, calendar: calendar) == .month(2026, 4))
        #expect(DateBucket(date("2025-12-31 16:31"), now: now, calendar: calendar) == .year(2025))
        #expect(DateBucket.month(2026, 4).title(calendar: calendar) == "April")
        #expect(DateBucket.year(2025).title(calendar: calendar) == "2025")
    }
}
