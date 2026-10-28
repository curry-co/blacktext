import Foundation

/// Per-Mac view settings. Notes themselves live in the database.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static let defaultFontSize: CGFloat = 15
    static let fontSizeRange: ClosedRange<CGFloat> = 10...36

    static func register() {
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

    static var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: "fontSize")) }
        set { defaults.set(Double(newValue.clamped(to: fontSizeRange)), forKey: "fontSize") }
    }

    static var sidebarVisible: Bool {
        get { defaults.bool(forKey: "sidebarVisible") }
        set { defaults.set(newValue, forKey: "sidebarVisible") }
    }

    static var theme: String {
        get { defaults.string(forKey: "theme") ?? "system" }
        set { defaults.set(newValue, forKey: "theme") }
    }

    static var spellCheck: Bool {
        get { defaults.bool(forKey: "spellCheck") }
        set { defaults.set(newValue, forKey: "spellCheck") }
    }

    static var highlightAll: Bool {
        get { defaults.bool(forKey: "find.highlightAll") }
        set { defaults.set(newValue, forKey: "find.highlightAll") }
    }

    static var matchCase: Bool {
        get { defaults.bool(forKey: "find.matchCase") }
        set { defaults.set(newValue, forKey: "find.matchCase") }
    }

    static var wholeWord: Bool {
        get { defaults.bool(forKey: "find.wholeWord") }
        set { defaults.set(newValue, forKey: "find.wholeWord") }
    }

    static var regex: Bool {
        get { defaults.bool(forKey: "find.regex") }
        set { defaults.set(newValue, forKey: "find.regex") }
    }

    static var preserveCase: Bool {
        get { defaults.bool(forKey: "find.preserveCase") }
        set { defaults.set(newValue, forKey: "find.preserveCase") }
    }

    static var findHistory: [String] {
        get { defaults.stringArray(forKey: "find.history") ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: "find.history") }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
