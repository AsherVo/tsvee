import AppKit

/// Spell checking for `text` columns, kept off the drawing path: the grid asks
/// for a cell's misspellings while drawing, gets whatever is cached (nothing,
/// the first time), and the check runs asynchronously behind it — so scrolling
/// never blocks on the spell checker. Results come back keyed by the string
/// itself, so they survive row/column edits and only new prose is ever checked.
final class SpellCheckIndex {

    /// Called on the main queue when a finished check changes what should be
    /// drawn. The grid uses it to redisplay.
    var onUpdate: (() -> Void)?

    /// Document tag shared by every check, so "Ignore Spelling" applies to the
    /// whole sheet rather than one cell.
    let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    private var cache: [String: [NSRange]] = [:]
    private var inFlight: Set<String> = []

    /// Misspelled ranges in `text` — empty while a first check is still in
    /// flight, which is why the grid redraws when `onUpdate` fires.
    func misspellings(in text: String) -> [NSRange] {
        if let cached = cache[text] { return cached }
        request(text)
        return []
    }

    private func request(_ text: String) {
        guard !inFlight.contains(text) else { return }
        inFlight.insert(text)
        let tag = documentTag
        _ = NSSpellChecker.shared.requestChecking(
            of: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: nil,
            inSpellDocumentWithTag: tag
        ) { [weak self] _, results, _, _ in
            let ranges = results.filter { $0.resultType == .spelling }.map(\.range)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(text)
                if self.cache.count > 20_000 { self.cache.removeAll() }
                self.cache[text] = ranges
                if !ranges.isEmpty { self.onUpdate?() }
            }
        }
    }

    /// Drops every cached result. Needed after Learn / Ignore Spelling, which
    /// can un-misspell a word anywhere in the sheet, not just where it was
    /// right-clicked.
    func invalidateAll() {
        cache.removeAll()
        inFlight.removeAll()
        onUpdate?()
    }
}

/// Draws (and hit-tests) a wrapped `text` cell through a TextKit stack rather
/// than `NSString.draw(in:)`, because laying the text out is what makes the
/// spelling squiggles placeable and lets a right-click be mapped back to the
/// word under the cursor. One instance is reused for every cell — it's
/// reconfigured per draw, never retained state.
final class TextCellRenderer {

    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()

    init() {
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
    }

    /// `rect` is the text area (the cell already inset), in the view's flipped
    /// coordinates.
    func draw(_ text: String, font: NSFont, color: NSColor,
              in rect: NSRect, misspellings: [NSRange]) {
        prepare(text: text, font: font, color: color, width: rect.width)
        let glyphs = layout.glyphRange(for: container)

        NSGraphicsContext.current?.saveGraphicsState()
        rect.clip()
        layout.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
        for range in misspellings {
            drawSquiggle(under: range, origin: rect.origin)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// Character offset in `text` under `point`, or nil when the click missed
    /// the glyphs (past the end of a line, below the last one, …).
    func characterIndex(in text: String, font: NSFont,
                        rect: NSRect, at point: NSPoint) -> Int? {
        guard rect.contains(point) else { return nil }
        prepare(text: text, font: font, color: .labelColor, width: rect.width)
        layout.ensureLayout(for: container)

        let local = NSPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container,
                                     fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        // glyphIndex(for:) clamps to the nearest glyph, so a click in the empty
        // space after a line would otherwise "hit" its last word.
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                      in: container)
        guard box.contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    private func prepare(text: String, font: NSFont, color: NSColor, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
        container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
    }

    /// The red zigzag AppKit puts under a misspelling in a text view. Drawn by
    /// hand (per line fragment, so wrapped words get a squiggle on each line)
    /// because temporary attributes only render inside a real text view.
    private func drawSquiggle(under characterRange: NSRange, origin: NSPoint) {
        let full = NSRange(location: 0, length: storage.length)
        guard let clamped = characterRange.intersection(full), clamped.length > 0 else { return }
        let glyphs = layout.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)

        NSColor.systemRed.setStroke()
        layout.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { fragment, _ in
            let path = NSBezierPath()
            let period: CGFloat = 3, amplitude: CGFloat = 1
            let baseline = fragment.maxY + origin.y - amplitude - 0.5
            var x = fragment.minX + origin.x
            let right = fragment.maxX + origin.x
            path.move(to: NSPoint(x: x, y: baseline))
            var up = true
            while x < right {
                x = min(x + period / 2, right)
                path.line(to: NSPoint(x: x, y: up ? baseline - amplitude : baseline + amplitude))
                up.toggle()
            }
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Payload for the spelling-correction context-menu items.
final class SpellingFix: NSObject {
    let pos: GridPos
    let range: NSRange
    let word: String
    /// nil for Learn / Ignore, which act on the word rather than replace it.
    let replacement: String?

    init(pos: GridPos, range: NSRange, word: String, replacement: String?) {
        self.pos = pos
        self.range = range
        self.word = word
        self.replacement = replacement
    }
}
