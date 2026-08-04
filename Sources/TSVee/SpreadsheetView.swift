import AppKit

struct GridPos: Equatable {
    var row: Int
    var col: Int
}

/// The grid itself. A single custom-drawn view (only visible cells are ever
/// drawn) inside an NSScrollView, with Google-Sheets-style chrome: column
/// letters, row numbers, accent-colored range selection, drag-to-resize
/// columns, type-to-edit, and phantom rows/columns past the end of the data
/// that materialize when you edit them.
final class SpreadsheetView: NSView, NSTextFieldDelegate, NSMenuItemValidation {

    // MARK: - Configuration

    private enum Metrics {
        static let rowHeaderWidth: CGFloat = 52
        static let colHeaderHeight: CGFloat = 26
        static let defaultRowHeight: CGFloat = 24
        static let defaultColWidth: CGFloat = 110
        static let idColWidth: CGFloat = 180
        static let headerRowHeights: [CGFloat] = [34, 29, 25]   // levels 1–3
        static let minColWidth: CGFloat = 36
        static let phantomRows = 200
        static let phantomCols = 26
        static let resizeGrabMargin: CGFloat = 4
    }

    private enum Palette {
        static var gridLine: NSColor { NSColor.separatorColor.withAlphaComponent(0.4) }
        static var chromeBackground: NSColor { .windowBackgroundColor }
        static var chromeText: NSColor { .secondaryLabelColor }
        static var chromeSelected: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.25) }
        static var selectionFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.10) }
        static var selectionBorder: NSColor { .controlAccentColor }
        static var duplicateFill: NSColor { NSColor.systemRed.withAlphaComponent(0.18) }
        static var fieldRowFill: NSColor { NSColor.windowBackgroundColor.withAlphaComponent(0.8) }
        static func headerFill(level: Int) -> NSColor {
            let alphas: [CGFloat] = [0.18, 0.11, 0.06]
            return NSColor.controlAccentColor.withAlphaComponent(alphas[min(max(level, 1), 3) - 1])
        }
    }

    // MARK: - Wiring

    weak var model: SpreadsheetModel? {
        didSet { modelDidChange() }
    }
    var formatProvider: (() -> TSSFormat)?
    /// Read-modify-write access to the document's TSSFormat (marks it dirty).
    var onFormatChange: (((inout TSSFormat) -> Void) -> Void)?
    var onSelectionChange: (() -> Void)?

    // MARK: - State

    private var gridRows = 1
    private var gridCols = 1
    private var xOffsets: [CGFloat] = [Metrics.rowHeaderWidth]
    private var yOffsets: [CGFloat] = [Metrics.colHeaderHeight]
    private var cachedWidths: [Int: CGFloat] = [:]
    private var cachedHeights: [Int: CGFloat] = [:]

    private var anchor = GridPos(row: 0, col: 0)
    private var focus = GridPos(row: 0, col: 0)

    private var editor: NSTextField?
    private var editingCell: GridPos?
    private var editSessionFromTyping = false
    private var isCommittingEdit = false

    private enum DragMode {
        case none
        case selectCells
        case selectRows
        case selectColumns
        case resizeColumn(col: Int, startX: CGFloat, startWidth: CGFloat)
    }
    private var dragMode: DragMode = .none

    // MARK: - View basics

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
    override var undoManager: UndoManager? { model?.undoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clipView = enclosingScrollView?.contentView else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func clipBoundsChanged() {
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: - Geometry

    private func width(ofColumn c: Int) -> CGFloat {
        cachedWidths[c] ?? (c == 0 ? Metrics.idColWidth : Metrics.defaultColWidth)
    }

    private func height(ofRow r: Int) -> CGFloat {
        if let custom = cachedHeights[r] { return custom }
        if let model, r < model.rowCount {
            let level = model.headerLevel(ofRow: r)
            if level > 0 { return Metrics.headerRowHeights[level - 1] }
        }
        return Metrics.defaultRowHeight
    }

    func modelDidChange() {
        guard let model else { return }
        let format = formatProvider?() ?? TSSFormat()
        cachedWidths = format.columnWidths
        cachedHeights = format.rowHeights
        gridRows = model.rowCount + Metrics.phantomRows
        gridCols = model.columnCount + Metrics.phantomCols
        clampSelection()
        rebuildOffsets()
        needsDisplay = true
    }

    private func rebuildOffsets() {
        xOffsets = [Metrics.rowHeaderWidth]
        xOffsets.reserveCapacity(gridCols + 1)
        for c in 0..<gridCols { xOffsets.append(xOffsets[c] + width(ofColumn: c)) }

        yOffsets = [Metrics.colHeaderHeight]
        yOffsets.reserveCapacity(gridRows + 1)
        for r in 0..<gridRows { yOffsets.append(yOffsets[r] + height(ofRow: r)) }

        setFrameSize(NSSize(width: xOffsets[gridCols], height: yOffsets[gridRows]))
    }

    private func cellRect(_ row: Int, _ col: Int) -> NSRect {
        NSRect(x: xOffsets[col], y: yOffsets[row],
               width: xOffsets[col + 1] - xOffsets[col],
               height: yOffsets[row + 1] - yOffsets[row])
    }

    /// Index of the row/column containing the given offset (clamped).
    private func index(in offsets: [CGFloat], of position: CGFloat) -> Int {
        var low = 0, high = offsets.count - 2
        if position <= offsets[0] { return 0 }
        if position >= offsets[high + 1] { return high }
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func rowAt(_ y: CGFloat) -> Int { index(in: yOffsets, of: y) }
    private func colAt(_ x: CGFloat) -> Int { index(in: xOffsets, of: x) }

    private func clampSelection() {
        anchor.row = min(max(anchor.row, 0), gridRows - 1)
        anchor.col = min(max(anchor.col, 0), gridCols - 1)
        focus.row = min(max(focus.row, 0), gridRows - 1)
        focus.col = min(max(focus.col, 0), gridCols - 1)
    }

    private var selectedRows: ClosedRange<Int> { min(anchor.row, focus.row)...max(anchor.row, focus.row) }
    private var selectedCols: ClosedRange<Int> { min(anchor.col, focus.col)...max(anchor.col, focus.col) }

    // MARK: - Cell naming (A1 style)

    static func columnLetters(_ index: Int) -> String {
        var name = ""
        var n = index
        while true {
            name = String(UnicodeScalar(UInt8(65 + n % 26))) + name
            n = n / 26 - 1
            if n < 0 { break }
        }
        return name
    }

    func focusedCellName() -> String {
        Self.columnLetters(focus.col) + String(focus.row + 1)
    }

    func focusedCellValue() -> String {
        model?.value(row: focus.row, column: focus.col) ?? ""
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let model, gridRows > 0, gridCols > 0 else { return }

        let vis = visibleRect
        let r0 = rowAt(max(dirtyRect.minY, yOffsets[0]))
        let r1 = rowAt(min(dirtyRect.maxY, yOffsets[gridRows] - 0.5))
        let c0 = colAt(max(dirtyRect.minX, xOffsets[0]))
        let c1 = colAt(min(dirtyRect.maxX, xOffsets[gridCols] - 0.5))

        drawRowBackgrounds(model: model, rows: r0...r1)
        drawSelectionFill()
        drawGridLines(rows: r0...r1, cols: c0...c1, in: dirtyRect)
        drawCellText(model: model, rows: r0...r1, cols: c0...c1)
        drawSelectionBorder()
        drawChrome(vis: vis, model: model)
    }

    private func drawRowBackgrounds(model: SpreadsheetModel, rows: ClosedRange<Int>) {
        let fullWidth = xOffsets[gridCols] - xOffsets[0]
        for r in rows {
            var fill: NSColor?
            if r < model.rowCount {
                let level = model.headerLevel(ofRow: r)
                if level > 0 { fill = Palette.headerFill(level: level) }
                else if model.isFieldNameRow(r) { fill = Palette.fieldRowFill }
            }
            if let fill {
                fill.setFill()
                NSRect(x: xOffsets[0], y: yOffsets[r], width: fullWidth, height: height(ofRow: r)).fill()
            }
            if model.duplicateIDRows.contains(r) {
                Palette.duplicateFill.setFill()
                cellRect(r, 0).fill()
            }
        }
    }

    private func drawSelectionFill() {
        Palette.selectionFill.setFill()
        selectionRect().fill()
    }

    private func selectionRect() -> NSRect {
        let rows = selectedRows, cols = selectedCols
        return NSRect(
            x: xOffsets[cols.lowerBound],
            y: yOffsets[rows.lowerBound],
            width: xOffsets[cols.upperBound + 1] - xOffsets[cols.lowerBound],
            height: yOffsets[rows.upperBound + 1] - yOffsets[rows.lowerBound])
    }

    private func drawGridLines(rows: ClosedRange<Int>, cols: ClosedRange<Int>, in dirty: NSRect) {
        Palette.gridLine.setFill()
        let top = max(dirty.minY, yOffsets[0])
        let bottom = min(dirty.maxY, yOffsets[gridRows])
        let left = max(dirty.minX, xOffsets[0])
        let right = min(dirty.maxX, xOffsets[gridCols])
        for c in cols.lowerBound...(cols.upperBound + 1) {
            NSRect(x: xOffsets[c] - 0.5, y: top, width: 1, height: bottom - top).fill()
        }
        for r in rows.lowerBound...(rows.upperBound + 1) {
            NSRect(x: left, y: yOffsets[r] - 0.5, width: right - left, height: 1).fill()
        }
    }

    private func cellFont(forRow row: Int) -> NSFont {
        guard let model else { return .systemFont(ofSize: 12) }
        switch model.headerLevel(ofRow: row) {
        case 1: return .systemFont(ofSize: 14, weight: .bold)
        case 2: return .systemFont(ofSize: 13, weight: .semibold)
        case 3: return .systemFont(ofSize: 12, weight: .semibold)
        default:
            return model.isFieldNameRow(row)
                ? .systemFont(ofSize: 12, weight: .semibold)
                : .systemFont(ofSize: 12)
        }
    }

    private func drawCellText(model: SpreadsheetModel, rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        guard let context = NSGraphicsContext.current else { return }
        for r in rows {
            guard r < model.rowCount else { break }
            let font = cellFont(forRow: r)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            for c in cols {
                guard c < model.columnCount else { break }
                let text = model.value(row: r, column: c)
                guard !text.isEmpty else { continue }
                if editingCell == GridPos(row: r, col: c) { continue }
                let rect = cellRect(r, c)
                let size = text.size(withAttributes: attrs)
                context.saveGraphicsState()
                rect.insetBy(dx: 1, dy: 1).clip()
                text.draw(
                    at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2),
                    withAttributes: attrs)
                context.restoreGraphicsState()
            }
        }
    }

    private func drawSelectionBorder() {
        guard editor == nil else { return }
        let rect = selectionRect().insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        Palette.selectionBorder.setStroke()
        path.stroke()
    }

    private func drawChrome(vis: NSRect, model: SpreadsheetModel) {
        let headerH = Metrics.colHeaderHeight
        let headerW = Metrics.rowHeaderWidth
        let chromeFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

        // Column letter band (sticky at the top of the viewport).
        let band = NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: headerH)
        Palette.chromeBackground.setFill()
        band.fill()

        let c0 = colAt(max(vis.minX, xOffsets[0]))
        let c1 = colAt(min(vis.maxX, xOffsets[gridCols] - 0.5))
        for c in c0...c1 {
            let rect = NSRect(x: xOffsets[c], y: vis.minY,
                              width: xOffsets[c + 1] - xOffsets[c], height: headerH)
            if selectedCols.contains(c) {
                Palette.chromeSelected.setFill()
                rect.fill()
            }
            let title = Self.columnLetters(c)
            let attrs: [NSAttributedString.Key: Any] = [.font: chromeFont, .foregroundColor: Palette.chromeText]
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
            Palette.gridLine.setFill()
            NSRect(x: rect.maxX - 0.5, y: vis.minY, width: 1, height: headerH).fill()
        }

        // Row number strip (sticky at the left of the viewport).
        let strip = NSRect(x: vis.minX, y: vis.minY + headerH, width: headerW, height: vis.height - headerH)
        Palette.chromeBackground.setFill()
        strip.fill()

        let r0 = rowAt(max(vis.minY, yOffsets[0]))
        let r1 = rowAt(min(vis.maxY, yOffsets[gridRows] - 0.5))
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        for r in r0...r1 {
            let rect = NSRect(x: vis.minX, y: yOffsets[r], width: headerW, height: height(ofRow: r))
            guard rect.maxY > vis.minY + headerH else { continue }
            if selectedRows.contains(r) {
                Palette.chromeSelected.setFill()
                rect.fill()
            }
            let isDuplicate = model.duplicateIDRows.contains(r)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: isDuplicate ? NSColor.systemRed : Palette.chromeText,
            ]
            let title = String(r + 1)
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.maxX - size.width - 7, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
            Palette.gridLine.setFill()
            NSRect(x: vis.minX, y: rect.maxY - 0.5, width: headerW, height: 1).fill()
        }

        // Corner box.
        let corner = NSRect(x: vis.minX, y: vis.minY, width: headerW, height: headerH)
        Palette.chromeBackground.setFill()
        corner.fill()

        // Chrome edges.
        Palette.gridLine.setFill()
        NSRect(x: vis.minX, y: vis.minY + headerH - 0.5, width: vis.width, height: 1).fill()
        NSRect(x: vis.minX + headerW - 0.5, y: vis.minY, width: 1, height: vis.height).fill()
    }

    // MARK: - Hit testing

    private enum HitArea {
        case corner
        case columnHeader(col: Int, resizeEdgeOf: Int?)
        case rowHeader(row: Int)
        case cell(GridPos)
    }

    private func hitArea(at p: NSPoint) -> HitArea {
        let vis = visibleRect
        let inColumnBand = p.y < vis.minY + Metrics.colHeaderHeight
        let inRowStrip = p.x < vis.minX + Metrics.rowHeaderWidth
        if inColumnBand && inRowStrip { return .corner }
        if inColumnBand {
            let c = colAt(p.x)
            // Near a column's right edge (or the previous column's edge)?
            if abs(p.x - xOffsets[c + 1]) <= Metrics.resizeGrabMargin {
                return .columnHeader(col: c, resizeEdgeOf: c)
            }
            if c > 0 && abs(p.x - xOffsets[c]) <= Metrics.resizeGrabMargin {
                return .columnHeader(col: c, resizeEdgeOf: c - 1)
            }
            return .columnHeader(col: c, resizeEdgeOf: nil)
        }
        if inRowStrip { return .rowHeader(row: rowAt(p.y)) }
        return .cell(GridPos(row: rowAt(p.y), col: colAt(p.x)))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitEdit(thenMove: nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)

        switch hitArea(at: p) {
        case .corner:
            selectAll(nil)

        case .columnHeader(let c, let resizeEdge):
            if let edge = resizeEdge {
                dragMode = .resizeColumn(col: edge, startX: p.x, startWidth: width(ofColumn: edge))
            } else {
                if shift { focus = GridPos(row: gridRows - 1, col: c) }
                else {
                    anchor = GridPos(row: 0, col: c)
                    focus = GridPos(row: gridRows - 1, col: c)
                }
                dragMode = .selectColumns
                selectionDidChange()
            }

        case .rowHeader(let r):
            if shift { focus = GridPos(row: r, col: gridCols - 1) }
            else {
                anchor = GridPos(row: r, col: 0)
                focus = GridPos(row: r, col: gridCols - 1)
            }
            dragMode = .selectRows
            selectionDidChange()

        case .cell(let pos):
            if shift {
                focus = pos
            } else {
                anchor = pos
                focus = pos
            }
            dragMode = .selectCells
            selectionDidChange()
            if event.clickCount == 2 {
                beginEditing(at: pos, initialText: nil)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .none:
            break
        case .selectCells:
            focus = GridPos(row: rowAt(p.y), col: colAt(p.x))
            selectionDidChange()
        case .selectRows:
            focus = GridPos(row: rowAt(p.y), col: gridCols - 1)
            selectionDidChange()
        case .selectColumns:
            focus = GridPos(row: gridRows - 1, col: colAt(p.x))
            selectionDidChange()
        case .resizeColumn(let col, let startX, let startWidth):
            let newWidth = max(Metrics.minColWidth, startWidth + (p.x - startX))
            cachedWidths[col] = newWidth
            rebuildOffsets()
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .resizeColumn(let col, _, _) = dragMode, let finalWidth = cachedWidths[col] {
            onFormatChange? { format in
                format.columnWidths[col] = finalWidth
            }
        }
        dragMode = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .columnHeader(_, .some) = hitArea(at: p) {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.utf16.first else {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags
        let shift = mods.contains(.shift)

        switch Int(scalar) {
        case NSUpArrowFunctionKey: move(dRow: -1, dCol: 0, extend: shift)
        case NSDownArrowFunctionKey: move(dRow: 1, dCol: 0, extend: shift)
        case NSLeftArrowFunctionKey: move(dRow: 0, dCol: -1, extend: shift)
        case NSRightArrowFunctionKey: move(dRow: 0, dCol: 1, extend: shift)
        case 9: move(dRow: 0, dCol: 1, extend: false)                       // Tab
        case 25: move(dRow: 0, dCol: -1, extend: false)                     // Shift-Tab
        case 13, 3:                                                          // Return / Enter
            beginEditing(at: focus, initialText: nil)
        case 127, NSDeleteFunctionKey:                                       // Backspace / Del
            clearSelectedCells()
        case 27:                                                             // Escape
            break
        default:
            let isFunctionKey = scalar >= 0xF700
            let hasCommand = mods.contains(.command) || mods.contains(.control)
            if !isFunctionKey, !hasCommand, chars.rangeOfCharacter(from: .controlCharacters) == nil {
                beginEditing(at: focus, initialText: chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func move(dRow: Int, dCol: Int, extend: Bool) {
        var target = focus
        target.row = min(max(target.row + dRow, 0), gridRows - 1)
        target.col = min(max(target.col + dCol, 0), gridCols - 1)
        focus = target
        if !extend { anchor = target }
        scrollCellToVisible(target)
        selectionDidChange()
    }

    private func scrollCellToVisible(_ pos: GridPos) {
        // Expand by the chrome size so the cell is never hidden under the
        // sticky headers.
        var rect = cellRect(pos.row, pos.col)
        rect.origin.x -= Metrics.rowHeaderWidth
        rect.origin.y -= Metrics.colHeaderHeight
        rect.size.width += Metrics.rowHeaderWidth
        rect.size.height += Metrics.colHeaderHeight
        scrollToVisible(rect)
    }

    private func selectionDidChange() {
        needsDisplay = true
        onSelectionChange?()
    }

    // MARK: - Editing

    private func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    func beginEditing(at pos: GridPos, initialText: String?) {
        guard let model else { return }
        commitEdit(thenMove: nil)
        anchor = pos
        focus = pos
        selectionDidChange()
        scrollCellToVisible(pos)

        let field = NSTextField(frame: cellRect(pos.row, pos.col).insetBy(dx: 1, dy: 1))
        field.font = cellFont(forRow: pos.row)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.stringValue = initialText ?? model.value(row: pos.row, column: pos.col)
        addSubview(field)

        editor = field
        editingCell = pos
        editSessionFromTyping = (initialText != nil)
        window?.makeFirstResponder(field)
        if let fieldEditor = field.currentEditor() {
            fieldEditor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
        needsDisplay = true
    }

    private enum MoveAfterEdit { case up, down, left, right }

    private func commitEdit(thenMove direction: MoveAfterEdit?) {
        guard let field = editor, let cell = editingCell, !isCommittingEdit else { return }
        isCommittingEdit = true
        let text = sanitize(field.stringValue)
        editor = nil
        editingCell = nil
        field.removeFromSuperview()
        model?.setValue(text, row: cell.row, column: cell.col)
        isCommittingEdit = false
        window?.makeFirstResponder(self)
        switch direction {
        case .up: move(dRow: -1, dCol: 0, extend: false)
        case .down: move(dRow: 1, dCol: 0, extend: false)
        case .left: move(dRow: 0, dCol: -1, extend: false)
        case .right: move(dRow: 0, dCol: 1, extend: false)
        case nil: needsDisplay = true
        }
    }

    private func cancelEdit() {
        guard let field = editor else { return }
        editor = nil
        editingCell = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Commit coming from the formula bar.
    func applyToFocusedCell(_ text: String) {
        model?.setValue(sanitize(text), row: focus.row, column: focus.col)
        window?.makeFirstResponder(self)
    }

    // MARK: - NSTextFieldDelegate (the in-cell editor)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editor else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            commitEdit(thenMove: shift ? .up : .down)
            return true
        case #selector(NSResponder.insertTab(_:)):
            commitEdit(thenMove: .right)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            commitEdit(thenMove: .left)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEdit()
            return true
        case #selector(NSResponder.moveUp(_:)):
            commitEdit(thenMove: .up)
            return true
        case #selector(NSResponder.moveDown(_:)):
            commitEdit(thenMove: .down)
            return true
        case #selector(NSResponder.moveLeft(_:)) where editSessionFromTyping:
            commitEdit(thenMove: .left)
            return true
        case #selector(NSResponder.moveRight(_:)) where editSessionFromTyping:
            commitEdit(thenMove: .right)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === editor else { return }
        commitEdit(thenMove: nil)
    }

    // MARK: - Clipboard & selection commands

    @objc func copy(_ sender: Any?) {
        guard let model else { return }
        let rows = selectedRows, cols = selectedCols
        let text = rows.map { r in
            cols.map { c in model.value(row: r, column: c) }.joined(separator: "\t")
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        clearSelectedCells()
    }

    @objc func paste(_ sender: Any?) {
        guard let model,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        var block = text
        if block.hasSuffix("\n") { block.removeLast() }
        let lines = block.components(separatedBy: "\n").map { line -> [String] in
            (line.hasSuffix("\r") ? String(line.dropLast()) : line).components(separatedBy: "\t")
        }
        let origin = GridPos(row: selectedRows.lowerBound, col: selectedCols.lowerBound)
        for (dr, line) in lines.enumerated() {
            for (dc, value) in line.enumerated() {
                model.setValue(value, row: origin.row + dr, column: origin.col + dc)
            }
        }
        undoManager?.setActionName("Paste")
        anchor = origin
        focus = GridPos(row: origin.row + lines.count - 1,
                        col: origin.col + (lines.map(\.count).max() ?? 1) - 1)
        clampSelection()
        selectionDidChange()
    }

    @objc func delete(_ sender: Any?) {
        clearSelectedCells()
    }

    override func selectAll(_ sender: Any?) {
        guard let model else { return }
        anchor = GridPos(row: 0, col: 0)
        focus = GridPos(row: max(model.rowCount - 1, 0), col: max(model.columnCount - 1, 0))
        selectionDidChange()
    }

    private func clearSelectedCells() {
        guard let model else { return }
        for r in selectedRows where r < model.rowCount {
            for c in selectedCols where c < model.columnCount {
                model.setValue("", row: r, column: c)
            }
        }
        undoManager?.setActionName("Clear Cells")
    }

    // MARK: - Undo plumbing

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    // MARK: - Row / column commands (Sheet menu + context menu)

    @objc func insertRowAbove(_ sender: Any?) {
        model?.insertRow(at: selectedRows.lowerBound)
    }

    @objc func insertRowBelow(_ sender: Any?) {
        guard let model else { return }
        model.insertRow(at: min(selectedRows.upperBound + 1, model.rowCount))
    }

    @objc func deleteSelectedRows(_ sender: Any?) {
        guard let model else { return }
        let indexes = IndexSet(selectedRows.filter { $0 < model.rowCount })
        model.removeRows(indexes)
    }

    @objc func insertColumnLeft(_ sender: Any?) {
        model?.insertColumn(at: max(selectedCols.lowerBound, 1))
    }

    @objc func insertColumnRight(_ sender: Any?) {
        guard let model else { return }
        model.insertColumn(at: min(selectedCols.upperBound + 1, model.columnCount))
    }

    @objc func deleteSelectedColumns(_ sender: Any?) {
        guard let model else { return }
        let indexes = IndexSet(selectedCols.filter { $0 >= 1 && $0 < model.columnCount })
        model.removeColumns(indexes)
    }

    @objc func jumpToNextDuplicateID(_ sender: Any?) {
        guard let model, !model.duplicateIDRows.isEmpty else { return }
        let sorted = model.duplicateIDRows.sorted()
        let next = sorted.first(where: { $0 > focus.row }) ?? sorted[0]
        anchor = GridPos(row: next, col: 0)
        focus = anchor
        scrollCellToVisible(anchor)
        selectionDidChange()
    }

    // MARK: - Context menu & validation

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if case .cell(let pos) = hitArea(at: p), !(selectedRows.contains(pos.row) && selectedCols.contains(pos.col)) {
            anchor = pos
            focus = pos
            selectionDidChange()
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Insert Row Above", action: #selector(insertRowAbove(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Row Below", action: #selector(insertRowBelow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Rows", action: #selector(deleteSelectedRows(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Insert Column Left", action: #selector(insertColumnLeft(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Column Right", action: #selector(insertColumnRight(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Columns", action: #selector(deleteSelectedColumns(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            return undoManager?.canRedo ?? false
        case #selector(deleteSelectedColumns(_:)):
            guard let model else { return false }
            return selectedCols.contains(where: { $0 >= 1 && $0 < model.columnCount })
        case #selector(deleteSelectedRows(_:)):
            guard let model else { return false }
            return selectedRows.lowerBound < model.rowCount && model.rowCount > 1
        case #selector(jumpToNextDuplicateID(_:)):
            return !(model?.duplicateIDRows.isEmpty ?? true)
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }
}
