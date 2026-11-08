import Foundation
import Testing
@testable import BlackTextCore

@Suite struct AgentTests {
    let store: Store
    let service: AgentService

    init() throws {
        store = try Store(url: temporaryDatabase())
        service = AgentService(store: store, link: AppLink(database: store.url), agentName: "test-agent")
    }

    @Test func appendToCurrentKeepsVersionsBeforeAndAfter() throws {
        let id = try store.createNote(text: "Draft")
        store.currentNoteID = id
        let result = try service.appendToCurrent(text: "Added by agent")
        #expect(result.ok)
        #expect(try store.note(id: id)?.text == "Draft\n\nAdded by agent")
        let versions = try store.versions(noteID: id)
        #expect(versions.count == 2)
        #expect(versions[0].source == "agent:test-agent")
        #expect(versions[1].source == "user")
        #expect(try store.version(id: versions[1].id)?.text == "Draft")
    }

    @Test func appendWithBlankCanvasCreatesTheCurrentNote() throws {
        let result = try service.appendToCurrent(text: "Fresh")
        let id = try #require(result.noteID)
        #expect(store.currentNoteID == id)
        #expect(try store.note(id: id)?.text == "Fresh")
    }

    @Test func replaceInNote() throws {
        let id = try store.createNote(text: "black coffee, Coffee")
        let result = try service.replace(in: id, find: "coffee", with: "tea", options: FindOptions(), preserveCase: true)
        #expect(result.replacements == 2)
        #expect(try store.note(id: id)?.text == "black tea, Tea")

        let none = try service.replace(in: id, find: "milk", with: "x", options: FindOptions())
        #expect(none.replacements == 0)
        #expect(try store.versions(noteID: id).count == 2)
    }

    @Test func readOnlyRefusesEdits() throws {
        store.agentsCanEdit = false
        #expect(throws: AgentError.self) { try service.createNote(text: "nope") }
        #expect(throws: AgentError.self) { try service.appendToCurrent(text: "nope") }
        #expect(try store.noteCount() == 0)
    }

    @Test func editsToDeletedNotesFail() throws {
        let id = try store.createNote(text: "x")
        try store.softDelete(noteID: id)
        let result = try service.replace(in: id, find: "x", with: "y", options: FindOptions())
        #expect(!result.ok)
    }

    @Test func runningAppReceivesEditsThroughTheInbox() throws {
        let app = AppLink(database: store.url)
        #expect(try app.holdWhileRunning())
        #expect(service.link.isAppRunning)
        // Generous, because tests run in parallel and shared CI runners are slow. A passing run
        // returns as soon as the app answers, so this only lengthens a failing one.
        service.appTimeout = 10

        // Pretend to be the app: answer queued ops from another thread, for as long as the service waits.
        let appStore = try Store(url: store.url)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<1_000 {
                if let op = try? appStore.pendingOps().first {
                    let result = (try? appStore.applyDirectly(op)) ?? .failure("failed")
                    try? appStore.complete(opID: op.id, result: result)
                    done.signal()
                    return
                }
                usleep(10_000)
            }
            done.signal()
        }
        let id = try store.createNote(text: "Live")
        store.currentNoteID = id
        let result = try service.appendToCurrent(text: "via app")
        done.wait()
        #expect(result.ok)
        #expect(result.queued == nil)
        #expect(try store.note(id: id)?.text == "Live\n\nvia app")
        _ = app
    }
}

@Suite struct MCPTests {
    let server: MCPServer
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
        server = MCPServer(service: AgentService(store: store, link: AppLink(database: store.url)), version: "test")
    }

    func call(_ json: String) throws -> [String: Any] {
        let line = try #require(server.handle(line: json))
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func toolText(_ response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @Test func initializeNegotiatesVersionAndNamesTheAgent() throws {
        let response = try call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Claude Code","version":"2"}}}"#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(server.service.source == "agent:claude-code")
    }

    @Test func notificationsGetNoResponse() {
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func unknownMethodIsAnError() throws {
        let response = try call(#"{"jsonrpc":"2.0","id":"x","method":"nope"}"#)
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(response["id"] as? String == "x")
    }

    @Test func listsTools() throws {
        let response = try call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try #require((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["list_notes", "read_note", "search", "list_versions", "read_version", "create_note", "append_to_current",
                          "replace_in_note", "edit_status"])
    }

    @Test func createSearchAndRead() throws {
        let created = try call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_note","arguments":{"text":"Black like my coffee"}}}"#)
        #expect(toolText(created).contains("\"id\""))

        let search = try call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search","arguments":{"query":"coffee"}}}"#)
        #expect(toolText(search).contains("Black like my coffee"))

        let id = try #require(try store.notes(limit: 1).first?.id)
        let read = try call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_note","arguments":{"id":\#(id)}}}"#)
        #expect(toolText(read).contains("Black like my coffee"))
    }

    func isError(_ response: [String: Any]) -> Bool {
        (response["result"] as? [String: Any])?["isError"] as? Bool == true
    }

    /// A value of the wrong type is an error, never read as "not given", which for a note means the open one.
    @Test func argumentsOfTheWrongTypeAreRejected() throws {
        let first = try store.createNote(text: "first")
        let open = try store.createNote(text: "the open note")
        store.currentNoteID = open
        for arguments in [#"{"id":"\#(first)"}"#, #"{"id":true}"#, #"{"id":1.5}"#, #"{"id":0}"#, #"{"id":-1}"#, #"{"note":1}"#] {
            let response = try call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_note","arguments":\#(arguments)}}"#)
            #expect(isError(response), "read_note \(arguments)")
            #expect(!toolText(response).contains("the open note"), "read_note \(arguments)")
        }
        let replace = try call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"replace_in_note","arguments":{"note_id":true,"find":"first","replace":"x"}}}"#)
        #expect(isError(replace))
        #expect(try store.note(id: first)?.text == "first")
        let flag = try call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"search","arguments":{"query":"first","regex":"yes"}}}"#)
        #expect(isError(flag))
    }

    @Test func malformedRequestsAreRejected() throws {
        for line in [#"{"id":1,"method":"ping"}"#, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#] {
            let response = try call(line)
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32600, "\(line)")
        }
        let params = try call(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]}"#)
        #expect((params["error"] as? [String: Any])?["code"] as? Int == -32602)
        // String request ids are fine.
        #expect(try call(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)["result"] != nil)
    }

    @Test func toolErrorsAreReportedAsToolResults() throws {
        let response = try call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"read_note","arguments":{"id":999}}}"#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }
}

@Suite struct AgentTargetingTests {
    let store: Store

    init() throws {
        store = try Store(url: temporaryDatabase())
    }

    func append(_ text: String, to noteID: NoteID? = nil) -> AgentOp {
        AgentOp(noteID: noteID, edit: .append(text: text, newParagraph: true), source: "agent:test")
    }

    /// Asked for while one note was open, applied after the user moved to another: it lands in the first.
    @Test func aQueuedEditLandsOnTheNoteItWasAimedAt() throws {
        let first = try store.createNote(text: "first")
        let second = try store.createNote(text: "second")
        store.currentNoteID = first
        let op = try store.pin(append("added"))
        store.currentNoteID = second
        #expect(try store.applyDirectly(op).ok)
        #expect(try store.note(id: first)?.text == "first\n\nadded")
        #expect(try store.note(id: second)?.text == "second")
    }

    /// The note was removed and its id reused by a new one before the edit was applied.
    @Test func aQueuedEditDoesNotLandOnANoteThatReusedTheId() throws {
        let gone = try store.createNote(text: "gone")
        let op = try store.pin(append("added", to: gone))
        try store.hardDelete(noteID: gone)
        let reused = try store.createNote(text: "someone else")
        #expect(reused == gone)
        #expect(!(try store.applyDirectly(op).ok))
        #expect(try store.note(id: reused)?.text == "someone else")
    }

    @Test func anEditAimedAtABlankCanvasMakesANewNote() throws {
        let op = try store.pin(append("fresh"))
        let other = try store.createNote(text: "opened since")
        store.currentNoteID = other
        let result = try store.applyDirectly(op)
        let id = try #require(result.noteID)
        #expect(id != other)
        #expect(try store.note(id: id)?.text == "fresh")
        #expect(try store.note(id: other)?.text == "opened since")
    }

    @Test func aQueuedEditIsRecordedAsDoneWithTheEdit() throws {
        let id = try store.createNote(text: "black coffee")
        var op = AgentOp(noteID: id, edit: .replace(find: "coffee", replacement: "tea", options: FindOptions(), all: true, preserveCase: false),
                         source: "agent:test")
        op = try store.pin(op)
        op.id = try store.enqueue(op)
        let pending = try #require(try store.pendingOps().first)
        #expect(pending.pinned)
        #expect(pending.targetUID == op.targetUID)
        #expect(try store.applyDirectly(pending).replacements == 1)
        #expect(try store.result(opID: op.id)?.replacements == 1)
        #expect(try store.pendingOps().isEmpty)
    }

    @Test func anEditWorkedOutFromAnOldReadIsRefused() throws {
        let id = try store.createNote(text: "old")
        try store.updateText(noteID: id, text: "newer, from elsewhere")
        #expect(throws: StoreError.conflict(id)) {
            try store.commitEdit(noteID: id, expected: "old", text: "old, edited", source: "agent:test")
        }
        #expect(try store.note(id: id)?.text == "newer, from elsewhere")
        #expect(try store.versions(noteID: id).isEmpty)
    }

    @Test func eachLibraryHasItsOwnChangeNotification() {
        let one = temporaryDatabase()
        #expect(AppLink(database: one).changedNotification == AppLink(database: one).changedNotification)
        #expect(AppLink(database: one).changedNotification != AppLink(database: temporaryDatabase()).changedNotification)
    }

    @Test func aQueuedEditGivesARequestToAskAbout() throws {
        let link = AppLink(database: store.url)
        #expect(try link.holdWhileRunning()) // "the app", which never answers
        let service = AgentService(store: store, link: AppLink(database: store.url))
        service.appTimeout = 0.05
        let id = try store.createNote(text: "x")
        store.currentNoteID = id
        let result = try service.appendToCurrent(text: "y")
        #expect(result.queued == true)
        let request = try #require(result.request)
        #expect(try service.status(request: request) == nil)
        try store.complete(opID: request, result: .success(noteID: id))
        #expect(try service.status(request: request)?.ok == true)
        #expect(throws: AgentError.self) { try service.status(request: request + 100) }
        _ = link
    }
}

@Suite struct CommandLineArgumentTests {
    @Test func optionsNeedTheirValues() {
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["FIND", "REPLACE", "--note"]) }
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["-n"]) }
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["-n", "zero"]).count(default: 20) }
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["-n", "0"]).count(default: 20) }
    }

    @Test func unknownFlagsAreErrors() {
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["text", "--frist"]) }
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments(["-30 degrees"]) }
    }

    @Test func textAfterDoubleDashIsText() throws {
        let args = try CommandLineArguments(["--json", "--", "-30 degrees", "--case"])
        #expect(args.positional == ["-30 degrees", "--case"])
        #expect(args.flags == ["--json"])
    }

    @Test func noteIDs() throws {
        #expect(try CommandLineArguments.noteID("12") == 12)
        #expect(try CommandLineArguments.noteID("current") == nil)
        #expect(try CommandLineArguments.noteID(nil) == nil)
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments.noteID("0") }
        #expect(throws: CommandLineArguments.Invalid.self) { try CommandLineArguments.noteID("twelve") }
    }
}
