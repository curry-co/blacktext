import AppKit
import BlackTextCore

/// Every color in BlackText. Black, white, and transparencies of each. Nothing else.
enum Palette {
    static let background = dynamic(light: .white, dark: .black)
    static let text = dynamic(light: .black, dark: NSColor(white: 0.93, alpha: 1))
    static let secondaryText = dynamic(light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.45))
    static let tertiaryText = dynamic(light: NSColor(white: 0, alpha: 0.25), dark: NSColor(white: 1, alpha: 0.28))
    static let selection = dynamic(light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.25))
    static let rowTint = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10))
    static let currentRowTint = dynamic(light: NSColor(white: 0, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.17))
    static let matchBackground = text
    static let matchText = background
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))
    static let field = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.09))
    static let sidebarSelection = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.14))
    /// Pure black on white, pure white on black.
    static let inverse = dynamic(light: .black, dark: .white)
    static let mark = dynamic(light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.5))

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("blacktext.themeDidChange")
}

/// Light or dark. Follows the system until the sun/moon is clicked, then sticks.
enum Theme {
    enum Choice: String {
        case system, light, dark
    }

    static var choice: Choice {
        get { Choice(rawValue: Preferences.theme) ?? .system }
        set { Preferences.theme = newValue.rawValue }
    }

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func apply() {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    static func toggle() {
        choice = isDark ? .light : .dark
        apply()
    }
}

/// A view that fills itself with a (dynamic) color, so it follows light and dark.
class FillView: NSView {
    var color: NSColor = Palette.background {
        didSet { needsDisplay = true }
    }

    convenience init(color: NSColor) {
        self.init(frame: .zero)
        self.color = color
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}
