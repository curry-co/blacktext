import AppKit
import BlackTextCore

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarController, didSelectNote id: NoteID)
    func sidebar(_ sidebar: SidebarController, didSelectVersion version: VersionSummary)
    func sidebar(_ sidebar: SidebarController, didSelectDeleted note: NoteSummary)
    func sidebar(_ sidebar: SidebarController, didSelectHit hit: SearchHit)
    func sidebar(_ sidebar: SidebarController, delete id: NoteID)
    func sidebarDidFinishRecentlyDeleted(_ sidebar: SidebarController)
    func sidebarDidRequestCanvas(_ sidebar: SidebarController)
    func sidebarDidRequestNewNote(_ sidebar: SidebarController)
    func sidebarDidCancel(_ sidebar: SidebarController) -> Bool
}

/// The left panel: notes by last edit with their versions tucked underneath,
/// or search results, or Recently Deleted. Paged, so it's instant at any size.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum Mode { case notes, search, deleted }

    final class Header {
        let title: String
        let showsDone: Bool
        init(_ title: String, showsDone: Bool = false) {
            self.title = title
            self.showsDone = showsDone
        }
    }

    final class NoteRow {
        var summary: NoteSummary
        var versions: [VersionRow]?
        init(_ summary: NoteSummary) { self.summary = summary }
    }

    final class VersionRow {
        let summary: VersionSummary
        unowned let note: NoteRow
        init(_ summary: VersionSummary, note: NoteRow) {
            self.summary = summary
            self.note = note
        }
    }

    final class HitRow {
        let hit: SearchHit
        init(_ hit: SearchHit) { self.hit = hit }
    }

    static let pageSize = 200

    let store: Store
    weak var delegate: SidebarDelegate?
    private let outline = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private(set) var mode: Mode = .notes
    private var notes: [NoteSummary] = []
    private var hasMore = true
    private var isLoadingMore = false
    private var rows: [AnyObject] = []
    private var noteRows: [NoteID: NoteRow] = [:]
    private var expanded: Set<NoteID> = []
    private var isSyncingSelection = false
    /// The note open in the canvas.
    private(set) var currentNoteID: NoteID?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var outlineView: NSOutlineView { outline }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Palette.background
        outline.selectionHighlightStyle = .regular
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.floatsGroupRows = false
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.sidebar = self
        outline.setAccessibilityLabel("Notes")

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)

        let root = FillView(color: Palette.background)
        let newNote = NewNoteButton(target: self, action: #selector(newNoteClicked(_:)))
        for view in [newNote, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            newNote.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            newNote.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            newNote.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: newNote.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        view = root
    }

    // MARK: Loading

    /// Reloads the notes already shown (at least one page). Cheap: titles and counts only, no text.
    func reloadNotes() {
        let count = max(Self.pageSize, notes.count)
        notes = (try? store.notes(limit: count)) ?? []
        hasMore = notes.count == count
        rebuild()
    }

    private func loadMore() {
        guard mode == .notes, hasMore, !isLoadingMore, let last = notes.last else { return }
        isLoadingMore = true
        let page = (try? store.notes(limit: Self.pageSize, after: NoteCursor(after: last))) ?? []
        hasMore = page.count == Self.pageSize
        notes += page
        rebuild()
        isLoadingMore = false
    }

    /// Updates one note after a save, moving it to the top if it was just edited.
    func noteDidSave(_ summary: NoteSummary) {
        notes.removeAll { $0.id == summary.id }
        let index = notes.firstIndex { ($0.updatedAt, $0.id) < (summary.updatedAt, summary.id) } ?? notes.count
        if index < notes.count || !hasMore { notes.insert(summary, at: index) }
        rebuild()
    }

    func noteDidDisappear(_ id: NoteID) {
        notes.removeAll { $0.id == id }
        noteRows[id] = nil
        expanded.remove(id)
        rebuild()
    }

    func setCurrentNote(_ id: NoteID?) {
        currentNoteID = id
        syncSelection(scroll: true)
    }

    private func rebuild() {
        guard mode == .notes else { return }
        var newRows: [AnyObject] = []
        var lastBucket: DateBucket?
        let now = Date()
        for summary in notes {
            let bucket = DateBucket(summary.updatedAt, now: now)
            if bucket != lastBucket {
                newRows.append(Header(bucket.title()))
                lastBucket = bucket
            }
            let row = noteRows[summary.id] ?? NoteRow(summary)
            if row.summary.versionCount != summary.versionCount { row.versions = nil }
            row.summary = summary
            noteRows[summary.id] = row
            newRows.append(row)
        }
        rows = newRows
        reloadOutline()
    }

    private func reloadOutline() {
        let selectedVersion = outline.item(atRow: outline.selectedRow) as? VersionRow
        isSyncingSelection = true
        outline.reloadData()
        for id in expanded {
            if let row = noteRows[id], row.summary.versionCount > 0 { outline.expandItem(row) }
        }
        if let selectedVersion, let row = selectedVersion.note.versions?.first(where: { $0.summary.id == selectedVersion.summary.id }) {
            let index = outline.row(forItem: row)
            if index >= 0 { outline.selectRowIndexes([index], byExtendingSelection: false) }
            isSyncingSelection = false
            return
        }
        isSyncingSelection = false
        syncSelection(scroll: false)
    }

    private func syncSelection(scroll: Bool) {
        guard mode == .notes else { return }
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        guard let id = currentNoteID, let row = noteRows[id] else {
            outline.deselectAll(nil)
            return
        }
        let index = outline.row(forItem: row)
        guard index >= 0 else { return }
        if (outline.item(atRow: outline.selectedRow) as? VersionRow)?.note === row { return }
        outline.selectRowIndexes([index], byExtendingSelection: false)
        if scroll { outline.scrollRowToVisible(index) }
    }

    private func loadVersions(_ row: NoteRow) {
        guard row.versions == nil else { return }
        let versions = (try? store.versions(noteID: row.summary.id)) ?? []
        row.versions = versions.map { VersionRow($0, note: row) }
    }

    // MARK: Modes

    func showResults(_ hits: [SearchHit], query: String) {
        mode = .search
        let title = hits.isEmpty ? "No notes" : hits.count == 1 ? "1 note" : "\(hits.count)\(hits.count >= 200 ? "+" : "") notes"
        rows = [Header(title)] + hits.map(HitRow.init)
        isSyncingSelection = true
        outline.reloadData()
        outline.scrollRowToVisible(0)
        isSyncingSelection = false
    }

    /// Moves the selection among search results; returns false if there's nowhere to go.
    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        let selectable = (0..<outline.numberOfRows).filter { !(outline.item(atRow: $0) is Header) }
        guard !selectable.isEmpty else { return false }
        let current = selectable.firstIndex(of: outline.selectedRow)
        let next = current.map { $0 + delta } ?? (delta > 0 ? 0 : selectable.count - 1)
        guard selectable.indices.contains(next) else { return false }
        outline.selectRowIndexes([selectable[next]], byExtendingSelection: false)
        outline.scrollRowToVisible(selectable[next])
        return true
    }

    func showRecentlyDeleted() {
        mode = .deleted
        let deleted = (try? store.deletedNotes()) ?? []
        rows = [Header(deleted.isEmpty ? "Recently Deleted is empty" : "Recently Deleted", showsDone: true)]
            + deleted.map(NoteRow.init)
        isSyncingSelection = true
        outline.reloadData()
        isSyncingSelection = false
    }

    func showNotes() {
        guard mode != .notes else { return }
        mode = .notes
        reloadNotes()
        syncSelection(scroll: true)
    }

    @objc private func newNoteClicked(_ sender: Any?) {
        delegate?.sidebarDidRequestNewNote(self)
    }

    @objc private func finishRecentlyDeleted(_ sender: Any?) {
        delegate?.sidebarDidFinishRecentlyDeleted(self)
    }

    // MARK: Keyboard

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guard mode == .notes, let row = outline.item(atRow: outline.selectedRow) as? NoteRow else { return false }
            delegate?.sidebar(self, delete: row.summary.id)
            return true
        case 36, 76, 48: // return, enter, tab
            delegate?.sidebarDidRequestCanvas(self)
            return true
        case 53: // escape
            return delegate?.sidebarDidCancel(self) ?? false
        default:
            return false
        }
    }

    var selectedNoteForDeletion: NoteID? {
        guard mode == .notes else { return nil }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? NoteRow)?.summary.id
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard selectedNoteForDeletion != nil else { return }
        menu.addItem(withTitle: "Delete Note", action: #selector(deleteClicked(_:)), keyEquivalent: "").target = self
    }

    @objc private func deleteClicked(_ sender: Any?) {
        if let id = selectedNoteForDeletion { delegate?.sidebar(self, delete: id) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rows.count }
        if let row = item as? NoteRow {
            loadVersions(row)
            return row.versions?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let row = item as? NoteRow { return row.versions![index] }
        return rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard mode == .notes, let row = item as? NoteRow else { return false }
        return row.summary.versionCount > 0
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch item {
        case is Header: return 30
        case is VersionRow: return 24
        case is HitRow: return 66
        default: return 46
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is Header)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        MonoRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let header as Header:
            let cell = reuse(outlineView) { HeaderCell(frame: .zero) }
            cell.configure(header.title, done: header.showsDone ? (self, #selector(finishRecentlyDeleted(_:))) : nil)
            return cell
        case let row as NoteRow:
            if mode == .notes, hasMore, let index = notes.lastIndex(where: { $0.id == row.summary.id }), index > notes.count - 40 {
                DispatchQueue.main.async { [weak self] in self?.loadMore() }
            }
            let cell = reuse(outlineView) { NoteCell(frame: .zero) }
            let summary = row.summary
            let detail = mode == .deleted
                ? "Deleted \(Format.short(summary.deletedAt ?? Date())) · \(Format.words(summary.wordCount))"
                : "\(Format.short(summary.updatedAt)) · \(Format.words(summary.wordCount))"
            cell.configure(title: summary.title, detail: detail)
            return cell
        case let version as VersionRow:
            let cell = reuse(outlineView) { VersionCell(frame: .zero) }
            let by = version.summary.origin.map { " · \($0)" } ?? ""
            cell.configure("\(Format.versionTime(version.summary.createdAt)) · \(Format.words(version.summary.wordCount))\(by)")
            return cell
        case let hit as HitRow:
            let cell = reuse(outlineView) { HitCell(frame: .zero) }
            cell.configure(hit.hit)
            return cell
        default:
            return nil
        }
    }

    private func reuse<T: NSTableCellView>(_ outlineView: NSOutlineView, make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: T.self))
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? T { return cell }
        let cell = make()
        cell.identifier = identifier
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, outline.selectedRow >= 0 else { return }
        switch outline.item(atRow: outline.selectedRow) {
        case let row as NoteRow:
            if mode == .deleted {
                delegate?.sidebar(self, didSelectDeleted: row.summary)
            } else {
                delegate?.sidebar(self, didSelectNote: row.summary.id)
            }
        case let version as VersionRow:
            delegate?.sidebar(self, didSelectVersion: version.summary)
        case let hit as HitRow:
            delegate?.sidebar(self, didSelectHit: hit.hit)
        default:
            break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? NoteRow { expanded.insert(row.summary.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? NoteRow { expanded.remove(row.summary.id) }
    }
}

final class SidebarOutlineView: NSOutlineView {
    weak var sidebar: SidebarController?

    override func keyDown(with event: NSEvent) {
        if sidebar?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // Keep the disclosure arrow small and close to the text.
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 4, dy: 0)
    }
}

/// Monochrome selection: a soft gray rounded rect. Text stays its normal color.
final class MonoRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Palette.sidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private func label(size: CGFloat, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = NSFont.systemFont(ofSize: size)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

final class HeaderCell: NSTableCellView {
    private let title = label(size: 11, color: Palette.secondaryText)
    private var done: MonoButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, done target: (AnyObject, Selector)?) {
        title.stringValue = text
        done?.removeFromSuperview()
        done = nil
        guard let target else { return }
        let button = MonoButton(text: "Done", target: target.0, action: target.1)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        done = button
    }
}

final class NoteCell: NSTableCellView {
    private let title = label(size: 13, color: Palette.text)
    private let detail = label(size: 11, color: Palette.secondaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        addSubview(detail)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, detail detailText: String) {
        title.stringValue = text.isEmpty ? "New note" : text
        title.textColor = text.isEmpty ? Palette.secondaryText : Palette.text
        detail.stringValue = detailText
        setAccessibilityLabel("\(title.stringValue), \(detailText)")
    }
}

final class VersionCell: NSTableCellView {
    private let title = label(size: 11.5, color: Palette.secondaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        title.stringValue = text
        setAccessibilityLabel("Version, \(text)")
    }
}

final class HitCell: NSTableCellView {
    private let title = label(size: 13, color: Palette.text)
    private let detail = label(size: 11, color: Palette.secondaryText)
    private let snippet = label(size: 11.5, color: Palette.secondaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        snippet.maximumNumberOfLines = 2
        snippet.lineBreakMode = .byTruncatingTail
        snippet.cell?.wraps = true
        for view in [title, detail, snippet] { addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            snippet.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ hit: SearchHit) {
        title.stringValue = hit.note.title.isEmpty ? "Empty note" : hit.note.title
        let matches = hit.matchCount == 1 ? "1 match" : "\(Format.number(hit.matchCount))\(hit.isCountCapped ? "+" : "") matches"
        detail.stringValue = "\(Format.short(hit.note.updatedAt)) · \(matches)"
        let text = NSMutableAttributedString(string: hit.snippet, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Palette.secondaryText,
        ])
        for range in hit.snippetMatches where NSMaxRange(range) <= text.length {
            text.addAttributes([.backgroundColor: Palette.matchBackground, .foregroundColor: Palette.matchText], range: range)
        }
        snippet.attributedStringValue = text
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue), \(hit.snippet)")
    }
}
