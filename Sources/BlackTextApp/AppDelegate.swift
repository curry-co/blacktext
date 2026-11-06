import AppKit
import BlackTextCore
import notify

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var store: Store!
    private var windowController: MainWindowController!
    private let link = AppLink()
    private var hotKey: HotKey?
    private var notifyToken: Int32 = 0
    private let services = ServiceProvider()
    private var cloudSync: CloudSync?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        Theme.apply()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("did-finish-launching")
        link.holdWhileRunning()
        let stores: (Store, Store, Store)
        do {
            stores = (try Store(), try Store(), try Store())
        } catch {
            let alert = NSAlert()
            alert.messageText = "BlackText couldn't open its notes"
            alert.informativeText = "\(error)\n\n\(Paths.databaseURL.path)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        store = stores.0
        windowController = MainWindowController(store: stores.0, saveStore: stores.1, searchStore: stores.2)
        windowController.start()
        NSApp.activate(ignoringOtherApps: true)
        LaunchTrace.windowShown()

        // Everything below waits until the window is up.
        DispatchQueue.main.async { [weak self] in self?.finishLaunching() }
    }

    private func finishLaunching() {
        // Spell checking loads dictionaries; start it once the window is up.
        windowController.editor.setSpellChecking(Preferences.spellCheck)
        notify_register_dispatch(AppLink.changedNotification, &notifyToken, .main) { [weak self] _ in
            self?.databaseDidChange()
        }
        databaseDidChange()
        hotKey = HotKey.showHide { [weak self] in self?.toggleVisibility() }
        services.open = { [weak self] text in self?.windowController.openNewNote(text: text) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        let store = self.store!
        DispatchQueue.global(qos: .utility).async {
            _ = try? store.purgeDeleted(before: Date().addingTimeInterval(-30 * 86_400))
        }
        startCloudSync()
        LaunchTrace.finished()
    }

    // MARK: iCloud

    /// Only builds signed with the iCloud entitlement sync (not `make install`).
    private func startCloudSync() {
        guard CloudSync.isAvailable, let syncStore = try? Store() else { return }
        let sync = CloudSync(store: syncStore, deviceName: Host.current().localizedName ?? "Mac")
        sync.willApplyRemoteChanges = { [weak self] in self?.windowController.editor.saveBeforeRemoteChanges() }
        sync.didApplyRemoteChanges = { [weak self] ids in self?.windowController.remoteNotesDidChange(ids) }
        windowController.onLocalChange = { [weak sync] in sync?.localChangesMayExist() }
        cloudSync = sync
        sync.start()
        NSApp.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        cloudSync?.fetchNow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        cloudSync?.fetchNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let start = Date()
        windowController?.editor.flush()
        LaunchTrace.quit(seconds: Date().timeIntervalSince(start))
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.editor.saveSoon()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Agents and the CLI

    /// The CLI or an agent changed something: apply queued edits, then refresh the sidebar.
    private func databaseDidChange() {
        guard let store, let windowController else { return }
        let ops = (try? store.pendingOps()) ?? []
        for op in ops {
            let result = store.agentsCanEdit ? windowController.editor.apply(op) : .failure(AgentError.readOnly.description)
            try? store.complete(opID: op.id, result: result)
        }
        windowController.databaseDidChange()
        cloudSync?.localChangesMayExist()
    }

    private func toggleVisibility() {
        guard let window = windowController?.window else { return }
        if NSApp.isActive, window.isVisible, window.isKeyWindow {
            windowController.editor.saveSoon()
            NSApp.hide(nil)
        } else {
            windowController.show()
            windowController.editor.focusCanvas()
        }
    }

    // MARK: URLs: blacktext://new?text=…  blacktext://append?text=…  blacktext://open

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "blacktext" {
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value ?? ""
            switch url.host {
            case "new" where !text.isEmpty:
                windowController.openNewNote(text: text)
            case "append" where !text.isEmpty:
                let op = AgentOp(noteID: nil, edit: .append(text: text, newParagraph: true), source: "user")
                _ = windowController.editor.apply(op)
                windowController.show()
            default:
                windowController.show()
            }
        }
    }

    // MARK: Menu actions

    @objc func showMainWindow(_ sender: Any?) {
        windowController.show()
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "One page. Plain text. Nothing added.\n\(BlackText.repository)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationVersion: BlackText.version, .version: ""])
    }

    @objc func toggleAgentsCanEdit(_ sender: Any?) {
        store.agentsCanEdit.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAgentsCanEdit(_:)) {
            item.state = store?.agentsCanEdit == false ? .off : .on
        }
        return true
    }

    private var cliURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/blacktext")
    }

    @objc func copyMCPConfig(_ sender: Any?) {
        let config = """
        {
          "mcpServers": {
            "blacktext": {
              "command": "\(cliURL.path)",
              "args": ["mcp"]
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        let alert = NSAlert()
        alert.messageText = "MCP config copied"
        alert.informativeText = """
            Paste it into your agent app's MCP settings (for example Claude Desktop's claude_desktop_config.json).

            For Claude Code, run:
            claude mcp add blacktext -- "\(cliURL.path)" mcp
            """
        alert.runModal()
    }

    @objc func installCommandLineTool(_ sender: Any?) {
        let alert = NSAlert()
        do {
            let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let link = bin.appendingPathComponent("blacktext")
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cliURL)
            alert.messageText = "Installed blacktext in ~/.local/bin"
            alert.informativeText = "Try: blacktext help\n\nIf your shell can't find it, add ~/.local/bin to your PATH."
        } catch {
            alert.messageText = "Couldn't install the command line tool"
            alert.informativeText = "\(error.localizedDescription)"
        }
        alert.runModal()
    }

    @objc func exportAllAsText(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to put a folder of .txt files, one per note."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Exporter.export(to: destination) }
            DispatchQueue.main.async {
                switch result {
                case .success(let folder):
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: BlackText.repository)!)
    }

    @objc func openShortcuts(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: BlackText.repository + "#keyboard")!)
    }
}

/// Services → New BlackText Note: select text anywhere, send it here.
final class ServiceProvider: NSObject {
    var open: ((String) -> Void)?

    @objc func newNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        open?(text)
    }
}

enum Exporter {
    /// Writes every note as a .txt file into a new folder inside `directory`. Returns the folder.
    static func export(to directory: URL) throws -> URL {
        let store = try Store()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        var folder = directory.appendingPathComponent("BlackText export \(stamp.string(from: Date()))", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = directory.appendingPathComponent("BlackText export \(stamp.string(from: Date())) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileStamp = DateFormatter()
        fileStamp.dateFormat = "yyyy-MM-dd HHmm"
        var used = Set<String>()
        try store.forEachNote { note in
            let title = note.title.isEmpty ? "Empty note" : String(note.title.prefix(60))
            let safe = title.map { "/:\\".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            var name = "\(fileStamp.string(from: note.createdAt)) \(safe)"
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(fileStamp.string(from: note.createdAt)) \(safe) \(counter)"
                counter += 1
            }
            used.insert(name.lowercased())
            let file = folder.appendingPathComponent(name).appendingPathExtension("txt")
            try note.text.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.creationDate: note.createdAt, .modificationDate: note.updatedAt], ofItemAtPath: file.path)
        }
        return folder
    }
}
