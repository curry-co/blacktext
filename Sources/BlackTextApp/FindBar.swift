import AppKit

/// The bar that slides down above the canvas. FindController owns the behavior.
final class FindBar: NSView {
    let searchField = PlainField(placeholder: "Find")
    let replaceField = PlainField(placeholder: "Replace")
    let countLabel = NSTextField(labelWithString: "")
    let previousButton: MonoButton
    let nextButton: MonoButton
    let closeButton: MonoButton
    let oneToggle: MonoToggle
    let allToggle: MonoToggle
    let caseToggle: MonoToggle
    let wordToggle: MonoToggle
    let regexToggle: MonoToggle
    let noteScopeToggle: MonoToggle
    let allNotesScopeToggle: MonoToggle
    let replaceButton: MonoButton
    let replaceAllButton: MonoButton
    let preserveCaseToggle: MonoToggle

    private let replaceRow = NSStackView()
    private var replaceRowHeight: NSLayoutConstraint!

    init(target: AnyObject) {
        previousButton = MonoButton(symbol: "chevron.up", label: "Previous match (⇧↩)", target: target, action: #selector(FindController.previousMatch(_:)))
        nextButton = MonoButton(symbol: "chevron.down", label: "Next match (↩)", target: target, action: #selector(FindController.nextMatch(_:)))
        closeButton = MonoButton(symbol: "xmark", label: "Close (Esc)", target: target, action: #selector(FindController.close(_:)))
        oneToggle = MonoToggle("One", toolTip: "One at a time (⌥⌘A)", target: target, action: #selector(FindController.chooseOneAtATime(_:)))
        allToggle = MonoToggle("All", toolTip: "Highlight all (⌥⌘A)", target: target, action: #selector(FindController.chooseHighlightAll(_:)))
        caseToggle = MonoToggle("Aa", toolTip: "Match case (⌥⌘C)", target: target, action: #selector(FindController.toggleMatchCase(_:)))
        wordToggle = MonoToggle("W", toolTip: "Whole word (⌥⌘W)", target: target, action: #selector(FindController.toggleWholeWord(_:)))
        regexToggle = MonoToggle(".*", toolTip: "Regular expression (⌥⌘R)", target: target, action: #selector(FindController.toggleRegex(_:)))
        noteScopeToggle = MonoToggle("Note", toolTip: "Find in this note (⌘F)", target: target, action: #selector(FindController.chooseNoteScope(_:)))
        allNotesScopeToggle = MonoToggle("All notes", toolTip: "Search all notes (⇧⌘F)", target: target, action: #selector(FindController.chooseAllNotesScope(_:)))
        replaceButton = MonoButton(text: "Replace", target: target, action: #selector(FindController.replaceCurrent(_:)))
        replaceAllButton = MonoButton(text: "Replace All", target: target, action: #selector(FindController.replaceAll(_:)))
        preserveCaseToggle = MonoToggle("Preserve case", toolTip: "Coffee → Tea, COFFEE → TEA", target: target, action: #selector(FindController.togglePreserveCase(_:)))
        super.init(frame: .zero)
        replaceButton.toolTip = "Replace this one and go to the next (↩ in Replace)"
        replaceAllButton.toolTip = "Replace all (⌥⌘↩)"
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func well(around field: NSTextField) -> NSView {
        let well = FieldWell()
        field.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(field)
        NSLayoutConstraint.activate([
            well.heightAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        well.setContentHuggingPriority(.defaultLow, for: .horizontal)
        well.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return well
    }

    private func gap(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func build() {
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = Palette.secondaryText
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        let searchWell = well(around: searchField)
        let findRow = NSStackView(views: [
            searchWell, countLabel, previousButton, nextButton, gap(6),
            oneToggle, allToggle, gap(6), caseToggle, wordToggle, regexToggle, gap(6),
            noteScopeToggle, allNotesScopeToggle, gap(2), closeButton,
        ])
        findRow.orientation = .horizontal
        findRow.spacing = 4
        findRow.alignment = .centerY
        // On narrow windows, drop the less-used controls first.
        for view in [noteScopeToggle, allNotesScopeToggle] { findRow.setVisibilityPriority(.detachOnlyIfNecessary, for: view) }
        for view in [wordToggle, regexToggle, caseToggle] { findRow.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: view) }
        for view in [oneToggle, allToggle] { findRow.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 700), for: view) }

        let replaceWell = well(around: replaceField)
        for view in [replaceWell, replaceButton, replaceAllButton, gap(6), preserveCaseToggle] {
            replaceRow.addArrangedSubview(view)
        }
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 8
        replaceRow.alignment = .centerY

        let column = NSStackView(views: [findRow, replaceRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            findRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            replaceWell.widthAnchor.constraint(equalTo: searchWell.widthAnchor),
            searchWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    var isReplaceVisible: Bool {
        get { !replaceRow.isHidden }
        set { replaceRow.isHidden = !newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        bounds.fill()
        Palette.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
