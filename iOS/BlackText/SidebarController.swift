import UIKit
import BlackTextCore

protocol SidebarDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarController, didSelectNote id: NoteID)
    func sidebar(_ sidebar: SidebarController, didSelectVersion version: VersionSummary)
    func sidebar(_ sidebar: SidebarController, didSelectDeleted note: NoteSummary)
    func sidebar(_ sidebar: SidebarController, didSelectHit hit: SearchHit)
    func sidebar(_ sidebar: SidebarController, delete id: NoteID)
    func sidebar(_ sidebar: SidebarController, putBack id: NoteID)
    func sidebarDidRequestRecentlyDeleted(_ sidebar: SidebarController)
    func sidebarDidFinishRecentlyDeleted(_ sidebar: SidebarController)
    func sidebarDidRequestNewNote(_ sidebar: SidebarController)
}

/// The left panel: notes by last edit with their versions tucked underneath,
/// or search results, or Recently Deleted. Paged, so it's instant at any size.
final class SidebarController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    enum Mode { case notes, search, deleted }

    /// The highlighted row: the note in the canvas, the version or deleted note being previewed,
    /// or the search result being shown.
    enum Selection: Equatable {
        case note(NoteID)
        case version(VersionID)
        case hit(NoteID)
    }

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
    let tableView = UITableView(frame: .zero, style: .plain)
    private let footer = UIView()
    private(set) var mode: Mode = .notes
    private var notes: [NoteSummary] = []
    private var hasMore = true
    private var isLoadingMore = false
    private var rows: [AnyObject] = []
    private var noteRows: [NoteID: NoteRow] = [:]
    private var expanded: Set<NoteID> = []
    private(set) var selection: Selection?
    /// The note open in the canvas.
    private(set) var currentNoteID: NoteID?

    init(store: Store) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = Palette.background

        let newNote = NewNoteButton(action: UIAction { [weak self] _ in
            guard let self else { return }
            delegate?.sidebarDidRequestNewNote(self)
        })
        newNote.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(newNote)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = Palette.background
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        tableView.accessibilityLabel = "Notes"
        for type in [HeaderCell.self, NoteCell.self, VersionCell.self, HitCell.self] as [SidebarCell.Type] {
            tableView.register(type, forCellReuseIdentifier: String(describing: type))
        }

        // Recently Deleted sits at the bottom, shown when there's something in it.
        let line = Hairline(.horizontal)
        let button = MonoButton(text: "Recently Deleted", color: Palette.secondaryText, action: UIAction { [weak self] _ in
            guard let self else { return }
            delegate?.sidebarDidRequestRecentlyDeleted(self)
        })
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(line)
        footer.addSubview(button)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: footer.topAnchor),
            line.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            button.leadingAnchor.constraint(equalTo: footer.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            button.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: line.bottomAnchor),
            button.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
        // Just under required, so the stack view can fold it away when it's hidden.
        let height = footer.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .init(999)
        height.isActive = true
        footer.isHidden = true

        let content = UIStackView(arrangedSubviews: [tableView, footer])
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            newNote.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            newNote.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            newNote.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: newNote.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
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
        updateFooter()
    }

    /// Sync and other outside changes: re-reads whatever the sidebar is showing.
    /// Search results are left alone; the find bar refreshes those.
    func reload() {
        switch mode {
        case .notes: reloadNotes()
        case .deleted: showRecentlyDeleted()
        case .search: break
        }
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
        updateFooter()
    }

    func setCurrentNote(_ id: NoteID?) {
        currentNoteID = id
        syncSelection(scroll: true)
    }

    /// A version preview closed: highlight the note again.
    func clearVersionSelection() {
        guard case .version? = selection else { return }
        selection = nil
        syncSelection(scroll: false)
    }

    func updateFooter() {
        let deleted = mode == .notes ? ((try? store.deletedCount()) ?? 0) : 0
        // Only on change: stack views misbehave when told to hide what's already hidden.
        if footer.isHidden != (deleted == 0) { footer.isHidden = deleted == 0 }
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
            if expanded.contains(summary.id), summary.versionCount > 0 {
                loadVersions(row)
                newRows.append(contentsOf: row.versions ?? [])
            }
        }
        rows = newRows
        tableView.reloadData()
        syncSelection(scroll: false)
    }

    private func loadVersions(_ row: NoteRow) {
        guard row.versions == nil else { return }
        let versions = (try? store.versions(noteID: row.summary.id)) ?? []
        row.versions = versions.map { VersionRow($0, note: row) }
    }

    private func toggleVersions(of id: NoteID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
        rebuild()
    }

    private func versionRow(_ id: VersionID) -> VersionRow? {
        for noteID in expanded {
            if let row = noteRows[noteID]?.versions?.first(where: { $0.summary.id == id }) { return row }
        }
        return nil
    }

    private func syncSelection(scroll: Bool) {
        guard mode == .notes else {
            refreshSelection()
            return
        }
        // Keep a previewed version of the current note highlighted.
        if case .version(let versionID)? = selection, let version = versionRow(versionID),
           version.note.summary.id == currentNoteID {
            refreshSelection()
            return
        }
        selection = currentNoteID.map(Selection.note)
        refreshSelection()
        if scroll, let id = currentNoteID,
           let index = rows.firstIndex(where: { ($0 as? NoteRow)?.summary.id == id }) {
            scrollToRowIfNeeded(index)
        }
    }

    private func scrollToRowIfNeeded(_ index: Int) {
        guard tableView.window != nil, rows.indices.contains(index), tableView.numberOfRows(inSection: 0) > index else { return }
        let indexPath = IndexPath(row: index, section: 0)
        if tableView.indexPathsForVisibleRows?.contains(indexPath) == true { return }
        tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
    }

    /// Scrolls the highlighted row into view (when the sidebar slides in).
    func revealSelection() {
        guard let index = rows.firstIndex(where: isSelected) else { return }
        scrollToRowIfNeeded(index)
    }

    private func isSelected(_ row: AnyObject) -> Bool {
        switch (row, selection) {
        case let (note as NoteRow, .note(id)?): return note.summary.id == id
        case let (version as VersionRow, .version(id)?): return version.summary.id == id
        case let (hit as HitRow, .hit(id)?): return hit.hit.note.id == id
        default: return false
        }
    }

    private func refreshSelection() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] where rows.indices.contains(indexPath.row) {
            (tableView.cellForRow(at: indexPath) as? SidebarCell)?.isCurrent = isSelected(rows[indexPath.row])
        }
    }

    /// Highlights a row (the version being previewed, say) without telling the delegate.
    func highlight(_ selection: Selection?) {
        self.selection = selection
        refreshSelection()
    }

    // MARK: Modes

    func showResults(_ hits: [SearchHit], query: String) {
        mode = .search
        let title = hits.isEmpty ? "No notes" : hits.count == 1 ? "1 note" : "\(hits.count)\(hits.count >= 200 ? "+" : "") notes"
        rows = [Header(title)] + hits.map(HitRow.init)
        switch selection {
        case .hit(let id)? where hits.contains(where: { $0.note.id == id }): break
        default: selection = nil
        }
        tableView.reloadData()
        if !rows.isEmpty { tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false) }
        updateFooter()
    }

    /// Moves the highlight among search results and shows the result; returns false if there's nowhere to go.
    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        let selectable = rows.indices.filter { !(rows[$0] is Header) }
        guard !selectable.isEmpty else { return false }
        let current = selectable.firstIndex { isSelected(rows[$0]) }
        let next = current.map { $0 + delta } ?? (delta > 0 ? 0 : selectable.count - 1)
        guard selectable.indices.contains(next) else { return false }
        scrollToRowIfNeeded(selectable[next])
        choose(rows[selectable[next]])
        return true
    }

    /// The note before or after the current one, for ⌥⌘↑ / ⌥⌘↓.
    func adjacentNote(by delta: Int) -> NoteID? {
        guard mode == .notes, !notes.isEmpty else { return nil }
        var anchor = currentNoteID
        if case .version(let versionID)? = selection, let version = versionRow(versionID) { anchor = version.note.summary.id }
        let index = anchor.flatMap { id in notes.firstIndex { $0.id == id } }
        let next = index.map { $0 + delta } ?? (delta > 0 ? 0 : notes.count - 1)
        if next >= notes.count - 1 { loadMore() }
        guard notes.indices.contains(next) else { return nil }
        return notes[next].id
    }

    func showRecentlyDeleted() {
        mode = .deleted
        let deleted = (try? store.deletedNotes()) ?? []
        rows = [Header(deleted.isEmpty ? "Recently Deleted is empty" : "Recently Deleted", showsDone: true)]
            + deleted.map(NoteRow.init)
        if case .note(let id)? = selection, !deleted.contains(where: { $0.id == id }) { selection = nil }
        tableView.reloadData()
        updateFooter()
    }

    func showNotes() {
        guard mode != .notes else { return }
        mode = .notes
        selection = nil
        reloadNotes()
        syncSelection(scroll: true)
    }

    /// Whether a touch at `point` (in this view) lands on a row with its own swipe actions.
    func hasSwipeActions(at point: CGPoint) -> Bool {
        let local = tableView.convert(point, from: view)
        guard mode != .search, let indexPath = tableView.indexPathForRow(at: local),
              rows.indices.contains(indexPath.row) else { return false }
        return rows[indexPath.row] is NoteRow
    }

    private func choose(_ row: AnyObject) {
        switch row {
        case let note as NoteRow:
            highlight(.note(note.summary.id))
            if mode == .deleted {
                delegate?.sidebar(self, didSelectDeleted: note.summary)
            } else {
                delegate?.sidebar(self, didSelectNote: note.summary.id)
            }
        case let version as VersionRow:
            highlight(.version(version.summary.id))
            delegate?.sidebar(self, didSelectVersion: version.summary)
        case let hit as HitRow:
            highlight(.hit(hit.hit.note.id))
            delegate?.sidebar(self, didSelectHit: hit.hit)
        default:
            break
        }
    }

    // MARK: Data source

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    private func dequeue<T: SidebarCell>(_ type: T.Type, for indexPath: IndexPath) -> T {
        let identifier = String(describing: type)
        return tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath) as? T
            ?? T(style: .default, reuseIdentifier: identifier)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = rows[indexPath.row]
        let cell: SidebarCell
        switch item {
        case let header as Header:
            let headerCell = dequeue(HeaderCell.self, for: indexPath)
            headerCell.configure(header.title, onDone: header.showsDone ? { [weak self] in
                guard let self else { return }
                delegate?.sidebarDidFinishRecentlyDeleted(self)
            } : nil)
            cell = headerCell
        case let row as NoteRow:
            if mode == .notes, hasMore, indexPath.row > rows.count - 40 {
                DispatchQueue.main.async { [weak self] in self?.loadMore() }
            }
            let noteCell = dequeue(NoteCell.self, for: indexPath)
            let summary = row.summary
            let detail = mode == .deleted
                ? "Deleted \(Format.short(summary.deletedAt ?? Date())) · \(Format.words(summary.wordCount))"
                : "\(Format.short(summary.updatedAt)) · \(Format.words(summary.wordCount))"
            let id = summary.id
            let disclosure: NoteCell.Disclosure = mode == .notes && summary.versionCount > 0
                ? (expanded.contains(id) ? .expanded : .collapsed) : .none
            noteCell.configure(title: summary.title, detail: detail, disclosure: disclosure) { [weak self] in
                self?.toggleVersions(of: id)
            }
            cell = noteCell
        case let version as VersionRow:
            let versionCell = dequeue(VersionCell.self, for: indexPath)
            let by = version.summary.agentName.map { " · \($0)" } ?? ""
            versionCell.configure("\(Format.versionTime(version.summary.createdAt)) · \(Format.words(version.summary.wordCount))\(by)")
            cell = versionCell
        case let hit as HitRow:
            let hitCell = dequeue(HitCell.self, for: indexPath)
            hitCell.configure(hit.hit)
            cell = hitCell
        default:
            cell = dequeue(HeaderCell.self, for: indexPath)
        }
        cell.isCurrent = isSelected(item)
        return cell
    }

    // MARK: Delegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch rows[indexPath.row] {
        case is Header: return 34
        case is VersionRow: return 36
        case is HitRow: return 84
        default: return 58
        }
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        !(rows[indexPath.row] is Header)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard rows.indices.contains(indexPath.row) else { return }
        choose(rows[indexPath.row])
    }

    /// Swipe left on a note: Delete (to Recently Deleted). In Recently Deleted: Put Back.
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard mode != .search, let row = rows[indexPath.row] as? NoteRow else { return nil }
        let id = row.summary.id
        let action: UIContextualAction
        if mode == .deleted {
            action = UIContextualAction(style: .normal, title: "Put Back") { [weak self] _, _, done in
                done(true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.delegate?.sidebar(self, putBack: id)
                }
            }
        } else {
            action = UIContextualAction(style: .normal, title: "Delete") { [weak self] _, _, done in
                done(true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.delegate?.sidebar(self, delete: id)
                }
            }
        }
        // Monochrome, like everything else.
        action.backgroundColor = Palette.buttonGray
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .notes, let row = rows[indexPath.row] as? NoteRow else { return nil }
        let id = row.summary.id
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Delete Note", image: UIImage(systemName: "trash")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.sidebar(self, delete: id)
                },
            ])
        }
    }
}

// MARK: Cells

/// Monochrome selection: a soft gray rounded rect behind the row. Text stays its normal color.
class SidebarCell: UITableViewCell {
    private let pill = UIView()
    var isCurrent = false { didSet { updatePill() } }

    required override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        pill.backgroundColor = Palette.sidebarSelection
        pill.layer.cornerRadius = 8
        pill.layer.cornerCurve = .continuous
        pill.isHidden = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updatePill()
    }

    private func updatePill() {
        pill.isHidden = !(isCurrent || isHighlighted)
    }

    static func label(size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

final class HeaderCell: SidebarCell {
    private let title = SidebarCell.label(size: 12, color: Palette.secondaryText, weight: .medium)
    private var done: MonoButton?

    required init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -70),
            title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
        title.accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, onDone: (() -> Void)?) {
        title.text = text
        done?.removeFromSuperview()
        done = nil
        guard let onDone else { return }
        let button = MonoButton(text: "Done", action: UIAction { _ in onDone() })
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        done = button
    }
}

final class NoteCell: SidebarCell {
    enum Disclosure { case none, collapsed, expanded }

    private let title = SidebarCell.label(size: 15, color: Palette.text)
    private let detail = SidebarCell.label(size: 12.5, color: Palette.secondaryText)
    private let disclosureButton = UIButton(type: .system)
    private var onToggle: (() -> Void)?

    required init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        disclosureButton.setImage(UIImage(systemName: "chevron.right",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)), for: .normal)
        disclosureButton.tintColor = Palette.secondaryText
        disclosureButton.accessibilityLabel = "Versions"
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
        for view in [title, detail, disclosureButton] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -2),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -2),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            disclosureButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            disclosureButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 40),
            disclosureButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, detail detailText: String, disclosure: Disclosure, onToggle: @escaping () -> Void) {
        title.text = text.isEmpty ? "New note" : text
        title.textColor = text.isEmpty ? Palette.tertiaryText : Palette.text
        detail.text = detailText
        self.onToggle = onToggle
        disclosureButton.isHidden = disclosure == .none
        disclosureButton.transform = disclosure == .expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        disclosureButton.accessibilityValue = disclosure == .expanded ? "Shown" : "Hidden"
        accessibilityLabel = "\(title.text ?? ""), \(detailText)"
    }
}

final class VersionCell: SidebarCell {
    private let title = SidebarCell.label(size: 13, color: Palette.secondaryText)

    required init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        title.text = text
        accessibilityLabel = "Version, \(text)"
    }
}

final class HitCell: SidebarCell {
    private let title = SidebarCell.label(size: 15, color: Palette.text)
    private let detail = SidebarCell.label(size: 12.5, color: Palette.secondaryText)
    private let snippet = SidebarCell.label(size: 13, color: Palette.secondaryText)

    required init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        snippet.numberOfLines = 2
        for view in [title, detail, snippet] { contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            snippet.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ hit: SearchHit) {
        title.text = hit.note.title.isEmpty ? "Empty note" : hit.note.title
        let matches = hit.matchCount == 1 ? "1 match" : "\(Format.number(hit.matchCount)) matches"
        detail.text = "\(Format.short(hit.note.updatedAt)) · \(matches)"
        let text = NSMutableAttributedString(string: hit.snippet, attributes: [
            .font: UIFont.systemFont(ofSize: 13), .foregroundColor: Palette.secondaryText,
        ])
        for range in hit.snippetMatches where NSMaxRange(range) <= text.length {
            text.addAttributes([.backgroundColor: Palette.matchBackground, .foregroundColor: Palette.matchText], range: range)
        }
        snippet.attributedText = text
        accessibilityLabel = "\(title.text ?? ""), \(detail.text ?? ""), \(hit.snippet)"
    }
}
