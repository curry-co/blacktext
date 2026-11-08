import Foundation
import Testing
@testable import BlackTextCore

/// Searching all notes must give the same answers as searching each note, whichever index serves it.
@Suite struct SearchCorrectnessTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    /// Notes older than the newest few are found through an index; a scan budget of 1 sends everything
    /// after the newest note there.
    func search(_ text: String, _ options: FindOptions = FindOptions(), limit: Int = 100) throws -> [NoteID] {
        try store.search(FindQuery(text, options: options), limit: limit, scanBudget: 1).map(\.note.id)
    }

    func note(_ text: String, edited: TimeInterval) throws -> NoteID {
        let id = try store.createNote(text: text, date: Date(timeIntervalSince1970: edited))
        try store.updateText(noteID: id, text: text + " ", date: Date(timeIntervalSince1970: edited))
        return id
    }

    @Test func olderMatchesComeInEditOrderEvenWhenCreatedInAnother() throws {
        let editedLater = try note("coffee, the older note", edited: 300)
        _ = try note("coffee, created after it", edited: 200)
        _ = try note("the newest note", edited: 400)
        #expect(try search("coffee", limit: 1) == [editedLater])
        #expect(try search("coffee", FindOptions(wholeWord: true), limit: 1) == [editedLater])
    }

    @Test func theIndexFindsWhatTheNoteItselfWouldFind() throws {
        let german = try note("Die Straße ist lang", edited: 100)
        let shouting = try note("THE STRASSE", edited: 200)
        let ligature = try note("the ﬁrst draft", edited: 250)
        let kelvin = try note("273 \u{212A}", edited: 300)
        _ = try note("the newest note", edited: 400)

        for id in [german, shouting] {
            let text = try #require(try store.note(id: id)?.text) as NSString
            #expect(!(try FindEngine.matches(of: FindQuery("strasse"), in: text)).isEmpty, "in-note search matches")
        }
        #expect(Set(try search("strasse")) == [german, shouting])
        #expect(Set(try search("straße")) == [german, shouting])
        #expect(Set(try search("strasse", FindOptions(wholeWord: true))) == [german, shouting])
        if !(try FindEngine.matches(of: FindQuery("first"), in: "the ﬁrst draft")).isEmpty {
            #expect(try search("first") == [ligature])
        }
        #expect(try search("k") == [kelvin], "a one-letter search, through the LIKE path")
    }

    @Test func wholeWordsEndAtAnEmojiTheSameWayWithOrWithoutRegex() throws {
        let text = "a cat🙂 and a dog" as NSString
        let literal = try FindEngine.matches(of: FindQuery("cat", options: FindOptions(wholeWord: true)), in: text)
        let regex = try FindEngine.matches(of: FindQuery("cat", options: FindOptions(wholeWord: true, regex: true)), in: text)
        #expect(literal.count == 1)
        #expect(literal == regex)
        // A combining mark belongs to the letter before it: "cafe" isn't a whole word in "café" spelled with one.
        let decomposed = "the cafe\u{301} downstairs" as NSString
        #expect(try FindEngine.matches(of: FindQuery("cafe", options: FindOptions(wholeWord: true)), in: decomposed).isEmpty)
        #expect(try FindEngine.matches(of: FindQuery("cafe", options: FindOptions(wholeWord: true, regex: true)), in: decomposed).isEmpty)
    }

    @Test func cancellingStopsPromptlyAfterTheFirstMatch() throws {
        let text = String(repeating: "a ", count: 5_000) as NSString
        for options in [FindOptions(), FindOptions(regex: true)] {
            var asked = 0
            let found = try FindEngine.matches(of: FindQuery("a", options: options), in: text, isCancelled: {
                asked += 1
                return asked > 1
            })
            #expect(found.count < 10, "\(options)")
        }
    }

    @Test func replaceAllReplacesEveryMatch() throws {
        let text = String(repeating: "x", count: 500_001)
        let result = try FindEngine.replaceAll(in: text, query: FindQuery("x"), template: "y")
        #expect(result.count == 500_001)
        #expect(!result.text.contains("x"))
    }

    @Test func aCappedMatchCountSaysSo() throws {
        let id = try store.createNote(text: String(repeating: "a ", count: 10_001))
        let hit = try #require(try store.search(FindQuery("a")).first { $0.note.id == id })
        #expect(hit.matchCount == 10_000)
        #expect(hit.isCountCapped)
    }
}
