import AppKit

struct GridPos: Equatable {
    var row: Int
    var col: Int
}

/// The grid itself. A single custom-drawn view (only visible cells are ever
/// drawn) inside an NSScrollView, with Google-Sheets-style chrome: column
/// letters, row numbers, accent-colored range selection, frozen panes for the
/// field-name row and ID column, a fill handle (autofill), drag-to-move rows
/// and columns, drag-to-resize columns, type-to-edit, and phantom
/// rows/columns past the end of the data that materialize when you edit them.
///
/// Frozen panes are rendered by drawing the same document-space content up to
/// four times with different (translation, clip) pairs. Because every frozen
/// row/column sits at the very start of the document, translating by the
/// scroll offset pins it to the viewport edge, and the clip guarantees
/// non-frozen content can never leak into a frozen pane.
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
        static let fillHandleGrabMargin: CGFloat = 6
    }

    private enum Palette {
        static var gridLine: NSColor { NSColor.separatorColor.withAlphaComponent(0.4) }
        static var paneEdge: NSColor { NSColor.separatorColor }
        static var chromeBackground: NSColor { .windowBackgroundColor }
        static var chromeText: NSColor { .secondaryLabelColor }
        static var chromeSelected: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.25) }
        static var selectionFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.10) }
        static var selectionBorder: NSColor { .controlAccentColor }
        static var duplicateFill: NSColor { NSColor.systemRed.withAlphaComponent(0.18) }
        /// Field-name row: neutral grey, clearly distinct from the
        /// accent-tinted section headers.
        static var fieldRowFill: NSColor { NSColor.systemGray.withAlphaComponent(0.22) }
        static func headerFill(level: Int) -> NSColor {
            switch level {
            case 1: return NSColor.controlAccentColor.withAlphaComponent(0.32)
            case 2: return NSColor.controlAccentColor.withAlphaComponent(0.20)
            default: return NSColor.systemGray.withAlphaComponent(0.08)   // ### = comment
            }
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
    private var cachedTypes: [Int: ColumnType] = [:]
    private var textColumnIndices: [Int] = []
    /// Wrapped-text height memo, keyed by "width|text" (value-based, so it
    /// survives model changes).
    private var wrapHeightCache: [String: CGFloat] = [:]

    /// 1 when the field-name row / ID column is frozen, else 0.
    private var frozenRowCount = 0
    private var frozenColCount = 0

    private var anchor = GridPos(row: 0, col: 0)
    private var focus = GridPos(row: 0, col: 0)

    private var editor: NSTextField?
    private var editingCell: GridPos?
    private var editSessionFromTyping = false
    private var isCommittingEdit = false

    private enum FillDirection { case up, down, left, right }

    private enum DragMode {
        case none
        case selectCells
        case selectRows
        case selectColumns
        case resizeColumn(col: Int, startX: CGFloat, startWidth: CGFloat)
        case fillHandle
        case moveRows(ClosedRange<Int>)
        case moveColumns(ClosedRange<Int>)
    }
    private var dragMode: DragMode = .none
    private var didDragSinceMouseDown = false
    private var pendingHeaderReselect: (() -> Void)?

    /// Live fill-handle drag target (the cells that will be written).
    private var fillTarget: (rows: ClosedRange<Int>, cols: ClosedRange<Int>, direction: FillDirection)?
    /// Live row/column move insertion boundary (pre-move index), nil = invalid.
    private var moveDropIndex: Int?

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
        // A frozen cell's editor is pinned to the viewport, not the document —
        // scrolling out from under it would strand it, so land the edit.
        if let cell = editingCell, cell.row < frozenRowCount || cell.col < frozenColCount {
            commitEdit(thenMove: nil)
        }
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
            // Text columns wrap, so rows grow to fit their tallest text cell.
            if !textColumnIndices.isEmpty {
                var h = Metrics.defaultRowHeight
                for c in textColumnIndices where c < model.columnCount {
                    let text = model.value(row: r, column: c)
                    guard !text.isEmpty else { continue }
                    h = max(h, wrappedHeight(text: text, width: width(ofColumn: c)))
                }
                return h
            }
        }
        return Metrics.defaultRowHeight
    }

    private func wrappedHeight(text: String, width: CGFloat) -> CGFloat {
        let key = "\(Int(width))|\(text)"
        if let cached = wrapHeightCache[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(width - 12, 20), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style])
        let height = max(ceil(bounds.height) + 8, Metrics.defaultRowHeight)
        if wrapHeightCache.count > 50_000 { wrapHeightCache.removeAll() }
        wrapHeightCache[key] = height
        return height
    }

    /// Total height of the sticky top chrome: letter band + frozen row.
    private var chromeTop: CGFloat { yOffsets[frozenRowCount] }
    /// Total width of the sticky left chrome: number strip + frozen column.
    private var chromeLeft: CGFloat { xOffsets[frozenColCount] }

    func modelDidChange() {
        guard let model else { return }
        let format = formatProvider?() ?? TSSFormat()
        cachedWidths = format.columnWidths
        cachedHeights = format.rowHeights
        cachedTypes = format.columnTypes
        textColumnIndices = format.columnTypes.filter { $0.value == .text }.keys.sorted()
        frozenRowCount = (format.freezeFieldRow && model.hasFieldNameRow) ? 1 : 0
        frozenColCount = format.freezeIDColumn ? 1 : 0
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

    private func rectFor(rows: ClosedRange<Int>, cols: ClosedRange<Int>) -> NSRect {
        NSRect(x: xOffsets[cols.lowerBound],
               y: yOffsets[rows.lowerBound],
               width: xOffsets[cols.upperBound + 1] - xOffsets[cols.lowerBound],
               height: yOffsets[rows.upperBound + 1] - yOffsets[rows.lowerBound])
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
    private var isFullRowSelection: Bool { selectedCols == 0...(gridCols - 1) }
    private var isFullColumnSelection: Bool { selectedRows == 0...(gridRows - 1) }

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

        // Visible body range (below/right of the sticky chrome).
        let bodyR0 = max(rowAt(min(max(vis.minY + chromeTop, yOffsets[0]), yOffsets[gridRows] - 0.5)), frozenRowCount)
        let bodyR1 = rowAt(min(vis.maxY, yOffsets[gridRows] - 0.5))
        let bodyC0 = max(colAt(min(max(vis.minX + chromeLeft, xOffsets[0]), xOffsets[gridCols] - 0.5)), frozenColCount)
        let bodyC1 = colAt(min(vis.maxX, xOffsets[gridCols] - 0.5))
        let bodyRows: ClosedRange<Int>? = bodyR0 <= bodyR1 ? bodyR0...bodyR1 : nil
        let bodyCols: ClosedRange<Int>? = bodyC0 <= bodyC1 ? bodyC0...bodyC1 : nil

        if let bodyRows, let bodyCols {
            drawPane(model: model, rows: bodyRows, cols: bodyCols,
                     translateX: 0, translateY: 0,
                     clip: NSRect(x: vis.minX + chromeLeft, y: vis.minY + chromeTop,
                                  width: vis.width - chromeLeft, height: vis.height - chromeTop))
        }
        if frozenColCount > 0, let bodyRows {
            drawPane(model: model, rows: bodyRows, cols: 0...(frozenColCount - 1),
                     translateX: vis.minX, translateY: 0,
                     clip: NSRect(x: vis.minX + Metrics.rowHeaderWidth, y: vis.minY + chromeTop,
                                  width: chromeLeft - Metrics.rowHeaderWidth, height: vis.height - chromeTop))
        }
        if frozenRowCount > 0, let bodyCols {
            drawPane(model: model, rows: 0...(frozenRowCount - 1), cols: bodyCols,
                     translateX: 0, translateY: vis.minY,
                     clip: NSRect(x: vis.minX + chromeLeft, y: vis.minY + Metrics.colHeaderHeight,
                                  width: vis.width - chromeLeft, height: chromeTop - Metrics.colHeaderHeight))
        }
        if frozenRowCount > 0 && frozenColCount > 0 {
            drawPane(model: model, rows: 0...(frozenRowCount - 1), cols: 0...(frozenColCount - 1),
                     translateX: vis.minX, translateY: vis.minY,
                     clip: NSRect(x: vis.minX + Metrics.rowHeaderWidth, y: vis.minY + Metrics.colHeaderHeight,
                                  width: chromeLeft - Metrics.rowHeaderWidth, height: chromeTop - Metrics.colHeaderHeight))
        }

        drawChrome(vis: vis, model: model, bodyCols: bodyCols, bodyRows: bodyRows)
        drawMoveIndicator(vis: vis)
    }

    /// Draws one pane: cell backgrounds, selection, grid lines, text, and
    /// selection adornments, in document coordinates shifted by the given
    /// translation and hard-clipped to the pane's viewport region.
    private func drawPane(model: SpreadsheetModel,
                          rows: ClosedRange<Int>, cols: ClosedRange<Int>,
                          translateX: CGFloat, translateY: CGFloat, clip: NSRect) {
        guard clip.width > 0, clip.height > 0,
              let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        cg.saveGState()
        cg.clip(to: clip)
        cg.translateBy(x: translateX, y: translateY)

        // Row backgrounds (header tints span the full row).
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

        // Selection fill.
        Palette.selectionFill.setFill()
        rectFor(rows: selectedRows, cols: selectedCols).fill()

        // Grid lines.
        Palette.gridLine.setFill()
        let top = yOffsets[rows.lowerBound], bottom = yOffsets[rows.upperBound + 1]
        let left = xOffsets[cols.lowerBound], right = xOffsets[cols.upperBound + 1]
        for c in cols.lowerBound...(cols.upperBound + 1) {
            NSRect(x: xOffsets[c] - 0.5, y: top, width: 1, height: bottom - top).fill()
        }
        for r in rows.lowerBound...(rows.upperBound + 1) {
            NSRect(x: left, y: yOffsets[r] - 0.5, width: right - left, height: 1).fill()
        }

        // Text.
        for r in rows {
            guard r < model.rowCount else { break }
            // Header and field-name rows ignore column types entirely.
            let plainRow = model.headerLevel(ofRow: r) == 0 && !model.isFieldNameRow(r)
            let rowColor = textColor(forRow: r)
            for c in cols {
                guard c < model.columnCount else { break }
                let text = model.value(row: r, column: c)
                guard !text.isEmpty else { continue }
                if editingCell == GridPos(row: r, col: c) { continue }
                let rect = cellRect(r, c)
                let font = cellFont(forRow: r, column: c)
                let type = plainRow ? (cachedTypes[c] ?? .raw) : .raw

                switch type {
                case .text:
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byWordWrapping
                    text.draw(in: rect.insetBy(dx: 6, dy: 4), withAttributes: [
                        .font: font,
                        .foregroundColor: rowColor,
                        .paragraphStyle: style,
                    ])
                case .integer, .float:
                    let valid = type == .integer ? Int(text) != nil : Double(text) != nil
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: valid ? rowColor : NSColor.systemRed,
                    ]
                    let size = text.size(withAttributes: attrs)
                    cg.saveGState()
                    rect.insetBy(dx: 1, dy: 1).clip()
                    text.draw(at: NSPoint(x: rect.maxX - size.width - 6, y: rect.midY - size.height / 2),
                              withAttributes: attrs)
                    cg.restoreGState()
                case .raw:
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: rowColor,
                    ]
                    let size = text.size(withAttributes: attrs)
                    cg.saveGState()
                    rect.insetBy(dx: 1, dy: 1).clip()
                    text.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2),
                              withAttributes: attrs)
                    cg.restoreGState()
                }
            }
        }

        // Autofill preview: dashed outline around the cells that will fill.
        if let target = fillTarget {
            let path = NSBezierPath(rect: rectFor(rows: target.rows, cols: target.cols).insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.lineWidth = 1.5
            Palette.selectionBorder.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }

        // Selection border + fill handle (hidden while editing in-cell).
        if editor == nil {
            let rect = rectFor(rows: selectedRows, cols: selectedCols).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            Palette.selectionBorder.setStroke()
            path.stroke()

            let handle = NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 8, height: 8)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: handle).fill()
            Palette.selectionBorder.setFill()
            NSBezierPath(ovalIn: handle.insetBy(dx: 1, dy: 1)).fill()
        }

        cg.restoreGState()
    }

    private func cellFont(forRow row: Int) -> NSFont {
        guard let model else { return .systemFont(ofSize: 12) }
        switch model.headerLevel(ofRow: row) {
        case 1: return .systemFont(ofSize: 14, weight: .bold)
        case 2: return .systemFont(ofSize: 13, weight: .semibold)
        case 3:
            // "###" rows read as greyed-out comments: regular weight, italic.
            return NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        default:
            return model.isFieldNameRow(row)
                ? .systemFont(ofSize: 12, weight: .semibold)
                : .systemFont(ofSize: 12)
        }
    }

    private func cellFont(forRow row: Int, column: Int) -> NSFont {
        // IDs are identifiers — monospace in plain data rows.
        if column == 0, let model, row < model.rowCount,
           model.headerLevel(ofRow: row) == 0, !model.isFieldNameRow(row) {
            return .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        }
        return cellFont(forRow: row)
    }

    private func textColor(forRow row: Int) -> NSColor {
        guard let model, row < model.rowCount else { return .labelColor }
        return model.headerLevel(ofRow: row) == 3 ? .secondaryLabelColor : .labelColor
    }

    private func drawChrome(vis: NSRect, model: SpreadsheetModel,
                            bodyCols: ClosedRange<Int>?, bodyRows: ClosedRange<Int>?) {
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        let headerH = Metrics.colHeaderHeight
        let headerW = Metrics.rowHeaderWidth
        let chromeFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

        func drawLetter(_ c: Int, translateX: CGFloat) {
            let rect = NSRect(x: xOffsets[c] + translateX, y: vis.minY,
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

        func drawNumber(_ r: Int, translateY: CGFloat) {
            let rect = NSRect(x: vis.minX, y: yOffsets[r] + translateY,
                              width: headerW, height: height(ofRow: r))
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

        // Column letter band.
        Palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: headerH).fill()
        if let bodyCols {
            cg.saveGState()
            cg.clip(to: NSRect(x: vis.minX + chromeLeft, y: vis.minY,
                               width: vis.width - chromeLeft, height: headerH))
            for c in bodyCols { drawLetter(c, translateX: 0) }
            cg.restoreGState()
        }
        for c in 0..<frozenColCount { drawLetter(c, translateX: vis.minX) }

        // Row number strip.
        Palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY + headerH, width: headerW, height: vis.height - headerH).fill()
        if let bodyRows {
            cg.saveGState()
            cg.clip(to: NSRect(x: vis.minX, y: vis.minY + chromeTop,
                               width: headerW, height: vis.height - chromeTop))
            for r in bodyRows { drawNumber(r, translateY: 0) }
            cg.restoreGState()
        }
        for r in 0..<frozenRowCount { drawNumber(r, translateY: vis.minY) }

        // Corner box.
        Palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY, width: headerW, height: headerH).fill()

        // Chrome and frozen-pane edges (pane edges slightly stronger).
        Palette.gridLine.setFill()
        NSRect(x: vis.minX, y: vis.minY + headerH - 0.5, width: vis.width, height: 1).fill()
        NSRect(x: vis.minX + headerW - 0.5, y: vis.minY, width: 1, height: vis.height).fill()
        Palette.paneEdge.setFill()
        if frozenRowCount > 0 {
            NSRect(x: vis.minX, y: vis.minY + chromeTop - 2, width: vis.width, height: 3).fill()
        }
        if frozenColCount > 0 {
            NSRect(x: vis.minX + chromeLeft - 2, y: vis.minY, width: 3, height: vis.height).fill()
        }
    }

    private func drawMoveIndicator(vis: NSRect) {
        guard let drop = moveDropIndex else { return }
        Palette.selectionBorder.setFill()
        switch dragMode {
        case .moveRows:
            let sticky = drop <= frozenRowCount ? vis.minY : 0
            NSRect(x: vis.minX, y: yOffsets[drop] + sticky - 1.25, width: vis.width, height: 2.5).fill()
        case .moveColumns:
            let sticky = drop <= frozenColCount ? vis.minX : 0
            NSRect(x: xOffsets[drop] + sticky - 1.25, y: vis.minY, width: 2.5, height: vis.height).fill()
        default:
            break
        }
    }

    // MARK: - Hit testing

    private enum HitArea {
        case corner
        case columnHeader(col: Int, resizeEdgeOf: Int?)
        case rowHeader(row: Int)
        case cell(GridPos)
    }

    /// Column at an on-screen x, honoring the sticky frozen column.
    private func columnAtScreenX(_ x: CGFloat, vis: NSRect) -> Int {
        if frozenColCount > 0, x < vis.minX + chromeLeft {
            return colAt(min(max(x - vis.minX, xOffsets[0]), chromeLeft - 0.5))
        }
        return colAt(x)
    }

    /// Row at an on-screen y, honoring the sticky frozen row.
    private func rowAtScreenY(_ y: CGFloat, vis: NSRect) -> Int {
        if frozenRowCount > 0, y < vis.minY + chromeTop {
            return rowAt(min(max(y - vis.minY, yOffsets[0]), chromeTop - 0.5))
        }
        return rowAt(y)
    }

    private func hitArea(at p: NSPoint) -> HitArea {
        let vis = visibleRect
        if p.y < vis.minY + Metrics.colHeaderHeight {
            if p.x < vis.minX + Metrics.rowHeaderWidth { return .corner }
            // Frozen columns' edges are sticky; check them first.
            for c in 0..<frozenColCount {
                if abs(p.x - (vis.minX + xOffsets[c + 1])) <= Metrics.resizeGrabMargin {
                    return .columnHeader(col: c, resizeEdgeOf: c)
                }
            }
            let c = columnAtScreenX(p.x, vis: vis)
            if c >= frozenColCount {
                if abs(p.x - xOffsets[c + 1]) <= Metrics.resizeGrabMargin {
                    return .columnHeader(col: c, resizeEdgeOf: c)
                }
                if c > frozenColCount, abs(p.x - xOffsets[c]) <= Metrics.resizeGrabMargin {
                    return .columnHeader(col: c, resizeEdgeOf: c - 1)
                }
            }
            return .columnHeader(col: c, resizeEdgeOf: nil)
        }
        if p.x < vis.minX + Metrics.rowHeaderWidth {
            return .rowHeader(row: rowAtScreenY(p.y, vis: vis))
        }
        return .cell(GridPos(row: rowAtScreenY(p.y, vis: vis), col: columnAtScreenX(p.x, vis: vis)))
    }

    /// On-screen rect of the fill handle (selection's bottom-right corner,
    /// shifted if that corner lives in a frozen pane).
    private func fillHandleScreenRect() -> NSRect? {
        guard editor == nil else { return nil }
        let vis = visibleRect
        let rect = rectFor(rows: selectedRows, cols: selectedCols)
        var x = rect.maxX, y = rect.maxY
        if selectedCols.upperBound < frozenColCount { x += vis.minX }
        if selectedRows.upperBound < frozenRowCount { y += vis.minY }
        let m = Metrics.fillHandleGrabMargin
        return NSRect(x: x - m, y: y - m, width: m * 2, height: m * 2)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitEdit(thenMove: nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        didDragSinceMouseDown = false
        pendingHeaderReselect = nil

        if let handle = fillHandleScreenRect(), handle.contains(p) {
            dragMode = .fillHandle
            return
        }

        switch hitArea(at: p) {
        case .corner:
            selectAll(nil)

        case .columnHeader(let c, let resizeEdge):
            if let edge = resizeEdge {
                dragMode = .resizeColumn(col: edge, startX: p.x, startWidth: width(ofColumn: edge))
            } else if !shift, isFullColumnSelection, selectedCols.contains(c), !selectedCols.contains(0) {
                // Grabbing an already-selected header moves the selection.
                dragMode = .moveColumns(selectedCols)
                pendingHeaderReselect = { [weak self] in self?.selectColumn(c, extend: false) }
                NSCursor.closedHand.set()
            } else {
                selectColumn(c, extend: shift)
                dragMode = .selectColumns
            }

        case .rowHeader(let r):
            if !shift, isFullRowSelection, selectedRows.contains(r) {
                dragMode = .moveRows(selectedRows)
                pendingHeaderReselect = { [weak self] in self?.selectRow(r, extend: false) }
                NSCursor.closedHand.set()
            } else {
                selectRow(r, extend: shift)
                dragMode = .selectRows
            }

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

    private func selectColumn(_ c: Int, extend: Bool) {
        if extend {
            focus = GridPos(row: gridRows - 1, col: c)
        } else {
            anchor = GridPos(row: 0, col: c)
            focus = GridPos(row: gridRows - 1, col: c)
        }
        selectionDidChange()
    }

    private func selectRow(_ r: Int, extend: Bool) {
        if extend {
            focus = GridPos(row: r, col: gridCols - 1)
        } else {
            anchor = GridPos(row: r, col: 0)
            focus = GridPos(row: r, col: gridCols - 1)
        }
        selectionDidChange()
    }

    override func mouseDragged(with event: NSEvent) {
        didDragSinceMouseDown = true
        autoscroll(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let vis = visibleRect

        switch dragMode {
        case .none:
            break

        case .selectCells:
            focus = GridPos(row: rowAtScreenY(p.y, vis: vis), col: columnAtScreenX(p.x, vis: vis))
            selectionDidChange()

        case .selectRows:
            focus = GridPos(row: rowAtScreenY(p.y, vis: vis), col: gridCols - 1)
            selectionDidChange()

        case .selectColumns:
            focus = GridPos(row: gridRows - 1, col: columnAtScreenX(p.x, vis: vis))
            selectionDidChange()

        case .resizeColumn(let col, let startX, let startWidth):
            cachedWidths[col] = max(Metrics.minColWidth, startWidth + (p.x - startX))
            rebuildOffsets()
            needsDisplay = true

        case .fillHandle:
            updateFillTarget(pointer: p)
            NSCursor.crosshair.set()

        case .moveRows(let range):
            guard let model else { break }
            let r = rowAt(p.y)
            let mid = (yOffsets[r] + yOffsets[r + 1]) / 2
            var idx = p.y > mid ? r + 1 : r
            idx = min(max(idx, frozenRowCount), model.rowCount)
            moveDropIndex = (idx < range.lowerBound || idx > range.upperBound + 1) ? idx : nil
            NSCursor.closedHand.set()
            needsDisplay = true

        case .moveColumns(let range):
            guard let model else { break }
            let c = colAt(p.x)
            let mid = (xOffsets[c] + xOffsets[c + 1]) / 2
            var idx = p.x > mid ? c + 1 : c
            idx = min(max(idx, max(frozenColCount, 1)), model.columnCount)
            moveDropIndex = (idx < range.lowerBound || idx > range.upperBound + 1) ? idx : nil
            NSCursor.closedHand.set()
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .resizeColumn(let col, _, _):
            if let finalWidth = cachedWidths[col] {
                onFormatChange? { format in
                    format.columnWidths[col] = finalWidth
                }
            }

        case .fillHandle:
            if let target = fillTarget {
                applyFill(target: target)
            }
            fillTarget = nil
            needsDisplay = true

        case .moveRows(let range):
            defer { moveDropIndex = nil; needsDisplay = true }
            if !didDragSinceMouseDown {
                pendingHeaderReselect?()
                break
            }
            if let model, let drop = moveDropIndex, range.upperBound < model.rowCount {
                remapRowHeights(SpreadsheetModel.moveMapping(range: range, to: drop))
                model.moveRows(range, to: drop)
                let newStart = drop > range.upperBound ? drop - range.count : drop
                anchor = GridPos(row: newStart, col: 0)
                focus = GridPos(row: newStart + range.count - 1, col: gridCols - 1)
                selectionDidChange()
            }

        case .moveColumns(let range):
            defer { moveDropIndex = nil; needsDisplay = true }
            if !didDragSinceMouseDown {
                pendingHeaderReselect?()
                break
            }
            if let model, let drop = moveDropIndex, range.upperBound < model.columnCount {
                remapColumnFormatting(SpreadsheetModel.moveMapping(range: range, to: drop))
                model.moveColumns(range, to: drop)
                let newStart = drop > range.upperBound ? drop - range.count : drop
                anchor = GridPos(row: 0, col: newStart)
                focus = GridPos(row: gridRows - 1, col: newStart + range.count - 1)
                selectionDidChange()
            }

        default:
            break
        }
        dragMode = .none
        pendingHeaderReselect = nil
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let handle = fillHandleScreenRect(), handle.contains(p) {
            NSCursor.crosshair.set()
            return
        }
        switch hitArea(at: p) {
        case .columnHeader(let c, let resizeEdge):
            if resizeEdge != nil {
                NSCursor.resizeLeftRight.set()
            } else if isFullColumnSelection, selectedCols.contains(c), !selectedCols.contains(0) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        case .rowHeader(let r):
            if isFullRowSelection, selectedRows.contains(r) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            NSCursor.arrow.set()
        }
    }

    // MARK: - Autofill (fill handle)

    private func updateFillTarget(pointer p: NSPoint) {
        let rect = rectFor(rows: selectedRows, cols: selectedCols)
        let dx = p.x > rect.maxX ? p.x - rect.maxX : (p.x < rect.minX ? p.x - rect.minX : 0)
        let dy = p.y > rect.maxY ? p.y - rect.maxY : (p.y < rect.minY ? p.y - rect.minY : 0)

        var target: (rows: ClosedRange<Int>, cols: ClosedRange<Int>, direction: FillDirection)?
        if abs(dy) >= abs(dx), dy != 0 {
            if dy > 0 {
                let end = rowAt(p.y)
                if end > selectedRows.upperBound {
                    target = ((selectedRows.upperBound + 1)...end, selectedCols, .down)
                }
            } else {
                let start = rowAt(p.y)
                if start < selectedRows.lowerBound {
                    target = (start...(selectedRows.lowerBound - 1), selectedCols, .up)
                }
            }
        } else if dx != 0 {
            if dx > 0 {
                let end = colAt(p.x)
                if end > selectedCols.upperBound {
                    target = (selectedRows, (selectedCols.upperBound + 1)...end, .right)
                }
            } else {
                let start = colAt(p.x)
                if start < selectedCols.lowerBound {
                    target = (selectedRows, start...(selectedCols.lowerBound - 1), .left)
                }
            }
        }
        fillTarget = target
        needsDisplay = true
    }

    private func applyFill(target: (rows: ClosedRange<Int>, cols: ClosedRange<Int>, direction: FillDirection)) {
        guard let model else { return }
        switch target.direction {
        case .down:
            for c in selectedCols {
                let source = selectedRows.map { model.value(row: $0, column: c) }
                let values = AutofillSeries.extend(source, count: target.rows.count)
                for (i, r) in target.rows.enumerated() {
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .up:
            for c in selectedCols {
                let source = selectedRows.reversed().map { model.value(row: $0, column: c) }
                let values = AutofillSeries.extend(source, count: target.rows.count)
                for (i, r) in target.rows.reversed().enumerated() {
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .right:
            for r in selectedRows {
                let source = selectedCols.map { model.value(row: r, column: $0) }
                let values = AutofillSeries.extend(source, count: target.cols.count)
                for (i, c) in target.cols.enumerated() {
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .left:
            for r in selectedRows {
                let source = selectedCols.reversed().map { model.value(row: r, column: $0) }
                let values = AutofillSeries.extend(source, count: target.cols.count)
                for (i, c) in target.cols.reversed().enumerated() {
                    model.setValue(values[i], row: r, column: c)
                }
            }
        }
        undoManager?.setActionName("Autofill")

        // Selection grows to cover the filled region, like Sheets.
        anchor = GridPos(row: min(selectedRows.lowerBound, target.rows.lowerBound),
                         col: min(selectedCols.lowerBound, target.cols.lowerBound))
        focus = GridPos(row: max(selectedRows.upperBound, target.rows.upperBound),
                        col: max(selectedCols.upperBound, target.cols.upperBound))
        selectionDidChange()
    }

    // MARK: - Formatting remaps (keep .tss widths/heights on moved rows/cols)

    private func remapColumnFormatting(_ mapping: [Int: Int]) {
        guard !mapping.isEmpty, let format = formatProvider?(),
              !(format.columnWidths.isEmpty && format.columnTypes.isEmpty) else { return }
        onFormatChange? { format in
            var widths: [Int: CGFloat] = [:]
            for (k, v) in format.columnWidths { widths[mapping[k] ?? k] = v }
            format.columnWidths = widths
            var types: [Int: ColumnType] = [:]
            for (k, v) in format.columnTypes { types[mapping[k] ?? k] = v }
            format.columnTypes = types
        }
        let inverse = Dictionary(uniqueKeysWithValues: mapping.map { ($1, $0) })
        undoManager?.registerUndo(withTarget: self) { view in
            view.remapColumnFormatting(inverse)
        }
        modelDidChange()
    }

    private func remapRowHeights(_ mapping: [Int: Int]) {
        guard !mapping.isEmpty, !(formatProvider?().rowHeights.isEmpty ?? true) else { return }
        onFormatChange? { format in
            var updated: [Int: CGFloat] = [:]
            for (k, v) in format.rowHeights { updated[mapping[k] ?? k] = v }
            format.rowHeights = updated
        }
        let inverse = Dictionary(uniqueKeysWithValues: mapping.map { ($1, $0) })
        undoManager?.registerUndo(withTarget: self) { view in
            view.remapRowHeights(inverse)
        }
        modelDidChange()
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
        let vis = visibleRect
        let cell = cellRect(pos.row, pos.col)
        var rect = cell
        // Frozen cells are always on screen along their frozen axis; pad the
        // other axis by the chrome so cells never land under the panes.
        if pos.col < frozenColCount {
            rect.origin.x = vis.minX
            rect.size.width = 1
        } else {
            rect.origin.x -= chromeLeft
            rect.size.width += chromeLeft
        }
        if pos.row < frozenRowCount {
            rect.origin.y = vis.minY
            rect.size.height = 1
        } else {
            rect.origin.y -= chromeTop
            rect.size.height += chromeTop
        }
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

        // Frozen cells render pinned to the viewport; the editor must match.
        let vis = visibleRect
        var frame = cellRect(pos.row, pos.col).insetBy(dx: 1, dy: 1)
        if pos.col < frozenColCount { frame.origin.x += vis.minX }
        if pos.row < frozenRowCount { frame.origin.y += vis.minY }

        let isTextColumn = cachedTypes[pos.col] == .text
            && model.headerLevel(ofRow: pos.row) == 0 && !model.isFieldNameRow(pos.row)

        let field = NSTextField(frame: frame)
        field.font = cellFont(forRow: pos.row, column: pos.col)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        if isTextColumn {
            field.cell?.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
        } else {
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        field.stringValue = initialText ?? model.value(row: pos.row, column: pos.col)
        addSubview(field)

        editor = field
        editingCell = pos
        editSessionFromTyping = (initialText != nil)
        window?.makeFirstResponder(field)
        if let fieldEditor = field.currentEditor() {
            fieldEditor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            if isTextColumn, let textView = fieldEditor as? NSTextView {
                textView.isContinuousSpellCheckingEnabled = true
            }
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

    // MARK: - Freeze toggles (View menu)

    @objc func toggleFreezeFieldRow(_ sender: Any?) {
        onFormatChange? { $0.freezeFieldRow.toggle() }
        modelDidChange()
    }

    @objc func toggleFreezeIDColumn(_ sender: Any?) {
        onFormatChange? { $0.freezeIDColumn.toggle() }
        modelDidChange()
    }

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

    // MARK: - Column type & sizing

    @objc private func setColumnType(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = ColumnType(rawValue: raw), let model else { return }
        onFormatChange? { format in
            for c in selectedCols where c < model.columnCount {
                if type == .raw {
                    format.columnTypes.removeValue(forKey: c)
                } else {
                    format.columnTypes[c] = type
                }
            }
        }
        modelDidChange()
    }

    @objc private func autoSizeColumns(_ sender: Any?) {
        guard let model else { return }
        let cols = selectedCols.filter { $0 < model.columnCount }
        guard !cols.isEmpty else { return }
        onFormatChange? { format in
            for c in cols {
                // Pre-filter by character count so huge sheets only measure a
                // handful of candidate strings.
                var candidates: [(row: Int, count: Int)] = []
                for r in 0..<model.rowCount {
                    let n = model.value(row: r, column: c).count
                    if n > 0 { candidates.append((r, n)) }
                }
                candidates.sort { $0.count > $1.count }
                var maxWidth = Metrics.minColWidth
                for (r, _) in candidates.prefix(24) {
                    let text = model.value(row: r, column: c)
                    let w = (text as NSString).size(withAttributes: [.font: cellFont(forRow: r, column: c)]).width
                    maxWidth = max(maxWidth, w + 14)
                }
                format.columnWidths[c] = min(maxWidth.rounded(.up), 800)
            }
        }
        modelDidChange()
    }

    // MARK: - Cross-file ID navigation

    @objc private func jumpToDocument(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CrossFileTarget,
              let document = target.document else { return }
        document.showWindows()
        (document.windowControllers.first as? DocumentWindowController)?.reveal(row: target.row)
    }

    /// Selects a row (full width), scrolls it into view. Used when arriving
    /// from another sheet.
    func selectRowAndReveal(_ row: Int) {
        guard row < gridRows else { return }
        anchor = GridPos(row: row, col: 0)
        focus = GridPos(row: row, col: gridCols - 1)
        scrollCellToVisible(GridPos(row: row, col: 0))
        selectionDidChange()
    }

    // MARK: - Context menu & validation

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        var contextRow: Int?
        switch hitArea(at: p) {
        case .cell(let pos):
            if !(selectedRows.contains(pos.row) && selectedCols.contains(pos.col)) {
                anchor = pos
                focus = pos
                selectionDidChange()
            }
            contextRow = pos.row
        case .rowHeader(let r):
            if !(isFullRowSelection && selectedRows.contains(r)) {
                selectRow(r, extend: false)
            }
            contextRow = r
        case .columnHeader(let c, _):
            if !(isFullColumnSelection && selectedCols.contains(c)) {
                selectColumn(c, extend: false)
            }
        case .corner:
            return nil
        }

        let menu = NSMenu()

        // "Go to <ID> in <other sheet>" — same ID in other open files.
        if let model, let row = contextRow, row < model.rowCount {
            let id = model.value(row: row, column: 0)
            if !id.isEmpty, !id.hasPrefix("#"), !model.isFieldNameRow(row) {
                let submenu = NSMenu()
                for case let document as TSVDocument in NSDocumentController.shared.documents
                where document.model !== model {
                    guard let targetRow = document.model.firstRow(withID: id) else { continue }
                    let item = NSMenuItem(
                        title: "\(document.displayName ?? "Untitled") — row \(targetRow + 1)",
                        action: #selector(jumpToDocument(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = CrossFileTarget(document: document, row: targetRow)
                    submenu.addItem(item)
                }
                if submenu.items.isEmpty {
                    submenu.addItem(withTitle: "No Other Open Sheet Has This ID", action: nil, keyEquivalent: "")
                }
                let shownID = id.count > 30 ? id.prefix(30) + "…" : id
                let goTo = NSMenuItem(title: "Go to “\(shownID)” In", action: nil, keyEquivalent: "")
                goTo.submenu = submenu
                menu.addItem(goTo)
                menu.addItem(.separator())
            }
        }

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

        // Column formatting — hidden for whole-row selections, where "the
        // selected columns" would mean every column in the sheet.
        if !isFullRowSelection, let model {
            menu.addItem(.separator())

            let typeMenu = NSMenu()
            let selectedTypes = Set(selectedCols
                .filter { $0 < model.columnCount }
                .map { cachedTypes[$0] ?? .raw })
            for (title, type) in [("Raw", ColumnType.raw), ("Integer", .integer),
                                  ("Float", .float), ("Text", .text)] {
                let item = NSMenuItem(title: title, action: #selector(setColumnType(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = type.rawValue
                if selectedTypes == [type] { item.state = .on }
                else if selectedTypes.contains(type) { item.state = .mixed }
                typeMenu.addItem(item)
            }
            let plural = selectedCols.count > 1
            let typeItem = NSMenuItem(title: plural ? "Column Data Types" : "Column Data Type",
                                      action: nil, keyEquivalent: "")
            typeItem.submenu = typeMenu
            menu.addItem(typeItem)

            let autoSize = NSMenuItem(title: plural ? "Auto-Size Columns" : "Auto-Size Column",
                                      action: #selector(autoSizeColumns(_:)), keyEquivalent: "")
            autoSize.target = self
            menu.addItem(autoSize)
        }

        for item in menu.items where item.target == nil && item.action != nil {
            item.target = self
        }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            return undoManager?.canRedo ?? false
        case #selector(toggleFreezeFieldRow(_:)):
            let format = formatProvider?() ?? TSSFormat()
            menuItem.state = format.freezeFieldRow ? .on : .off
            return model?.hasFieldNameRow ?? false
        case #selector(toggleFreezeIDColumn(_:)):
            let format = formatProvider?() ?? TSSFormat()
            menuItem.state = format.freezeIDColumn ? .on : .off
            return true
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

/// Payload for the "Go to <ID> in <sheet>" context-menu items.
private final class CrossFileTarget: NSObject {
    weak var document: TSVDocument?
    let row: Int

    init(document: TSVDocument, row: Int) {
        self.document = document
        self.row = row
    }
}
