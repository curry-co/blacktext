import UIKit
import BlackTextCore

@MainActor
protocol FindControllerHost: AnyObject {
    /// The scope switched between this note and all notes (the sidebar shows results for all notes).
    func findDidChangeScope(_ find: FindController)
}

/// Find & replace: live as you type, one at a time or all at once, in this note or across all notes.
@MainActor
final class FindController: NSObject, UITextFieldDelegate {
    enum Scope { case note, allNotes }

    /// Notes up to this size are searched on the main thread, synchronously, on every keystroke.
    static let synchronousLimit = 200_000

    let editor: EditorController
    let sidebar: SidebarController
    let searchStore: Store
    weak var host: FindControllerHost?

    /// Built the first time it's needed, so it costs nothing at launch.
    private(set) lazy var bar: FindBar = {
        let bar = FindBar(controller: self)
        bar.searchField.delegate = self
        bar.replaceField.delegate = self
        bar.searchField.returnKeyType = .search
        bar.searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        bar.searchField.onCommand = { [weak self] command in self?.handle(command, inSearchField: true) }
        bar.replaceField.onCommand = { [weak self] command in self?.handle(command, inSearchField: false) }
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
    private var editDebounce: Task<Void, Never>?
    private var allDebounce: Task<Void, Never>?
    private var historyIndex: Int?
    private var lastQueryText = ""

    private(set) var highlightAll = Preferences.highlightAll
    private(set) var options = FindOptions(matchCase: Preferences.matchCase, wholeWord: Preferences.wholeWord, regex: Preferences.regex)
    private(set) var preserveCase = Preferences.preserveCase

    init(editor: EditorController, sidebar: SidebarController, searchStore: Store) {
        self.editor = editor
        self.sidebar = sidebar
        self.searchStore = searchStore
        super.init()
        editor.marksView.onTap = { [weak self] fraction in self?.jump(toFraction: fraction) }
    }

    var query: FindQuery { FindQuery(isVisible ? (bar.searchField.text ?? "") : lastQueryText, options: options) }

    private var searchText: String { bar.searchField.text ?? "" }

    // MARK: Showing and hiding

    func show(replace: Bool, scope: Scope) {
        let textView = editor.activeTextView
        let selection = textView.selectedRange
        if selection.length > 0, selection.length < 300, NSMaxRange(selection) <= textView.textStorage.length {
            let selected = textView.textStorage.mutableString.substring(with: selection)
            if !selected.contains(where: \.isNewline) { bar.searchField.text = selected }
        } else if !isVisible, searchText.isEmpty {
            bar.searchField.text = lastQueryText
        }
        searchOrigin = selection.location == NSNotFound ? 0 : selection.location
        bar.isReplaceVisible = replace
        let scopeChanged = self.scope != scope
        self.scope = scope
        historyIndex = nil
        syncToggles()
        updateHistoryMenu()

        if !isVisible {
            isVisible = true
            UIView.animate(withDuration: 0.15) {
                self.bar.isHidden = false
                self.editor.view.layoutIfNeeded()
            }
        }
        bar.searchField.becomeFirstResponder()
        bar.selectAllSearchText()
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes {
            searchAllNotes(debounce: false)
        } else if scopeChanged {
            sidebar.showNotes()
        }
        if scopeChanged { host?.findDidChangeScope(self) }
    }

    /// Opens the bar already searching for `query`. Used only for CI's Simulator screenshots.
    func showForScreenshot(query: String) {
        show(replace: false, scope: .note)
        bar.searchField.text = query
        recompute(anchor: 0, reveal: true)
    }

    /// Closes the bar, leaving the current match selected so typing replaces it.
    func hide() {
        guard isVisible else { return }
        commitHistory()
        lastQueryText = searchText
        let textView = editor.activeTextView
        if let index = current, matches.indices.contains(index) {
            textView.selectedRange = matches[index]
        }
        clearHighlights()
        isVisible = false
        editDebounce?.cancel()
        allDebounce?.cancel()
        UIView.animate(withDuration: 0.12) {
            self.bar.isHidden = true
            self.editor.view.layoutIfNeeded()
        }
        if scope == .allNotes {
            scope = .note
            sidebar.showNotes()
            host?.findDidChangeScope(self)
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
        let text = textView.textStorage.mutableString
        if text.length <= Self.synchronousLimit {
            do {
                apply(try FindEngine.matches(of: query, in: text), invalid: false, anchor: anchor, reveal: reveal)
            } catch {
                apply([], invalid: true, anchor: nil, reveal: false)
            }
            return
        }
        // Large notes: search a copy off the main thread, dropping stale searches.
        let snapshot = (text.copy() as? NSString) ?? NSString()
        let generations = noteGeneration
        noteQueue.async { [weak self] in
            let result = Result { try FindEngine.matches(of: query, in: snapshot, isCancelled: { !generations.isCurrent(generation) }) }
            DispatchQueue.main.async { [weak self] in
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
            label = "\(Format.number((current ?? 0) + 1)) of \(Format.number(matches.count))"
        }
        bar.countLabel.text = label
        let canReplace = editor.preview == nil && !matches.isEmpty
        bar.replaceButton.isEnabled = canReplace
        bar.replaceAllButton.isEnabled = canReplace
        bar.replaceAllButton.setText(matches.isEmpty ? "Replace All" : "Replace All (\(Format.number(matches.count)))")
    }

    private func updateMarks() {
        let textView = editor.activeTextView
        let length = textView.textStorage.length
        guard !matches.isEmpty, length > 0 else {
            editor.marksView.marks = []
            editor.marksView.current = nil
            return
        }
        var positions: [CGFloat]
        if length <= Self.synchronousLimit, matches.count <= 5_000 {
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            layoutManager.ensureLayout(for: container)
            let inset = textView.textContainerInset
            let used = layoutManager.usedRect(for: container)
            // Short notes map onto the screen as they appear; long ones onto the whole note.
            let height = max(1, used.height + inset.top + inset.bottom, textView.bounds.height)
            positions = matches.map { range in
                let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return ((line.midY + inset.top) / height).clamped(to: 0...1)
            }
        } else {
            positions = matches.map { CGFloat($0.location) / CGFloat(length) }
        }
        editor.marksView.marks = positions
        editor.marksView.current = current.map { positions[$0] }
    }

    private func jump(toFraction fraction: CGFloat) {
        let marks = editor.marksView.marks
        guard let nearest = marks.indices.min(by: { abs(marks[$0] - fraction) < abs(marks[$1] - fraction) }) else { return }
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
            // The field changed without an edit event (dictation, accessibility): search first.
            lastQueryText = searchText
            recompute(anchor: searchOrigin, reveal: true)
            if scope == .allNotes { searchAllNotes(debounce: false) }
            return
        }
        guard !matches.isEmpty else { return }
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
        guard let ranges = try? FindEngine.matches(of: query, in: textView.textStorage.mutableString), !ranges.isEmpty else { return }
        let selection = textView.selectedRange
        let target = forward
            ? ranges.first { $0.location >= NSMaxRange(selection) } ?? ranges[0]
            : ranges.last { NSMaxRange($0) <= selection.location } ?? ranges[ranges.count - 1]
        textView.selectedRange = target
        textView.reveal(target)
    }

    /// ⌘E: the selected text becomes the search.
    func useSelection() {
        let textView = editor.activeTextView
        let selection = textView.selectedRange
        guard selection.length > 0, NSMaxRange(selection) <= textView.textStorage.length else { return }
        let text = textView.textStorage.mutableString.substring(with: selection)
        bar.searchField.text = text
        lastQueryText = text
        if isVisible {
            recompute(anchor: selection.location, reveal: false)
            if scope == .allNotes { searchAllNotes(debounce: false) }
        }
    }

    /// The canvas changed (typing, or another note opened): refresh matches without jumping.
    func editorTextDidChange() {
        guard isVisible else { return }
        editDebounce?.cancel()
        editDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let anchor = self.current.flatMap { self.matches.indices.contains($0) ? self.matches[$0].location : nil }
            self.recompute(anchor: anchor, reveal: false)
        }
    }

    /// A different note is in the canvas: show its matches from the top.
    func editorDidOpenNote() {
        guard isVisible else { return }
        editDebounce?.cancel()
        recompute(anchor: 0, reveal: true)
    }

    /// Sync changed the database: run the all-notes search again.
    func refreshAllNotes() {
        guard isVisible, scope == .allNotes else { return }
        searchAllNotes(debounce: false)
    }

    // MARK: Replace

    func replaceCurrent() {
        guard editor.preview == nil, isVisible else { return }
        // Make sure the match is still where we think it is.
        let anchor = current.flatMap { matches.indices.contains($0) ? matches[$0].location : nil } ?? searchOrigin
        let query = self.query
        let text = editor.textView.textStorage.mutableString
        guard let ranges = try? FindEngine.matches(of: query, in: text), !ranges.isEmpty else { return }
        let range = ranges.first { $0.location >= anchor } ?? ranges[0]
        let regex = try? FindEngine.regex(for: query)
        let piece = FindEngine.replacement(for: range, in: text, query: query, template: bar.replaceField.text ?? "",
                                           preserveCase: preserveCase, regex: regex)
        editor.replace([range], with: [piece], actionName: "Replace")
        editDebounce?.cancel()
        recompute(anchor: range.location + (piece as NSString).length, reveal: true)
    }

    /// Replace All: one undo step, with a version saved first.
    func replaceAll() {
        guard editor.preview == nil, isVisible else { return }
        let query = self.query
        let template = bar.replaceField.text ?? ""
        let text = editor.textView.textStorage.mutableString
        guard let ranges = try? FindEngine.matches(of: query, in: text), !ranges.isEmpty else { return }
        let regex = try? FindEngine.regex(for: query)
        let pieces = ranges.map {
            FindEngine.replacement(for: $0, in: text, query: query, template: template, preserveCase: preserveCase, regex: regex)
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
        guard !query.isEmpty else {
            sidebar.showResults([], query: "")
            return
        }
        allDebounce = Task { @MainActor [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled, let self else { return }
            self.runAllNotesSearch(query, generation: generation)
        }
    }

    /// Searches every note on a background connection; only the newest search gets shown.
    private func runAllNotesSearch(_ query: FindQuery, generation: Int) {
        let store = searchStore
        let generations = allGeneration
        allQueue.async { [weak self] in
            let hits = (try? store.search(query, limit: 200, isCancelled: { !generations.isCurrent(generation) })) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, generations.isCurrent(generation), self.isVisible, self.scope == .allNotes else { return }
                self.sidebar.showResults(hits, query: query.text)
            }
        }
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
        bar.replaceToggle.isOn = bar.isReplaceVisible
    }

    private func optionsChanged() {
        Preferences.matchCase = options.matchCase
        Preferences.wholeWord = options.wholeWord
        Preferences.regex = options.regex
        syncToggles()
        recompute(anchor: current.flatMap { matches.indices.contains($0) ? matches[$0].location : nil }, reveal: false)
        if scope == .allNotes { searchAllNotes(debounce: false) }
    }

    func toggleHighlightAll() { setHighlightAll(!highlightAll) }

    func setHighlightAll(_ value: Bool) {
        highlightAll = value
        Preferences.highlightAll = value
        syncToggles()
        editor.activeTextView.setFindHighlights(matches, current: current, highlightAll: highlightAll)
    }

    func toggleMatchCase() { options.matchCase.toggle(); optionsChanged() }
    func toggleWholeWord() { options.wholeWord.toggle(); optionsChanged() }
    func toggleRegex() { options.regex.toggle(); optionsChanged() }

    func togglePreserveCase() {
        preserveCase.toggle()
        Preferences.preserveCase = preserveCase
        syncToggles()
    }

    /// The touch way to reach the replace row (⌥⌘F on a keyboard).
    func toggleReplace() {
        let visible = !bar.isReplaceVisible
        UIView.animate(withDuration: 0.12) {
            self.bar.isReplaceVisible = visible
            self.editor.view.layoutIfNeeded()
        }
        syncToggles()
        if visible {
            bar.replaceField.becomeFirstResponder()
        } else if bar.replaceField.isFirstResponder {
            bar.searchField.becomeFirstResponder()
        }
    }

    func chooseScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        syncToggles()
        if scope == .allNotes {
            searchAllNotes(debounce: false)
        } else {
            allDebounce?.cancel()
            sidebar.showNotes()
        }
        host?.findDidChangeScope(self)
    }

    // MARK: History

    private func commitHistory() {
        let text = searchText
        guard !text.isEmpty else { return }
        var history = Preferences.findHistory
        if history.first == text { return }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        Preferences.findHistory = history
        updateHistoryMenu()
    }

    /// ↑ / ↓ in the field on a hardware keyboard.
    private func moveInHistory(older: Bool) {
        let history = Preferences.findHistory
        guard !history.isEmpty else { return }
        let next: Int? = older
            ? min((historyIndex ?? -1) + 1, history.count - 1)
            : historyIndex.flatMap { $0 > 0 ? $0 - 1 : nil }
        historyIndex = next
        bar.searchField.text = next.map { history[$0] } ?? ""
        bar.selectAllSearchText()
        lastQueryText = searchText
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes { searchAllNotes(debounce: true) }
    }

    /// The clock button in the field: recent searches, newest first.
    private func updateHistoryMenu() {
        let history = Preferences.findHistory.prefix(15)
        bar.historyButton.isHidden = history.isEmpty
        bar.historyButton.menu = UIMenu(title: "Recent Searches", children: history.map { text in
            UIAction(title: text) { [weak self] _ in self?.useHistoryItem(text) }
        })
    }

    private func useHistoryItem(_ text: String) {
        bar.searchField.text = text
        lastQueryText = text
        historyIndex = nil
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes { searchAllNotes(debounce: false) }
    }

    // MARK: Fields

    @objc private func searchTextChanged() {
        historyIndex = nil
        lastQueryText = searchText
        recompute(anchor: searchOrigin, reveal: true)
        if scope == .allNotes { searchAllNotes(debounce: true) }
    }

    /// ↩ in Find goes to the next match; ↩ in Replace replaces this one and moves on.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === bar.searchField {
            step(forward: true)
        } else {
            replaceCurrent()
        }
        return false
    }

    private func handle(_ command: PlainField.Command, inSearchField: Bool) {
        switch command {
        case .previous:
            if inSearchField { step(forward: false) } else { replaceCurrent() }
        case .cancel:
            hide()
        case .up, .down:
            guard inSearchField else { return }
            let down = command == .down
            if scope == .allNotes {
                sidebar.moveSelection(by: down ? 1 : -1)
            } else {
                moveInHistory(older: !down)
            }
        case .tab:
            if inSearchField, bar.isReplaceVisible {
                bar.replaceField.becomeFirstResponder()
            } else {
                editor.focusCanvas()
            }
        case .backtab:
            if !inSearchField { bar.searchField.becomeFirstResponder() }
        }
    }
}
