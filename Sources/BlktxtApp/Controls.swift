import AppKit

/// A small text toggle. On: inverted (like a find match). Off: gray text.
final class MonoToggle: NSControl {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    private let font12 = NSFont.systemFont(ofSize: 12)
    private var isPressed = false

    init(_ title: String, toolTip: String? = nil, target: AnyObject?, action: Selector) {
        self.title = title
        super.init(frame: .zero)
        self.toolTip = toolTip
        self.target = target
        self.action = action
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(toolTip ?? title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font12])
        return NSSize(width: ceil(size.width) + 14, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1.5), xRadius: 5, yRadius: 5)
        if isOn {
            Palette.text.setFill()
            shape.fill()
        } else if isPressed {
            Palette.field.setFill()
            shape.fill()
        }
        let color = isOn ? Palette.background : Palette.secondaryText
        let attributes: [NSAttributedString.Key: Any] = [.font: font12, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func accessibilityValue() -> Any? { isOn }
}

/// A borderless button: an SF Symbol or short text in gray, darker when pressed.
final class MonoButton: NSButton {
    convenience init(symbol: String, label: String, target: AnyObject?, action: Selector) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        self.init(image: image ?? NSImage(), target: target, action: action)
        title = ""
        configure()
        imagePosition = .imageOnly
        toolTip = label
        setAccessibilityLabel(label)
    }

    convenience init(text: String, target: AnyObject?, action: Selector) {
        self.init(title: text, target: target, action: action)
        configure()
        imagePosition = .noImage
        font = NSFont.systemFont(ofSize: 12)
        updateTitleColor()
    }

    private func configure() {
        isBordered = false
        bezelStyle = .inline
        contentTintColor = Palette.secondaryText
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    func setText(_ text: String) {
        title = text
        updateTitleColor()
    }

    private func updateTitleColor() {
        guard !title.isEmpty else { return }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? Palette.text : Palette.tertiaryText,
        ])
    }

    override var isEnabled: Bool {
        didSet { updateTitleColor() }
    }
}

/// The "+" at the top of the sidebar. 50% gray; solid black or white (the opposite of the
/// background) while the pointer is over it; back to gray once clicked.
final class NewNoteButton: NSControl {
    private static let gray = NSColor(white: 0.5, alpha: 1)
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        toolTip = "New note (⌘↩)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New note")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isHovered = false
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHovered ? Palette.inverse : Self.gray).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        Palette.background.setFill()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 6
        let thickness: CGFloat = 2
        NSRect(x: (center.x - arm).rounded(), y: (center.y - thickness / 2).rounded(), width: arm * 2, height: thickness).fill()
        NSRect(x: (center.x - thickness / 2).rounded(), y: (center.y - arm).rounded(), width: thickness, height: arm * 2).fill()
    }
}

/// A rounded, tinted well for a text field.
final class FieldWell: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Palette.field.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// A plain text field without a bezel, for the find bar.
final class PlainField: NSTextField {
    var onMove: ((_ up: Bool) -> Bool)?

    convenience init(placeholder: String) {
        self.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 13)
        textColor = Palette.text
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.tertiaryText,
        ])
        setAccessibilityLabel(placeholder)
    }
}

/// Ticks at the right edge of the canvas, one per match. Click one to jump to it.
final class MatchMarksView: NSView {
    /// Positions from 0 (top) to 1 (bottom).
    var marks: [CGFloat] = [] { didSet { needsDisplay = true } }
    var current: CGFloat? { didSet { needsDisplay = true } }
    var onClick: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        marks.isEmpty ? nil : super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty else { return }
        let usable = bounds.height - 8
        Palette.mark.setFill()
        var lastY = -10.0
        for mark in marks {
            let y = (4 + mark * usable).rounded()
            if y - lastY < 2 { continue }
            lastY = y
            NSRect(x: bounds.width - 9, y: y - 1, width: 6, height: 2).fill()
        }
        if let current {
            Palette.text.setFill()
            NSRect(x: bounds.width - 11, y: (4 + current * usable).rounded() - 1.5, width: 8, height: 3).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        onClick?(((y - 4) / max(1, bounds.height - 8)).clamped(to: 0...1))
    }
}

/// The thin bar above a read-only version or a deleted note: what it is, and what you can do.
final class PreviewBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = Palette.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 14
        for view in [label, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, actions: [(String, Selector)], target: AnyObject) {
        label.stringValue = text
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, action) in actions {
            buttons.addArrangedSubview(MonoButton(text: title, target: target, action: action))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        bounds.fill()
        Palette.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
