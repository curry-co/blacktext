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
    private let updater = Updater()
    /// Agent ops this run has applied. An op whose edit is in the canvas stays pending until a save records
    /// it, and mustn't be applied again meanwhile.
    private var handledOps: Set<Int64> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        Theme.apply()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("did-finish-launching")
        // While the app holds the lock, the blacktext command sends edits here instead of writing them itself.
        // Without it the two could overwrite each other, so don't run without it.
        do {
            guard try link.holdWhileRunning() else {
                if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
                    .first(where: { $0 != NSRunningApplication.current }) {
                    other.activate()
                } else {
                    stop("BlackText is already open", "Another copy of BlackText, or the blacktext command, is using these notes. Try again in a moment.")
                }
                NSApp.terminate(nil)
                return
            }
        } catch {
            stop("BlackText couldn't open its notes", "\(error)")
            NSApp.terminate(nil)
            return
        }
        let stores: (Store, Store, Store)
        do {
            stores = (try Store(), try Store(), try Store())
        } catch {
            stop("BlackText couldn't open its notes", "\(error)\n\n\(Paths.databaseURL.path)")
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

    private func stop(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func finishLaunching() {
        // Spell checking loads dictionaries; start it once the window is up.
        windowController.editor.setSpellChecking(Preferences.spellCheck)
        notify_register_dispatch(link.changedNotification, &notifyToken, .main) { [weak self] _ in
            self?.databaseDidChange()
        }
        databaseDidChange()
        hotKey = HotKey.showHide { [weak self] in self?.toggleVisibility() }
        services.open = { [weak self] text in self?.windowController.openNewNote(text: text) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        let store = self.store!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let purged = (try? store.purgeDeleted(before: Date().addingTimeInterval(-30 * 86_400))) ?? 0
            // Removing notes queues their deletions; send them now rather than at the next edit.
            guard purged > 0 else { return }
            DispatchQueue.main.async { self?.cloudSync?.localChangesMayExist() }
        }
        startCloudSync()
        updater.start()
        LaunchTrace.finished()
    }

    // MARK: iCloud

    /// Only builds signed with the iCloud entitlement sync (not `make install`).
    private func startCloudSync() {
        guard CloudSync.isAvailable, let syncStore = try? Store() else { return }
        let sync = CloudSync(store: syncStore, deviceName: Host.current().localizedName ?? "Mac")
        sync.willApplyRemoteChanges = { [weak self] in self?.windowController.editor.saveBeforeRemoteChanges() }
        sync.didApplyRemoteChanges = { [weak self] ids in self?.windowController.remoteNotesDidChange(ids) }
        sync.onStatusChange = { [weak self] status in self?.syncStatusDidChange(status) }
        windowController.onLocalChange = { [weak sync] in sync?.localChangesMayExist() }
        cloudSync = sync
        sync.start()
        NSApp.registerForRemoteNotifications()
    }

    private var toldAboutSuspension = false

    /// Sync stopping for the user to decide is said once a launch; the rest waits for the menu.
    private func syncStatusDidChange(_ status: CloudSync.Status) {
        guard status.suspension != nil, !toldAboutSuspension else { return }
        toldAboutSuspension = true
        showSyncStatus(nil)
    }

    /// BlackText → iCloud Sync…: where sync stands, and what can be done about it.
    @objc func showSyncStatus(_ sender: Any?) {
        guard let sync = cloudSync else { return }
        let status = sync.status
        let alert = NSAlert()
        if let suspension = status.suspension {
            alert.messageText = "iCloud sync is off"
            alert.informativeText = suspension.explanation
            alert.addButton(withTitle: "Keep Off")
            alert.addButton(withTitle: "Turn Sync On")
            if alert.runModal() == .alertSecondButtonReturn { sync.resume() }
            return
        }
        var lines: [String] = []
        let waiting = status.pending - status.failed
        lines.append(waiting == 0 ? "Everything here has been sent." : "\(waiting) \(waiting == 1 ? "change is" : "changes are") waiting to be sent.")
        if status.failed > 0 {
            lines.append("iCloud refused \(status.failed) \(status.failed == 1 ? "change" : "changes"); \(status.failed == 1 ? "it's" : "they're") kept here and tried again at the next launch.")
        }
        if let error = status.lastError { lines.append("Last problem: \(error)") }
        if let sent = status.lastSent { lines.append("Last sent \(Format.dateTime(sent)).") }
        alert.messageText = "iCloud sync"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: status.failed > 0 ? "Try Again Now" : "Sync Now")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if status.failed > 0 { try? store.retryFailedSyncChanges() }
        sync.localChangesMayExist()
        sync.fetchNow()
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

    /// Quitting saves first. If the save fails, asks before quitting, since the canvas is the only full copy
    /// (apart from the recovery copy, if one could be written).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = windowController?.editor,
              case .failed(let message, let copy) = editor.flush() else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Quit without saving your latest changes?"
        alert.informativeText = copy.map { "\(message)\n\nA copy of the text is in \($0.path)." }
            ?? "\(message)\n\nNo copy could be saved either. Copy the text somewhere safe first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
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
        for op in ops where !handledOps.contains(op.id) {
            handledOps.insert(op.id)
            // Saving the canvas so an agent can read it isn't an edit: it's allowed when agents may only read.
            let mayApply = op.edit == .flush || store.agentsCanEdit
            let result = mayApply ? windowController.editor.apply(op) : .failure(AgentError.readOnly.description)
            if let result { try? store.complete(opID: op.id, result: result) }
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

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    @objc func toggleAgentsCanEdit(_ sender: Any?) {
        store.agentsCanEdit.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAgentsCanEdit(_:)) {
            item.state = store?.agentsCanEdit == false ? .off : .on
        }
        if item.action == #selector(showSyncStatus(_:)) {
            item.isHidden = cloudSync == nil
            item.title = cloudSync?.status.suspension == nil ? "iCloud Sync…" : "iCloud Sync Is Off…"
        }
        if item.action == #selector(checkForUpdates(_:)) {
            item.isHidden = !updater.isAvailable
            return updater.canCheckForUpdates
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
            // Replace a link (an earlier install), but not something else of the same name.
            if let existing = try? FileManager.default.attributesOfItem(atPath: link.path) {
                guard existing[.type] as? FileAttributeType == .typeSymbolicLink else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: link.path,
                        NSLocalizedDescriptionKey: "\(link.path) already exists and isn't a link to BlackText. Move it aside and try again."])
                }
                try FileManager.default.removeItem(at: link)
            }
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
        // Include what's in the canvas now.
        windowController?.editor.flush()
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

    /// File → Back Up Notes…: one file with everything (history and Recently Deleted too), unlike the
    /// text export. To restore it, quit BlackText and put it in place of the notes file.
    @objc func backUpNotes(_ sender: Any?) {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "BlackText backup \(stamp.string(from: Date())).sqlite"
        panel.message = "A complete copy of your notes, with their history. To restore it, quit BlackText and put it in place of \(Paths.databaseURL.path)."
        guard panel.runModal() == .OK, let destination = panel.url, let store else { return }
        windowController?.editor.flush()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try store.writeBackup(to: destination) }
            DispatchQueue.main.async {
                switch result {
                case .success: NSWorkspace.shared.activateFileViewerSelecting([destination])
                case .failure(let error): NSAlert(error: error).runModal()
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
            let safe = fileName(note.title)
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

    /// A note's title as a file name: path separators and control characters become "-", no leading dot,
    /// and at most 150 bytes of UTF-8 (whole characters), so the full name stays inside the 255-byte limit.
    static func fileName(_ title: String) -> String {
        var name = ""
        var bytes = 0
        for character in title {
            let safe: Character = "/:\\".contains(character) || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
                ? "-" : character
            let size = String(safe).utf8.count
            guard bytes + size <= 150 else { break }
            name.append(safe)
            bytes += size
        }
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Empty note" : name
    }
}
