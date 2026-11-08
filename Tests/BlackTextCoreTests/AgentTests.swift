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
        #expect(app.holdWhileRunning())
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
        #expect(names == ["list_notes", "read_note", "search", "list_versions", "read_version", "create_note", "append_to_current", "replace_in_note"])
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

    @Test func toolErrorsAreReportedAsToolResults() throws {
        let response = try call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"read_note","arguments":{"id":999}}}"#)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }
}
