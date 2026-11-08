import Foundation
import Testing
@testable import BlackTextCore

struct DiskFull: Error, CustomStringConvertible {
    var description: String { "database or disk is full" }
}

/// The canvas's autosave, driven the way an editor drives it: change the text, say so, save.
@MainActor @Suite struct NoteSessionTests {
    final class Canvas { var text = "" }

    let store: Store
    let saveStore: Store
    let session: NoteSession
    let canvas = Canvas()

    init() throws {
        store = try Store(url: temporaryDatabase())
        saveStore = try Store(url: store.url)
        session = NoteSession(store: store, saveStore: saveStore)
        session.text = { [canvas] in canvas.text }
    }

    func open(_ text: String) throws -> NoteID {
        let id = try store.createNote(text: text)
        session.load(try store.note(id: id))
        canvas.text = text
        return id
    }

    func type(_ text: String) {
        canvas.text = text
        session.textDidChange()
    }

    var recovered: URL { store.url.deletingLastPathComponent().appendingPathComponent("Recovered", isDirectory: true) }

    func recoveryCopies() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    @Test func aFailedSaveStaysUnsavedAndIsRetried() throws {
        let id = try open("first")
        saveStore.injectFault { _ in throw DiskFull() }
        type("first, then more")
        let failed = session.save(wait: true)
        #expect(session.isDirty)
        #expect(try store.note(id: id)?.text == "first")
        #expect(recoveryCopies() == ["first, then more"])
        guard case .failed(let message, let copy?) = failed else {
            Issue.record("expected a failed outcome with a recovery copy, got \(failed)")
            return
        }
        #expect(message.contains("full"))
        #expect(copy.deletingLastPathComponent().lastPathComponent == "Recovered")

        saveStore.injectFault(nil)
        #expect(session.save(wait: true) == .saved)
        #expect(!session.isDirty)
        #expect(try store.note(id: id)?.text == "first, then more")
        #expect(recoveryCopies().isEmpty)
    }

    @Test func waitingWaitsForSavesAlreadyOnTheirWay() throws {
        let id = try open("old")
        saveStore.injectFault { _ in usleep(150_000) }
        type("new")
        session.save()
        session.save(version: .never, wait: true)
        #expect(try store.note(id: id)?.text == "new")
    }

    @Test func anOlderSaveLandingDoesNotCountNewerTypingAsSaved() throws {
        let id = try open("one")
        saveStore.injectFault { _ in usleep(100_000) }
        type("two")
        session.save()
        type("three")
        session.waitForSaves()
        #expect(session.isDirty)
        saveStore.injectFault(nil)
        session.save(wait: true)
        #expect(!session.isDirty)
        #expect(try store.note(id: id)?.text == "three")
    }

    @Test func textAndItsVersionLandTogetherOrNotAtAll() throws {
        let id = try open("draft")
        saveStore.injectFault { sql in if sql.hasPrefix("INSERT INTO versions") { throw DiskFull() } }
        type("draft, finished")
        session.save(version: .always, wait: true)
        #expect(try store.note(id: id)?.text == "draft")
        #expect(session.isDirty)

        saveStore.injectFault(nil)
        session.save(wait: true)
        #expect(try store.note(id: id)?.text == "draft, finished")
        let versions = try store.versions(noteID: id)
        #expect(versions.count == 1)
        let version = try #require(versions.first)
        #expect(try store.version(id: version.id)?.text == "draft, finished")
    }

    @Test func aBlankCanvasThatCannotBecomeANoteKeepsItsText() throws {
        session.load(nil)
        store.injectFault { _ in throw DiskFull() }
        type("first words")
        session.save(wait: true)
        #expect(session.isDirty)
        #expect(recoveryCopies() == ["first words"])

        store.injectFault(nil)
        session.save(wait: true)
        let id = try #require(session.noteID)
        #expect(try store.note(id: id)?.text == "first words")
    }

    @Test func anAgentEditInTheCanvasIsRecordedByTheSaveThatStoresIt() throws {
        let id = try open("draft")
        let op = try store.enqueue(AgentOp(noteID: id, edit: .append(text: "more", newParagraph: true), source: "agent:test"))
        saveStore.injectFault { _ in throw DiskFull() }
        type("draft\n\nmore")
        session.save(version: .always, source: "agent:test", wait: true, completing: (op, .success(noteID: id)))
        // Not stored, so not done: after a crash now, the app would apply it again, to the stored text.
        #expect(try store.result(opID: op) == nil)

        saveStore.injectFault(nil)
        session.save(wait: true)
        #expect(try store.result(opID: op)?.ok == true)
        #expect(try store.note(id: id)?.text == "draft\n\nmore")
        #expect(try store.versions(noteID: id).first?.source == "agent:test")
    }

    @Test func clearingASavedNoteKeepsWhatItSaid() throws {
        let id = try open("a short note")
        type("")
        session.save(wait: true)
        let versions = try store.versions(noteID: id)
        #expect(versions.count == 1)
        #expect(try versions.first.flatMap { try store.version(id: $0.id)?.text } == "a short note")

        // Leaving the now-empty note puts it in Recently Deleted, history and all.
        session.leave()
        session.waitForSaves()
        let note = try #require(try store.note(id: id))
        #expect(note.deletedAt != nil)
        #expect(try store.versions(noteID: id).count == 1)
    }

    @Test func aNoteThatNeverHadAnythingInItIsDiscarded() throws {
        let id = try store.createNote()
        session.load(try store.note(id: id))
        session.leave()
        session.waitForSaves()
        #expect(try store.note(id: id) == nil)
    }

    @Test func typingIntoANoteDeletedElsewhereSavesItAsANewNote() throws {
        let id = try open("kept")
        try store.softDelete(noteID: id) // on another device
        type("kept, and typed after")
        session.save(wait: true)
        #expect(try store.note(id: id)?.text == "kept")
        let live = try store.notes(limit: 10)
        #expect(live.count == 1)
        let copy = try #require(live.first)
        #expect(copy.id != id)
        #expect(try store.note(id: copy.id)?.text == "kept, and typed after")
        #expect(session.noteID == copy.id)
        #expect(!session.isDirty)
    }

    @Test func savesQueuedBeforeTheFirstLandsMakeOnlyOneNewNote() throws {
        let id = try open("kept")
        try store.softDelete(noteID: id)
        type("typed once")
        session.save()
        type("typed twice")
        session.save()
        session.waitForSaves()
        let live = try store.notes(limit: 10)
        #expect(live.count == 1)
        #expect(try live.first.flatMap { try store.note(id: $0.id)?.text } == "typed twice")
        #expect(session.noteID == live.first?.id)
        #expect(!session.isDirty)
    }

    @Test func typingIntoANoteRemovedElsewhereSavesItAsANewNote() throws {
        let id = try open("gone")
        try store.hardDelete(noteID: id)
        type("gone, but not this")
        session.save(wait: true)
        let live = try store.notes(limit: 10)
        #expect(live.count == 1)
        #expect(try live.first.flatMap { try store.note(id: $0.id)?.text } == "gone, but not this")
    }
}

@Suite struct AgentSafetyTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    @Test func anAgentEditLandsWhollyOrNotAtAll() throws {
        let id = try store.createNote(text: "black coffee")
        var inserts = 0
        store.injectFault { sql in
            guard sql.hasPrefix("INSERT INTO versions") else { return }
            inserts += 1
            if inserts == 2 { throw DiskFull() }
        }
        let op = AgentOp(noteID: id, edit: .replace(find: "coffee", replacement: "tea", options: FindOptions(), all: true, preserveCase: false),
                         source: "agent:test")
        #expect(throws: (any Error).self) { try store.applyDirectly(op) }
        store.injectFault(nil)
        #expect(try store.note(id: id)?.text == "black coffee")
        #expect(try store.versions(noteID: id).isEmpty)
    }

    @Test func agentsCannotEditWhenThePermissionCannotBeRead() throws {
        store.agentsCanEdit = true
        store.injectFault { _ in throw DiskFull() }
        #expect(!store.agentsCanEdit)
    }

    @Test func theAppLockIsTakenOnFirstLaunch() throws {
        let database = temporaryDatabase() // its folder doesn't exist yet
        let link = AppLink(database: database)
        #expect(try link.holdWhileRunning())
    }

    @Test func aLockThatCannotBeOpenedIsNotTakenAsTheAppBeingClosed() throws {
        let database = temporaryDatabase()
        try FileManager.default.createDirectory(at: Paths.lockURL(for: database), withIntermediateDirectories: true)
        var wrote = false
        #expect(throws: (any Error).self) { try AppLink(database: database).ifAppNotRunning { wrote = true } }
        #expect(!wrote)
    }
}
