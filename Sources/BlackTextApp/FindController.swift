import AppKit
import BlackTextCore

/// A counter other threads can check to see if their search is still wanted.
final class Generation: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == value
    }
}

/// Find & replace: live as you type, one at a time or all at once, in this note or across all notes.
final class FindController: NSObject, NSTextFieldDelegate {
    enum Scope { case note, allNotes }

    /// Notes up to this size are searched on the main thread, synchronously, on every keystroke.
    static let synchronousLimit = 200_000
    /// Matches shown in a note are counted up to this many (Replace All replaces them all regardless).
    static let matchLimit = 500_000

    let editor: EditorController
    let sidebar: SidebarController
    let searchStore: Store
    /// Built the first time it's needed, so it costs nothing at launch.
    private(set) lazy var bar: FindBar = {
        let bar = FindBar(target: self)
        bar.searchField.delegate = self
        bar.replaceField.delegate = self
        bar.isHidden = true
        editor.findBar = bar
        return bar
    }()

    private(set) var isVisible = false
    private(set) var scope: Scope = .note
    private var matches: [NSRange] = []
    private var current: Int?
    private var isInvalid = false
    /// The query the current matches are for.
    private var matchedQuery: FindQuery?
    private var searchOrigin = 0
    private let noteGeneration = Generation()
    private let allGeneration = Generation()
    private let noteQueue = DispatchQueue(label: "co.curry.blacktext.find", qos: .userInitiated)
    private let allQueue = DispatchQueue(label: "co.curry.blacktext.search", qos: .userInitiated)
    private var editDebounce: DispatchWorkItem?
    private var allDebounce: DispatchWorkItem?
    private var historyIndex: Int?
    private var lastQueryText = ""

    /// Shows the sidebar if it's hidden, for all-notes results.
    var showSidebar: (() -> Void)?
    var highlightAll = Preferences.highlightAll
    var options = FindOptions(matchCase: Preferences.matchCase, wholeWord: Preferences.wholeWord, regex: Preferences.regex)
    var preserveCase = Preferences.preserveCase

    init(editor: EditorController, sidebar: SidebarController, searchStore: Store) {
        self.editor = editor
        self.sidebar = sidebar
        self.searchStore = searchStore
        super.init()
        editor.marksView.onClick = { [weak self] fraction in self?.jump(toFraction: fraction) }
    }

    var query: FindQuery { FindQuery(isVisible ? bar.searchField.stringValue : lastQueryText, options: options) }

    // MARK: Showing and hiding

    func show(replace: Bool, scope: Scope) {
        let textView = editor.activeTextView
        let selection = textView.selectedRange()
        if selection.length > 0, selection.length < 300 {
            let selected = (textView.string as NSString).substring(with: selection)
            if !selected.contains(where: \.isNewline) { bar.searchField.stringValue = selected }
        } else if !isVisible, bar.searchField.stringValue.isEmpty {
            bar.searchField.stringValue = lastQueryText
        }
        searchOrigin = selection.location
        bar.isReplaceVisible = replace
        let scopeChanged = self.scope != scope
        self.scope = scope
        historyIndex = nil
        syncToggles()

        if !isVisible {
            isVisible = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                bar.isHidden = false
                editor.view.layoutSubtreeIfNeeded()
            }
        }
        editor.view.window?.makeFirstResponder(bar.searchField)
        bar.searchField.currentEditor()?.selectAll(nil)
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes {
            searchAllNotes(debounce: false)
        } else if scopeChanged {
            sidebar.showNotes()
        }
    }

    /// Closes the bar, leaving the current match selected so typing replaces it.
    func hide() {
        guard isVisible else { return }
        // Anything still searching is for a bar that's gone.
        _ = noteGeneration.next()
        _ = allGeneration.next()
        editDebounce?.cancel()
        allDebounce?.cancel()
        commitHistory()
        lastQueryText = bar.searchField.stringValue
        let textView = editor.activeTextView
        if let index = current, matches.indices.contains(index) {
            textView.setSelectedRange(matches[index])
        }
        clearHighlights()
        isVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.allowsImplicitAnimation = true
            bar.isHidden = true
            editor.view.layoutSubtreeIfNeeded()
        }
        if scope == .allNotes {
            scope = .note
            sidebar.showNotes()
        }
        editor.focusCanvas()
    }

    private func clearHighlights() {
        matchedQuery = nil
        editor.textView.clearFindHighlights()
        editor.previewTextView.clearFindHighlights()
        editor.marksView.marks = []
        editor.marksView.current = nil
        matches = []
        current = nil
    }

    // MARK: Searching this note

    /// Re-runs the search on the visible text. `anchor` picks the first match at or after a position.
    func recompute(anchor: Int?, reveal: Bool) {
        guard isVisible else { return }
        let generation = noteGeneration.next()
        let query = self.query
        let textView = editor.activeTextView
        guard !query.isEmpty else {
            apply([], invalid: false, anchor: nil, reveal: false)
            return
        }
        let text = textView.string as NSString
        if text.length <= Self.synchronousLimit {
            do {
                apply(try FindEngine.matches(of: query, in: text), invalid: false, anchor: anchor, reveal: reveal)
            } catch {
                apply([], invalid: true, anchor: nil, reveal: false)
            }
            return
        }
        let snapshot = text.copy() as! NSString
        let generations = noteGeneration
        noteQueue.async { [weak self] in
            let result = Result { try FindEngine.matches(of: query, in: snapshot, isCancelled: { !generations.isCurrent(generation) }) }
            DispatchQueue.main.async {
                guard let self, generations.isCurrent(generation) else { return }
                switch result {
                case .success(let ranges): self.apply(ranges, invalid: false, anchor: anchor, reveal: reveal)
                case .failure: self.apply([], invalid: true, anchor: nil, reveal: false)
                }
            }
        }
    }

    private func apply(_ ranges: [NSRange], invalid: Bool, anchor: Int?, reveal: Bool) {
        matches = ranges
        matchedQuery = query
        isInvalid = invalid
        if ranges.isEmpty {
            current = nil
        } else if let anchor {
            current = ranges.firstIndex { $0.location >= anchor } ?? 0
        } else if let index = current {
            current = min(index, ranges.count - 1)
        } else {
            current = 0
        }
        let textView = editor.activeTextView
        textView.setFindHighlights(ranges, current: current, highlightAll: highlightAll)
        updateCount()
        updateMarks()
        if reveal, let index = current { textView.reveal(ranges[index]) }
    }

    private func updateCount() {
        let label: String
        if isInvalid {
            label = "invalid"
        } else if query.isEmpty {
            label = ""
        } else if matches.isEmpty {
            label = "No results"
        } else {
            // Counting stops at FindEngine's limit; say so rather than give a wrong total.
            let more = matches.count >= Self.matchLimit ? "+" : ""
            label = "\(Format.number((current ?? 0) + 1)) of \(Format.number(matches.count))\(more)"
        }
        bar.countLabel.stringValue = label
        let canReplace = editor.preview == nil && !matches.isEmpty
        bar.replaceButton.isEnabled = canReplace
        bar.replaceAllButton.isEnabled = canReplace
        let more = matches.count >= Self.matchLimit ? "+" : ""
        bar.replaceAllButton.setText(matches.isEmpty ? "Replace All" : "Replace All (\(Format.number(matches.count))\(more))")
    }

    private func updateMarks() {
        let textView = editor.activeTextView
        let length = (textView.string as NSString).length
        guard !matches.isEmpty, length > 0 else {
            editor.marksView.marks = []
            editor.marksView.current = nil
            return
        }
        var positions: [CGFloat]
        if length <= Self.synchronousLimit, matches.count <= 5_000,
           let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let height = max(1, textView.bounds.height)
            positions = matches.map { range in
                let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return ((line.midY + textView.textContainerOrigin.y) / height).clamped(to: 0...1)
            }
        } else {
            positions = matches.map { CGFloat($0.location) / CGFloat(length) }
        }
        editor.marksView.marks = positions
        editor.marksView.current = current.map { positions[$0] }
    }

    private func jump(toFraction fraction: CGFloat) {
        let marks = editor.marksView.marks
        guard !marks.isEmpty else { return }
        let nearest = marks.indices.min { abs(marks[$0] - fraction) < abs(marks[$1] - fraction) }!
        select(nearest)
    }

    private func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        current = index
        let textView = editor.activeTextView
        textView.setFindHighlights(matches, current: current, highlightAll: highlightAll)
        textView.reveal(matches[index])
        updateCount()
        editor.marksView.current = editor.marksView.marks.indices.contains(index) ? editor.marksView.marks[index] : nil
    }

    func step(forward: Bool) {
        if !isVisible {
            findWithBarClosed(forward: forward)
            return
        }
        if matchedQuery != query {
            // The field changed without a keystroke (dictation, accessibility): search first.
            lastQueryText = bar.searchField.stringValue
            recompute(anchor: searchOrigin, reveal: true)
            if scope == .allNotes { searchAllNotes(debounce: false) }
            return
        }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        commitHistory()
        let count = matches.count
        let index = current.map { forward ? ($0 + 1) % count : ($0 - 1 + count) % count } ?? 0
        select(index)
    }

    /// ⌘G with the bar closed: select the next match of the last search.
    private func findWithBarClosed(forward: Bool) {
        let query = self.query
        guard !query.isEmpty else {
            show(replace: false, scope: .note)
            return
        }
        let textView = editor.activeTextView
        guard let ranges = try? FindEngine.matches(of: query, in: textView.string as NSString), !ranges.isEmpty else {
            NSSound.beep()
            return
        }
        let selection = textView.selectedRange()
        let target = forward
            ? ranges.first { $0.location >= NSMaxRange(selection) } ?? ranges[0]
            : ranges.last { NSMaxRange($0) <= selection.location } ?? ranges[ranges.count - 1]
        textView.setSelectedRange(target)
        textView.reveal(target)
    }

    func useSelection() {
        let textView = editor.activeTextView
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let text = (textView.string as NSString).substring(with: selection)
        bar.searchField.stringValue = text
        lastQueryText = text
        if isVisible {
            recompute(anchor: selection.location, reveal: false)
            if scope == .allNotes { searchAllNotes(debounce: false) }
        }
    }

    /// The canvas changed (typing, or another note opened): refresh matches without jumping.
    func editorTextDidChange() {
        guard isVisible else { return }
        // A search still running is for the old text; its ranges mustn't land on the new one.
        _ = noteGeneration.next()
        editDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let anchor = self.current.flatMap { self.matches.indices.contains($0) ? self.matches[$0].location : nil }
            self.recompute(anchor: anchor, reveal: false)
        }
        editDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// A different note is in the canvas: show its matches from the top.
    func editorDidOpenNote() {
        guard isVisible else { return }
        editDebounce?.cancel()
        recompute(anchor: 0, reveal: true)
    }

    // MARK: Replace

    @objc func replaceCurrent(_ sender: Any?) {
        guard editor.preview == nil, isVisible else { NSSound.beep(); return }
        // Make sure the match is still where we think it is.
        let anchor = current.flatMap { matches.indices.contains($0) ? matches[$0].location : nil } ?? searchOrigin
        let text = editor.textView.string as NSString
        guard let ranges = try? FindEngine.matches(of: query, in: text), !ranges.isEmpty else { NSSound.beep(); return }
        let range = ranges.first { $0.location >= anchor } ?? ranges[0]
        let regex = try? FindEngine.regex(for: query)
        let piece = FindEngine.replacement(for: range, in: text, query: query, template: bar.replaceField.stringValue,
                                           preserveCase: preserveCase, regex: regex ?? nil)
        editor.replace([range], with: [piece], actionName: "Replace")
        editDebounce?.cancel()
        recompute(anchor: range.location + (piece as NSString).length, reveal: true)
    }

    @objc func replaceAll(_ sender: Any?) {
        guard editor.preview == nil, isVisible else { NSSound.beep(); return }
        let query = self.query
        let template = bar.replaceField.stringValue
        let text = editor.textView.string as NSString
        guard let ranges = try? FindEngine.matches(of: query, in: text, limit: .max), !ranges.isEmpty else { NSSound.beep(); return }
        let regex = try? FindEngine.regex(for: query)
        let pieces = ranges.map {
            FindEngine.replacement(for: $0, in: text, query: query, template: template, preserveCase: preserveCase, regex: regex ?? nil)
        }
        editor.saveVersionBeforeChange()
        editor.replace(ranges, with: pieces, actionName: "Replace All")
        commitHistory()
        editDebounce?.cancel()
        recompute(anchor: nil, reveal: false)
    }

    // MARK: All notes

    private func searchAllNotes(debounce: Bool) {
        allDebounce?.cancel()
        let query = self.query
        let generation = allGeneration.next()
        let generations = allGeneration
        guard !query.isEmpty else {
            sidebar.showResults([], query: "")
            return
        }
        let store = searchStore
        let work = DispatchWorkItem { [weak self] in
            // Search what's in the canvas too, not just what was saved a moment ago.
            self?.editor.session.save(version: .never, wait: true)
            self?.allQueue.async {
                let hits = (try? store.search(query, limit: 200, isCancelled: { !generations.isCurrent(generation) })) ?? []
                DispatchQueue.main.async {
                    guard let self, generations.isCurrent(generation), self.isVisible, self.scope == .allNotes else { return }
                    self.sidebar.showResults(hits, query: query.text)
                }
            }
        }
        allDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.08 : 0), execute: work)
    }

    // MARK: Toggles

    private func syncToggles() {
        bar.oneToggle.isOn = !highlightAll
        bar.allToggle.isOn = highlightAll
        bar.caseToggle.isOn = options.matchCase
        bar.wordToggle.isOn = options.wholeWord
        bar.regexToggle.isOn = options.regex
        bar.preserveCaseToggle.isOn = preserveCase
        bar.noteScopeToggle.isOn = scope == .note
        bar.allNotesScopeToggle.isOn = scope == .allNotes
    }

    private func optionsChanged() {
        Preferences.matchCase = options.matchCase
        Preferences.wholeWord = options.wholeWord
        Preferences.regex = options.regex
        syncToggles()
        recompute(anchor: current.flatMap { matches.indices.contains($0) ? matches[$0].location : nil }, reveal: false)
        if scope == .allNotes { searchAllNotes(debounce: false) }
    }

    @objc func chooseOneAtATime(_ sender: Any?) { setHighlightAll(false) }
    @objc func chooseHighlightAll(_ sender: Any?) { setHighlightAll(true) }

    func toggleHighlightAll() { setHighlightAll(!highlightAll) }

    private func setHighlightAll(_ value: Bool) {
        highlightAll = value
        Preferences.highlightAll = value
        syncToggles()
        editor.activeTextView.setFindHighlights(matches, current: current, highlightAll: highlightAll)
    }

    @objc func toggleMatchCase(_ sender: Any?) { options.matchCase.toggle(); optionsChanged() }
    @objc func toggleWholeWord(_ sender: Any?) { options.wholeWord.toggle(); optionsChanged() }
    @objc func toggleRegex(_ sender: Any?) { options.regex.toggle(); optionsChanged() }

    @objc func togglePreserveCase(_ sender: Any?) {
        preserveCase.toggle()
        Preferences.preserveCase = preserveCase
        syncToggles()
    }

    @objc func chooseNoteScope(_ sender: Any?) {
        guard scope != .note else { return }
        scope = .note
        syncToggles()
        sidebar.showNotes()
    }

    @objc func chooseAllNotesScope(_ sender: Any?) {
        guard scope != .allNotes else { return }
        scope = .allNotes
        syncToggles()
        showSidebar?()
        searchAllNotes(debounce: false)
    }

    /// Notes changed (a save, another device, an agent): all-notes results may be out of date.
    func notesDidChange() {
        guard isVisible, scope == .allNotes else { return }
        searchAllNotes(debounce: true)
    }

    @objc func previousMatch(_ sender: Any?) { step(forward: false) }
    @objc func nextMatch(_ sender: Any?) { step(forward: true) }
    @objc func close(_ sender: Any?) { hide() }

    // MARK: History

    private func commitHistory() {
        let text = bar.searchField.stringValue
        guard !text.isEmpty else { return }
        var history = Preferences.findHistory
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        Preferences.findHistory = history
    }

    private func moveInHistory(older: Bool) {
        let history = Preferences.findHistory
        guard !history.isEmpty else { return }
        let next: Int? = older
            ? min((historyIndex ?? -1) + 1, history.count - 1)
            : historyIndex.flatMap { $0 > 0 ? $0 - 1 : nil }
        historyIndex = next
        bar.searchField.stringValue = next.map { history[$0] } ?? ""
        bar.searchField.currentEditor()?.selectAll(nil)
        recompute(anchor: searchOrigin, reveal: true)
    }

    // MARK: Field delegate

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === bar.searchField else { return }
        historyIndex = nil
        lastQueryText = bar.searchField.stringValue
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes { searchAllNotes(debounce: true) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let isSearch = control === bar.searchField
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if isSearch {
                step(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            } else {
                replaceCurrent(nil)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard isSearch else { return false }
            let down = selector == #selector(NSResponder.moveDown(_:))
            if scope == .allNotes {
                sidebar.moveSelection(by: down ? 1 : -1)
            } else {
                moveInHistory(older: !down)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if isSearch, bar.isReplaceVisible {
                control.window?.makeFirstResponder(bar.replaceField)
            } else {
                editor.focusCanvas()
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if !isSearch { control.window?.makeFirstResponder(bar.searchField) }
            return true
        default:
            return false
        }
    }
}
