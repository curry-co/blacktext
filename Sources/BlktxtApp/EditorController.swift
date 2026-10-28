import AppKit
import BlktxtCore

protocol EditorControllerDelegate: AnyObject {
    func editor(_ editor: EditorController, didOpen noteID: NoteID?)
    func editor(_ editor: EditorController, didSave summary: NoteSummary)
    func editor(_ editor: EditorController, didDiscard noteID: NoteID)
    func editorDidChangeText(_ editor: EditorController)
    func editorDidRequestEscape(_ editor: EditorController) -> Bool
}

/// The right side of the window: the canvas, the find bar above it, and read-only previews.
final class EditorController: NSViewController, NSTextViewDelegate, EditorTextViewDelegate {
    enum Preview: Equatable {
        case version(VersionSummary)
        case deleted(NoteSummary)
    }

    let store: Store
    let session: NoteSession
    weak var delegate: EditorControllerDelegate?

    let textView = EditorTextView.make()
    let previewTextView = EditorTextView.make()
    private let scrollView = NSScrollView()
    private let previewScrollView = NSScrollView()
    let marksView = MatchMarksView()
    let previewBar = PreviewBar()
    private let stack = NSStackView()
    private(set) var preview: Preview?
    private var previewText = ""

    /// Remembered caret per note for this session.
    private var selections: [NoteID: NSRange] = [:]

    var findBar: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let findBar { stack.insertArrangedSubview(findBar, at: 0) }
        }
    }

    init(store: Store, saveStore: Store) {
        self.store = store
        session = NoteSession(store: store, saveStore: saveStore)
        super.init(nibName: nil, bundle: nil)
        session.text = { [weak self] in self?.textView.string ?? "" }
        session.onSaved = { [weak self] summary in
            guard let self else { return }
            delegate?.editor(self, didSave: summary)
        }
        session.onDiscarded = { [weak self] id in
            guard let self else { return }
            delegate?.editor(self, didDiscard: id)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var noteID: NoteID? { session.noteID }

    /// The text view find works on: the preview when one is showing.
    var activeTextView: EditorTextView { preview == nil ? textView : previewTextView }

    var isCanvasFocused: Bool { view.window?.firstResponder === textView && preview == nil }

    override func loadView() {
        let root = FillView(color: Palette.background)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let canvas = NSView()
        for (scroll, text) in [(scrollView, textView), (previewScrollView, previewTextView)] {
            scroll.drawsBackground = true
            scroll.backgroundColor = Palette.background
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.documentView = text
            scroll.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: canvas.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            ])
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            text.editorDelegate = self
        }
        textView.delegate = self
        textView.setAccessibilityLabel("Note")
        previewTextView.isEditable = false
        previewTextView.setAccessibilityLabel("Version preview")
        previewScrollView.isHidden = true

        marksView.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(marksView)
        NSLayoutConstraint.activate([
            marksView.topAnchor.constraint(equalTo: canvas.topAnchor),
            marksView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            marksView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            marksView.widthAnchor.constraint(equalToConstant: 14),
        ])

        previewBar.isHidden = true
        stack.addArrangedSubview(previewBar)
        stack.addArrangedSubview(canvas)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    @objc private func didScroll(_ note: Notification) {
        activeTextView.refreshMatchColors()
    }

    // MARK: Opening notes

    /// Opens a note in the canvas (nil = blank canvas). What was there is saved first.
    func open(noteID: NoteID?, caretAtEnd: Bool = false, select range: NSRange? = nil) {
        exitPreview()
        if let current = session.noteID {
            if current == noteID { return }
            selections[current] = textView.selectedRange()
        }
        session.leave()
        session.waitForSaves()

        let note = noteID.flatMap { try? store.note(id: $0) }.flatMap { $0.deletedAt == nil ? $0 : nil }
        session.load(note)
        textView.setPlainText(note?.text ?? "")
        textView.undoManager?.removeAllActions()

        let length = (textView.string as NSString).length
        var selection = range ?? (caretAtEnd ? NSRange(location: length, length: 0) : nil)
            ?? note.flatMap { selections[$0.id] } ?? NSRange(location: 0, length: 0)
        if NSMaxRange(selection) > length { selection = NSRange(location: length, length: 0) }
        textView.setSelectedRange(selection)
        if selection.location == 0 {
            textView.scroll(.zero)
        } else {
            textView.scrollRangeToVisible(selection)
        }
        delegate?.editor(self, didOpen: note?.id)
    }

    /// Opens the note that was open last time, with the caret at the end.
    func restoreLastNote() {
        let id = store.currentNoteID
        let note = id.flatMap { try? store.note(id: $0) }
        guard let note, note.deletedAt == nil else {
            session.load(nil)
            return
        }
        session.load(note)
        textView.setPlainText(note.text)
        let end = NSRange(location: (note.text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    func focusCanvas() {
        view.window?.makeFirstResponder(preview == nil ? textView : previewTextView)
    }

    var canFileAway: Bool {
        preview == nil && !textView.string.allSatisfy(\.isWhitespace)
    }

    /// ⌘↩ and the + button: saves this note (with a version) and starts a new, empty one at the top
    /// of the sidebar. ⌘Z right after brings the previous note back. Returns the new note, or nil if
    /// the canvas was already an empty note.
    @discardableResult
    func startNewNote() -> NoteID? {
        exitPreview()
        let hasText = !textView.string.allSatisfy(\.isWhitespace)
        if !hasText, session.noteID != nil { return nil }
        if textView.hasMarkedText() { textView.unmarkText() }
        // Wait for the save so the filed note is dated before the new one.
        session.save(version: .ifChanged, wait: true)
        let previous = session.noteID
        guard let id = try? store.createNote() else { return nil }
        open(noteID: id)
        if let previous, hasText {
            textView.undoManager?.registerUndo(withTarget: self) { editor in
                editor.open(noteID: previous, caretAtEnd: true)
            }
            textView.undoManager?.setActionName("New Note")
        }
        return id
    }

    /// Saves now, waiting for the write. Used on quit.
    func flush() {
        session.save(version: .ifChanged, wait: true)
    }

    func saveSoon() {
        session.save()
    }

    // MARK: Text changes

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let text = textView.string as NSString
        for (index, value) in affectedRanges.enumerated() {
            session.record(replacing: value.rangeValue, in: text, with: replacementStrings?[index] ?? "")
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        session.textDidChange()
        delegate?.editorDidChangeText(self)
    }

    func editorTextViewDidCancel(_ textView: EditorTextView) -> Bool {
        if delegate?.editorDidRequestEscape(self) == true { return true }
        if preview != nil {
            exitPreview()
            return true
        }
        return false
    }

    /// Replaces several ranges as one undoable step (Replace, Replace All, agent edits).
    func replace(_ ranges: [NSRange], with strings: [String], actionName: String) {
        guard !ranges.isEmpty, let storage = textView.textStorage else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        let undo = textView.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        if textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings) {
            storage.beginEditing()
            for (range, string) in zip(ranges, strings).reversed() {
                storage.replaceCharacters(in: range, with: string)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        undo?.endUndoGrouping()
        undo?.setActionName(actionName)
        textView.breakUndoCoalescing()
    }

    /// Saves a version of what's there now, before a big change.
    func saveVersionBeforeChange() {
        session.save(version: .always, wait: true)
    }

    // MARK: Text size

    func setFontSize(_ size: CGFloat) {
        Preferences.fontSize = size
        textView.applyFontSize(Preferences.fontSize)
        previewTextView.applyFontSize(Preferences.fontSize)
    }

    func setSpellChecking(_ enabled: Bool) {
        Preferences.spellCheck = enabled
        textView.setSpellChecking(enabled)
    }

    // MARK: Previews

    /// Shows a version or a deleted note read-only in place of the canvas.
    func showPreview(_ preview: Preview) {
        let text: String
        let label: String
        let actions: [(String, Selector)]
        switch preview {
        case .version(let version):
            guard let loaded = try? store.version(id: version.id) else { return }
            text = loaded.text
            let by = version.agentName.map { " · by \($0)" } ?? ""
            label = "\(Format.dateTime(version.createdAt)) · \(Format.words(version.wordCount))\(by)"
            actions = [("Copy", #selector(copyPreview(_:))), ("New Note from This", #selector(newNoteFromPreview(_:))),
                       ("Done", #selector(closePreview(_:)))]
        case .deleted(let note):
            guard let loaded = try? store.note(id: note.id) else { return }
            text = loaded.text
            label = "Deleted \(Format.dateTime(note.deletedAt ?? Date())) · \(Format.words(note.wordCount))"
            actions = [("Put Back", #selector(putBackPreview(_:))), ("Done", #selector(closePreview(_:)))]
        }
        if self.preview == nil { session.save() }
        self.preview = preview
        previewText = text
        previewTextView.setPlainText(text)
        previewTextView.setSelectedRange(NSRange(location: 0, length: 0))
        previewTextView.scroll(.zero)
        previewBar.configure(text: label, actions: actions, target: self)
        previewBar.isHidden = false
        previewScrollView.isHidden = false
        scrollView.isHidden = true
        delegate?.editorDidChangeText(self)
    }

    func exitPreview() {
        guard preview != nil else { return }
        preview = nil
        previewTextView.clearFindHighlights()
        previewTextView.setPlainText("")
        previewBar.isHidden = true
        previewScrollView.isHidden = true
        scrollView.isHidden = false
        delegate?.editorDidChangeText(self)
    }

    var onPutBack: ((NoteID) -> Void)?

    @objc func closePreview(_ sender: Any?) {
        let wasPreviewing = preview != nil
        exitPreview()
        if wasPreviewing { view.window?.makeFirstResponder(textView) }
    }

    @objc func copyPreview(_ sender: Any?) {
        let selected = previewTextView.selectedRange()
        let text = selected.length > 0 ? (previewText as NSString).substring(with: selected) : previewText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func newNoteFromPreview(_ sender: Any?) {
        let text = previewText
        guard let id = try? store.createNote(text: text) else { return }
        _ = try? store.addVersion(noteID: id, text: text)
        open(noteID: id, caretAtEnd: true)
        focusCanvas()
    }

    @objc func putBackPreview(_ sender: Any?) {
        guard case .deleted(let note) = preview else { return }
        try? store.putBack(noteID: note.id)
        onPutBack?(note.id)
    }

    // MARK: Agent edits

    /// Applies an agent's edit. Edits to the open note go through the text view so they're
    /// live and undoable and never clobber typing; other notes are edited in the database.
    func apply(_ op: AgentOp) -> AgentResult {
        let targetsCanvas = op.noteID == nil || op.noteID == session.noteID
        guard targetsCanvas else {
            session.waitForSaves()
            return (try? store.applyDirectly(op)) ?? .failure("Could not apply the edit.")
        }
        switch op.edit {
        case .flush:
            session.save(wait: true)
            return .success(noteID: session.noteID)

        case let .append(text, newParagraph):
            saveVersionBeforeChange()
            let existing = textView.string
            let insertion = NoteEdits.separator(appendingTo: existing, newParagraph: newParagraph) + text
            let end = NSRange(location: (existing as NSString).length, length: 0)
            replace([end], with: [insertion], actionName: "Agent Edit")
            session.save(version: .always, source: op.source, wait: true)
            return .success(noteID: session.noteID)

        case let .replace(find, template, options, all, preserveCase):
            let query = FindQuery(find, options: options)
            let text = textView.string as NSString
            let regex: NSRegularExpression?
            var ranges: [NSRange]
            do {
                regex = try FindEngine.regex(for: query)
                ranges = try FindEngine.matches(of: query, in: text)
            } catch {
                return .failure("Invalid regular expression: \(find)")
            }
            if !all { ranges = Array(ranges.prefix(1)) }
            guard !ranges.isEmpty else { return .success(noteID: session.noteID, replacements: 0) }
            saveVersionBeforeChange()
            let pieces = ranges.map {
                FindEngine.replacement(for: $0, in: text, query: query, template: template, preserveCase: preserveCase, regex: regex)
            }
            replace(ranges, with: pieces, actionName: "Agent Edit")
            session.save(version: .always, source: op.source, wait: true)
            return .success(noteID: session.noteID, replacements: ranges.count)
        }
    }
}

enum Format {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let dayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func number(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func words(_ count: Int) -> String {
        "\(number(count)) \(count == 1 ? "word" : "words")"
    }

    /// "2:14 PM" today, "Monday" this week, "Apr 12" this year, "Apr 12, 2024" before.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) { return timeFormatter.string(from: date) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return weekdayFormatter.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return dayFormatter.string(from: date) }
        return dayYearFormatter.string(from: date)
    }

    /// Version rows: "2:14 PM" today, otherwise like `dateTime`.
    static func versionTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dateTime(date)
    }

    /// "Today, 2:14 PM", "Apr 12, 4:20 PM", "Apr 12, 2024, 4:20 PM".
    static func dateTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(dayFormatter.string(from: date)), \(time)"
        }
        return "\(dayYearFormatter.string(from: date)), \(time)"
    }
}
