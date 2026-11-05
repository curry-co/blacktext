import AppKit

protocol EditorTextViewDelegate: AnyObject {
    /// Esc. Return true if handled.
    func editorTextViewDidCancel(_ textView: EditorTextView) -> Bool
}

/// The canvas: a plain-text NSTextView with one font, a centered reading column,
/// and the find highlights (inverted matches, tinted rows) drawn underneath the glyphs.
final class EditorTextView: NSTextView {
    weak var editorDelegate: EditorTextViewDelegate?

    /// Widest the text column gets, in points, as a multiple of the font size (about 70 characters).
    static let columnWidthInEms: CGFloat = 42
    static let minimumPadding: CGFloat = 28
    static let verticalPadding: CGFloat = 22

    private(set) var findMatches: [NSRange] = []
    private(set) var currentMatch: Int?
    private(set) var highlightAll = true
    private var coloredRange = NSRange(location: 0, length: 0)

    /// A TextKit 1 stack with non-contiguous layout, so huge texts only lay out what's needed.
    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        usesFindPanel = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        setSpellChecking(false)

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        drawsBackground = true
        backgroundColor = Palette.background
        textColor = Palette.text
        insertionPointColor = Palette.text
        selectedTextAttributes = [.backgroundColor: Palette.selection]
        applyFontSize(Preferences.fontSize)
    }

    func setSpellChecking(_ enabled: Bool) {
        isContinuousSpellCheckingEnabled = enabled
        // Spelling underlines only: no autocorrect, capitalization, or substitutions.
        enabledTextCheckingTypes = enabled ? NSTextCheckingResult.CheckingType.spelling.rawValue : 0
    }

    // MARK: Font

    var editorFont: NSFont { font ?? NSFont.systemFont(ofSize: Preferences.fontSize) }

    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (fontSize * 0.42).rounded()
        return [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Palette.text, .paragraphStyle: paragraph]
    }

    func applyFontSize(_ size: CGFloat) {
        let attributes = Self.attributes(fontSize: size)
        font = attributes[.font] as? NSFont
        defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        typingAttributes = attributes
        if let textStorage, textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
        }
        updateInsets()
    }

    /// Replaces all text without touching undo or the delegate.
    func setPlainText(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: Self.attributes(fontSize: Preferences.fontSize))
        textStorage?.setAttributedString(attributed)
        typingAttributes = Self.attributes(fontSize: Preferences.fontSize)
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let column = editorFont.pointSize * Self.columnWidthInEms
        let width = bounds.width
        let x = max(Self.minimumPadding, ((width - column) / 2).rounded(.down))
        let inset = NSSize(width: x, height: Self.verticalPadding)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Keys and clicks

    override func cancelOperation(_ sender: Any?) {
        if editorDelegate?.editorTextViewDidCancel(self) == true { return }
        super.cancelOperation(sender)
    }

    /// ⌘-click opens a link. Links look like any other text.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = url(at: convert(event.locationInWindow, from: nil)) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func url(at point: NSPoint) -> URL? {
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        guard index < text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        guard line.length < 20_000,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let match = detector.matches(in: string, range: line).first { NSLocationInRange(index, $0.range) }
        return match?.url
    }

    // MARK: Find highlights

    func setFindHighlights(_ matches: [NSRange], current: Int?, highlightAll: Bool) {
        findMatches = matches
        currentMatch = current
        self.highlightAll = highlightAll
        refreshMatchColors(force: true)
        needsDisplay = true
    }

    func clearFindHighlights() {
        setFindHighlights([], current: nil, highlightAll: highlightAll)
    }

    /// The characters currently on screen.
    var visibleCharacterRange: NSRange {
        guard let layoutManager, let textContainer else { return NSRange(location: 0, length: 0) }
        var rect = visibleRect
        rect.origin.x -= textContainerOrigin.x
        rect.origin.y -= textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Indices of matches that overlap `range`, found by binary search.
    private func matchIndices(overlapping range: NSRange) -> Range<Int> {
        var low = 0
        var high = findMatches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(findMatches[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < findMatches.count, findMatches[end].location < NSMaxRange(range) { end += 1 }
        return low..<end
    }

    private func isHighlighted(_ index: Int) -> Bool { highlightAll || index == currentMatch }

    /// Inverted text color for matches near the screen. Done in a window so a note with
    /// a hundred thousand matches stays fast; scrolling calls this again.
    func refreshMatchColors(force: Bool = false) {
        guard let layoutManager else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        let visible = visibleCharacterRange
        if !force, coloredRange.length > 0, NSIntersectionRange(visible, coloredRange).length == visible.length { return }

        let stale = force ? all : NSIntersectionRange(coloredRange, all)
        if stale.length > 0 { layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: stale) }
        coloredRange = NSRange(location: 0, length: 0)
        guard !findMatches.isEmpty else { return }

        let start = max(0, visible.location - 40_000)
        let window = NSRange(location: start, length: min(all.length, NSMaxRange(visible) + 40_000) - start)
        for index in matchIndices(overlapping: window) where isHighlighted(index) {
            let range = NSIntersectionRange(findMatches[index], all)
            if range.length > 0 { layoutManager.addTemporaryAttribute(.foregroundColor, value: Palette.matchText, forCharacterRange: range) }
        }
        coloredRange = window
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !findMatches.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        var containerRect = rect
        containerRect.origin.x -= origin.x
        containerRect.origin.y -= origin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let indices = matchIndices(overlapping: characters).filter(isHighlighted)
        guard !indices.isEmpty else { return }

        let spacing = (defaultParagraphStyle?.lineSpacing ?? 0)
        let lineHeight = layoutManager.defaultLineHeight(for: editorFont)

        // Rows first, one fill per row so overlapping matches don't darken it.
        var rows: [CGFloat: (rect: NSRect, current: Bool)] = [:]
        for index in indices {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: findMatches[index], actualCharacterRange: nil)
            let isCurrent = index == currentMatch
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                let row = NSRect(x: 0, y: lineRect.minY + origin.y - spacing / 2, width: self.bounds.width, height: lineRect.height)
                let existing = rows[row.minY]
                rows[row.minY] = (row, (existing?.current ?? false) || isCurrent)
            }
        }
        for row in rows.values {
            (row.current && highlightAll ? Palette.currentRowTint : Palette.rowTint).setFill()
            row.rect.fill()
        }

        // Then the inverted chips behind each match.
        Palette.matchBackground.setFill()
        let none = NSRange(location: NSNotFound, length: 0)
        for index in indices {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: findMatches[index], actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: none, in: textContainer) { rect, _ in
                var chip = rect.offsetBy(dx: origin.x, dy: origin.y)
                chip.size.height = lineHeight
                chip = chip.insetBy(dx: -2, dy: -1)
                NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// Where a match sits, in this view's coordinates.
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Scrolls so `range` is comfortably on screen (about a third of the way down) if it isn't already.
    func reveal(_ range: NSRange) {
        guard let rect = rect(for: range), let clip = enclosingScrollView?.contentView else { return }
        let visible = visibleRect
        let comfortable = visible.insetBy(dx: 0, dy: min(60, visible.height / 4))
        guard !comfortable.contains(rect) else { return }
        let y = max(0, min(rect.midY - visible.height * 0.35, bounds.height - visible.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}
