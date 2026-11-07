import UIKit
import BlackTextCore

/// Every color in BlackText. Black, white, and transparencies of each. Nothing else.
/// The same values as the Mac app's Palette.
enum Palette {
    static let background = dynamic(light: .white, dark: .black)
    static let text = dynamic(light: .black, dark: UIColor(white: 0.93, alpha: 1))
    static let secondaryText = dynamic(light: UIColor(white: 0, alpha: 0.45), dark: UIColor(white: 1, alpha: 0.45))
    static let tertiaryText = dynamic(light: UIColor(white: 0, alpha: 0.25), dark: UIColor(white: 1, alpha: 0.28))
    static let selection = dynamic(light: UIColor(white: 0, alpha: 0.15), dark: UIColor(white: 1, alpha: 0.25))
    static let rowTint = dynamic(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.10))
    static let currentRowTint = dynamic(light: UIColor(white: 0, alpha: 0.11), dark: UIColor(white: 1, alpha: 0.17))
    static let matchBackground = text
    static let matchText = background
    static let separator = dynamic(light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.12))
    static let field = dynamic(light: UIColor(white: 0, alpha: 0.05), dark: UIColor(white: 1, alpha: 0.09))
    static let sidebarSelection = dynamic(light: UIColor(white: 0, alpha: 0.08), dark: UIColor(white: 1, alpha: 0.14))
    /// Pure black on white, pure white on black.
    static let inverse = dynamic(light: .black, dark: .white)
    static let mark = dynamic(light: UIColor(white: 0, alpha: 0.45), dark: UIColor(white: 1, alpha: 0.5))
    /// The + and Save+New buttons at rest.
    static let buttonGray = UIColor(white: 0.5, alpha: 1)
    /// Over the canvas while the sidebar slides over it on iPhone.
    static let dim = dynamic(light: UIColor(white: 0, alpha: 0.18), dark: UIColor(white: 1, alpha: 0.10))

    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }
}

/// Light or dark. Follows the system until the sun/moon is tapped, then sticks.
@MainActor
enum Theme {
    enum Choice: String {
        case system, light, dark
    }

    static var choice: Choice {
        get { Choice(rawValue: Preferences.theme) ?? .system }
        set { Preferences.theme = newValue.rawValue }
    }

    /// Whether `window` shows dark. Read from the choice, so it's right the moment the toggle flips.
    static func isDark(in window: UIWindow?) -> Bool {
        switch choice {
        case .light: return false
        case .dark: return true
        case .system:
            let traits = window?.windowScene?.traitCollection ?? window?.traitCollection
            return traits?.userInterfaceStyle == .dark
        }
    }

    static func apply(to window: UIWindow?) {
        switch choice {
        case .system: window?.overrideUserInterfaceStyle = .unspecified
        case .light: window?.overrideUserInterfaceStyle = .light
        case .dark: window?.overrideUserInterfaceStyle = .dark
        }
    }

    static func toggle(in window: UIWindow?) {
        choice = isDark(in: window) ? .light : .dark
        apply(to: window)
    }
}

/// A thin line in the separator color, one pixel tall (or wide).
final class Hairline: UIView {
    enum Axis { case horizontal, vertical }
    private let axis: Axis

    init(_ axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        backgroundColor = Palette.separator
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let pixel = 1 / max(1, traitCollection.displayScale)
        return axis == .horizontal
            ? CGSize(width: UIView.noIntrinsicMetric, height: pixel)
            : CGSize(width: pixel, height: UIView.noIntrinsicMetric)
    }
}
