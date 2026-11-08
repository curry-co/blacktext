import Foundation

/// Per-device view settings. Notes themselves live in the database.
public enum Preferences {
    private static let defaults = UserDefaults.standard

    public static let defaultFontSize: CGFloat = 15
    public static let fontSizeRange: ClosedRange<CGFloat> = 10...36

    public static func register() {
        defaults.register(defaults: [
            "fontSize": Double(defaultFontSize),
            "sidebarVisible": true,
            "theme": "system",
            "spellCheck": true,
            "find.highlightAll": true,
            "find.matchCase": false,
            "find.wholeWord": false,
            "find.regex": false,
            "find.preserveCase": false,
            "find.history": [String](),
        ])
    }

    public static var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "fontSize")) }
        set { defaults.set(Double(newValue.clamped(to: fontSizeRange)), forKey: "fontSize") }
    }

    public static var sidebarVisible: Bool {
        get { defaults.bool(forKey: "sidebarVisible") }
        set { defaults.set(newValue, forKey: "sidebarVisible") }
    }

    public static var theme: String {
        get { defaults.string(forKey: "theme") ?? "system" }
        set { defaults.set(newValue, forKey: "theme") }
    }

    public static var spellCheck: Bool {
        get { defaults.bool(forKey: "spellCheck") }
        set { defaults.set(newValue, forKey: "spellCheck") }
    }

    public static var highlightAll: Bool {
        get { defaults.bool(forKey: "find.highlightAll") }
        set { defaults.set(newValue, forKey: "find.highlightAll") }
    }

    public static var matchCase: Bool {
        get { defaults.bool(forKey: "find.matchCase") }
        set { defaults.set(newValue, forKey: "find.matchCase") }
    }

    public static var wholeWord: Bool {
        get { defaults.bool(forKey: "find.wholeWord") }
        set { defaults.set(newValue, forKey: "find.wholeWord") }
    }

    public static var regex: Bool {
        get { defaults.bool(forKey: "find.regex") }
        set { defaults.set(newValue, forKey: "find.regex") }
    }

    public static var preserveCase: Bool {
        get { defaults.bool(forKey: "find.preserveCase") }
        set { defaults.set(newValue, forKey: "find.preserveCase") }
    }

    public static var findHistory: [String] {
        get { defaults.stringArray(forKey: "find.history") ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: "find.history") }
    }
}

/// The canvas's text size on iPhone and iPad, which follows the system Text Size setting (Dynamic Type).
/// `Preferences.fontSize` is the size picked at the standard setting; the system setting scales it by how
/// much bigger its body text is than standard. Pinching and ⌘+ / ⌘− change what's shown a point at a time.
public struct CanvasTextSize: Equatable {
    /// The system's body text size at the standard setting.
    public static let standardBodySize: CGFloat = 17

    /// The saved size, at the standard setting.
    public let base: CGFloat
    /// The system's body text size now, over the standard one.
    public let scale: CGFloat

    public init(base: CGFloat, systemBodySize: CGFloat) {
        self.base = base.clamped(to: Preferences.fontSizeRange)
        let scale = systemBodySize / Self.standardBodySize
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// The size the canvas shows, in whole points.
    public var points: CGFloat { (base * scale).rounded() }

    /// The sizes the canvas can show at this setting: the saved range, scaled.
    public var range: ClosedRange<CGFloat> {
        let low = (Preferences.fontSizeRange.lowerBound * scale).rounded(.up)
        let high = (Preferences.fontSizeRange.upperBound * scale).rounded(.down)
        return low...max(low, high)
    }

    /// The saved size that shows `points` (rounded, and kept in range) at this setting.
    public func base(showing points: CGFloat) -> CGFloat {
        (points.rounded().clamped(to: range) / scale).clamped(to: Preferences.fontSizeRange)
    }

    /// A point bigger or smaller than shown now.
    public func stepped(by delta: CGFloat) -> CanvasTextSize {
        CanvasTextSize(base: base(showing: points + delta), systemBodySize: scale * Self.standardBodySize)
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
