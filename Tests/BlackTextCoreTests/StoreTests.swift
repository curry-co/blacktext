import Foundation
import Testing
@testable import BlackTextCore

func temporaryDatabase() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("blacktext-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("test.sqlite")
}

@Suite struct StoreTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    @Test func createUpdateAndRead() throws {
        let id = try store.createNote(text: "Hello\nworld")
        var note = try #require(try store.note(id: id))
        #expect(note.title == "Hello")
        #expect(note.wordCount == 2)

        let later = Date().addingTimeInterval(10)
        let summary = try #require(try store.updateText(noteID: id, text: "Goodbye now", date: later))
        #expect(summary.title == "Goodbye now")
        note = try #require(try store.note(id: id))
        #expect(note.text == "Goodbye now")
        #expect(abs(note.updatedAt.timeIntervalSince(later)) < 0.001)
    }

    @Test func unchangedTextIsNotRewritten() throws {
        let id = try store.createNote(text: "same")
        #expect(try store.updateText(noteID: id, text: "same") == nil)
    }

    @Test func notesAreOrderedByLastEditAndPaged() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [NoteID] = []
        for i in 0..<25 { ids.append(try store.createNote(text: "note \(i)", date: base.addingTimeInterval(Double(i)))) }
        // Editing the oldest note moves it to the top.
        try store.updateText(noteID: ids[0], text: "note 0, edited", date: base.addingTimeInterval(100))

        let first = try store.notes(limit: 10)
        #expect(first.map(\.id).first == ids[0])
        #expect(first.count == 10)
        let second = try store.notes(limit: 10, after: NoteCursor(after: first.last!))
        let third = try store.notes(limit: 10, after: NoteCursor(after: second.last!))
        let all = first + second + third
        #expect(all.count == 25)
        #expect(Set(all.map(\.id)).count == 25)
        #expect(try store.notes(limit: 5, offset: 1).first?.id == ids[24])
    }

    @Test func versionsAreCompressedAndDeduplicated() throws {
        let id = try store.createNote()
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let v1 = try store.addVersion(noteID: id, text: long)
        #expect(v1 != nil)
        #expect(try store.addVersion(noteID: id, text: long) == nil)
        #expect(try store.addVersion(noteID: id, text: "   ") == nil)
        let v2 = try store.addVersion(noteID: id, text: long + "more", source: "agent:claude-code")
        let versions = try store.versions(noteID: id)
        #expect(versions.map(\.id) == [v2!, v1!])
        #expect(versions.first?.agentName == "claude-code")
        #expect(try store.version(id: v1!)?.text == long)
        #expect(try store.summary(id: id)?.versionCount == 2)
    }

    /// Restoring a version that can't be read must fail, not hand back empty text to restore.
    @Test func aVersionThatDoesNotDecodeIsAnError() throws {
        let id = try store.createNote(text: "draft")
        let version = try #require(try store.addVersion(noteID: id, text: "draft"))
        try store.db.run("UPDATE versions SET compressed = 1, body = x'01020304' WHERE id = ?", .int(version))
        #expect(throws: (any Error).self) { try store.version(id: version) }
        try store.db.run("UPDATE versions SET compressed = 0, body = x'61ff62' WHERE id = ?", .int(version))
        #expect(throws: (any Error).self) { try store.version(id: version) }

        // An unreadable latest version doesn't stop the next one being saved.
        #expect(try store.addVersion(noteID: id, text: "draft") != nil)
    }

    @Test func compressionRefusesBytesItDidNotWrite() throws {
        let long = String(repeating: "black coffee ", count: 100)
        let packed = Compression.pack(long)
        #expect(packed.compressed)
        #expect(try Compression.unpack(packed.data, compressed: true) == long)
        #expect(try Compression.unpack(Data("plain".utf8), compressed: false) == "plain")
        #expect(throws: (any Error).self) { try Compression.unpack(Data([0x01, 0x02, 0x03]), compressed: true) }
        #expect(throws: (any Error).self) { try Compression.unpack(Data([0xFF]), compressed: false) }
    }

    @Test func deleteMovesToRecentlyDeletedAndPurges() throws {
        let keep = try store.createNote(text: "keep")
        let gone = try store.createNote(text: "gone")
        try store.addVersion(noteID: gone, text: "gone")
        try store.softDelete(noteID: gone, date: Date().addingTimeInterval(-40 * 86_400))
        #expect(try store.notes(limit: 10).map(\.id) == [keep])
        #expect(try store.deletedNotes().map(\.id) == [gone])
        #expect(try store.search(FindQuery("gone")).isEmpty)

        try store.putBack(noteID: gone)
        #expect(try store.notes(limit: 10).count == 2)

        try store.softDelete(noteID: gone, date: Date().addingTimeInterval(-40 * 86_400))
        #expect(try store.purgeDeleted(before: Date().addingTimeInterval(-30 * 86_400)) == 1)
        #expect(try store.note(id: gone) == nil)
        #expect(try store.versions(noteID: gone).isEmpty)
    }

    @Test func searchUsesTheIndexAndExactOptions() throws {
        let a = try store.createNote(text: "Black coffee, nothing added.", date: Date(timeIntervalSince1970: 100))
        let b = try store.createNote(text: "coffeehouse notes\nand more COFFEE", date: Date(timeIntervalSince1970: 200))
        _ = try store.createNote(text: "tea only", date: Date(timeIntervalSince1970: 300))

        let hits = try store.search(FindQuery("coffee"))
        #expect(hits.map(\.note.id) == [b, a])
        #expect(hits.first?.matchCount == 2)

        #expect(try store.search(FindQuery("coffee", options: FindOptions(wholeWord: true))).map(\.note.id) == [b, a])
        #expect(try store.search(FindQuery("COFFEE", options: FindOptions(matchCase: true))).map(\.note.id) == [b])
        #expect(try store.search(FindQuery("ffee")).count == 2)
        #expect(try store.search(FindQuery("ad")).map(\.note.id) == [a])
        #expect(try store.search(FindQuery("co+f", options: FindOptions(regex: true))).count == 2)

        // Edits are reindexed.
        try store.updateText(noteID: a, text: "Black tea")
        #expect(try store.search(FindQuery("coffee")).map(\.note.id) == [b])
    }

    @Test func searchSnippetMarksMatches() throws {
        let prefix = String(repeating: "lorem ipsum ", count: 20)
        _ = try store.createNote(text: prefix + "the coffee\nis hot")
        let hit = try #require(try store.search(FindQuery("coffee")).first)
        #expect(hit.snippet.hasPrefix("…"))
        #expect(!hit.snippet.contains("\n"))
        let marked = (hit.snippet as NSString).substring(with: try #require(hit.snippetMatches.first))
        #expect(marked == "coffee")
    }

    @Test func searchWithQuotesAndSymbols() throws {
        _ = try store.createNote(text: #"She said "hi" and left (quickly)."#)
        #expect(try store.search(FindQuery(#""hi""#)).count == 1)
        #expect(try store.search(FindQuery("(quickly)")).count == 1)
        #expect(try store.search(FindQuery("100%")).isEmpty)
    }

    @Test func stateAndCurrentNote() throws {
        #expect(store.currentNoteID == nil)
        store.currentNoteID = 42
        #expect(store.currentNoteID == 42)
        store.currentNoteID = nil
        #expect(store.currentNoteID == nil)
        #expect(store.agentsCanEdit)
        store.agentsCanEdit = false
        #expect(!store.agentsCanEdit)
    }

    @Test func twoConnectionsShareOneFile() throws {
        let other = try Store(url: store.url)
        let id = try store.createNote(text: "from one")
        #expect(try other.note(id: id)?.text == "from one")
    }
}

@Suite struct SearchPassTests {
    @Test func olderNotesAreFoundThroughTheIndexes() throws {
        let store = try Store(url: temporaryDatabase())
        let base = Date(timeIntervalSince1970: 1_000_000)
        let old = try store.createNote(text: "an old note about art and coffee", date: base)
        for i in 0..<20 { _ = try store.createNote(text: "start part heart \(i)", date: base.addingTimeInterval(Double(i + 1))) }
        // A tiny scan budget forces pass 2 after the first note.
        #expect(try store.search(FindQuery("coffee"), scanBudget: 1).map(\.note.id) == [old])
        #expect(try store.search(FindQuery("art", options: FindOptions(wholeWord: true)), scanBudget: 1).map(\.note.id) == [old])
        #expect(try store.search(FindQuery("art"), scanBudget: 1).count == 21)
        #expect(try store.search(FindQuery("co+f", options: FindOptions(regex: true)), scanBudget: 1).map(\.note.id) == [old])
        #expect(try store.search(FindQuery("an"), scanBudget: 1).map(\.note.id) == [old])
    }

    @Test func wordPhrase() {
        #expect(Store.wordPhrase(for: FindQuery("art", options: FindOptions(wholeWord: true))) == "\"art\"")
        #expect(Store.wordPhrase(for: FindQuery("c++", options: FindOptions(wholeWord: true))) == "\"c\"")
        #expect(Store.wordPhrase(for: FindQuery("++", options: FindOptions(wholeWord: true))) == nil)
        #expect(Store.wordPhrase(for: FindQuery("art")) == nil)
    }
}
