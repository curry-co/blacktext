import AppKit
import BlktxtCore

/// The one window: a top strip with the sidebar and sun/moon toggles, the sidebar, and the canvas.
/// Most menu actions land here so they work wherever focus is.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    EditorControllerDelegate, SidebarDelegate
{
    let store: Store
    let editor: EditorController
    let sidebar: SidebarController
    let find: FindController
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private let sidebarButton: MonoButton
    private let themeButton: MonoButton
    private lazy var fieldEditor = MonoFieldEditor()

    init(store: Store, saveStore: Store, searchStore: Store) {
        self.store = store
        editor = EditorController(store: store, saveStore: saveStore)
        sidebar = SidebarController(store: store)
        find = FindController(editor: editor, sidebar: sidebar, searchStore: searchStore)
        sidebarButton = MonoButton(symbol: "sidebar.left", label: "Toggle Sidebar (⌃⌘S)", target: nil, action: #selector(toggleNoteSidebar(_:)))
        themeButton = MonoButton(symbol: "moon", label: "Dark (⌃⌘L)", target: nil, action: #selector(toggleTheme(_:)))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "BlackText"
        window.backgroundColor = Palette.background
        window.minSize = NSSize(width: 420, height: 280)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        sidebarButton.target = self
        themeButton.target = self
        editor.delegate = self
        sidebar.delegate = self
        editor.onPutBack = { [weak self] id in self?.putBack(id) }
        buildContent()
        if !window.setFrameUsingName("main") { window.center() }
        window.setFrameAutosaveName("main")
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 420
        sidebarItem.preferredThicknessFraction = 0.26
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.isCollapsed = !Preferences.sidebarVisible
        self.sidebarItem = sidebarItem
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 280
        split.splitView = MonoSplitView()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "split"
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)

        let root = FillView(color: Palette.background)
        let topBar = TitleStrip()
        for view in [topBar, split.view, sidebarButton, themeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        window.contentView = root
        let content = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: content.topAnchor),
            split.view.topAnchor.constraint(equalTo: content.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebarButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 80),
            sidebarButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            themeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            themeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
        updateThemeButton()
    }

    /// Shows the window with the last note open and the cursor at the end, ready to type.
    func start() {
        editor.restoreLastNote()
        sidebar.reloadNotes()
        sidebar.setCurrentNote(editor.noteID)
        showWindow(nil)
        editor.focusCanvas()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func themeDidChange() {
        updateThemeButton()
        window?.contentView?.needsDisplay = true
    }

    private func updateThemeButton() {
        let dark = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let symbol = dark ? "moon" : "sun.max"
        themeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: dark ? "Dark" : "Light")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        themeButton.toolTip = dark ? "Switch to light (⌃⌘L)" : "Switch to dark (⌃⌘L)"
        themeButton.setAccessibilityLabel(themeButton.toolTip)
    }

    func windowDidChangeEffectiveAppearance() { updateThemeButton() }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        editor.flush()
    }

    func windowDidResignKey(_ notification: Notification) {
        editor.saveSoon()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is PlainField ? fieldEditor : nil
    }

    // MARK: Editor delegate

    func editor(_ editor: EditorController, didOpen noteID: NoteID?) {
        if sidebar.mode == .notes { sidebar.setCurrentNote(noteID) }
        find.editorDidOpenNote()
    }

    func editor(_ editor: EditorController, didSave summary: NoteSummary) {
        sidebar.noteDidSave(summary)
        // A blank canvas becomes a note on its first save; select it once, without scrolling on every save.
        if sidebar.mode == .notes, sidebar.currentNoteID != editor.noteID { sidebar.setCurrentNote(editor.noteID) }
    }

    func editor(_ editor: EditorController, didDiscard noteID: NoteID) {
        sidebar.noteDidDisappear(noteID)
    }

    func editorDidChangeText(_ editor: EditorController) {
        find.editorTextDidChange()
    }

    func editorDidRequestEscape(_ editor: EditorController) -> Bool {
        if find.isVisible {
            find.hide()
            return true
        }
        return false
    }

    // MARK: Sidebar delegate

    func sidebar(_ sidebar: SidebarController, didSelectNote id: NoteID) {
        editor.open(noteID: id)
    }

    func sidebar(_ sidebar: SidebarController, didSelectVersion version: VersionSummary) {
        if editor.noteID != version.noteID { editor.open(noteID: version.noteID) }
        editor.showPreview(.version(version))
        find.editorDidOpenNote()
    }

    func sidebar(_ sidebar: SidebarController, didSelectDeleted note: NoteSummary) {
        editor.showPreview(.deleted(note))
    }

    func sidebar(_ sidebar: SidebarController, didSelectHit hit: SearchHit) {
        editor.open(noteID: hit.note.id)
        find.editorDidOpenNote()
    }

    func sidebar(_ sidebar: SidebarController, delete id: NoteID) {
        deleteNote(id)
    }

    func sidebarDidFinishRecentlyDeleted(_ sidebar: SidebarController) {
        editor.exitPreview()
        sidebar.showNotes()
    }

    func sidebarDidRequestCanvas(_ sidebar: SidebarController) {
        editor.focusCanvas()
    }

    func sidebarDidRequestNewNote(_ sidebar: SidebarController) {
        newNote(nil)
    }

    func sidebarDidCancel(_ sidebar: SidebarController) -> Bool {
        if find.isVisible {
            find.hide()
            return true
        }
        if sidebar.mode == .deleted {
            sidebarDidFinishRecentlyDeleted(sidebar)
            return true
        }
        if editor.preview != nil {
            editor.exitPreview()
            return true
        }
        editor.focusCanvas()
        return true
    }

    // MARK: Notes

    func deleteNote(_ id: NoteID) {
        let wasOpen = editor.noteID == id
        if wasOpen {
            editor.flush()
            editor.open(noteID: nil)
        }
        try? store.softDelete(noteID: id)
        sidebar.noteDidDisappear(id)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.putBack(id)
            if wasOpen { controller.editor.open(noteID: id, caretAtEnd: true) }
        }
        window?.undoManager?.setActionName("Delete Note")
    }

    private func putBack(_ id: NoteID) {
        try? store.putBack(noteID: id)
        if sidebar.mode == .deleted {
            editor.exitPreview()
            sidebar.showRecentlyDeleted()
        } else {
            sidebar.reloadNotes()
        }
    }

    /// Opens a new note with `text` (Services menu, blktxt:// links).
    func openNewNote(text: String) {
        guard let id = try? store.createNote(text: text) else { return }
        _ = try? store.addVersion(noteID: id, text: text)
        if sidebar.mode != .notes { sidebar.showNotes() }
        sidebar.reloadNotes()
        editor.open(noteID: id, caretAtEnd: true)
        show()
        editor.focusCanvas()
    }

    /// Something outside the app changed the database (the CLI or an agent).
    func databaseDidChange() {
        if sidebar.mode == .notes { sidebar.reloadNotes() }
    }

    // MARK: Actions

    @objc func fileNoteAway(_ sender: Any?) { newNote(sender) }

    /// ⌘↩, ⌘N and the + button: file this note away and start a new one right below the button.
    @objc func newNote(_ sender: Any?) {
        if find.isVisible { find.hide() }
        if sidebar.mode != .notes { sidebar.showNotes() }
        if let id = editor.startNewNote(), let summary = try? store.summary(id: id) {
            sidebar.noteDidSave(summary)
        }
        editor.focusCanvas()
    }

    @objc func toggleNoteSidebar(_ sender: Any?) {
        let collapse = !sidebarItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            sidebarItem.animator().isCollapsed = collapse
        }
        Preferences.sidebarVisible = !collapse
        if collapse { editor.focusCanvas() }
    }

    @objc func toggleTheme(_ sender: Any?) {
        Theme.toggle()
    }

    @objc func biggerText(_ sender: Any?) { editor.setFontSize(Preferences.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { editor.setFontSize(Preferences.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { editor.setFontSize(Preferences.defaultFontSize) }

    @objc func previousNote(_ sender: Any?) { stepNote(by: -1) }
    @objc func nextNote(_ sender: Any?) { stepNote(by: 1) }

    private func stepNote(by delta: Int) {
        if sidebarItem.isCollapsed { toggleNoteSidebar(nil) }
        let outline = sidebar.outlineView
        let selectable = (0..<outline.numberOfRows).filter { outline.item(atRow: $0) is SidebarController.NoteRow }
        guard !selectable.isEmpty else { return }
        var anchor = outline.selectedRow
        if let version = outline.item(atRow: anchor) as? SidebarController.VersionRow { anchor = outline.row(forItem: version.note) }
        let next = selectable.firstIndex(of: anchor).map { $0 + delta } ?? (delta > 0 ? 0 : selectable.count - 1)
        guard selectable.indices.contains(next) else { return }
        outline.selectRowIndexes([selectable[next]], byExtendingSelection: false)
        outline.scrollRowToVisible(selectable[next])
    }

    @objc func showRecentlyDeleted(_ sender: Any?) {
        if sidebar.mode == .deleted {
            sidebarDidFinishRecentlyDeleted(sidebar)
            return
        }
        if find.isVisible { find.hide() }
        if sidebarItem.isCollapsed { toggleNoteSidebar(nil) }
        editor.exitPreview()
        sidebar.showRecentlyDeleted()
        window?.makeFirstResponder(sidebar.outlineView)
    }

    @objc func deleteCurrentNote(_ sender: Any?) {
        if window?.firstResponder === sidebar.outlineView, let id = sidebar.selectedNoteForDeletion {
            deleteNote(id)
        } else if let id = editor.noteID {
            deleteNote(id)
        }
    }

    @objc func toggleSpellChecking(_ sender: Any?) {
        editor.setSpellChecking(!Preferences.spellCheck)
    }

    // Find

    @objc func showFind(_ sender: Any?) { find.show(replace: false, scope: .note) }
    @objc func showFindAndReplace(_ sender: Any?) { find.show(replace: true, scope: .note) }

    @objc func showSearchAllNotes(_ sender: Any?) {
        if sidebarItem.isCollapsed { toggleNoteSidebar(nil) }
        if sidebar.mode == .deleted { sidebar.showNotes() }
        find.show(replace: false, scope: .allNotes)
    }

    @objc func findNextMatch(_ sender: Any?) { find.step(forward: true) }
    @objc func findPreviousMatch(_ sender: Any?) { find.step(forward: false) }
    @objc func useSelectionForFind(_ sender: Any?) { find.useSelection() }
    @objc func toggleHighlightAll(_ sender: Any?) { find.toggleHighlightAll() }
    @objc func toggleFindMatchCase(_ sender: Any?) { find.toggleMatchCase(sender) }
    @objc func toggleFindWholeWord(_ sender: Any?) { find.toggleWholeWord(sender) }
    @objc func toggleFindRegex(_ sender: Any?) { find.toggleRegex(sender) }
    @objc func replaceAllMatches(_ sender: Any?) { find.replaceAll(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(fileNoteAway(_:)):
            return editor.isCanvasFocused && editor.canFileAway
        case #selector(toggleNoteSidebar(_:)):
            item.title = sidebarItem.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleTheme(_:)):
            item.title = Theme.isDark ? "Light Mode" : "Dark Mode"
            return true
        case #selector(biggerText(_:)):
            return Preferences.fontSize < Preferences.fontSizeRange.upperBound
        case #selector(smallerText(_:)):
            return Preferences.fontSize > Preferences.fontSizeRange.lowerBound
        case #selector(showRecentlyDeleted(_:)):
            item.state = sidebar.mode == .deleted ? .on : .off
            return true
        case #selector(deleteCurrentNote(_:)):
            return editor.noteID != nil || sidebar.selectedNoteForDeletion != nil
        case #selector(toggleSpellChecking(_:)):
            item.state = Preferences.spellCheck ? .on : .off
            return true
        case #selector(toggleHighlightAll(_:)):
            item.state = find.highlightAll ? .on : .off
            return true
        case #selector(toggleFindMatchCase(_:)):
            item.state = find.options.matchCase ? .on : .off
            return true
        case #selector(toggleFindWholeWord(_:)):
            item.state = find.options.wholeWord ? .on : .off
            return true
        case #selector(toggleFindRegex(_:)):
            item.state = find.options.regex ? .on : .off
            return true
        case #selector(replaceAllMatches(_:)):
            return find.isVisible && editor.preview == nil
        case #selector(useSelectionForFind(_:)):
            return editor.activeTextView.selectedRange().length > 0
        default:
            return true
        }
    }
}

/// The strip under the traffic lights, with BLACKTEXT centered in it. Dragging it moves the window.
final class TitleStrip: FillView {
    private let title = TitleLabel(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Clipped so the title disappears with the strip in full screen.
        clipsToBounds = true
        let name = "BLACKTEXT"
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.secondaryText,
        ])
        // Letter-spaced, but not after the last letter, so it stays truly centered.
        text.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: name.utf16.count - 1))
        title.attributedStringValue = text
        title.setAccessibilityElement(false)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
    }
}

/// Text that clicks pass through, so the strip under it still drags and double-click zooms.
final class TitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class MonoSplitView: NSSplitView {
    override var dividerColor: NSColor { Palette.separator }
}

/// The field editor for find fields: monochrome caret and selection.
final class MonoFieldEditor: NSTextView {
    init() {
        super.init(frame: .zero, textContainer: nil)
        isFieldEditor = true
        insertionPointColor = Palette.text
        selectedTextAttributes = [.backgroundColor: Palette.selection]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError() }
}
