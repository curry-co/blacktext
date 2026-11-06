import UIKit
import BlackTextCore

/// Gives small controls a finger-sized target without making them look bigger.
private func expandedBounds(_ bounds: CGRect, minimum: CGFloat = 44) -> CGRect {
    let dx = max(0, minimum - bounds.width) / 2
    let dy = max(0, minimum - bounds.height) / 2
    return bounds.insetBy(dx: -dx, dy: -dy)
}

/// A borderless button: an SF Symbol or short text, fading while pressed.
final class MonoButton: UIButton {
    /// An SF Symbol at 13 pt regular in gray, like the Mac's title bar buttons.
    convenience init(symbol: String, label: String, action: UIAction? = nil) {
        self.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        config.baseForegroundColor = Palette.secondaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        configuration = config
        accessibilityLabel = label
        // Icons keep their size; fields beside them take the spare room.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        isPointerInteractionEnabled = true
        if let action { addAction(action, for: .primaryActionTriggered) }
    }

    /// Short text in the text color; tertiary when disabled.
    convenience init(text: String, color: UIColor = Palette.text, action: UIAction? = nil) {
        self.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.title = text
        config.baseForegroundColor = color
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 13)
            return outgoing
        }
        configuration = config
        configurationUpdateHandler = { button in
            guard var config = button.configuration else { return }
            config.baseForegroundColor = button.isEnabled ? color : Palette.tertiaryText
            button.configuration = config
        }
        // Text buttons keep their words; text fields beside them give way.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.init(760), for: .horizontal)
        isPointerInteractionEnabled = true
        if let action { addAction(action, for: .primaryActionTriggered) }
    }

    func setSymbol(_ name: String, label: String) {
        configuration?.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        accessibilityLabel = label
    }

    func setText(_ text: String) {
        configuration?.title = text
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedBounds(bounds).contains(point)
    }
}

/// A small text toggle. On: inverted (like a find match). Off: gray text.
final class MonoToggle: UIControl {
    var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
    var isOn = false {
        didSet {
            setNeedsDisplay()
            accessibilityValue = isOn ? "On" : "Off"
        }
    }
    private let font = UIFont.systemFont(ofSize: 13)

    init(_ title: String, label: String? = nil, action: UIAction) {
        self.title = title
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label ?? title
        accessibilityValue = "Off"
        // Never squeezed: a row of toggles scrolls instead.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addAction(action, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(redraw))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redraw() { setNeedsDisplay() }

    override var isHighlighted: Bool {
        didSet { setNeedsDisplay() }
    }

    override var intrinsicContentSize: CGSize {
        let size = (title as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width) + 16, height: 30)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedBounds(bounds).contains(point)
    }

    override func draw(_ rect: CGRect) {
        let shape = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 2), cornerRadius: 6)
        if isOn {
            Palette.text.setFill()
            shape.fill()
        } else if isHighlighted {
            Palette.field.setFill()
            shape.fill()
        }
        let color = isOn ? Palette.background : Palette.secondaryText
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attributes)
    }
}

/// The "+" at the top of the sidebar. 50% gray; solid black or white (the opposite of the
/// background) while pressed or while a pointer hovers over it; back to gray once tapped.
final class NewNoteButton: UIControl {
    private var isHovered = false { didSet { setNeedsDisplay() } }

    init(action: UIAction) {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "New note"
        addAction(action, for: .touchUpInside)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(redraw))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redraw() { setNeedsDisplay() }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: isHovered = true
        default: isHovered = false
        }
    }

    override var isHighlighted: Bool {
        didSet { setNeedsDisplay() }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 32) }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        isHovered = false
    }

    override func draw(_ rect: CGRect) {
        (isHighlighted || isHovered ? Palette.inverse : Palette.buttonGray).setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: 7).fill()
        Palette.background.setFill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 6
        let thickness: CGFloat = 2
        UIRectFill(CGRect(x: (center.x - arm).rounded(), y: (center.y - thickness / 2).rounded(), width: arm * 2, height: thickness))
        UIRectFill(CGRect(x: (center.x - thickness / 2).rounded(), y: (center.y - arm).rounded(), width: thickness, height: arm * 2))
    }
}

/// The touch version of ⌘↩: a small 50% gray rounded rectangle labeled Save+New, the same style
/// as the + button. Solid black (light) or white (dark) while pressed. For a few seconds after a
/// tap it reads Undo, in the same spot and at the same size.
final class SaveNewButton: UIControl {
    enum Mode { case saveNew, undo }

    var mode: Mode = .saveNew {
        didSet {
            setNeedsDisplay()
            accessibilityLabel = title
        }
    }
    private let font = UIFont.systemFont(ofSize: 14, weight: .semibold)

    private var title: String { mode == .saveNew ? "Save+New" : "Undo" }

    init(action: UIAction) {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        accessibilityHint = "Saves this note and starts a new one"
        addAction(action, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(redraw))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redraw() { setNeedsDisplay() }

    override var isHighlighted: Bool {
        didSet { setNeedsDisplay() }
    }

    /// Sized for the longer label, so Undo sits exactly where Save+New was.
    override var intrinsicContentSize: CGSize {
        let width = ["Save+New", "Undo"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60
        return CGSize(width: ceil(width) + 26, height: 34)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expandedBounds(bounds).contains(point)
    }

    override func draw(_ rect: CGRect) {
        (isHighlighted ? Palette.inverse : Palette.buttonGray).setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.background]
        let size = (title as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attributes)
    }
}

/// A rounded, tinted well for a text field.
final class FieldWell: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.field
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A plain text field without a border, for the find bar. Hardware-keyboard keys that the
/// Mac's find fields handle (⇧↩, ↑, ↓, Esc, Tab) are passed to `onCommand`.
final class PlainField: UITextField {
    enum Command { case previous, up, down, cancel, tab, backtab }

    var onCommand: ((Command) -> Void)?

    convenience init(placeholder: String) {
        self.init(frame: .zero)
        borderStyle = .none
        font = UIFont.systemFont(ofSize: 15)
        textColor = Palette.text
        tintColor = Palette.text
        attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .font: UIFont.systemFont(ofSize: 15), .foregroundColor: Palette.tertiaryText,
        ])
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        inlinePredictionType = .no
        clearButtonMode = .never
        enablesReturnKeyAutomatically = false
        accessibilityLabel = placeholder
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(previousKey)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upKey)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downKey)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelKey)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKey)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(backtabKey)),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func previousKey() { onCommand?(.previous) }
    @objc private func upKey() { onCommand?(.up) }
    @objc private func downKey() { onCommand?(.down) }
    @objc private func cancelKey() { onCommand?(.cancel) }
    @objc private func tabKey() { onCommand?(.tab) }
    @objc private func backtabKey() { onCommand?(.backtab) }
}

/// Ticks at the right edge of the canvas, one per match. Tap one to jump to it.
final class MatchMarksView: UIView {
    /// Positions from 0 (top) to 1 (bottom).
    var marks: [CGFloat] = [] { didSet { setNeedsDisplay() } }
    var current: CGFloat? { didSet { setNeedsDisplay() } }
    var onTap: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(redraw))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func redraw() { setNeedsDisplay() }

    /// Touches pass through to the text when there's nothing to tap.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !marks.isEmpty && super.point(inside: point, with: event)
    }

    override func draw(_ rect: CGRect) {
        guard !marks.isEmpty else { return }
        let usable = bounds.height - 8
        Palette.mark.setFill()
        var lastY: CGFloat = -10
        for mark in marks {
            let y = (4 + mark * usable).rounded()
            if y - lastY < 2 { continue }
            lastY = y
            UIRectFill(CGRect(x: bounds.width - 9, y: y - 1, width: 6, height: 2))
        }
        if let current {
            Palette.text.setFill()
            UIRectFill(CGRect(x: bounds.width - 11, y: (4 + current * usable).rounded() - 1.5, width: 8, height: 3))
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let y = recognizer.location(in: self).y
        onTap?(((y - 4) / max(1, bounds.height - 8)).clamped(to: 0...1))
    }
}

/// The thin bar above a read-only version or a deleted note: what it is, and what you can do.
/// On narrow screens the actions wrap onto a second line.
final class PreviewBar: UIView {
    private let label = UILabel()
    private let buttons = UIStackView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = Palette.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(buttons)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = Hairline(.horizontal)
        addSubview(line)
        // Vertical constraints sit just under required so the editor's stack view can fold the bar away.
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        bottom.priority = .init(999)
        let height = stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bottom,
            height,
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, actions: [(String, () -> Void)]) {
        label.text = text
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, handler) in actions {
            buttons.addArrangedSubview(MonoButton(text: title, action: UIAction { _ in handler() }))
        }
        accessibilityLabel = text
    }

    override func layoutSubviews() {
        // Label and actions side by side when there's room, stacked when there isn't.
        let narrow = bounds.width < 520
        let axis: NSLayoutConstraint.Axis = narrow ? .vertical : .horizontal
        if stack.axis != axis {
            stack.axis = axis
            stack.alignment = narrow ? .leading : .center
            stack.spacing = narrow ? 0 : 12
        }
        super.layoutSubviews()
    }
}
