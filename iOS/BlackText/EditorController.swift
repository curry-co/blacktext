import UIKit
import BlackTextCore

protocol EditorControllerDelegate: AnyObject {
    func editor(_ editor: EditorController, didOpen noteID: NoteID?)
    func editor(_ editor: EditorController, didSave summary: NoteSummary)
    func editor(_ editor: EditorController, didDiscard noteID: NoteID)
    /// A note the sidebar hasn't seen: made from a preview, or the canvas's unsaved text kept as a new note
    /// after its note was deleted elsewhere.
    func editor(_ editor: EditorController, didCreate noteID: NoteID)
    func editorDidChangeText(_ editor: EditorController)
    /// The Save+New button: file this note away, like ⌘↩.
    func editorDidRequestNewNote(_ editor: EditorController)
}

/// The canvas side: the text, the find bar above it, read-only previews, and Save+New.
final class EditorController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    enum Preview: Equatable {
        case version(VersionSummary)
        case deleted(NoteSummary)
    }

    /// How long Save+New offers Undo after a tap.
    static let undoOfferSeconds = 4

    let store: Store
    let session: NoteSession
    weak var delegate: EditorControllerDelegate?
    var onPutBack: ((NoteID) -> Void)?

    let textView = EditorTextView.make()
    let previewTextView = EditorTextView.make()
    let marksView = MatchMarksView()
    let previewBar = PreviewBar()
    /// Shown while saving fails.
    private let problemBar = PreviewBar()
    private(set) lazy var saveNewButton = SaveNewButton(action: UIAction { [weak self] _ in self?.saveNewTapped() })
    private let stack = UIStackView()
    private let canvas = UIView()
    private(set) var preview: Preview?
    private var previewText = ""

    /// Remembered caret per note for this session.
    private var selections: [NoteID: NSRange] = [:]
    /// The note the last ⌘↩ / Save+New filed away, while the Undo button is on offer.
    private var filedNoteID: NoteID?
    private var undoOffer: Task<Void, Never>?
    private var pinchStartSize: CGFloat = 0
    private var needsInitialScroll = false
    private var lastTextHeight: CGFloat = 0

    private static let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted

    var findBar: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let findBar { stack.insertArrangedSubview(findBar, at: 0) }
        }
    }

    /// The top of the text area (below the find and preview bars), where the iPhone sidebar starts.
    var canvasTopAnchor: NSLayoutYAxisAnchor { canvas.topAnchor }

    init(store: Store, saveStore: Store) {
        self.store = store
        session = NoteSession(store: store, saveStore: saveStore)
        super.init(nibName: nil, bundle: nil)
        session.text = { [weak self] in self?.textView.text ?? "" }
        session.onSaved = { [weak self] summary in
            guard let self else { return }
            delegate?.editor(self, didSave: summary)
        }
        session.onDiscarded = { [weak self] id in
            guard let self else { return }
            delegate?.editor(self, didDiscard: id)
        }
        session.onRecreated = { [weak self] _, id in
            guard let self else { return }
            delegate?.editor(self, didCreate: id)
        }
        session.onOutcomeChanged = { [weak self] outcome in self?.showOutcome(outcome) }
    }

    required init?(coder: NSCoder) { fatalError() }

    var noteID: NoteID? { session.noteID }

    /// The text view find works on: the preview when one is showing.
    var activeTextView: EditorTextView { preview == nil ? textView : previewTextView }

    var isCanvasFocused: Bool { textView.isFirstResponder && preview == nil }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = Palette.background
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        canvas.backgroundColor = Palette.background
        canvas.clipsToBounds = true
        for text in [textView, previewTextView] {
            text.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(text)
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: canvas.topAnchor),
                text.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
                text.leadingAnchor.constraint(equalTo: canvas.safeAreaLayoutGuide.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: canvas.safeAreaLayoutGuide.trailingAnchor),
            ])
            text.delegate = self
        }
        textView.accessibilityLabel = "Note"
        // Keep the last line clear of the Save+New button.
        textView.bottomClearance = 50
        previewTextView.isEditable = false
        previewTextView.accessibilityLabel = "Version preview"
        previewTextView.isHidden = true

        marksView.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(marksView)
        NSLayoutConstraint.activate([
            marksView.topAnchor.constraint(equalTo: canvas.topAnchor),
            marksView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            marksView.trailingAnchor.constraint(equalTo: canvas.safeAreaLayoutGuide.trailingAnchor),
            marksView.widthAnchor.constraint(equalToConstant: 20),
        ])

        problemBar.isHidden = true
        stack.addArrangedSubview(problemBar)
        previewBar.isHidden = true
        stack.addArrangedSubview(previewBar)
        stack.addArrangedSubview(canvas)

        // Save+New rides just above the keyboard, or sits bottom-right when it's down.
        saveNewButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(saveNewButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
            saveNewButton.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            saveNewButton.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor, constant: -10),
        ])

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        canvas.addGestureRecognizer(pinch)
        view = root
        updateSaveNewButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = textView.bounds.height
        if needsInitialScroll, height > 0 {
            needsInitialScroll = false
            textView.layoutIfNeeded()
            textView.revealSelection()
        } else if height < lastTextHeight, textView.isFirstResponder {
            // The keyboard came up: keep the caret above it.
            textView.revealSelection()
        }
        lastTextHeight = height
    }

    // MARK: Opening notes

    /// Opens a note in the canvas (nil = blank canvas). What was there is saved first. If it can't be saved
    /// and no recovery copy could be written either, the canvas stays put and this returns false.
    @discardableResult
    func open(noteID: NoteID?, caretAtEnd: Bool = false, select range: NSRange? = nil) -> Bool {
        exitPreview()
        endUndoOffer()
        if let current = session.noteID {
            if current == noteID { return true }
            selections[current] = textView.selectedRange
        }
        if textView.markedTextRange != nil { textView.unmarkText() }
        guard leaveCurrentNote() else {
            delegate?.editor(self, didOpen: session.noteID)
            return false
        }

        let note = noteID.flatMap { try? store.note(id: $0) }.flatMap { $0.deletedAt == nil ? $0 : nil }
        session.load(note)
        textView.setPlainText(note?.text ?? "")
        textView.undoManager?.removeAllActions()

        let length = textView.textStorage.length
        var selection = range ?? (caretAtEnd ? NSRange(location: length, length: 0) : nil)
            ?? note.flatMap { selections[$0.id] } ?? NSRange(location: 0, length: 0)
        if NSMaxRange(selection) > length { selection = NSRange(location: length, length: 0) }
        textView.selectedRange = selection
        if selection.location == 0 {
            textView.setContentOffset(.zero, animated: false)
        } else {
            textView.layoutIfNeeded()
            textView.revealSelection()
        }
        updateSaveNewButton()
        delegate?.editor(self, didOpen: note?.id)
        return true
    }

    /// Saves the canvas before it shows something else. True if it's safe to: the database has the text, or
    /// a recovery copy does (and the user is told where).
    private func leaveCurrentNote() -> Bool {
        switch session.leave() {
        case .saved:
            return true
        case .failed(let message, let copy?):
            tellUnsaved(message: message, copy: copy)
            return true
        case .failed(let message, nil):
            tellUnsaved(message: message, copy: nil)
            return false
        }
    }

    private func tellUnsaved(message: String, copy: URL?) {
        let detail = copy == nil
            ? "\(message)\n\nIt's still open. Copy the text somewhere safe before you close it."
            : "\(message)\n\nA copy of the text was kept in BlackText's Recovered folder."
        let alert = UIAlertController(title: copy == nil ? "This note couldn't be saved" : "Your latest changes couldn't be saved",
                                      message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        guard presentedViewController == nil, view.window != nil else { return }
        present(alert, animated: true)
    }

    /// The bar above the canvas while saves are failing: what went wrong, Retry, and Copy to keep the text.
    private func showOutcome(_ outcome: NoteSession.Outcome) {
        switch outcome {
        case .saved:
            problemBar.isHidden = true
        case .failed(let message, _):
            problemBar.configure(text: "Not saved: \(message)", actions: [
                ("Retry", { [weak self] in self?.session.save(wait: true) }),
                ("Copy Text", { [weak self] in UIPasteboard.general.string = self?.textView.text }),
            ])
            problemBar.isHidden = false
        }
    }

    /// Opens the note that was open last time, with the caret at the end.
    func restoreLastNote() {
        let note = store.currentNoteID.flatMap { try? store.note(id: $0) }
        guard let note, note.deletedAt == nil else {
            session.load(nil)
            updateSaveNewButton()
            return
        }
        session.load(note)
        textView.setPlainText(note.text)
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        needsInitialScroll = true
        updateSaveNewButton()
    }

    func focusCanvas() {
        if preview == nil {
            textView.becomeFirstResponder()
        } else {
            previewTextView.becomeFirstResponder()
        }
    }

    /// Whether the canvas has anything besides whitespace. Stops at the first such character.
    private var canvasHasText: Bool {
        textView.textStorage.mutableString.rangeOfCharacter(from: Self.nonWhitespace).location != NSNotFound
    }

    var canFileAway: Bool {
        preview == nil && canvasHasText
    }

    /// ⌘↩, Save+New and the + button: saves this note (with a version) and starts a new, empty one
    /// at the top of the sidebar. ⌘Z (or the Undo button) right after brings the previous note back.
    /// Returns the new note, or nil if the canvas was already an empty note.
    @discardableResult
    func startNewNote() -> NoteID? {
        exitPreview()
        let hasText = canvasHasText
        if !hasText, session.noteID != nil { return nil }
        if textView.markedTextRange != nil { textView.unmarkText() }
        // Wait for the save so the filed note is dated before the new one.
        guard session.save(version: .ifChanged, wait: true).isSaved else {
            if case .failed(let message, let copy) = session.outcome { tellUnsaved(message: message, copy: copy) }
            return nil
        }
        let previous = session.noteID
        guard let id = try? store.createNote() else { return nil }
        guard open(noteID: id) else { return nil }
        if let previous, hasText {
            textView.undoManager?.registerUndo(withTarget: self) { editor in
                editor.open(noteID: previous, caretAtEnd: true)
            }
            textView.undoManager?.setActionName("New Note")
            offerUndo(of: previous)
        }
        return id
    }

    // MARK: Saving

    /// Saves now, with a version if anything changed, waiting for every write so far. Used on quit.
    @discardableResult
    func flush() -> NoteSession.Outcome {
        session.save(version: .ifChanged, wait: true)
    }

    func saveSoon() {
        session.save()
    }

    /// Sync: writes any pending typing to the database before returning (no extra version),
    /// and waits for saves already on their way.
    func flushPendingSave() {
        session.save(wait: true)
    }

    /// The app is going to the background: write now and wait, since it may never come back. If it fails,
    /// the text is in a recovery copy.
    func saveForBackground() {
        session.save(wait: true)
    }

    /// True while there's typing the database hasn't seen yet.
    var hasUnsavedChanges: Bool { session.isDirty }

    /// Sync: the open note may have changed on another device. If nothing was typed since the
    /// last save, shows the stored text in place, keeping the cursor and scroll position.
    /// Returns true if the canvas changed.
    @discardableResult
    func reloadCurrentNoteIfUnchanged() -> Bool {
        guard let id = session.noteID, textView.markedTextRange == nil else { return false }
        session.waitForSaves()
        let stored: Note?
        do {
            stored = try store.note(id: id)
        } catch {
            return false
        }
        guard let note = stored, note.deletedAt == nil else {
            // Deleted elsewhere. Unsaved typing here is kept as a new note by the next save; otherwise the
            // canvas starts blank (the note is in Recently Deleted).
            if session.isDirty {
                session.save()
                return false
            }
            open(noteID: nil)
            return true
        }
        guard !session.isDirty else { return false }
        let old = textView.textStorage.string
        guard old != note.text else { return false }
        let selection = TextDiff.map(textView.selectedRange, from: old as NSString, to: note.text as NSString)
        let offset = textView.contentOffset
        session.load(note)
        textView.setPlainText(note.text)
        textView.undoManager?.removeAllActions()
        textView.selectedRange = selection
        textView.layoutIfNeeded()
        let maxY = max(0, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(CGPoint(x: 0, y: min(offset.y, maxY)), animated: false)
        updateSaveNewButton()
        delegate?.editorDidChangeText(self)
        return true
    }

    // MARK: Text changes

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === self.textView else { return false }
        session.record(replacing: range, in: self.textView.textStorage.mutableString, with: text)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView === self.textView else { return }
        textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? EditorTextView)?.reassertTypingAttributes()
    }

    private func textDidChange() {
        session.textDidChange()
        // Typing ends the Undo offer; the button goes back to Save+New.
        if filedNoteID != nil { endUndoOffer() } else { updateSaveNewButton() }
        delegate?.editorDidChangeText(self)
    }

    /// Replaces several ranges (ascending, not overlapping) as one undoable step: Replace,
    /// Replace All, appends. Undo puts the old text back the same way, and redo works too.
    func replace(_ ranges: [NSRange], with strings: [String], actionName: String) {
        guard !ranges.isEmpty, ranges.count == strings.count else { return }
        if textView.markedTextRange != nil { textView.unmarkText() }
        let storage = textView.textStorage
        let before = storage.mutableString
        var restored: [NSRange] = []
        var originals: [String] = []
        var shift = 0
        for (range, string) in zip(ranges, strings) {
            session.record(replacing: range, in: before, with: string)
            originals.append(before.substring(with: range))
            let length = (string as NSString).length
            restored.append(NSRange(location: range.location + shift, length: length))
            shift += length - range.length
        }
        storage.beginEditing()
        for (range, string) in zip(ranges, strings).reversed() {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: textView.textAttributes))
        }
        storage.endEditing()
        let undo = textView.undoManager
        undo?.registerUndo(withTarget: self) { editor in
            editor.replace(restored, with: originals, actionName: actionName)
        }
        undo?.setActionName(actionName)
        if let last = restored.last { textView.selectedRange = NSRange(location: NSMaxRange(last), length: 0) }
        textDidChange()
    }

    /// Saves a version of what's there now, before a big change. False if it couldn't be saved.
    @discardableResult
    func saveVersionBeforeChange() -> Bool {
        session.save(version: .always, wait: true).isSaved
    }

    /// blacktext://append: adds text to the end of the open note, undoably, with a version either side.
    func appendText(_ text: String) {
        exitPreview()
        guard saveVersionBeforeChange() else {
            if case .failed(let message, let copy) = session.outcome { tellUnsaved(message: message, copy: copy) }
            return
        }
        let existing = textView.textStorage.string
        let insertion = NoteEdits.separator(appendingTo: existing, newParagraph: true) + text
        replace([NSRange(location: textView.textStorage.length, length: 0)], with: [insertion], actionName: "Append")
        session.save(version: .always, wait: true)
        textView.revealSelection()
    }

    // MARK: Save+New

    private func saveNewTapped() {
        switch saveNewButton.mode {
        case .saveNew: delegate?.editorDidRequestNewNote(self)
        case .undo: undoFileAway()
        }
    }

    /// The Undo button: brings back the note Save+New just filed away, as ⌘Z does.
    func undoFileAway() {
        guard let previous = filedNoteID else { return }
        endUndoOffer()
        open(noteID: previous, caretAtEnd: true)
    }

    private func offerUndo(of noteID: NoteID) {
        filedNoteID = noteID
        saveNewButton.mode = .undo
        updateSaveNewButton()
        undoOffer?.cancel()
        undoOffer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(EditorController.undoOfferSeconds))
            guard !Task.isCancelled else { return }
            self?.endUndoOffer()
        }
    }

    private func endUndoOffer() {
        undoOffer?.cancel()
        undoOffer = nil
        filedNoteID = nil
        if saveNewButton.mode != .saveNew { saveNewButton.mode = .saveNew }
        updateSaveNewButton()
    }

    /// Hidden on an empty canvas and over previews; always there while it offers Undo.
    func updateSaveNewButton() {
        let visible = preview == nil && (saveNewButton.mode == .undo || canvasHasText)
        if saveNewButton.isHidden == visible { saveNewButton.isHidden = !visible }
    }

    // MARK: Text size

    func setFontSize(_ size: CGFloat) {
        Preferences.fontSize = size
        let active = activeTextView
        let anchor = active.scrollAnchor
        textView.applyFontSize(Preferences.fontSize)
        previewTextView.applyFontSize(Preferences.fontSize)
        active.layoutIfNeeded()
        active.restoreScrollAnchor(anchor)
        // Match marks move with the text.
        delegate?.editorDidChangeText(self)
    }

    /// Pinching the canvas changes the text size, a point at a time.
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartSize = Preferences.fontSize
        case .changed:
            let size = (pinchStartSize * recognizer.scale).rounded().clamped(to: Preferences.fontSizeRange)
            if size != Preferences.fontSize { setFontSize(size) }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Previews

    /// Shows a version or a deleted note read-only in place of the canvas.
    func showPreview(_ preview: Preview) {
        let text: String
        let label: String
        let actions: [(String, () -> Void)]
        switch preview {
        case .version(let version):
            guard let loaded = try? store.version(id: version.id) else { return }
            text = loaded.text
            let by = version.agentName.map { " · by \($0)" } ?? ""
            label = "\(Format.dateTime(version.createdAt)) · \(Format.words(version.wordCount))\(by)"
            actions = [
                ("Copy", { [weak self] in self?.copyPreview() }),
                ("New Note from This", { [weak self] in self?.newNoteFromPreview() }),
                ("Done", { [weak self] in self?.closePreview() }),
            ]
        case .deleted(let note):
            guard let loaded = try? store.note(id: note.id) else { return }
            text = loaded.text
            label = "Deleted \(Format.dateTime(note.deletedAt ?? Date())) · \(Format.words(note.wordCount))"
            actions = [
                ("Put Back", { [weak self] in self?.putBackPreview() }),
                ("Done", { [weak self] in self?.closePreview() }),
            ]
        }
        if self.preview == nil { session.save() }
        endUndoOffer()
        // Read-only: put the keyboard away.
        if textView.isFirstResponder { textView.resignFirstResponder() }
        self.preview = preview
        previewText = text
        previewTextView.setPlainText(text)
        previewTextView.selectedRange = NSRange(location: 0, length: 0)
        previewTextView.setContentOffset(.zero, animated: false)
        previewBar.configure(text: label, actions: actions)
        previewBar.isHidden = false
        previewTextView.isHidden = false
        textView.isHidden = true
        updateSaveNewButton()
        delegate?.editorDidChangeText(self)
    }

    func exitPreview() {
        guard preview != nil else { return }
        preview = nil
        previewTextView.clearFindHighlights()
        previewTextView.setPlainText("")
        previewBar.isHidden = true
        previewTextView.isHidden = true
        textView.isHidden = false
        updateSaveNewButton()
        delegate?.editorDidChangeText(self)
    }

    func closePreview() {
        let wasPreviewing = preview != nil
        exitPreview()
        if wasPreviewing { focusCanvas() }
    }

    private func copyPreview() {
        let selected = previewTextView.selectedRange
        let text = selected.length > 0 && NSMaxRange(selected) <= (previewText as NSString).length
            ? (previewText as NSString).substring(with: selected) : previewText
        UIPasteboard.general.string = text
    }

    private func newNoteFromPreview() {
        let text = previewText
        guard let id = try? store.createNote(text: text, versionSource: "user") else { return }
        delegate?.editor(self, didCreate: id)
        open(noteID: id, caretAtEnd: true)
        focusCanvas()
    }

    private func putBackPreview() {
        guard case .deleted(let note) = preview else { return }
        try? store.putBack(noteID: note.id)
        onPutBack?(note.id)
    }
}
