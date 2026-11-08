import UIKit
import BlackTextCore

/// The canvas: a plain-text UITextView on TextKit 1 with one font, a centered reading column,
/// and the find highlights (inverted matches, tinted rows) drawn by its layout manager.
final class EditorTextView: UITextView {
    /// Widest the text column gets, in points, as a multiple of the font size (about 70 characters).
    static let columnWidthInEms: CGFloat = 42
    static let verticalPadding: CGFloat = 22

    /// Room kept clear under the last line, so the Save+New button never covers it.
    var bottomClearance: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    private(set) var fontSize = Preferences.defaultFontSize
    private(set) var textAttributes = EditorTextView.attributes(fontSize: Preferences.defaultFontSize)
    private(set) var findMatches: [NSRange] = []
    private(set) var currentMatch: Int?
    private(set) var highlightAll = true
    /// The characters whose highlights were last redrawn.
    private var refreshedRange = NSRange(location: 0, length: 0)
    /// The layout manager only holds the text storage weakly, so the view keeps it alive.
    private var ownedStorage: NSTextStorage?

    /// A TextKit 1 stack with non-contiguous layout, so huge texts only lay out what's on screen.
    /// Built by hand (rather than `UITextView(usingTextLayoutManager: false)`) so the layout manager
    /// can be the one that draws find highlights.
    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = FindLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = EditorTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        view.configure()
        return view
    }

    var highlighter: FindLayoutManager? { layoutManager as? FindLayoutManager }

    private func configure() {
        backgroundColor = Palette.background
        // The caret, selection and handles: monochrome.
        tintColor = Palette.text
        isEditable = true
        isSelectable = true
        allowsEditingTextAttributes = false
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        spellCheckingType = Preferences.spellCheck ? .yes : .no
        dataDetectorTypes = []
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        adjustsFontForContentSizeCategory = false
        if #available(iOS 18.0, *) {
            // Writing Tools may rewrite, but only ever as plain text.
            allowedWritingToolsResultOptions = [.plainText]
        }
        applyFontSize(Preferences.fontSize)
        highlighter?.traits = traitCollection
        registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(appearanceDidChange))
    }

    @objc private func appearanceDidChange() {
        highlighter?.traits = traitCollection
        if !findMatches.isEmpty { refreshHighlights(force: true) }
    }

    // MARK: Font

    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (fontSize * 0.42).rounded()
        return [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: Palette.text, .paragraphStyle: paragraph]
    }

    var editorFont: UIFont { (textAttributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: fontSize) }

    /// A view setting, not formatting: every character gets the same new size.
    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        textAttributes = Self.attributes(fontSize: size)
        let selection = selectedRange
        if textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributes(textAttributes, range: NSRange(location: 0, length: textStorage.length))
            textStorage.endEditing()
        }
        typingAttributes = textAttributes
        if NSMaxRange(selection) <= textStorage.length { selectedRange = selection }
        highlighter?.lineSpacing = (size * 0.42).rounded()
        highlighter?.lineHeight = editorFont.lineHeight
        setNeedsLayout()
    }

    /// UIKit resets typing attributes when the selection moves (and on an empty text), which
    /// would drop the line spacing. Put ours back.
    func reassertTypingAttributes() {
        guard markedTextRange == nil else { return }
        typingAttributes = textAttributes
    }

    /// Replaces all text without touching undo or the delegate.
    func setPlainText(_ text: String) {
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        typingAttributes = textAttributes
    }

    func setSpellChecking(_ enabled: Bool) {
        spellCheckingType = enabled ? .yes : .no
    }

    // MARK: Layout

    override func layoutSubviews() {
        updateInsets()
        super.layoutSubviews()
        highlighter?.rowExtent = (x: -textContainerInset.left, width: bounds.width)
        highlighter?.traits = traitCollection
        refreshHighlights()
    }

    private func updateInsets() {
        let column = fontSize * Self.columnWidthInEms
        let minimum: CGFloat = traitCollection.horizontalSizeClass == .regular ? 28 : 20
        let x = max(minimum, ((bounds.width - column) / 2).rounded(.down))
        let inset = UIEdgeInsets(top: Self.verticalPadding, left: x,
                                 bottom: Self.verticalPadding + bottomClearance, right: x)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Paste

    /// Paste always arrives as plain text, in the canvas font.
    override func paste(_ sender: Any?) {
        guard isEditable, let string = UIPasteboard.general.string else { return }
        insertText(string)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return isEditable && UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Find highlights

    /// Ranges past the end of the text (from a search of text that has since got shorter) are dropped:
    /// TextKit throws on them.
    func setFindHighlights(_ matches: [NSRange], current: Int?, highlightAll: Bool) {
        let length = textStorage.length
        let matches = matches.last.map { NSMaxRange($0) <= length } ?? true ? matches : matches.filter { NSMaxRange($0) <= length }
        let current = current.flatMap { matches.indices.contains($0) ? $0 : nil }
        findMatches = matches
        currentMatch = current
        self.highlightAll = highlightAll
        highlighter?.matches = matches
        highlighter?.current = current
        highlighter?.highlightAll = highlightAll
        refreshHighlights(force: true)
    }

    func clearFindHighlights() {
        guard !findMatches.isEmpty || currentMatch != nil else { return }
        setFindHighlights([], current: nil, highlightAll: highlightAll)
    }

    /// The characters currently on screen.
    var visibleCharacterRange: NSRange {
        var rect = CGRect(origin: contentOffset, size: bounds.size)
        rect.origin.x -= textContainerInset.left
        rect.origin.y -= textContainerInset.top
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Asks for the highlights near the screen to be redrawn. Done in a window around what's
    /// visible so a note with a hundred thousand matches stays fast; scrolling calls this again.
    func refreshHighlights(force: Bool = false) {
        guard let highlighter else { return }
        let length = textStorage.length
        guard length > 0 else {
            refreshedRange = NSRange(location: 0, length: 0)
            return
        }
        let all = NSRange(location: 0, length: length)
        if !force, findMatches.isEmpty { return }
        let visible = visibleCharacterRange
        if !force, refreshedRange.length > 0, NSIntersectionRange(visible, refreshedRange).length == visible.length { return }

        let window: NSRange
        if length <= FindController.synchronousLimit {
            window = all
        } else {
            let start = max(0, visible.location - 40_000)
            window = NSRange(location: start, length: min(length, NSMaxRange(visible) + 40_000) - start)
        }
        let previous = NSIntersectionRange(refreshedRange, all)
        let stale = force && previous.length > 0 ? NSUnionRange(previous, window) : window
        highlighter.invalidateDisplay(forCharacterRange: stale)
        refreshedRange = window
    }

    /// Where a range sits, in this view's content coordinates.
    func rect(for range: NSRange) -> CGRect {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    /// Scrolls so `range` is comfortably on screen (about a third of the way down) if it isn't already.
    func reveal(_ range: NSRange) {
        let target = rect(for: range)
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        let comfortable = visible.insetBy(dx: 0, dy: min(60, visible.height / 4))
        guard !comfortable.contains(target) else { return }
        // With non-contiguous layout the content size can lag behind; never clamp short of the target.
        let contentHeight = max(contentSize.height, target.maxY + textContainerInset.bottom)
        let maxY = max(0, contentHeight - bounds.height)
        let y = min(max(0, target.midY - visible.height * 0.35), maxY)
        setContentOffset(CGPoint(x: contentOffset.x, y: y.rounded()), animated: false)
        refreshHighlights()
    }

    /// Scrolls so the caret (or selection) is on screen.
    func revealSelection() {
        let range = selectedRange
        guard range.location != NSNotFound, textStorage.length > 0 else {
            setContentOffset(.zero, animated: false)
            return
        }
        scrollRangeToVisible(range)
    }

    /// The first character on screen, and how far below the top edge its line starts.
    var scrollAnchor: (index: Int, offset: CGFloat) {
        let index = visibleCharacterRange.location
        guard index < textStorage.length else { return (index, 0) }
        return (index, rect(for: NSRange(location: index, length: 1)).minY - contentOffset.y)
    }

    /// Scrolls so the character from `scrollAnchor` is back where it was (after a text size change).
    func restoreScrollAnchor(_ anchor: (index: Int, offset: CGFloat)) {
        guard anchor.index > 0, anchor.index < textStorage.length else { return }
        let target = rect(for: NSRange(location: anchor.index, length: 1))
        let contentHeight = max(contentSize.height, target.maxY + textContainerInset.bottom)
        let maxY = max(0, contentHeight - bounds.height)
        let y = target.minY - anchor.offset
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(0, y), maxY).rounded()), animated: false)
    }
}

/// Draws find highlights without touching the text: faint row tints and inverted chips behind
/// matches, and the matched glyphs in the background color. Nothing goes into the text storage,
/// so undo and autosave never see a highlight.
final class FindLayoutManager: NSLayoutManager {
    var matches: [NSRange] = []
    var current: Int?
    var highlightAll = true
    /// The text view's traits, used to resolve the light/dark palette while drawing.
    var traits = UITraitCollection(userInterfaceStyle: .light)
    /// Where a tinted row starts and how wide it is, in text container coordinates (the whole view).
    var rowExtent: (x: CGFloat, width: CGFloat) = (0, 0)
    var lineSpacing: CGFloat = 0
    var lineHeight: CGFloat = 0
    /// While set, glyphs are drawn in this color instead of their own.
    private var glyphColor: CGColor?

    private func color(_ color: UIColor) -> CGColor {
        color.resolvedColor(with: traits).cgColor
    }

    /// Indices of matches that overlap `range`, found by binary search.
    private func matchIndices(overlapping range: NSRange) -> Range<Int> {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matches[mid]) <= range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < matches.count, matches[end].location < NSMaxRange(range) { end += 1 }
        return low..<end
    }

    private func highlightedIndices(forGlyphRange glyphs: NSRange) -> [Int] {
        guard !matches.isEmpty else { return [] }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Typing may have shortened the text since the matches were found; they're redone shortly.
        let length = textStorage?.length ?? 0
        return matchIndices(overlapping: characters).filter { (highlightAll || $0 == current) && NSMaxRange(matches[$0]) <= length }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let indices = highlightedIndices(forGlyphRange: glyphsToShow)
        guard !indices.isEmpty, let context = UIGraphicsGetCurrentContext(), let container = textContainers.first else { return }

        // Rows first, one fill per row so overlapping matches don't darken it.
        var rows: [CGFloat: (rect: CGRect, current: Bool)] = [:]
        for index in indices {
            let glyphs = glyphRange(forCharacterRange: matches[index], actualCharacterRange: nil)
            let isCurrent = index == current
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                let row = CGRect(x: origin.x + self.rowExtent.x, y: origin.y + lineRect.minY - self.lineSpacing / 2,
                                 width: self.rowExtent.width, height: lineRect.height)
                let existing = rows[row.minY]
                rows[row.minY] = (row, (existing?.current ?? false) || isCurrent)
            }
        }
        context.saveGState()
        for row in rows.values {
            context.setFillColor(color(row.current && highlightAll ? Palette.currentRowTint : Palette.rowTint))
            context.fill(row.rect)
        }

        // Then the inverted chips behind each match.
        let none = NSRange(location: NSNotFound, length: 0)
        let chips = UIBezierPath()
        for index in indices {
            let glyphs = glyphRange(forCharacterRange: matches[index], actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: none, in: container) { rect, _ in
                var chip = rect.offsetBy(dx: origin.x, dy: origin.y)
                if self.lineHeight > 0 { chip.size.height = self.lineHeight }
                chip = chip.insetBy(dx: -2, dy: -1)
                chips.append(UIBezierPath(roundedRect: chip, cornerRadius: 3))
            }
        }
        context.setFillColor(color(Palette.matchBackground))
        context.addPath(chips.cgPath)
        context.fillPath()
        context.restoreGState()
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        let indices = highlightedIndices(forGlyphRange: glyphsToShow)
        guard !indices.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        // Draw in runs: plain text as usual, matched text in the background color.
        let inverted = color(Palette.matchText)
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for index in indices {
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: matches[index], actualCharacterRange: nil), glyphsToShow)
            guard glyphs.length > 0, glyphs.location >= cursor else { continue }
            if glyphs.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyphs.location - cursor), at: origin)
            }
            glyphColor = inverted
            super.drawGlyphs(forGlyphRange: glyphs, at: origin)
            glyphColor = nil
            cursor = NSMaxRange(glyphs)
        }
        if cursor < end {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor), at: origin)
        }
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int,
                               font: UIFont, textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any], in context: CGContext) {
        guard let glyphColor else {
            super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font,
                               textMatrix: textMatrix, attributes: attributes, in: context)
            return
        }
        var attributes = attributes
        attributes[.foregroundColor] = UIColor(cgColor: glyphColor)
        context.saveGState()
        context.setFillColor(glyphColor)
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font,
                           textMatrix: textMatrix, attributes: attributes, in: context)
        context.restoreGState()
    }
}
