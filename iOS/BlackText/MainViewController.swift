import UIKit
import BlackTextCore

/// The one screen: a top bar (sidebar toggle, BLACKTEXT, find, sun/moon), the sidebar, and the canvas.
/// On iPad (regular width) the sidebar sits beside the canvas; on iPhone it slides in over it.
/// Most commands land here so they work wherever focus is.
final class MainViewController: UIViewController, EditorControllerDelegate, SidebarDelegate,
    FindControllerHost, UIGestureRecognizerDelegate
{
    let store: Store
    let editor: EditorController
    let sidebar: SidebarController
    let find: FindController
    /// Called after this screen writes to the database, so iCloud sync can send it right away.
    var onLocalChange: (() -> Void)?
    private let topBar = TopBar()
    private let sidebarContainer = UIView()
    private let dimView = UIView()
    private lazy var sidebarLeading = sidebarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    private lazy var sidebarWidth = sidebarContainer.widthAnchor.constraint(equalToConstant: 300)
    private var dockedConstraints: [NSLayoutConstraint] = []
    private var overlayConstraints: [NSLayoutConstraint] = []
    private let edgePan = UIScreenEdgePanGestureRecognizer()
    private let sidebarSwipe = UISwipeGestureRecognizer()
    private let dimSwipe = UISwipeGestureRecognizer()

    /// Regular width: the sidebar sits beside the canvas. Compact: it slides over it.
    private(set) var isDocked = true
    private(set) var isSidebarShown = false
    /// Whether the canvas had the keyboard when the sliding sidebar came in, to give it back after.
    private var canvasHadFocus = false
    private var hasAppeared = false

    init(store: Store, saveStore: Store, searchStore: Store) {
        self.store = store
        editor = EditorController(store: store, saveStore: saveStore)
        sidebar = SidebarController(store: store)
        find = FindController(editor: editor, sidebar: sidebar, searchStore: searchStore)
        super.init(nibName: nil, bundle: nil)
        editor.delegate = self
        sidebar.delegate = self
        find.host = self
        editor.onPutBack = { [weak self] id in self?.putBack(id) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        addChild(editor)
        addChild(sidebar)
        let editorView: UIView = editor.view
        let sidebarView: UIView = sidebar.view
        let edge = Hairline(.vertical)
        for subview in [editorView, sidebarView, sidebarContainer, dimView, topBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(editorView)
        view.addSubview(dimView)
        view.addSubview(sidebarContainer)
        view.addSubview(topBar)
        sidebarContainer.addSubview(sidebarView)
        sidebarContainer.addSubview(edge)
        sidebarContainer.backgroundColor = Palette.background
        dimView.backgroundColor = Palette.dim
        dimView.alpha = 0
        dimView.isHidden = true
        editor.didMove(toParent: self)
        sidebar.didMove(toParent: self)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            editorView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            editorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarLeading,
            sidebarWidth,
            sidebarView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: edge.leadingAnchor),
            edge.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            edge.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        dockedConstraints = [
            editorView.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
        ]
        // On iPhone the sidebar starts below the find bar, so search results never cover the field.
        overlayConstraints = [
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarContainer.topAnchor.constraint(equalTo: editor.canvasTopAnchor),
        ]

        topBar.sidebarButton.addAction(UIAction { [weak self] _ in self?.toggleNoteSidebar() }, for: .primaryActionTriggered)
        topBar.findButton.addAction(UIAction { [weak self] _ in self?.findButtonTapped() }, for: .primaryActionTriggered)
        topBar.themeButton.addAction(UIAction { [weak self] _ in self?.toggleTheme() }, for: .primaryActionTriggered)

        // iPhone: tap or swipe the dimmed canvas to close the sidebar, swipe the sidebar away,
        // or pull it in from the left edge.
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        for swipe in [sidebarSwipe, dimSwipe] {
            swipe.direction = .left
            swipe.delegate = self
            swipe.addTarget(self, action: #selector(swipedAway))
        }
        sidebarContainer.addGestureRecognizer(sidebarSwipe)
        dimView.addGestureRecognizer(dimSwipe)
        edgePan.edges = .left
        edgePan.delegate = self
        edgePan.addTarget(self, action: #selector(edgePanned(_:)))
        view.addGestureRecognizer(edgePan)

        applyLayoutMode(docked: traitCollection.horizontalSizeClass == .regular)
        registerForTraitChanges([UITraitHorizontalSizeClass.self], action: #selector(sizeClassDidChange))
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(appearanceDidChange))
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Traits are final here (not yet in viewDidLoad).
        let docked = traitCollection.horizontalSizeClass == .regular
        if docked != isDocked || !hasAppeared { applyLayoutMode(docked: docked) }
        updateThemeButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        sidebar.revealSelection()
        // Ready to type: the cursor is at the end of the last note (unless the sidebar is over it).
        if isDocked || !isSidebarShown { editor.focusCanvas() }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let width = preferredSidebarWidth(for: view.bounds.width)
        if sidebarWidth.constant != width {
            sidebarWidth.constant = width
            if !isSidebarShown { sidebarLeading.constant = -width }
        }
    }

    private func preferredSidebarWidth(for total: CGFloat) -> CGFloat {
        isDocked ? min(max(260, (total * 0.3).rounded()), 360) : max(200, min(340, total - 56))
    }

    /// Shows the last note with the cursor at the end, and the first page of the sidebar.
    func start() {
        editor.restoreLastNote()
        sidebar.reloadNotes()
        sidebar.setCurrentNote(editor.noteID)
    }

    // MARK: Layout

    @objc private func sizeClassDidChange() {
        let docked = traitCollection.horizontalSizeClass == .regular
        if docked != isDocked { applyLayoutMode(docked: docked) }
    }

    private func applyLayoutMode(docked: Bool) {
        isDocked = docked
        NSLayoutConstraint.deactivate(docked ? overlayConstraints : dockedConstraints)
        NSLayoutConstraint.activate(docked ? dockedConstraints : overlayConstraints)
        sidebarWidth.constant = preferredSidebarWidth(for: view.bounds.width)
        // The sidebar opens beside the canvas as it was left; over it, only when asked.
        let shown = docked ? Preferences.sidebarVisible : false
        isSidebarShown = !shown
        setSidebarShown(shown, animated: false)
    }

    private func setSidebarShown(_ shown: Bool, animated: Bool) {
        guard shown != isSidebarShown else { return }
        isSidebarShown = shown
        if isDocked { Preferences.sidebarVisible = shown }
        let overlay = !isDocked && shown
        sidebarLeading.constant = shown ? 0 : -sidebarWidth.constant
        sidebarContainer.isHidden = false
        if overlay {
            dimView.isHidden = false
            sidebar.revealSelection()
        }
        topBar.sidebarButton.accessibilityValue = shown ? "Shown" : "Hidden"
        let changes = {
            self.dimView.alpha = overlay ? 1 : 0
            self.view.layoutIfNeeded()
        }
        let finished = { (_: Bool) in
            if !(self.isSidebarShown && !self.isDocked) { self.dimView.isHidden = true }
            // Off screen, it shouldn't take VoiceOver or keyboard focus.
            if !self.isSidebarShown { self.sidebarContainer.isHidden = true }
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState],
                           animations: changes, completion: finished)
        } else {
            changes()
            finished(true)
        }
    }

    private func openOverlay() {
        canvasHadFocus = editor.textView.isFirstResponder
        // Put the keyboard away unless it's needed for searching all notes.
        if !(find.isVisible && find.scope == .allNotes) { view.endEditing(true) }
        setSidebarShown(true, animated: true)
    }

    private func closeOverlay(focusCanvas: Bool? = nil) {
        let focus = focusCanvas ?? canvasHadFocus
        canvasHadFocus = false
        setSidebarShown(false, animated: true)
        if focus, !find.isVisible { editor.focusCanvas() }
    }

    @objc private func dimTapped() {
        if !isDocked, isSidebarShown { closeOverlay() }
    }

    @objc private func swipedAway() {
        if !isDocked, isSidebarShown { closeOverlay() }
    }

    @objc private func edgePanned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        if recognizer.state == .began, !isDocked, !isSidebarShown { openOverlay() }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === edgePan { return !isDocked && !isSidebarShown }
        if recognizer === sidebarSwipe || recognizer === dimSwipe { return !isDocked && isSidebarShown }
        return true
    }

    /// Swipe-left on a note row is Delete, so closing the sidebar by swiping only listens elsewhere.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === sidebarSwipe { return !sidebar.hasSwipeActions(at: touch.location(in: sidebar.view)) }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === sidebarSwipe || recognizer === dimSwipe
    }

    // MARK: Theme

    @objc private func appearanceDidChange() { updateThemeButton() }

    private func updateThemeButton() {
        let dark = Theme.isDark(in: view.window)
        topBar.themeButton.setSymbol(dark ? "moon" : "sun.max", label: dark ? "Switch to light" : "Switch to dark")
    }

    // MARK: Editor delegate

    func editor(_ editor: EditorController, didOpen noteID: NoteID?) {
        if sidebar.mode == .notes { sidebar.setCurrentNote(noteID) }
        find.editorDidOpenNote()
    }

    func editor(_ editor: EditorController, didSave summary: NoteSummary) {
        sidebar.noteDidSave(summary)
        find.refreshAllNotes(debounce: true)
        // A blank canvas becomes a note on its first save; select it once, without scrolling on every save.
        if sidebar.mode == .notes, sidebar.currentNoteID != editor.noteID { sidebar.setCurrentNote(editor.noteID) }
        onLocalChange?()
    }

    func editor(_ editor: EditorController, didDiscard noteID: NoteID) {
        sidebar.noteDidDisappear(noteID)
        onLocalChange?()
    }

    func editor(_ editor: EditorController, didCreate noteID: NoteID) {
        if sidebar.mode == .notes {
            sidebar.reloadNotes()
            if editor.noteID == noteID { sidebar.setCurrentNote(noteID) }
        }
        onLocalChange?()
    }

    func editorDidChangeText(_ editor: EditorController) {
        find.editorTextDidChange()
        if editor.preview == nil { sidebar.clearVersionSelection() }
    }

    func editorDidRequestNewNote(_ editor: EditorController) {
        newNote()
    }

    // MARK: Sidebar delegate

    func sidebar(_ sidebar: SidebarController, didSelectNote id: NoteID) {
        editor.open(noteID: id)
        if !isDocked { closeOverlay() }
    }

    func sidebar(_ sidebar: SidebarController, didSelectVersion version: VersionSummary) {
        if editor.noteID != version.noteID { editor.open(noteID: version.noteID) }
        editor.showPreview(.version(version))
        sidebar.highlight(.version(version.id))
        find.editorDidOpenNote()
        if !isDocked { closeOverlay(focusCanvas: false) }
    }

    func sidebar(_ sidebar: SidebarController, didSelectDeleted note: NoteSummary) {
        editor.showPreview(.deleted(note))
        if !isDocked { closeOverlay(focusCanvas: false) }
    }

    func sidebar(_ sidebar: SidebarController, didSelectHit hit: SearchHit) {
        editor.open(noteID: hit.note.id)
        find.editorDidOpenNote()
        // The find field keeps the keyboard; the note shows with its matches.
        if !isDocked { closeOverlay(focusCanvas: false) }
    }

    func sidebar(_ sidebar: SidebarController, delete id: NoteID) {
        deleteNote(id)
    }

    func sidebar(_ sidebar: SidebarController, putBack id: NoteID) {
        putBack(id)
    }

    func sidebarDidRequestRecentlyDeleted(_ sidebar: SidebarController) {
        showRecentlyDeleted()
    }

    func sidebarDidFinishRecentlyDeleted(_ sidebar: SidebarController) {
        editor.exitPreview()
        sidebar.showNotes()
    }

    func sidebarDidRequestNewNote(_ sidebar: SidebarController) {
        newNote()
        if !isDocked { closeOverlay(focusCanvas: true) }
    }

    // MARK: Find host

    func findDidChangeScope(_ find: FindController) {
        if find.scope == .allNotes {
            // Results go in the sidebar; on iPhone the find field keeps the keyboard.
            if !isSidebarShown {
                canvasHadFocus = false
                setSidebarShown(true, animated: true)
            }
        } else if !isDocked, isSidebarShown {
            setSidebarShown(false, animated: true)
        }
    }

    // MARK: Notes

    func deleteNote(_ id: NoteID) {
        let wasOpen = editor.noteID == id
        // Leaving the note saves it first; if that can't be done safely, it stays open and isn't deleted.
        if wasOpen, !editor.open(noteID: nil) { return }
        try? store.softDelete(noteID: id)
        onLocalChange?()
        sidebar.noteDidDisappear(id)
        let undo = editor.textView.undoManager
        undo?.registerUndo(withTarget: self) { controller in
            controller.putBack(id)
            if wasOpen { controller.editor.open(noteID: id, caretAtEnd: true) }
        }
        undo?.setActionName("Delete Note")
    }

    private func putBack(_ id: NoteID) {
        try? store.putBack(noteID: id)
        onLocalChange?()
        if sidebar.mode == .deleted {
            editor.exitPreview()
            sidebar.showRecentlyDeleted()
        } else {
            sidebar.reloadNotes()
        }
    }

    /// Opens a new note with `text` (blacktext://new links).
    func openNewNote(text: String) {
        guard let id = try? store.createNote(text: text, versionSource: "user") else { return }
        onLocalChange?()
        if find.isVisible { find.hide() }
        if sidebar.mode != .notes { sidebar.showNotes() }
        sidebar.reloadNotes()
        editor.open(noteID: id, caretAtEnd: true)
        if !isDocked, isSidebarShown { closeOverlay(focusCanvas: false) }
        editor.focusCanvas()
    }

    /// blacktext://append: adds text to the end of the open note.
    func appendToCurrentNote(_ text: String) {
        if find.isVisible { find.hide() }
        editor.appendText(text)
    }

    /// Something outside the canvas changed the database (sync, or another process).
    /// Refreshes the sidebar and, if nothing was typed since the last save, the open note.
    func databaseDidChange() {
        sidebar.reload()
        editor.reloadCurrentNoteIfUnchanged()
        find.refreshAllNotes()
    }

    // MARK: Actions

    /// ⌘↩: file this note away (only from the canvas, with something in it).
    @objc func fileNoteAway() { newNote() }

    /// ⌘N, ⌘↩, Save+New and the + button: file this note away and start a new one right below the +.
    @objc func newNote() {
        if find.isVisible { find.hide() }
        if sidebar.mode != .notes { sidebar.showNotes() }
        if let id = editor.startNewNote(), let summary = try? store.summary(id: id) {
            sidebar.noteDidSave(summary)
        }
        editor.focusCanvas()
    }

    @objc func toggleNoteSidebar() {
        if isDocked {
            setSidebarShown(!isSidebarShown, animated: true)
        } else if isSidebarShown {
            closeOverlay()
        } else {
            openOverlay()
        }
    }

    @objc func toggleTheme() {
        Theme.toggle(in: view.window)
        updateThemeButton()
    }

    private func findButtonTapped() {
        if find.isVisible {
            find.hide()
        } else {
            showFind()
        }
    }

    @objc func biggerText() { editor.stepTextSize(by: 1) }
    @objc func smallerText() { editor.stepTextSize(by: -1) }
    @objc func actualSizeText() { editor.resetTextSize() }

    @objc func previousNote() { stepNote(by: -1) }
    @objc func nextNote() { stepNote(by: 1) }

    private func stepNote(by delta: Int) {
        if isDocked, !isSidebarShown { setSidebarShown(true, animated: true) }
        guard let id = sidebar.adjacentNote(by: delta) else { return }
        editor.open(noteID: id)
    }

    @objc func showRecentlyDeleted() {
        if sidebar.mode == .deleted {
            sidebarDidFinishRecentlyDeleted(sidebar)
            return
        }
        if find.isVisible { find.hide() }
        editor.exitPreview()
        sidebar.showRecentlyDeleted()
        if !isSidebarShown {
            if isDocked { setSidebarShown(true, animated: true) } else { openOverlay() }
        }
    }

    /// Esc: close find, the sliding sidebar, Recently Deleted, or a version preview, in that order.
    @objc func escape() {
        if find.isVisible {
            find.hide()
        } else if !isDocked, isSidebarShown {
            closeOverlay()
        } else if sidebar.mode == .deleted {
            sidebarDidFinishRecentlyDeleted(sidebar)
        } else if editor.preview != nil {
            editor.closePreview()
        }
    }

    // Find

    @objc func showFind() { find.show(replace: false, scope: .note) }
    @objc func showFindAndReplace() { find.show(replace: true, scope: .note) }

    @objc func showSearchAllNotes() {
        if sidebar.mode == .deleted { sidebar.showNotes() }
        find.show(replace: false, scope: .allNotes)
        if !isSidebarShown { setSidebarShown(true, animated: true) }
    }

    @objc func findNextMatch() { find.step(forward: true) }
    @objc func findPreviousMatch() { find.step(forward: false) }
    @objc func useSelectionAsSearch() { find.useSelection() }
    @objc func toggleHighlightAll() { find.toggleHighlightAll() }
    @objc func toggleFindMatchCase() { find.toggleMatchCase() }
    @objc func toggleFindWholeWord() { find.toggleWholeWord() }
    @objc func toggleFindRegex() { find.toggleRegex() }
    @objc func replaceAllMatches() { find.replaceAll() }

    // MARK: Keyboard

    /// Built once, the first time a hardware keyboard asks.
    private lazy var commandList = KeyCommands.make()

    override var keyCommands: [UIKeyCommand]? { commandList }

    /// Like the Mac's menu validation: ⌘↩ only from a canvas with something in it, and so on.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(fileNoteAway):
            return editor.isCanvasFocused && editor.canFileAway
        case #selector(biggerText):
            return editor.canStepTextSize(by: 1)
        case #selector(smallerText):
            return editor.canStepTextSize(by: -1)
        case #selector(replaceAllMatches):
            return find.isVisible && editor.preview == nil
        case #selector(useSelectionAsSearch):
            return editor.activeTextView.selectedRange.length > 0
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }
}

/// The strip at the top: sidebar toggle at left, BLACKTEXT centered, find and sun/moon at right.
final class TopBar: UIView {
    let sidebarButton = MonoButton(symbol: "sidebar.left", label: "Toggle sidebar")
    let findButton = MonoButton(symbol: "magnifyingglass", label: "Find")
    let themeButton = MonoButton(symbol: "moon", label: "Switch to light")
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        let name = "BLACKTEXT"
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.secondaryText,
        ])
        // Letter-spaced, but not after the last letter, so it stays truly centered.
        text.addAttribute(.kern, value: 1.5, range: NSRange(location: 0, length: name.utf16.count - 1))
        title.attributedText = text
        title.isAccessibilityElement = false
        for view in [title, sidebarButton, findButton, themeButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            themeButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            themeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            findButton.trailingAnchor.constraint(equalTo: themeButton.leadingAnchor),
            findButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for button in [sidebarButton, findButton, themeButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
