import UIKit
import BlackTextCore

/// The bar that slides down above the canvas and pushes the text down. FindController owns the behavior.
///
/// A wide canvas gets the Mac's layout: field, count, arrows and toggles in one row. A narrow one
/// (iPhone, or iPad beside the sidebar) moves the toggles to a scrolling row of their own.
/// Touch has no ⌥⌘F, so a Replace toggle shows and hides the replace row.
final class FindBar: UIView {
    let searchField = PlainField(placeholder: "Find")
    let replaceField = PlainField(placeholder: "Replace")
    let countLabel = UILabel()
    let historyButton: MonoButton
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
    let replaceToggle: MonoToggle
    let preserveCaseToggle: MonoToggle
    let replaceButton: MonoButton
    let replaceAllButton: MonoButton

    /// Wide enough for everything in one row.
    static let wideWidth: CGFloat = 760

    private let column = UIStackView()
    private let findRow = UIStackView()
    private let togglesRow = UIStackView()
    private let togglesScroll = UIScrollView()
    private let toggles = UIStackView()
    private let replaceRow = UIStackView()
    private var isWide: Bool?

    init(controller: FindController) {
        func act(_ body: @escaping @MainActor (FindController) -> Void) -> UIAction {
            UIAction { [weak controller] _ in
                if let controller { body(controller) }
            }
        }
        historyButton = MonoButton(symbol: "clock.arrow.circlepath", label: "Recent searches")
        previousButton = MonoButton(symbol: "chevron.up", label: "Previous match", action: act { $0.step(forward: false) })
        nextButton = MonoButton(symbol: "chevron.down", label: "Next match", action: act { $0.step(forward: true) })
        closeButton = MonoButton(symbol: "xmark", label: "Close find", action: act { $0.hide() })
        oneToggle = MonoToggle("One", label: "One at a time", action: act { $0.setHighlightAll(false) })
        allToggle = MonoToggle("All", label: "Highlight all", action: act { $0.setHighlightAll(true) })
        caseToggle = MonoToggle("Aa", label: "Match case", action: act { $0.toggleMatchCase() })
        wordToggle = MonoToggle("W", label: "Whole word", action: act { $0.toggleWholeWord() })
        regexToggle = MonoToggle(".*", label: "Regular expression", action: act { $0.toggleRegex() })
        noteScopeToggle = MonoToggle("Note", label: "Find in this note", action: act { $0.chooseScope(.note) })
        allNotesScopeToggle = MonoToggle("All notes", label: "Search all notes", action: act { $0.chooseScope(.allNotes) })
        replaceToggle = MonoToggle("Replace", label: "Show replace", action: act { $0.toggleReplace() })
        preserveCaseToggle = MonoToggle("Preserve case", label: "Preserve case: Coffee to Tea, COFFEE to TEA",
                                        action: act { $0.togglePreserveCase() })
        replaceButton = MonoButton(text: "Replace", action: act { $0.replaceCurrent() })
        replaceAllButton = MonoButton(text: "Replace All", action: act { $0.replaceAll() })
        super.init(frame: .zero)
        backgroundColor = Palette.background
        historyButton.showsMenuAsPrimaryAction = true
        replaceButton.accessibilityHint = "Replaces this match and goes to the next"
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func well(around field: UITextField, accessory: UIView? = nil) -> UIView {
        let well = FieldWell()
        let row = UIStackView(arrangedSubviews: [field] + (accessory.map { [$0] } ?? []))
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(row)
        NSLayoutConstraint.activate([
            well.heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: accessory == nil ? -10 : -2),
            row.topAnchor.constraint(equalTo: well.topAnchor),
            row.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        well.setContentHuggingPriority(.defaultLow, for: .horizontal)
        well.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return well
    }

    private func gap(_ width: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func build() {
        countLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = Palette.secondaryText
        countLabel.textAlignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let searchWell = well(around: searchField, accessory: historyButton)
        for view in [searchWell, countLabel, previousButton, nextButton, closeButton] {
            findRow.addArrangedSubview(view)
        }
        findRow.axis = .horizontal
        findRow.alignment = .center
        findRow.spacing = 2
        findRow.setCustomSpacing(8, after: searchWell)

        for view in [oneToggle, allToggle, gap(8), caseToggle, wordToggle, regexToggle, gap(8),
                     noteScopeToggle, allNotesScopeToggle, gap(8), replaceToggle] {
            toggles.addArrangedSubview(view)
        }
        toggles.axis = .horizontal
        toggles.alignment = .center
        toggles.spacing = 2
        toggles.translatesAutoresizingMaskIntoConstraints = false
        togglesScroll.addSubview(toggles)
        togglesScroll.showsHorizontalScrollIndicator = false
        togglesScroll.alwaysBounceHorizontal = false
        // As wide as the toggles when there's room (wide layout); otherwise they scroll.
        let fitContent = togglesScroll.widthAnchor.constraint(equalTo: toggles.widthAnchor)
        fitContent.priority = .init(500)
        NSLayoutConstraint.activate([
            toggles.leadingAnchor.constraint(equalTo: togglesScroll.contentLayoutGuide.leadingAnchor),
            toggles.trailingAnchor.constraint(equalTo: togglesScroll.contentLayoutGuide.trailingAnchor),
            toggles.topAnchor.constraint(equalTo: togglesScroll.contentLayoutGuide.topAnchor),
            toggles.bottomAnchor.constraint(equalTo: togglesScroll.contentLayoutGuide.bottomAnchor),
            toggles.heightAnchor.constraint(equalTo: togglesScroll.frameLayoutGuide.heightAnchor),
            togglesScroll.heightAnchor.constraint(equalToConstant: 32),
            fitContent,
        ])
        togglesRow.axis = .horizontal

        let replaceWell = well(around: replaceField)
        // Takes whatever the row doesn't need, so the replace field lines up with the find field.
        let filler = UIView()
        filler.setContentHuggingPriority(.init(1), for: .horizontal)
        filler.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        for view in [replaceWell, replaceButton, replaceAllButton, filler] {
            replaceRow.addArrangedSubview(view)
        }
        replaceRow.axis = .horizontal
        replaceRow.alignment = .center
        replaceRow.spacing = 6
        replaceRow.isHidden = true

        for row in [findRow, togglesRow, replaceRow] { column.addArrangedSubview(row) }
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let line = Hairline(.horizontal)
        addSubview(line)
        // Vertical constraints sit just under required so the editor's stack view can fold the bar away.
        let bottom = column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bottom,
            replaceWell.widthAnchor.constraint(equalTo: searchWell.widthAnchor).with(priority: .init(260)),
            searchWell.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        arrange(wide: false)
        accessibilityLabel = "Find"
        shouldGroupAccessibilityChildren = true
    }

    override func layoutSubviews() {
        let wide = bounds.width >= Self.wideWidth
        if wide != isWide { arrange(wide: wide) }
        super.layoutSubviews()
    }

    /// Moves the toggles (and Preserve case) between their wide and narrow homes.
    private func arrange(wide: Bool) {
        isWide = wide
        togglesScroll.removeFromSuperview()
        preserveCaseToggle.removeFromSuperview()
        if wide {
            findRow.insertArrangedSubview(togglesScroll, at: max(0, findRow.arrangedSubviews.count - 1))
            findRow.setCustomSpacing(8, after: nextButton)
            replaceRow.insertArrangedSubview(preserveCaseToggle, at: max(0, replaceRow.arrangedSubviews.count - 1))
            replaceRow.setCustomSpacing(12, after: replaceAllButton)
            preserveCaseToggle.isHidden = false
            togglesRow.isHidden = true
        } else {
            togglesRow.addArrangedSubview(togglesScroll)
            toggles.addArrangedSubview(preserveCaseToggle)
            preserveCaseToggle.isHidden = replaceRow.isHidden
            togglesRow.isHidden = false
        }
    }

    var isReplaceVisible: Bool {
        get { !replaceRow.isHidden }
        set {
            // Only on change: stack views misbehave when told to hide what's already hidden.
            if replaceRow.isHidden == newValue { replaceRow.isHidden = !newValue }
            replaceToggle.isOn = newValue
            if isWide != true, preserveCaseToggle.isHidden == newValue { preserveCaseToggle.isHidden = !newValue }
        }
    }

    /// Selects the whole search text, so typing replaces it.
    func selectAllSearchText() {
        searchField.selectedTextRange = searchField.textRange(from: searchField.beginningOfDocument,
                                                              to: searchField.endOfDocument)
    }
}

extension NSLayoutConstraint {
    func with(priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
