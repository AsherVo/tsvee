import AppKit

struct GridPos: Equatable {
    var row: Int
    var col: Int
}

/// The formula bar's readout for a multi-cell selection.
struct SelectionTally {
    let populated: Int
    let total: Int
    /// True when the selection is the ID column and nothing else. Every counted
    /// row has an ID by definition, so a filled/total split there would always
    /// read `12/12` — it's a count of entries, and says so.
    let idsOnly: Bool
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
        /// Disclosure triangle for section headers, in the row-number strip.
        static let toggleSize: CGFloat = 9
        static let toggleHitWidth: CGFloat = 17
        static let frozenEdgeThickness: CGFloat = 3
        /// Checkbox for `boolean` columns, and the slop around it that still
        /// counts as a click on it.
        static let checkboxSize: CGFloat = 14
        static let checkboxHitMargin: CGFloat = 3
        /// Dropdown chevron for `select`/`multiselect` columns, and the strip
        /// at the cell's right edge that opens the menu.
        static let chevronSize: CGFloat = 8
        static let chevronHitWidth: CGFloat = 20
        /// The "columns are folded away here" marker in the letter band: a
        /// button-sized target sitting just clear of the seam, so grabbing the
        /// seam still resizes the column to its left.
        static let hiddenMarkerWidth: CGFloat = 13
        static let hiddenMarkerInset: CGFloat = resizeGrabMargin + 1
    }

    /// Every color the grid draws with, hanging off one accent — the system's
    /// by default, or whichever one this sheet named in its sidecar.
    private struct Palette {
        let accent: NSColor

        var gridLine: NSColor { NSColor.separatorColor.withAlphaComponent(0.4) }
        var paneEdge: NSColor { NSColor.separatorColor }
        var chromeBackground: NSColor { .windowBackgroundColor }
        var chromeText: NSColor { .secondaryLabelColor }
        var chromeSelected: NSColor { accent.withAlphaComponent(0.25) }
        var selectionFill: NSColor { accent.withAlphaComponent(0.10) }
        var selectionBorder: NSColor { accent }
        var duplicateFill: NSColor { NSColor.systemRed.withAlphaComponent(0.18) }
        /// Field-name row: neutral grey, clearly distinct from the
        /// accent-tinted section headers.
        var fieldRowFill: NSColor { NSColor.systemGray.withAlphaComponent(0.22) }
        func headerFill(level: Int) -> NSColor {
            switch level {
            case 1: return accent.withAlphaComponent(0.32)
            case 2: return accent.withAlphaComponent(0.20)
            default: return NSColor.systemGray.withAlphaComponent(0.08)   // ### = comment
            }
        }

        var frozenEdge: NSColor { NSColor.separatorColor.withAlphaComponent(1.0) }

        /// The "N rows" pill on a collapsed section header.
        var badgeFill: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }

        /// `boolean` checkboxes, borrowing the system's own control colors.
        var checkboxOn: NSColor { accent }
        var checkboxMark: NSColor { .white }
        var checkboxOff: NSColor { NSColor.tertiaryLabelColor }
    }

    /// Refreshed from the sidecar whenever the format changes.
    private var palette = Palette(accent: SheetAccent.system.color)

    // MARK: - Wiring

    weak var model: SpreadsheetModel? {
        didSet { modelDidChange() }
    }
    var formatProvider: (() -> TSSFormat)?
    /// Read-modify-write access to the document's TSSFormat (marks it dirty).
    var onFormatChange: (((inout TSSFormat) -> Void) -> Void)?
    var onSelectionChange: (() -> Void)?
    /// This document's file URL — the base that select and source columns
    /// resolve their relative sheet paths against.
    var documentURLProvider: (() -> URL?)?
    /// A `source` column pulled in new values from the sheet it mirrors, so
    /// this document's data now differs from what's on disk.
    var onDerivedDataChanged: (() -> Void)?

    // MARK: - State

    private var gridRows = 1
    private var gridCols = 1
    private var xOffsets: [CGFloat] = [Metrics.rowHeaderWidth]
    private var yOffsets: [CGFloat] = [Metrics.colHeaderHeight]
    private var cachedWidths: [Int: CGFloat] = [:]
    private var cachedHeights: [Int: CGFloat] = [:]
    private var cachedTypes: [Int: ColumnType] = [:]
    private var textColumnIndices: [Int] = []
    /// Columns whose cells can need more than one line: the wrapping `text`
    /// ones plus any holding a value with line breaks in it.
    private var growColumns: [Int] = []
    private var booleanColumnIndices: Set<Int> = []
    private var cachedSelectSources: [Int: SelectSource] = [:]
    private var cachedSourceSpecs: [Int: SourceSpec] = [:]
    /// Resolved option lists (and sets, for validation) per select column —
    /// refreshed with the model/format, and when the window becomes key again
    /// (the sheet the options come from may have been edited meanwhile).
    private var selectOptions: [Int: [String]] = [:]
    private var selectOptionSets: [Int: Set<String>] = [:]
    /// One reader for every sheet this one links to, shared by the two types
    /// that link: a select column's option sheet is very often the same file
    /// a source column mirrors.
    private let sheetLoader = LinkedSheetLoader()
    private lazy var optionsResolver = SelectOptionsResolver(loader: sheetLoader)
    private lazy var sourceResolver = SourceColumnResolver(loader: sheetLoader)
    /// Re-entrancy guard: filling a source column changes the model, which
    /// comes straight back round to `modelDidChange`.
    private var isPopulatingSourceColumns = false
    /// Wrapped-text height memo, keyed by "width|text" (value-based, so it
    /// survives model changes).
    private var wrapHeightCache: [String: CGFloat] = [:]

    /// 1 when the field-name row / ID column is frozen, else 0.
    private var frozenRowCount = 0
    private var frozenColCount = 0

    /// Header rows whose sections are collapsed (mirrors the `.tss` set).
    private var collapsedRows: Set<Int> = []
    /// Rows currently folded out of sight — the union of every collapsed
    /// section's body. Derived; hidden rows have height 0, which is what makes
    /// the rest of the view's geometry, drawing, and hit testing come along for
    /// free.
    private var hiddenRows: Set<Int> = []
    /// Collapsed header row → the last row it folds away. Derived alongside
    /// `hiddenRows`, and what lets a selection reach into a fold at its end.
    private var foldEnds: [Int: Int] = [:]
    /// Every "#"/"##" row in the sheet, in order. Resolving which section the
    /// top of the viewport is inside happens on every scroll, and this is what
    /// keeps it from rescanning the sheet each time.
    private var sectionHeaderRows: [Int] = []

    /// Columns hidden by the user (mirrors the `.tss` set). Like hidden rows
    /// these are zero-sized rather than skipped, so geometry, drawing and hit
    /// testing need no separate notion of "the nth visible column". The gap in
    /// the header letters is the cue that something is folded away, along with
    /// the marker drawn at the seam.
    private var hiddenColumns: Set<Int> = []

    /// Columns with the "Flag Duplicates" option on (mirrors the `.tss` set),
    /// and for each of them the rows whose value repeats another row's. Derived
    /// on every model change, so the red tint follows what's typed.
    private var duplicateFlagColumns: Set<Int> = []
    private var duplicateFlagRows: [Int: Set<Int>] = [:]

    private var anchor = GridPos(row: 0, col: 0)
    private var focus = GridPos(row: 0, col: 0)

    private var editor: NSTextField?
    private var editingCell: GridPos?
    private var editSessionFromTyping = false
    private var isCommittingEdit = false

    /// Autocomplete state while editing a select cell: the options to suggest
    /// from, and — when a suggestion is showing — what the user actually typed
    /// (the field holds typed text + the selected, unconfirmed remainder).
    private var editingSelectOptions: [String]?
    private var editingSelectIsMulti = false
    private var selectSuggestionBase: String?
    private var lastEditorText = ""
    private var isAutocompleting = false

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

    /// Spell checking + wrapped-text rendering for `text` columns.
    private let spellIndex = SpellCheckIndex()
    private let textRenderer = TextCellRenderer()

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A finished spell check can add squiggles to cells already on screen.
        spellIndex.onUpdate = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let clipView = enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clipView)
        }
        if let window {
            // Select options resolved from another sheet may have changed
            // while that sheet had focus; re-resolve on the way back in.
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    @objc private func windowBecameKey() {
        modelDidChange()
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
        if hiddenColumns.contains(c) { return 0 }
        return cachedWidths[c] ?? (c == 0 ? Metrics.idColWidth : Metrics.defaultColWidth)
    }

    private func height(ofRow r: Int) -> CGFloat {
        if hiddenRows.contains(r) { return 0 }
        if let custom = cachedHeights[r] { return custom }
        if let model, r < model.rowCount {
            let level = model.headerLevel(ofRow: r)
            if level > 0 { return Metrics.headerRowHeights[level - 1] }
            // Column headers wrap in every column, not just the `text` ones, so
            // the field-name row grows to fit the longest name it holds.
            if model.isFieldNameRow(r) {
                let font = cellFont(forRow: r)
                var h = Metrics.defaultRowHeight
                for c in 0..<model.columnCount where !hiddenColumns.contains(c) {
                    let text = model.value(row: r, column: c)
                    guard !text.isEmpty else { continue }
                    h = max(h, wrappedHeight(text: text, width: width(ofColumn: c), font: font))
                }
                return h
            }
            // Rows grow to fit whatever has to be laid out over more than
            // one line: a wrapping `text` cell, or any cell with line breaks.
            if !growColumns.isEmpty {
                var h = Metrics.defaultRowHeight
                for c in growColumns where c < model.columnCount && !hiddenColumns.contains(c) {
                    let text = model.value(row: r, column: c)
                    guard !text.isEmpty, wrapsText(row: r, column: c, text: text) else { continue }
                    h = max(h, wrappedHeight(text: text, width: width(ofColumn: c),
                                             font: cellFont(forRow: r, column: c)))
                }
                return h
            }
        }
        return Metrics.defaultRowHeight
    }

    private func wrappedHeight(text: String, width: CGFloat,
                              font: NSFont = .systemFont(ofSize: 12)) -> CGFloat {
        let key = "\(Int(width))|\(font.fontName)\(font.pointSize)|\(text)"
        if let cached = wrapHeightCache[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(width - 12, 20), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: style])
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
        growColumns = Set(textColumnIndices).union(model.columnsWithLineBreaks).sorted()
        booleanColumnIndices = Set(format.columnTypes.filter { $0.value == .boolean }.keys)
        cachedSelectSources = format.selectSources
        cachedSourceSpecs = format.sourceSpecs
        refreshSelectOptions(format: format)
        palette = Palette(accent: format.accent.color)
        frozenRowCount = (format.freezeFieldRow && model.hasFieldNameRow) ? 1 : 0
        frozenColCount = format.freezeIDColumn ? 1 : 0
        gridRows = model.rowCount + Metrics.phantomRows
        gridCols = model.columnCount + Metrics.phantomCols
        collapsedRows = format.collapsedSections
        sectionHeaderRows = (0..<model.rowCount).filter {
            SpreadsheetModel.sectionHeaderLevels.contains(model.headerLevel(ofRow: $0))
        }
        // Column 0 and the phantom columns are never hideable, whatever a
        // hand-edited sidecar says.
        hiddenColumns = format.hiddenColumns.filter { $0 >= 1 && $0 < model.columnCount }
        // Column 0 flags its duplicate IDs by itself, whatever the sidecar says.
        duplicateFlagColumns = format.flagDuplicateColumns
            .filter { $0 >= 1 && $0 < model.columnCount }
        duplicateFlagRows = duplicateFlagColumns.reduce(into: [:]) { rows, column in
            rows[column] = model.duplicateRows(inColumn: column)
        }
        recomputeHiddenRows(model: model)
        clampSelection()
        rebuildOffsets()
        needsDisplay = true
        populateSourceColumns()
    }

    /// Re-reads every sheet this one links to and takes the consequences:
    /// fresh options for the select columns, fresh values for the source ones.
    /// Called when the window comes forward, since a linked sheet may have
    /// been edited — in TSVee or anywhere else — while this one sat behind it.
    func refreshLinkedSheets() {
        guard !cachedSelectSources.isEmpty || !cachedSourceSpecs.isEmpty else { return }
        modelDidChange()
    }

    /// Folds every collapsed header's section body out of sight. Entries that
    /// no longer name a header with a body simply contribute nothing, so
    /// editing the "#" off a header always brings its rows back.
    private func recomputeHiddenRows(model: SpreadsheetModel) {
        var hidden: Set<Int> = []
        var ends: [Int: Int] = [:]
        for row in collapsedRows {
            guard let body = model.sectionBody(ofRow: row) else { continue }
            hidden.formUnion(body)
            ends[row] = body.upperBound
        }
        hiddenRows = hidden
        foldEnds = ends
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

    /// Where a cell actually appears: its document rect, shifted by the scroll
    /// offset when it lives in a frozen pane (frozen content is drawn pinned to
    /// the viewport edge).
    private func cellScreenRect(_ pos: GridPos) -> NSRect {
        let vis = visibleRect
        var rect = cellRect(pos.row, pos.col)
        if pos.col < frozenColCount { rect.origin.x += vis.minX }
        if pos.row < frozenRowCount { rect.origin.y += vis.minY }
        return rect
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
        // A selection endpoint inside a freshly collapsed section would be a
        // zero-height sliver you could still type into; pull it up to the
        // header that swallowed it. Hidden columns are the same story sideways.
        anchor.row = visibleRow(from: anchor.row, searching: -1)
        focus.row = visibleRow(from: focus.row, searching: -1)
        anchor.col = visibleColumn(from: anchor.col, searching: -1)
        focus.col = visibleColumn(from: focus.col, searching: -1)
    }

    /// Nearest unfolded row starting at `row` and walking by `step`, falling
    /// back to the other direction at the grid's edge. Row 0 and the phantom
    /// rows past the data are never hidden, so this always lands somewhere.
    private func visibleRow(from row: Int, searching step: Int) -> Int {
        var r = min(max(row, 0), gridRows - 1)
        while hiddenRows.contains(r), r + step >= 0, r + step < gridRows { r += step }
        while hiddenRows.contains(r), r - step >= 0, r - step < gridRows { r -= step }
        return r
    }

    /// The column counterpart of `visibleRow`. Column 0 is never hideable, so
    /// walking left always finds somewhere to land.
    private func visibleColumn(from col: Int, searching step: Int) -> Int {
        var c = min(max(col, 0), gridCols - 1)
        while hiddenColumns.contains(c), c + step >= 0, c + step < gridCols { c += step }
        while hiddenColumns.contains(c), c - step >= 0, c - step < gridCols { c -= step }
        return c
    }

    /// Nudges a row insertion boundary past any folded section it falls inside,
    /// so rows dropped or inserted just under a collapsed header land after the
    /// whole section instead of materializing already hidden.
    private func insertionBoundary(_ index: Int, rowCount: Int) -> Int {
        var at = index
        while at < rowCount, hiddenRows.contains(at) { at += 1 }
        return at
    }

    /// The selected rows, reaching down over a section that's folded away at
    /// the end of the selection. A fold in the *middle* of a selection is
    /// already inside the range, so the tail has to behave the same way —
    /// otherwise Select All quietly misses a collapsed last section, and the
    /// cursor can't reach past the header to include it (it's pulled out of
    /// folds on purpose). A body always sits directly below its header, so the
    /// reach stays contiguous.
    private var selectedRows: ClosedRange<Int> {
        let first = min(anchor.row, focus.row), last = max(anchor.row, focus.row)
        var end = last
        for (header, foldedThrough) in foldEnds where header >= first && header <= last {
            end = max(end, foldedThrough)
        }
        return first...end
    }
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

    /// The focused cell as the formula bar shows it: the file's spelling, so a
    /// multi-line value reads (and edits) as `\n` in that one-line field.
    func focusedCellValue() -> String {
        SpreadsheetModel.encodeCell(model?.value(row: focus.row, column: focus.col) ?? "")
    }

    // MARK: - Sticky section headers

    /// A section header pinned below the top chrome: which row it is, where it
    /// is drawn on screen, and the line it must not show above — the header it
    /// is sliding up behind on its way out.
    private struct StickyHeader {
        let row: Int
        let y: CGFloat
        let height: CGFloat
        let clipTop: CGFloat
        /// The part of the row that is actually on show, once the header above
        /// has clipped whatever has been pushed up behind it.
        var visibleTop: CGFloat { max(y, clipTop) }
        var visibleHeight: CGFloat { y + height - visibleTop }
        func covers(y point: CGFloat) -> Bool { point >= visibleTop && point < y + height }
    }

    /// The section headers the top of the viewport is scrolled inside — the
    /// "#" one, then the "##" one within it — pinned in that order under the
    /// chrome, so the section you are in always names itself.
    ///
    /// Each slot resolves from the row showing at that slot's own position, so
    /// a header climbing the screen takes a slot over exactly as it arrives at
    /// it. The one arriving pushes out the pinned headers it replaces (its own
    /// level and deeper), sliding them up behind the shallower ones, which stay.
    private func stickyHeaders(vis: NSRect) -> [StickyHeader] {
        guard let model, model.rowCount > 0 else { return [] }
        let base = vis.minY + chromeTop
        // Nothing to pin at the top of the sheet: every header is in its place.
        guard base > yOffsets[frozenRowCount] + 0.5 else { return [] }

        var rows: [Int] = []
        var heights: [CGFloat] = []
        var slotTop = base
        for level in SpreadsheetModel.sectionHeaderLevels {
            let probe = rowAt(min(max(slotTop, yOffsets[0]), yOffsets[gridRows] - 0.5))
            guard probe < model.rowCount else { break }
            guard let header = owningHeader(level: level, ofRow: probe, model: model),
                  !hiddenRows.contains(header) else { continue }
            let slotHeight = height(ofRow: header)
            rows.append(header)
            heights.append(slotHeight)
            slotTop += slotHeight
        }
        guard let deepest = rows.last else { return [] }

        let stackHeight = heights.reduce(0, +)
        var retained = rows.count
        var shift: CGFloat = 0
        if let next = incomingSectionHeader(below: deepest,
                                            between: base, and: base + stackHeight) {
            let level = model.headerLevel(ofRow: next)
            retained = rows.prefix { model.headerLevel(ofRow: $0) < level }.count
            shift = base + stackHeight - yOffsets[next]
        }

        var stickies: [StickyHeader] = []
        var y = base
        var clipTop = base
        for (i, row) in rows.enumerated() {
            // Everything from here down is on its way out, behind the header
            // above it.
            if i == retained { clipTop = y }
            stickies.append(StickyHeader(row: row, y: i < retained ? y : y - shift,
                                         height: heights[i], clipTop: clipTop))
            y += heights[i]
        }
        return stickies
    }

    /// The header of `level` whose section a row sits in: the nearest one at or
    /// above it, unless a shallower header closed that section first.
    private func owningHeader(level: Int, ofRow row: Int, model: SpreadsheetModel) -> Int? {
        for header in sectionHeaderRows.reversed() where header <= row {
            let headerLevel = model.headerLevel(ofRow: header)
            if headerLevel < level { return nil }
            if headerLevel == level { return header }
        }
        return nil
    }

    /// The section header on its way up into the pinned stack: the first one
    /// below the deepest pinned header that has climbed into the band the stack
    /// occupies. nil while the stack still has the top to itself.
    private func incomingSectionHeader(below row: Int,
                                       between top: CGFloat, and bottom: CGFloat) -> Int? {
        for header in sectionHeaderRows where header > row && !hiddenRows.contains(header) {
            guard yOffsets[header] > top else { continue }
            return yOffsets[header] < bottom ? header : nil
        }
        return nil
    }

    /// How much pinned header would stand over a row scrolled to the top of the
    /// body — the headroom a scroll has to leave it. A header row doesn't count
    /// itself: it takes its own slot in the stack.
    private func pinnedHeight(above row: Int) -> CGFloat {
        guard let model, row < model.rowCount else { return 0 }
        var total: CGFloat = 0
        for level in SpreadsheetModel.sectionHeaderLevels {
            guard let header = owningHeader(level: level, ofRow: row, model: model),
                  header != row, !hiddenRows.contains(header) else { continue }
            total += height(ofRow: header)
        }
        return total
    }

    /// Draws the pinned headers over the top of the body. An opaque backing
    /// goes down first: the header tints are translucent, and the rows sliding
    /// past underneath must not read through them.
    private func drawStickyHeaders(_ stickies: [StickyHeader], vis: NSRect,
                                   model: SpreadsheetModel, bodyCols: ClosedRange<Int>?) {
        guard !stickies.isEmpty, let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        var stackBottom: CGFloat?
        for sticky in stickies {
            guard sticky.visibleHeight > 0.5 else { continue }
            let band = NSRect(x: vis.minX + Metrics.rowHeaderWidth, y: sticky.visibleTop,
                              width: vis.width - Metrics.rowHeaderWidth,
                              height: sticky.visibleHeight)
            cg.saveGState()
            cg.clip(to: band)
            NSColor.textBackgroundColor.setFill()
            band.fill()
            cg.restoreGState()

            // The row is drawn exactly as it would be in place, shifted up to
            // the slot it has been pinned in.
            let translateY = sticky.y - yOffsets[sticky.row]
            if let bodyCols {
                drawPane(model: model, rows: sticky.row...sticky.row, cols: bodyCols,
                         translateX: 0, translateY: translateY,
                         clip: NSRect(x: vis.minX + chromeLeft, y: band.minY,
                                      width: vis.width - chromeLeft, height: band.height),
                         selection: false)
            }
            if frozenColCount > 0 {
                drawPane(model: model, rows: sticky.row...sticky.row, cols: 0...(frozenColCount - 1),
                         translateX: vis.minX, translateY: translateY,
                         clip: NSRect(x: vis.minX + Metrics.rowHeaderWidth, y: band.minY,
                                      width: chromeLeft - Metrics.rowHeaderWidth, height: band.height),
                         selection: false)
            }
            // The row itself is somewhere above; the tint is all the sign a
            // selection reaching it can give down here.
            if selectedRows.contains(sticky.row) {
                let span = rectFor(rows: sticky.row...sticky.row, cols: selectedCols)
                palette.selectionFill.setFill()
                NSRect(x: span.minX, y: band.minY, width: span.width, height: band.height)
                    .intersection(band).fill()
            }
            stackBottom = max(stackBottom ?? band.maxY, band.maxY)
        }
        // A firm edge under the stack: it floats over the sheet, and the row it
        // half covers should read as covered rather than cut off.
        if let stackBottom {
            palette.paneEdge.setFill()
            NSRect(x: vis.minX + Metrics.rowHeaderWidth, y: stackBottom - 1,
                   width: vis.width - Metrics.rowHeaderWidth, height: 1).fill()
        }
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

        let pinned = stickyHeaders(vis: vis)
        drawStickyHeaders(pinned, vis: vis, model: model, bodyCols: bodyCols)
        drawChrome(vis: vis, model: model, bodyCols: bodyCols, bodyRows: bodyRows,
                   pinnedHeaders: pinned)
        drawMoveIndicator(vis: vis)
    }

    /// Draws one pane: cell backgrounds, selection, grid lines, text, and
    /// selection adornments, in document coordinates shifted by the given
    /// translation and hard-clipped to the pane's viewport region.
    private func drawPane(model: SpreadsheetModel,
                          rows: ClosedRange<Int>, cols: ClosedRange<Int>,
                          translateX: CGFloat, translateY: CGFloat, clip: NSRect,
                          selection: Bool = true) {
        guard clip.width > 0, clip.height > 0,
              let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        cg.saveGState()
        cg.clip(to: clip)
        cg.translateBy(x: translateX, y: translateY)

        // Row backgrounds (header tints span the full row).
        let fullWidth = xOffsets[gridCols] - xOffsets[0]
        for r in rows where !hiddenRows.contains(r) {
            var fill: NSColor?
            if r < model.rowCount {
                let level = model.headerLevel(ofRow: r)
                if level > 0 { fill = palette.headerFill(level: level) }
                else if model.isFieldNameRow(r) { fill = palette.fieldRowFill }
            }
            if let fill {
                fill.setFill()
                NSRect(x: xOffsets[0], y: yOffsets[r], width: fullWidth, height: height(ofRow: r)).fill()
            }
            if model.duplicateIDRows.contains(r) {
                palette.duplicateFill.setFill()
                cellRect(r, 0).fill()
            }
            // The same tint in a column that asked for it — a repeated value
            // where the sheet says values shouldn't repeat.
            for c in cols where duplicateFlagColumns.contains(c) && !hiddenColumns.contains(c) {
                guard duplicateFlagRows[c]?.contains(r) == true else { continue }
                palette.duplicateFill.setFill()
                cellRect(r, c).fill()
            }
        }

        // Selection fill.
        if selection {
            palette.selectionFill.setFill()
            rectFor(rows: selectedRows, cols: selectedCols).fill()
        }

        // Grid lines.
        palette.gridLine.setFill()
        let top = yOffsets[rows.lowerBound], bottom = yOffsets[rows.upperBound + 1]
        let left = xOffsets[cols.lowerBound], right = xOffsets[cols.upperBound + 1]
        for c in cols.lowerBound...(cols.upperBound + 1) {
            NSRect(x: xOffsets[c] - 0.5, y: top, width: 1, height: bottom - top).fill()
        }
        for r in rows.lowerBound...(rows.upperBound + 1) {
            NSRect(x: left, y: yOffsets[r] - 0.5, width: right - left, height: 1).fill()
        }

        // Collapsed headers get a firm bottom edge — the seam where the folded
        // rows went (the skipped row numbers are the other half of the cue).
        palette.paneEdge.setFill()
        for r in rows where collapsedRows.contains(r) && !hiddenRows.contains(r) {
            guard model.sectionBody(ofRow: r) != nil else { continue }
            NSRect(x: xOffsets[0], y: yOffsets[r + 1] - 2, width: fullWidth, height: 2).fill()
        }

        // Text.
        for r in rows where !hiddenRows.contains(r) {
            guard r < model.rowCount else { break }
            // Header and field-name rows ignore column types entirely.
            let plainRow = model.headerLevel(ofRow: r) == 0 && !model.isFieldNameRow(r)
            let rowColor = textColor(forRow: r)
            for c in cols where !hiddenColumns.contains(c) {
                guard c < model.columnCount else { break }
                let text = model.value(row: r, column: c)
                if editingCell == GridPos(row: r, col: c) { continue }
                let rect = cellRect(r, c)
                let font = cellFont(forRow: r, column: c)
                let type = plainRow ? (cachedTypes[c] ?? .raw) : .raw
                // Empty cells have nothing to draw — except in a `boolean`
                // column (empty is an unchecked box) or a select column
                // (empty still gets its dropdown chevron).
                guard !text.isEmpty || type == .boolean
                    || type == .select || type == .multiselect else { continue }

                // A collapsed header says how much is folded away, pinned to
                // the right of its ID cell. The name is clipped short of the
                // badge rather than running underneath it.
                var textClip = rect.insetBy(dx: 1, dy: 1)
                if c == 0, let label = foldedRowsLabel(forRow: r) {
                    let pill = drawBadge(label, rightAlignedIn: rect)
                    textClip.size.width = max(pill.minX - 4 - textClip.minX, 0)
                }

                // Column headers wrap rather than clip — the row was sized
                // to fit them, and a name too long for its column is the one
                // label you can least afford to lose the end of. A raw value
                // with line breaks in it lays out the same way, so every line
                // shows.
                if type == .raw, model.isFieldNameRow(r) || text.contains("\n") {
                    var area = rect.insetBy(dx: 6, dy: 4)
                    area.size.width = max(min(area.maxX, textClip.maxX) - area.minX, 1)
                    textRenderer.draw(text, font: font, color: rowColor, in: area,
                                      misspellings: [], verticallyCentered: true)
                    continue
                }

                switch type {
                case .text:
                    // Prose: wrapped, and spell-checked with the misspellings
                    // underlined the way a text view would.
                    textRenderer.draw(text, font: font, color: rowColor,
                                      in: rect.insetBy(dx: 6, dy: 4),
                                      misspellings: spellIndex.misspellings(in: text))
                case .boolean:
                    if let checked = checkboxState(at: GridPos(row: r, col: c)) {
                        drawCheckbox(in: checkboxRect(in: rect), checked: checked)
                    } else if !text.isEmpty {
                        // No checkbox to draw here: either the line has no ID,
                        // or the value isn't TRUE/FALSE. Show it as-is, red when
                        // it's data the type doesn't describe.
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: BooleanCell(text) == .invalid
                                ? NSColor.systemRed : rowColor,
                        ]
                        let size = text.size(withAttributes: attrs)
                        cg.saveGState()
                        textClip.clip()
                        text.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2),
                                  withAttributes: attrs)
                        cg.restoreGState()
                    }
                case .select, .multiselect:
                    let pos = GridPos(row: r, col: c)
                    var color = rowColor
                    if selectCellKind(at: pos) != nil {
                        // The chevron marks the dropdown; text is clipped
                        // short of it. Values the options don't cover go red.
                        drawDropdownChevron(in: chevronRect(in: rect))
                        textClip.size.width = max(
                            rect.maxX - Metrics.chevronHitWidth - textClip.minX, 0)
                        if !SelectCell.isValid(text, options: selectOptionSets[c] ?? [],
                                               multi: type == .multiselect) {
                            color = .systemRed
                        }
                    }
                    guard !text.isEmpty else { continue }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: color,
                    ]
                    let size = text.size(withAttributes: attrs)
                    cg.saveGState()
                    textClip.clip()
                    text.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2),
                              withAttributes: attrs)
                    cg.restoreGState()
                case .source:
                    // Mirrored from another sheet, not typed here: drawn a
                    // shade back from the rest so it reads as filled in.
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                    let size = text.size(withAttributes: attrs)
                    cg.saveGState()
                    textClip.clip()
                    text.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - size.height / 2),
                              withAttributes: attrs)
                    cg.restoreGState()
                case .integer, .float:
                    let valid = type == .integer ? Int(text) != nil : Double(text) != nil
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: valid ? rowColor : NSColor.systemRed,
                    ]
                    let size = text.size(withAttributes: attrs)
                    cg.saveGState()
                    textClip.clip()
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
                    textClip.clip()
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
            palette.selectionBorder.withAlphaComponent(0.8).setStroke()
            path.stroke()
        }

        // Selection border + fill handle (hidden while editing in-cell).
        if selection, editor == nil {
            let rect = rectFor(rows: selectedRows, cols: selectedCols).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            palette.selectionBorder.setStroke()
            path.stroke()

            let handle = NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 8, height: 8)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(ovalIn: handle).fill()
            palette.selectionBorder.setFill()
            NSBezierPath(ovalIn: handle.insetBy(dx: 1, dy: 1)).fill()
        }

        cg.restoreGState()
    }

    // MARK: - Checkboxes (`boolean` columns)

    /// State of the checkbox drawn in a cell, or nil where no checkbox belongs:
    /// not a `boolean` column, a header / field-name row, a line with no ID (a
    /// checkbox there would have no row to belong to), or a value that isn't
    /// TRUE/FALSE.
    private func checkboxState(at pos: GridPos) -> Bool? {
        guard let model, cachedTypes[pos.col] == .boolean,
              pos.row < model.rowCount, pos.col < model.columnCount,
              model.headerLevel(ofRow: pos.row) == 0, !model.isFieldNameRow(pos.row),
              !model.value(row: pos.row, column: 0).isEmpty else { return nil }
        switch BooleanCell(model.value(row: pos.row, column: pos.col)) {
        case .on: return true
        case .off: return false
        case .invalid: return nil
        }
    }

    private func checkboxRect(in cell: NSRect) -> NSRect {
        let size = Metrics.checkboxSize
        return NSRect(x: (cell.midX - size / 2).rounded(),
                      y: (cell.midY - size / 2).rounded(),
                      width: size, height: size)
    }

    /// Clickable checkbox at a cell, in on-screen coordinates, or nil if that
    /// cell has no checkbox.
    private func checkboxHitRect(at pos: GridPos) -> NSRect? {
        guard checkboxState(at: pos) != nil else { return nil }
        return checkboxRect(in: cellScreenRect(pos))
            .insetBy(dx: -Metrics.checkboxHitMargin, dy: -Metrics.checkboxHitMargin)
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        box.lineWidth = 1
        if checked {
            palette.checkboxOn.setFill()
            box.fill()
            // Flipped view: maxY is the bottom, so the middle point of the
            // check is the low one.
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY + 0.5))
            check.line(to: NSPoint(x: rect.minX + 5.5, y: rect.maxY - 4))
            check.line(to: NSPoint(x: rect.maxX - 3.5, y: rect.minY + 4.5))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            palette.checkboxMark.setStroke()
            check.stroke()
        } else {
            NSColor.textBackgroundColor.setFill()
            box.fill()
            palette.checkboxOff.setStroke()
            box.stroke()
        }
    }

    private func toggleCheckbox(at pos: GridPos) {
        guard let model, let checked = checkboxState(at: pos) else { return }
        model.setValue(BooleanCell.literal(!checked), row: pos.row, column: pos.col)
        undoManager?.setActionName("Toggle Checkbox")
        needsDisplay = true
    }

    /// Space bar: flips every checkbox in the selection to the opposite of the
    /// focused cell's state, so a multi-cell selection lands uniform.
    private func toggleCheckboxesInSelection() {
        guard let model, let checked = checkboxState(at: focus) else { return }
        let newValue = BooleanCell.literal(!checked)
        for r in selectedRows where r < model.rowCount {
            for c in selectedCols where c < model.columnCount {
                guard checkboxState(at: GridPos(row: r, col: c)) != nil else { continue }
                model.setValue(newValue, row: r, column: c)
            }
        }
        undoManager?.setActionName("Toggle Checkbox")
        needsDisplay = true
    }

    // MARK: - Dropdowns (`select` / `multiselect` columns)

    private func refreshSelectOptions(format: TSSFormat) {
        var lists: [Int: [String]] = [:]
        for (column, type) in format.columnTypes where type == .select || type == .multiselect {
            guard let source = format.selectSources[column] else { continue }
            lists[column] = optionsResolver.options(for: source, tsvURL: documentURLProvider?())
        }
        selectOptions = lists
        selectOptionSets = lists.mapValues(Set.init)
    }

    // MARK: - Mirrored values (`source` columns)

    /// Fills every `source` column from the sheet it mirrors, matching this
    /// sheet's rows to that one's by ID. Rows the source doesn't have are
    /// blanked — the column says what the source says, including that it says
    /// nothing — but a source that can't be read at all is left alone rather
    /// than allowed to wipe the values already in the file.
    private func populateSourceColumns() {
        guard !isPopulatingSourceColumns, let model, !cachedSourceSpecs.isEmpty else { return }
        isPopulatingSourceColumns = true
        defer { isPopulatingSourceColumns = false }

        let tsvURL = documentURLProvider?()
        var changed = false
        for (column, spec) in cachedSourceSpecs
        where cachedTypes[column] == .source && column < model.columnCount {
            guard let lookup = sourceResolver.values(for: spec, tsvURL: tsvURL) else { continue }
            var mirrored: [Int: String] = [:]
            for row in 0..<model.rowCount {
                guard model.headerLevel(ofRow: row) == 0, !model.isFieldNameRow(row) else { continue }
                let id = model.value(row: row, column: 0)
                guard !id.isEmpty else { continue }
                mirrored[row] = lookup[id] ?? ""
            }
            if model.applyDerivedValues(mirrored, column: column) { changed = true }
        }
        if changed { onDerivedDataChanged?() }
    }

    /// True where a `source` column owns the cell and so nothing can be typed
    /// into it. Header and field-name rows are exempt — those are this sheet's
    /// own structure, not values the source provides.
    private func isMirroredCell(_ pos: GridPos) -> Bool {
        cellType(row: pos.row, column: pos.col) == .source
    }

    // MARK: - Dropdowns, continued

    /// The cells the type governs — same rows a boolean column gives a
    /// checkbox: a plain data row with an ID, inside the data. nil elsewhere
    /// (those cells show their text untouched, no chevron, no validation).
    private func selectCellKind(at pos: GridPos) -> (options: [String], multi: Bool)? {
        guard let model, let type = cachedTypes[pos.col],
              type == .select || type == .multiselect,
              pos.row < model.rowCount, pos.col < model.columnCount,
              model.headerLevel(ofRow: pos.row) == 0, !model.isFieldNameRow(pos.row),
              !model.value(row: pos.row, column: 0).isEmpty else { return nil }
        return (selectOptions[pos.col] ?? [], type == .multiselect)
    }

    private func chevronRect(in cell: NSRect) -> NSRect {
        let s = Metrics.chevronSize
        return NSRect(x: cell.maxX - s - 6, y: (cell.midY - s / 2).rounded(),
                      width: s, height: s)
    }

    /// The clickable strip at the right edge of a select cell, in on-screen
    /// coordinates, or nil where there's no dropdown.
    private func chevronHitRect(at pos: GridPos) -> NSRect? {
        guard selectCellKind(at: pos) != nil else { return nil }
        let cell = cellScreenRect(pos)
        return NSRect(x: cell.maxX - Metrics.chevronHitWidth, y: cell.minY,
                      width: Metrics.chevronHitWidth, height: cell.height)
    }

    private func drawDropdownChevron(in rect: NSRect) {
        // Flipped view: maxY is the bottom, where the triangle points.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + 2))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + 2))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
        path.close()
        NSColor.tertiaryLabelColor.setFill()
        path.fill()
    }

    private func showSelectMenu(at pos: GridPos) {
        guard let model, let kind = selectCellKind(at: pos) else { return }
        let menu = NSMenu()
        let current = Set(SelectCell.tokens(model.value(row: pos.row, column: pos.col)))

        if !kind.multi {
            let none = NSMenuItem(title: "None", action: #selector(pickSelectOption(_:)),
                                  keyEquivalent: "")
            none.target = self
            none.representedObject = SelectPick(pos: pos, option: nil, multi: false)
            if model.value(row: pos.row, column: pos.col).isEmpty { none.state = .on }
            menu.addItem(none)
            if !kind.options.isEmpty { menu.addItem(.separator()) }
        }
        for option in kind.options {
            let item = NSMenuItem(title: option, action: #selector(pickSelectOption(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = SelectPick(pos: pos, option: option, multi: kind.multi)
            if current.contains(option) { item.state = .on }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No Options Configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        let cell = cellScreenRect(pos)
        menu.popUp(positioning: nil, at: NSPoint(x: cell.minX, y: cell.maxY), in: self)
    }

    @objc private func pickSelectOption(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? SelectPick, let model else { return }
        if pick.multi, let option = pick.option {
            // Picking toggles membership in the comma-separated list.
            var tokens = SelectCell.tokens(model.value(row: pick.pos.row, column: pick.pos.col))
                .filter { !$0.isEmpty }
            if let existing = tokens.firstIndex(of: option) {
                tokens.remove(at: existing)
            } else {
                tokens.append(option)
            }
            model.setValue(tokens.joined(separator: ","), row: pick.pos.row, column: pick.pos.col)
        } else {
            model.setValue(pick.option ?? "", row: pick.pos.row, column: pick.pos.col)
        }
        undoManager?.setActionName("Pick Option")
        needsDisplay = true
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
                : .systemFont(ofSize: 12, weight: .medium)
        }
    }

    private func cellFont(forRow row: Int, column: Int) -> NSFont {
        // IDs are identifiers — monospace in plain data rows.
        if column == 0, let model, row < model.rowCount,
           model.headerLevel(ofRow: row) == 0, !model.isFieldNameRow(row) {
            return .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        }
        return cellFont(forRow: row)
    }

    /// A cell's effective column type. Header and field-name rows ignore the
    /// column's type entirely — they're raw. Past the end of the data a row is
    /// a plain data row in waiting, so the column's type already applies.
    private func cellType(row: Int, column: Int) -> ColumnType {
        if let model, row < model.rowCount,
           model.headerLevel(ofRow: row) > 0 || model.isFieldNameRow(row) { return .raw }
        return cachedTypes[column] ?? .raw
    }

    /// True when a cell is laid out as a block of lines instead of one clipped
    /// line: a `text` column, which wraps, or a `raw` cell with line breaks in
    /// it. (The field-name row wraps too, but its height is settled before
    /// this is asked.)
    private func wrapsText(row: Int, column: Int, text: String) -> Bool {
        switch cellType(row: row, column: column) {
        case .text: return true
        case .raw: return text.contains("\n")
        default: return false
        }
    }

    /// Where a line break is content rather than a stray control character:
    /// `raw` and `text` cells, the two kinds that hold free-form strings.
    /// Numbers, checkboxes and select tokens flatten it to a space.
    private func allowsLineBreaks(at pos: GridPos) -> Bool {
        switch cellType(row: pos.row, column: pos.col) {
        case .raw, .text: return true
        default: return false
        }
    }

    private func textColor(forRow row: Int) -> NSColor {
        guard let model, row < model.rowCount else { return .textColor }
        return model.headerLevel(ofRow: row) == 3 ? .secondaryLabelColor : .labelColor
    }

    private func drawChrome(vis: NSRect, model: SpreadsheetModel,
                            bodyCols: ClosedRange<Int>?, bodyRows: ClosedRange<Int>?,
                            pinnedHeaders: [StickyHeader]) {
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        let headerH = Metrics.colHeaderHeight
        let headerW = Metrics.rowHeaderWidth
        let chromeFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

        func drawLetter(_ c: Int, translateX: CGFloat) {
            guard !hiddenColumns.contains(c) else { return }
            let rect = NSRect(x: xOffsets[c] + translateX, y: vis.minY,
                              width: xOffsets[c + 1] - xOffsets[c], height: headerH)
            if selectedCols.contains(c) {
                palette.chromeSelected.setFill()
                rect.fill()
            }
            let title = Self.columnLetters(c)
            let attrs: [NSAttributedString.Key: Any] = [.font: chromeFont, .foregroundColor: palette.chromeText]
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
            palette.gridLine.setFill()
            NSRect(x: rect.maxX - 0.5, y: vis.minY, width: 1, height: headerH).fill()
        }

        func drawNumber(_ r: Int, translateY: CGFloat) {
            guard !hiddenRows.contains(r) else { return }
            let rect = NSRect(x: vis.minX, y: yOffsets[r] + translateY,
                              width: headerW, height: height(ofRow: r))
            if selectedRows.contains(r) {
                palette.chromeSelected.setFill()
                rect.fill()
            }
            let isDuplicate = model.duplicateIDRows.contains(r)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: isDuplicate ? NSColor.systemRed : palette.chromeText,
            ]
            let title = String(r + 1)
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.maxX - size.width - 7, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
            if model.sectionBody(ofRow: r) != nil {
                drawSectionToggle(in: rect, collapsed: collapsedRows.contains(r))
            }
            palette.gridLine.setFill()
            NSRect(x: vis.minX, y: rect.maxY - 0.5, width: headerW, height: 1).fill()
        }

        // Column letter band.
        palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: headerH).fill()
        if let bodyCols {
            cg.saveGState()
            cg.clip(to: NSRect(x: vis.minX + chromeLeft, y: vis.minY,
                               width: vis.width - chromeLeft, height: headerH))
            for c in bodyCols { drawLetter(c, translateX: 0) }
            cg.restoreGState()
        }
        for c in 0..<frozenColCount { drawLetter(c, translateX: vis.minX) }

        // Markers where columns are folded away. Clipped to the body band, so
        // one can't creep over the frozen pane or the corner box.
        if !hiddenColumns.isEmpty {
            cg.saveGState()
            cg.clip(to: NSRect(x: vis.minX + chromeLeft, y: vis.minY,
                               width: vis.width - chromeLeft, height: headerH))
            for run in hiddenColumnRuns {
                guard let marker = hiddenMarkerScreenRect(for: run, vis: vis) else { continue }
                drawHiddenColumnsMarker(in: marker)
            }
            cg.restoreGState()
        }

        // Row number strip.
        palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY + headerH, width: headerW, height: vis.height - headerH).fill()
        if let bodyRows {
            cg.saveGState()
            cg.clip(to: NSRect(x: vis.minX, y: vis.minY + chromeTop,
                               width: headerW, height: vis.height - chromeTop))
            for r in bodyRows { drawNumber(r, translateY: 0) }
            cg.restoreGState()
        }
        // Pinned section headers bring their own number and triangle with them,
        // so the strip names the row that is actually on show.
        for sticky in pinnedHeaders where sticky.visibleHeight > 0.5 {
            let band = NSRect(x: vis.minX, y: sticky.visibleTop,
                              width: headerW, height: sticky.visibleHeight)
            cg.saveGState()
            cg.clip(to: band)
            palette.chromeBackground.setFill()
            band.fill()
            drawNumber(sticky.row, translateY: sticky.y - yOffsets[sticky.row])
            cg.restoreGState()
        }
        for r in 0..<frozenRowCount { drawNumber(r, translateY: vis.minY) }

        // Corner box.
        palette.chromeBackground.setFill()
        NSRect(x: vis.minX, y: vis.minY, width: headerW, height: headerH).fill()

        // Chrome and frozen-pane edges (pane edges slightly stronger).
        palette.gridLine.setFill()
        NSRect(x: vis.minX, y: vis.minY + headerH - 0.5, width: vis.width, height: 1).fill()
        NSRect(x: vis.minX + headerW - 0.5, y: vis.minY, width: 1, height: vis.height).fill()
        palette.gridLine.setFill()
        if frozenRowCount > 0 {
            NSRect(x: vis.minX, y: vis.minY + chromeTop - Metrics.frozenEdgeThickness * 2/3, width: vis.width, height: Metrics.frozenEdgeThickness).fill()
        }
        if frozenColCount > 0 {
            NSRect(x: vis.minX + chromeLeft - Metrics.frozenEdgeThickness * 2/3, y: vis.minY, width: Metrics.frozenEdgeThickness, height: vis.height).fill()
        }
    }

    /// Disclosure triangle for a section header, drawn at the left of its
    /// row-number cell: pointing down when open, accent-tinted and pointing
    /// right when the section is folded.
    private func drawSectionToggle(in rowRect: NSRect, collapsed: Bool) {
        let s = Metrics.toggleSize
        let x = rowRect.minX + 6
        let y = rowRect.midY - s / 2
        let path = NSBezierPath()
        if collapsed {
            path.move(to: NSPoint(x: x + 1, y: y))
            path.line(to: NSPoint(x: x + 1, y: y + s))
            path.line(to: NSPoint(x: x + s - 1, y: y + s / 2))
        } else {
            path.move(to: NSPoint(x: x, y: y + 1))
            path.line(to: NSPoint(x: x + s, y: y + 1))
            path.line(to: NSPoint(x: x + s / 2, y: y + s - 1))
        }
        path.close()
        (collapsed ? palette.accent : palette.chromeText).setFill()
        path.fill()
    }

    /// The marker for a run of hidden columns: two arrowheads pointing apart,
    /// where the columns would be. Clicking it brings them back — the missing
    /// letters (C, then E) are the other half of the cue.
    private func drawHiddenColumnsMarker(in box: NSRect) {
        palette.badgeFill.setFill()
        NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5).fill()
        let size: CGFloat = 3.5
        let gap: CGFloat = 1.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.midX - gap - size, y: box.midY))
        path.line(to: NSPoint(x: box.midX - gap, y: box.midY - size))
        path.line(to: NSPoint(x: box.midX - gap, y: box.midY + size))
        path.close()
        path.move(to: NSPoint(x: box.midX + gap + size, y: box.midY))
        path.line(to: NSPoint(x: box.midX + gap, y: box.midY - size))
        path.line(to: NSPoint(x: box.midX + gap, y: box.midY + size))
        path.close()
        palette.accent.setFill()
        path.fill()
    }

    /// "12 entries" for a collapsed section header, nil for every other row —
    /// what a folded header owes you, since the rows themselves are gone. It
    /// counts entries rather than rows, the same as the selection tally: the
    /// spacer rows and comments people pad sections with aren't content, and
    /// counting them makes a section look bigger than it is.
    private func foldedRowsLabel(forRow row: Int) -> String? {
        guard collapsedRows.contains(row), let model,
              let body = model.sectionBody(ofRow: row) else { return nil }
        let entries = model.entryCount(in: body)
        return entries == 1 ? "1 entry" : "\(entries) entries"
    }

    private static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    /// Draws a small pill at the right edge of `cell` and returns its frame, so
    /// the caller can keep the cell's own text clear of it.
    @discardableResult
    private func drawBadge(_ label: String, rightAlignedIn cell: NSRect) -> NSRect {
        let size = label.size(withAttributes: Self.badgeAttributes)
        let pill = NSRect(x: (cell.maxX - size.width - 16).rounded(),
                          y: (cell.midY - size.height / 2 - 2).rounded(),
                          width: (size.width + 12).rounded(), height: (size.height + 4).rounded())
        palette.badgeFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 6, y: pill.midY - size.height / 2),
                   withAttributes: Self.badgeAttributes)
        return pill
    }

    /// On-screen hit box for a header row's triangle — the left edge of the
    /// row-number strip, leaving the (right-aligned) number itself clickable
    /// for row selection. nil when the row folds nothing.
    private func sectionToggleScreenRect(row: Int, vis: NSRect) -> NSRect? {
        guard let model, row < model.rowCount, !hiddenRows.contains(row),
              model.sectionBody(ofRow: row) != nil else { return nil }
        if let pinned = stickyHeaders(vis: vis).first(where: { $0.row == row }) {
            return NSRect(x: vis.minX, y: pinned.visibleTop,
                          width: Metrics.toggleHitWidth, height: pinned.visibleHeight)
        }
        let sticky = row < frozenRowCount ? vis.minY : 0
        return NSRect(x: vis.minX, y: yOffsets[row] + sticky,
                      width: Metrics.toggleHitWidth, height: height(ofRow: row))
    }

    private func drawMoveIndicator(vis: NSRect) {
        guard let drop = moveDropIndex else { return }
        palette.selectionBorder.setFill()
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
        case hiddenColumnsMarker(ClosedRange<Int>)
        case rowHeader(row: Int)
        case sectionToggle(row: Int)
        case cell(GridPos)
    }

    /// Hidden columns grouped into the contiguous runs they were folded into,
    /// left to right — one marker, and one "show these" click, per gap.
    private var hiddenColumnRuns: [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for c in hiddenColumns.sorted() {
            if let last = runs.last, last.upperBound + 1 == c {
                runs[runs.count - 1] = last.lowerBound...c
            } else {
                runs.append(c...c)
            }
        }
        return runs
    }

    /// On-screen box for a run's marker, inside the header of the column that
    /// follows the gap. nil when that column is frozen (the marker would ride
    /// the sticky pane and cover its letter).
    private func hiddenMarkerScreenRect(for run: ClosedRange<Int>, vis: NSRect) -> NSRect? {
        let following = run.upperBound + 1
        guard following < gridCols, following >= frozenColCount else { return nil }
        return NSRect(x: xOffsets[run.lowerBound] + Metrics.hiddenMarkerInset,
                      y: vis.minY + 5,
                      width: Metrics.hiddenMarkerWidth,
                      height: Metrics.colHeaderHeight - 10)
    }

    /// Column at an on-screen x, honoring the sticky frozen column.
    private func columnAtScreenX(_ x: CGFloat, vis: NSRect) -> Int {
        if frozenColCount > 0, x < vis.minX + chromeLeft {
            return colAt(min(max(x - vis.minX, xOffsets[0]), chromeLeft - 0.5))
        }
        // Hidden columns share their successor's offset, so — as with folded
        // rows — the search only needs help at the clamped past-the-end edge.
        return visibleColumn(from: colAt(x), searching: -1)
    }

    /// Row at an on-screen y, honoring the sticky frozen row.
    private func rowAtScreenY(_ y: CGFloat, vis: NSRect) -> Int {
        if frozenRowCount > 0, y < vis.minY + chromeTop {
            return rowAt(min(max(y - vis.minY, yOffsets[0]), chromeTop - 0.5))
        }
        // Folded rows share their successor's offset, so the search already
        // lands on a visible row everywhere but the clamped past-the-end case.
        return visibleRow(from: rowAt(y), searching: -1)
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
            for run in hiddenColumnRuns {
                if let marker = hiddenMarkerScreenRect(for: run, vis: vis), marker.contains(p) {
                    return .hiddenColumnsMarker(run)
                }
            }
            let c = columnAtScreenX(p.x, vis: vis)
            if c >= frozenColCount {
                if abs(p.x - xOffsets[c + 1]) <= Metrics.resizeGrabMargin {
                    return .columnHeader(col: c, resizeEdgeOf: c)
                }
                // The left edge belongs to the column before — the nearest
                // *visible* one, since a hidden neighbour has no width to drag.
                if c > frozenColCount, abs(p.x - xOffsets[c]) <= Metrics.resizeGrabMargin {
                    return .columnHeader(col: c,
                                         resizeEdgeOf: visibleColumn(from: c - 1, searching: -1))
                }
            }
            return .columnHeader(col: c, resizeEdgeOf: nil)
        }
        // A pinned section header stands in front of the row scrolled under
        // it, in the number strip as much as in the sheet.
        if let pinned = stickyHeaders(vis: vis).first(where: { $0.covers(y: p.y) }) {
            if p.x < vis.minX + Metrics.rowHeaderWidth {
                if let toggle = sectionToggleScreenRect(row: pinned.row, vis: vis),
                   toggle.contains(p) {
                    return .sectionToggle(row: pinned.row)
                }
                return .rowHeader(row: pinned.row)
            }
            return .cell(GridPos(row: pinned.row, col: columnAtScreenX(p.x, vis: vis)))
        }
        if p.x < vis.minX + Metrics.rowHeaderWidth {
            let r = rowAtScreenY(p.y, vis: vis)
            if let toggle = sectionToggleScreenRect(row: r, vis: vis), toggle.contains(p) {
                return .sectionToggle(row: r)
            }
            return .rowHeader(row: r)
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

        case .hiddenColumnsMarker(let run):
            setColumns(Array(run), hidden: false)

        case .sectionToggle(let r):
            // ⌥-click folds/unfolds the subsections along with the section.
            setSection(headerRow: r,
                       collapsed: !collapsedRows.contains(r),
                       includingSubsections: event.modifierFlags.contains(.option))

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
            // Hitting a checkbox toggles it rather than starting a drag or an
            // edit — including on a double-click, which just toggles twice.
            if !shift, let box = checkboxHitRect(at: pos), box.contains(p) {
                dragMode = .none
                toggleCheckbox(at: pos)
            } else if !shift, let zone = chevronHitRect(at: pos), zone.contains(p) {
                // The chevron opens the option dropdown instead of an edit.
                dragMode = .none
                showSelectMenu(at: pos)
            } else if event.clickCount == 2 {
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
            idx = insertionBoundary(idx, rowCount: model.rowCount)
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
                remapRowFormatting(SpreadsheetModel.moveMapping(range: range, to: drop))
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
        case .sectionToggle, .hiddenColumnsMarker:
            NSCursor.pointingHand.set()
        case .cell(let pos):
            if let box = checkboxHitRect(at: pos), box.contains(p) {
                NSCursor.pointingHand.set()
            } else if let zone = chevronHitRect(at: pos), zone.contains(p) {
                NSCursor.pointingHand.set()
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

    /// How far an unbroken run of unfolded rows reaches from `start` toward
    /// `limit`, or nil when `start` is itself folded. Autofill drags stop at
    /// the fold rather than writing into cells the user can't see.
    private func visibleRun(from start: Int, through limit: Int, step: Int) -> Int? {
        guard !hiddenRows.contains(start) else { return nil }
        var last = start
        while last != limit, !hiddenRows.contains(last + step) { last += step }
        return last
    }

    private func updateFillTarget(pointer p: NSPoint) {
        let rect = rectFor(rows: selectedRows, cols: selectedCols)
        let dx = p.x > rect.maxX ? p.x - rect.maxX : (p.x < rect.minX ? p.x - rect.minX : 0)
        let dy = p.y > rect.maxY ? p.y - rect.maxY : (p.y < rect.minY ? p.y - rect.minY : 0)

        var target: (rows: ClosedRange<Int>, cols: ClosedRange<Int>, direction: FillDirection)?
        if abs(dy) >= abs(dx), dy != 0 {
            if dy > 0 {
                let end = rowAt(p.y)
                if end > selectedRows.upperBound,
                   let stop = visibleRun(from: selectedRows.upperBound + 1, through: end, step: 1) {
                    target = ((selectedRows.upperBound + 1)...stop, selectedCols, .down)
                }
            } else {
                let start = rowAt(p.y)
                if start < selectedRows.lowerBound,
                   let stop = visibleRun(from: selectedRows.lowerBound - 1, through: start, step: -1) {
                    target = (stop...(selectedRows.lowerBound - 1), selectedCols, .up)
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
        // A mirrored column has nothing to extend: its values come from
        // another sheet, and the fill would be undone by the next refresh.
        func fills(_ r: Int, _ c: Int) -> Bool { !isMirroredCell(GridPos(row: r, col: c)) }
        switch target.direction {
        case .down:
            for c in selectedCols {
                let source = selectedRows.map { model.value(row: $0, column: c) }
                let values = AutofillSeries.extend(source, count: target.rows.count)
                for (i, r) in target.rows.enumerated() {
                    guard fills(r, c) else { continue }
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .up:
            for c in selectedCols {
                let source = selectedRows.reversed().map { model.value(row: $0, column: c) }
                let values = AutofillSeries.extend(source, count: target.rows.count)
                for (i, r) in target.rows.reversed().enumerated() {
                    guard fills(r, c) else { continue }
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .right:
            for r in selectedRows {
                let source = selectedCols.map { model.value(row: r, column: $0) }
                let values = AutofillSeries.extend(source, count: target.cols.count)
                for (i, c) in target.cols.enumerated() {
                    guard fills(r, c) else { continue }
                    model.setValue(values[i], row: r, column: c)
                }
            }
        case .left:
            for r in selectedRows {
                let source = selectedCols.reversed().map { model.value(row: r, column: $0) }
                let values = AutofillSeries.extend(source, count: target.cols.count)
                for (i, c) in target.cols.reversed().enumerated() {
                    guard fills(r, c) else { continue }
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
              !(format.columnWidths.isEmpty && format.columnTypes.isEmpty
                && format.selectSources.isEmpty && format.sourceSpecs.isEmpty
                && format.hiddenColumns.isEmpty
                && format.flagDuplicateColumns.isEmpty) else { return }
        onFormatChange? { format in
            var widths: [Int: CGFloat] = [:]
            for (k, v) in format.columnWidths { widths[mapping[k] ?? k] = v }
            format.columnWidths = widths
            var types: [Int: ColumnType] = [:]
            for (k, v) in format.columnTypes { types[mapping[k] ?? k] = v }
            format.columnTypes = types
            var sources: [Int: SelectSource] = [:]
            for (k, v) in format.selectSources { sources[mapping[k] ?? k] = v }
            format.selectSources = sources
            var specs: [Int: SourceSpec] = [:]
            for (k, v) in format.sourceSpecs { specs[mapping[k] ?? k] = v }
            format.sourceSpecs = specs
            format.hiddenColumns = Set(format.hiddenColumns.map { mapping[$0] ?? $0 })
            format.flagDuplicateColumns =
                Set(format.flagDuplicateColumns.map { mapping[$0] ?? $0 })
        }
        let inverse = Dictionary(uniqueKeysWithValues: mapping.map { ($1, $0) })
        undoManager?.registerUndo(withTarget: self) { view in
            view.remapColumnFormatting(inverse)
        }
        modelDidChange()
    }

    private func remapRowFormatting(_ mapping: [Int: Int]) {
        guard !mapping.isEmpty, let format = formatProvider?(),
              !(format.rowHeights.isEmpty && format.collapsedSections.isEmpty) else { return }
        onFormatChange? { format in
            var updated: [Int: CGFloat] = [:]
            for (k, v) in format.rowHeights { updated[mapping[k] ?? k] = v }
            format.rowHeights = updated
            format.collapsedSections = Set(format.collapsedSections.map { mapping[$0] ?? $0 })
        }
        let inverse = Dictionary(uniqueKeysWithValues: mapping.map { ($1, $0) })
        undoManager?.registerUndo(withTarget: self) { view in
            view.remapRowFormatting(inverse)
        }
        modelDidChange()
    }

    // MARK: - Keyboard

    /// Tab cycling, for the shortcuts the Window menu can't advertise on its
    /// own. A menu item carries one key equivalent apiece, so ⌃⇥ / ⌃⇧⇥ are
    /// named there and the older ⇧⌘[ / ⇧⌘] are matched here — as is ⌃⇧⇥
    /// itself, since shift-tab arrives as back-tab (U+0019) rather than as a
    /// shifted tab, which menu matching can miss. Matching here rather than in
    /// `keyDown` means the shortcuts work with the find bar or a cell editor
    /// focused too; the menu gets first refusal either way, so nothing fires
    /// twice.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, (window.tabbedWindows?.count ?? 0) > 1,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.modifierFlags.intersection(.deviceIndependentFlagsMask), key) {
        case ([.command, .shift], "["), ([.control, .shift], "\t"),
             ([.control, .shift], "\u{19}"):
            window.selectPreviousTab(nil)
        case ([.command, .shift], "]"), (.control, "\t"):
            window.selectNextTab(nil)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.utf16.first else {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags
        let shift = mods.contains(.shift)

        // Space toggles checkboxes in `boolean` columns; anywhere else it falls
        // through and types a space.
        if Int(scalar) == 32, !mods.contains(.command), !mods.contains(.control),
           checkboxState(at: focus) != nil {
            toggleCheckboxesInSelection()
            return
        }

        switch Int(scalar) {
        case NSUpArrowFunctionKey: move(dRow: -1, dCol: 0, extend: shift)
        case NSDownArrowFunctionKey: move(dRow: 1, dCol: 0, extend: shift)
        case NSLeftArrowFunctionKey: move(dRow: 0, dCol: -1, extend: shift)
        case NSRightArrowFunctionKey: move(dRow: 0, dCol: 1, extend: shift)
        // ⇥ steps across the row; ⌃⇥ belongs to the window (cycling tabs) and
        // is normally claimed by the menu long before it gets here.
        case 9 where !mods.contains(.control):
            move(dRow: 0, dCol: 1, extend: false)                            // Tab
        case 25 where !mods.contains(.control):
            move(dRow: 0, dCol: -1, extend: false)                           // Shift-Tab
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
        // Arrowing over a collapsed section steps across it in one go.
        if dRow != 0 {
            target.row = visibleRow(from: target.row, searching: dRow > 0 ? 1 : -1)
        }
        target.col = min(max(target.col + dCol, 0), gridCols - 1)
        // Likewise sideways: hidden columns are stepped over, not into.
        if dCol != 0 {
            target.col = visibleColumn(from: target.col, searching: dCol > 0 ? 1 : -1)
        }
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
            let headroom = chromeTop + pinnedHeight(above: pos.row)
            rect.origin.y -= headroom
            rect.size.height += headroom
        }
        scrollToVisible(rect)
    }

    /// Populated / empty tally for a multi-cell selection, for the formula bar.
    /// nil for a lone cell (whose content is already right there in the bar)
    /// and for a selection with nothing countable in it. A collapsed header is
    /// never a lone cell: it stands in for everything folded under it.
    func selectionTally() -> SelectionTally? {
        guard let model, selectedRows.count * selectedCols.count > 1 else { return nil }
        let tally = model.tally(rows: selectedRows, columns: selectedCols,
                                booleanColumns: booleanColumnIndices)
        let total = tally.populated + tally.empty
        guard total > 0 else { return nil }
        return SelectionTally(populated: tally.populated, total: total,
                              idsOnly: selectedCols == 0...0)
    }

    private func selectionDidChange() {
        needsDisplay = true
        onSelectionChange?()
    }

    // MARK: - Editing

    /// A tab can never live in a cell — it's the column separator — and CR is
    /// normalized to LF the way the file is on the way in. Line breaks survive
    /// only where they're content (see `allowsLineBreaks`).
    private func sanitize(_ text: String, at pos: GridPos) -> String {
        let flat = text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard allowsLineBreaks(at: pos) else {
            return flat.replacingOccurrences(of: "\n", with: " ")
        }
        return flat
    }

    func beginEditing(at pos: GridPos, initialText: String?) {
        guard let model, !hiddenRows.contains(pos.row), !isMirroredCell(pos) else { return }
        commitEdit(thenMove: nil)
        anchor = pos
        focus = pos
        selectionDidChange()
        scrollCellToVisible(pos)

        // Frozen cells render pinned to the viewport; the editor must match.
        let frame = cellScreenRect(pos).insetBy(dx: 1, dy: 1)

        let isTextColumn = isTextCell(pos)
        let multiline = allowsLineBreaks(at: pos)

        let field = NSTextField(frame: frame)
        field.font = cellFont(forRow: pos.row, column: pos.col)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.delegate = self
        if multiline {
            // ⌥Enter puts a line break in, which a single-line cell would
            // swallow — and once the value has lines, it has to wrap to show
            // them.
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
        let selectKind = selectCellKind(at: pos)
        editingSelectOptions = selectKind?.options
        editingSelectIsMulti = selectKind?.multi ?? false
        selectSuggestionBase = nil
        // Type-to-edit should suggest from the very first character, so the
        // pre-seeded text counts as "typed" rather than as already there.
        lastEditorText = initialText != nil ? "" : field.stringValue
        window?.makeFirstResponder(field)
        if let fieldEditor = field.currentEditor() {
            fieldEditor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            if let textView = fieldEditor as? NSTextView {
                // The window's field editor is shared between cells, so both
                // states have to be set — otherwise spell checking turned on
                // for a text column follows you into an ID or number column.
                textView.isContinuousSpellCheckingEnabled = isTextColumn
                textView.isGrammarCheckingEnabled = false
                // Never silently rewrite data on the way in.
                textView.isAutomaticSpellingCorrectionEnabled = false
                textView.isAutomaticTextReplacementEnabled = false
                textView.isAutomaticQuoteSubstitutionEnabled = false
                textView.isAutomaticDashSubstitutionEnabled = false
                // Continuous checking only marks text as it changes, so seed the
                // squiggles the grid already knows about — otherwise clicking
                // into a cell makes them vanish until the next keystroke.
                if isTextColumn, initialText == nil {
                    for range in spellIndex.misspellings(in: field.stringValue) {
                        textView.setSpellingState(
                            NSAttributedString.SpellingState.spelling.rawValue, range: range)
                    }
                }
            }
        }
        // Setting stringValue never fires controlTextDidChange, so a typed-in
        // first character needs its suggestion kicked off by hand.
        if editSessionFromTyping, editingSelectOptions != nil {
            autocompleteSelectEditor(field)
        }
        sizeEditorToFit()
        needsDisplay = true
    }

    /// Grows a wrapping editor downward over the rows below it, so the lines a
    /// value already has (and the ones ⌥Enter adds) are all visible while
    /// typing — the row itself only grows once the edit is committed.
    private func sizeEditorToFit() {
        guard let field = editor, let cell = editingCell,
              field.cell?.wraps == true else { return }
        var frame = cellScreenRect(cell).insetBy(dx: 1, dy: 1)
        let fits = NSRect(x: 0, y: 0, width: frame.width, height: .greatestFiniteMagnitude)
        let needed = field.cell?.cellSize(forBounds: fits).height ?? frame.height
        // Never past the bottom of the viewport: an editor that runs off the
        // window would put the end of what you're typing out of reach.
        let room = visibleRect.maxY - frame.minY
        frame.size.height = min(max(frame.height, ceil(needed) + 2), max(room, frame.height))
        if field.frame != frame {
            field.frame = frame
            // Shrinking uncovers grid the editor was standing on.
            needsDisplay = true
        }
    }

    private enum MoveAfterEdit { case up, down, left, right }

    private func commitEdit(thenMove direction: MoveAfterEdit?) {
        guard let field = editor, let cell = editingCell, !isCommittingEdit else { return }
        isCommittingEdit = true
        let text = sanitize(field.stringValue, at: cell)
        editor = nil
        editingCell = nil
        editingSelectOptions = nil
        selectSuggestionBase = nil
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

    /// Whether a cell is open for editing — text the user has typed but not
    /// committed, which anything replacing the model needs to know about.
    var isEditingCell: Bool { editor != nil }

    /// Throws away an in-progress cell edit from outside (a reload).
    func cancelCellEdit() { cancelEdit() }

    private func cancelEdit() {
        guard let field = editor else { return }
        editor = nil
        editingCell = nil
        editingSelectOptions = nil
        selectSuggestionBase = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Commit coming from the formula bar.
    func applyToFocusedCell(_ text: String) {
        guard !isMirroredCell(focus) else { return }
        // The bar shows the file's own spelling of the value, `\n` and all.
        model?.setValue(sanitize(SpreadsheetModel.decodeCell(text), at: focus),
                        row: focus.row, column: focus.col)
        window?.makeFirstResponder(self)
    }

    // MARK: - NSTextFieldDelegate (the in-cell editor)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editor else { return false }
        switch commandSelector {
        // Enter commits in place: the cell you were editing stays the cell
        // you're on, so a fix and a second Enter reopens the same cell.
        case #selector(NSResponder.insertNewline(_:)):
            commitEdit(thenMove: nil)
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
        // Arrows commit and move only while typing a fresh value over a cell.
        // Once the session is a real edit (double-click, Enter, the formula
        // bar), every arrow belongs to the insertion point — up and down
        // included, since a wrapped value has lines to move between.
        case #selector(NSResponder.moveUp(_:)) where editSessionFromTyping:
            commitEdit(thenMove: .up)
            return true
        case #selector(NSResponder.moveDown(_:)) where editSessionFromTyping:
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

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === editor else { return }
        autocompleteSelectEditor(field)
        sizeEditorToFit()
    }

    /// Inline autocomplete for select cells: the first option the token being
    /// typed is a prefix of is filled in ahead of the cursor, with the
    /// unconfirmed remainder selected — typing keeps narrowing it, ⌫ discards
    /// it, and committing the edit accepts it. On a multi-select the token is
    /// whatever follows the last comma, and typing "," confirms the suggestion
    /// (or expands a bare prefix) before starting the next token.
    private func autocompleteSelectEditor(_ field: NSTextField) {
        guard let options = editingSelectOptions, !options.isEmpty, !isAutocompleting,
              let textView = field.currentEditor() as? NSTextView else { return }
        let text = textView.string
        // What the user had really typed before this change: a showing
        // suggestion isn't part of it (typing replaces its selected remainder).
        let previous = selectSuggestionBase ?? lastEditorText
        lastEditorText = text
        selectSuggestionBase = nil

        func setText(_ newText: String, selecting range: NSRange) {
            isAutocompleting = true
            field.stringValue = newText
            textView.setSelectedRange(range)
            lastEditorText = newText
            isAutocompleting = false
        }

        // Comma on a multi-select confirms the token it closes: a bare prefix
        // ("fir,") becomes the option it was heading for ("fire,").
        if editingSelectIsMulti, text == previous + "," {
            let head = previous as NSString
            var start = 0
            let priorComma = head.range(of: ",", options: .backwards)
            if priorComma.location != NSNotFound { start = priorComma.location + 1 }
            let token = head.substring(from: start).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, !options.contains(token),
                  let match = options.first(where: {
                      $0.lowercased().hasPrefix(token.lowercased())
                  }) else { return }
            let confirmed = head.substring(to: start) + match + ","
            setText(confirmed, selecting: NSRange(location: (confirmed as NSString).length,
                                                  length: 0))
            return
        }

        // Suggest only while typing forward at the end of the text — deleting
        // or editing the middle should never fight the user.
        guard text.count > previous.count,
              textView.selectedRange.length == 0,
              textView.selectedRange.location == (text as NSString).length else { return }

        let ns = text as NSString
        var tokenStart = 0
        if editingSelectIsMulti {
            let lastComma = ns.range(of: ",", options: .backwards)
            if lastComma.location != NSNotFound { tokenStart = lastComma.location + 1 }
        }
        let typed = ns.substring(from: tokenStart)
        let token = typed.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !options.contains(token),
              let match = options.first(where: {
                  $0.lowercased().hasPrefix(token.lowercased())
              }) else { return }

        // Replace the token with the match (fixing its case), keep the typed
        // part before the cursor and the rest selected as the suggestion.
        let prefix = ns.substring(to: tokenStart) + typed.prefix(while: { $0 == " " })
        let completed = prefix + match
        let cursor = (prefix as NSString).length + (token as NSString).length
        setText(completed, selecting: NSRange(
            location: cursor,
            length: (completed as NSString).length - cursor))
        selectSuggestionBase = prefix + token
    }

    // MARK: - Clipboard & selection commands

    @objc func copy(_ sender: Any?) {
        guard let model else { return }
        let rows = selectedRows, cols = selectedCols
        // Cell line breaks travel escaped, exactly as in the file — a raw one
        // would read as the end of the row to every other spreadsheet.
        let text = rows.map { r in
            cols.map { c in SpreadsheetModel.encodeCell(model.value(row: r, column: c)) }
                .joined(separator: "\t")
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
                let pos = GridPos(row: origin.row + dr, col: origin.col + dc)
                guard !isMirroredCell(pos) else { continue }
                model.setValue(sanitize(SpreadsheetModel.decodeCell(value), at: pos),
                               row: pos.row, column: pos.col)
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
        // Keeps the cursor off a folded row when the last section is collapsed.
        clampSelection()
        selectionDidChange()
    }

    // MARK: - Arithmetic on the selection

    /// Selected cells arithmetic can touch: ones holding a number, and not
    /// mirrored from another sheet (those get overwritten on the next refresh).
    private var adjustableNumericCells: [GridPos] {
        guard let model else { return [] }
        var cells: [GridPos] = []
        for r in selectedRows where r < model.rowCount {
            for c in selectedCols where c < model.columnCount {
                let pos = GridPos(row: r, col: c)
                guard !isMirroredCell(pos),
                      CellArithmetic.number(model.value(row: r, column: c)) != nil else { continue }
                cells.append(pos)
            }
        }
        return cells
    }

    @objc private func adjustSelectedValues(_ sender: NSMenuItem) {
        guard let model,
              let raw = sender.representedObject as? String,
              let operation = CellArithmetic.Operation(rawValue: raw) else { return }
        // Re-read the selection rather than trusting the count in the title:
        // the sheet could have changed while the menu was open.
        let cells = adjustableNumericCells
        guard !cells.isEmpty else { NSSound.beep(); return }
        guard let operand = CellArithmetic.runPrompt(operation: operation,
                                                     cellCount: cells.count) else { return }
        for pos in cells {
            guard let updated = CellArithmetic.apply(
                operation, operand: operand,
                to: model.value(row: pos.row, column: pos.col)) else { continue }
            model.setValue(updated, row: pos.row, column: pos.col)
        }
        undoManager?.setActionName(operation.actionName)
    }

    private func clearSelectedCells() {
        guard let model else { return }
        for r in selectedRows where r < model.rowCount {
            for c in selectedCols where c < model.columnCount
                && !isMirroredCell(GridPos(row: r, col: c)) {
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

    // MARK: - Accent color (Sheet menu)

    /// Repaints this sheet in the accent color named by the menu item. Only
    /// colors change, so there's no geometry to rebuild.
    @objc func setSheetAccent(_ sender: Any?) {
        guard let accent = Self.accent(of: sender as? NSMenuItem) else { return }
        onFormatChange? { $0.accent = accent }
        palette = Palette(accent: accent.color)
        needsDisplay = true
    }

    private static func accent(of menuItem: NSMenuItem?) -> SheetAccent? {
        guard let raw = menuItem?.representedObject as? String else { return nil }
        return SheetAccent(rawValue: raw)
    }

    // MARK: - Section folding

    /// The section the cursor sits in — the focused row itself when it's a
    /// header, otherwise the innermost section around it.
    private var focusedSectionHeader: Int? {
        guard let model, focus.row < model.rowCount else { return nil }
        return model.enclosingSectionHeader(ofRow: focus.row)
    }

    /// Folds/unfolds one header's section, optionally carrying every
    /// subsection nested inside it along.
    private func setSection(headerRow: Int, collapsed: Bool, includingSubsections: Bool) {
        guard let model, let body = model.sectionBody(ofRow: headerRow) else { return }
        var affected = [headerRow]
        if includingSubsections {
            affected += body.filter { model.sectionBody(ofRow: $0) != nil }
        }
        applySectionCollapse(rows: affected, collapsed: collapsed)
        scrollSectionHeaderToTop(headerRow)
    }

    /// Brings a header up to the top of the body — under the chrome, and under
    /// any header pinned above it, which is exactly the slot it was pinned in.
    /// Folding a section from its pinned header would otherwise leave the
    /// triangle you just clicked somewhere off the top of the sheet: this way
    /// it stays under the cursor, ready to unfold what you just folded. A
    /// header already on screen doesn't move — the scroll is the minimum one
    /// that clears the chrome.
    private func scrollSectionHeaderToTop(_ row: Int) {
        guard let model, row < model.rowCount, !hiddenRows.contains(row) else { return }
        let headroom = chromeTop + pinnedHeight(above: row)
        var rect = cellRect(row, 0)
        // Vertical only: folding a section is no reason to yank the view back
        // to the ID column.
        rect.origin.x = visibleRect.minX
        rect.size.width = 1
        rect.origin.y -= headroom
        rect.size.height += headroom
        scrollToVisible(rect)
    }

    private func applySectionCollapse(rows: [Int], collapsed: Bool) {
        guard let model, !rows.isEmpty else { return }
        // Prune entries whose "#" has been edited away since they were written.
        var updated = collapsedRows.intersection(model.sectionHeaderRows())
        if collapsed { updated.formUnion(rows) } else { updated.subtract(rows) }
        guard updated != collapsedRows else { return }
        onFormatChange? { $0.collapsedSections = updated }
        modelDidChange()
        selectionDidChange()
    }

    /// Unfolds whatever is hiding a row. Cross-file jumps and duplicate-ID
    /// hops go through here so they never land on an invisible row.
    private func expandToReveal(row: Int) {
        guard let model, hiddenRows.contains(row) else { return }
        let blockers = collapsedRows.filter { model.sectionBody(ofRow: $0)?.contains(row) ?? false }
        applySectionCollapse(rows: Array(blockers), collapsed: false)
    }

    @objc func collapseSection(_ sender: Any?) {
        guard let header = focusedSectionHeader else { return }
        setSection(headerRow: header, collapsed: true, includingSubsections: false)
    }

    @objc func expandSection(_ sender: Any?) {
        guard let header = focusedSectionHeader else { return }
        setSection(headerRow: header, collapsed: false, includingSubsections: false)
    }

    @objc func collapseAllSections(_ sender: Any?) {
        guard let model else { return }
        applySectionCollapse(rows: model.sectionHeaderRows(), collapsed: true)
    }

    @objc func expandAllSections(_ sender: Any?) {
        applySectionCollapse(rows: Array(collapsedRows), collapsed: false)
    }

    // MARK: - Hiding columns

    /// The selected columns that can actually be folded away: real data
    /// columns that aren't already hidden, never the ID column (it anchors
    /// every row) and never the phantom space past the data.
    private var hideableSelectedColumns: [Int] {
        guard let model else { return [] }
        return selectedCols.filter {
            $0 >= 1 && $0 < model.columnCount && !hiddenColumns.contains($0)
        }
    }

    /// Hidden columns the selection reaches over. Selecting across a gap picks
    /// up the columns inside it, which is how a hidden run gets chosen without
    /// being clickable itself.
    private var hiddenColumnsInSelection: [Int] {
        selectedCols.filter { hiddenColumns.contains($0) }
    }

    @objc func hideSelectedColumns(_ sender: Any?) {
        setColumns(hideableSelectedColumns, hidden: true)
    }

    @objc func showHiddenColumns(_ sender: Any?) {
        setColumns(hiddenColumnsInSelection, hidden: false)
    }

    @objc func showAllHiddenColumns(_ sender: Any?) {
        setColumns(Array(hiddenColumns), hidden: false)
    }

    private func setColumns(_ columns: [Int], hidden: Bool) {
        guard !columns.isEmpty else { return }
        var updated = hiddenColumns
        if hidden { updated.formUnion(columns) } else { updated.subtract(columns) }
        guard updated != hiddenColumns else { return }
        onFormatChange? { $0.hiddenColumns = updated }
        // A selection sitting on the columns just hidden is pulled to the
        // nearest visible one by `clampSelection`.
        modelDidChange()
        selectionDidChange()
    }

    // MARK: - Row / column commands (Sheet menu + context menu)

    /// Insert / delete work in units of the selection: three selected rows
    /// insert three, the way a spreadsheet is expected to behave.
    private var insertRowCount: Int { selectedRows.count }
    private var insertColumnCount: Int { selectedCols.count }

    @objc func insertRowAbove(_ sender: Any?) {
        guard let model else { return }
        let at = min(selectedRows.lowerBound, model.rowCount)   // as the model clamps
        let count = insertRowCount
        shiftRowFormatting { SpreadsheetModel.shiftedIndex($0, afterInsertAt: at, count: count) }
        model.insertRow(at: at, count: count)
    }

    @objc func insertRowBelow(_ sender: Any?) {
        guard let model else { return }
        let at = insertionBoundary(min(selectedRows.upperBound + 1, model.rowCount),
                                   rowCount: model.rowCount)
        let count = insertRowCount
        shiftRowFormatting { SpreadsheetModel.shiftedIndex($0, afterInsertAt: at, count: count) }
        model.insertRow(at: at, count: count)
    }

    @objc func deleteSelectedRows(_ sender: Any?) {
        guard let model else { return }
        let indexes = IndexSet(selectedRows.filter { $0 < model.rowCount })
        // Mirror removeRows' own guard so the formatting shift can't run ahead
        // of a rejected deletion.
        guard !indexes.isEmpty, indexes.count < model.rowCount else { return }
        shiftRowFormatting { SpreadsheetModel.shiftedIndex($0, afterRemoving: indexes) }
        model.removeRows(indexes)
    }

    /// Re-keys per-row `.tss` state (heights, collapsed sections) so it stays
    /// attached to its content when rows are inserted or deleted above it.
    /// State on a deleted row is dropped — a collapsed header that outlived its
    /// row would keep its section folded with no triangle to unfold it.
    private func shiftRowFormatting(_ transform: (Int) -> Int?) {
        guard let format = formatProvider?(),
              !format.rowHeights.isEmpty || !format.collapsedSections.isEmpty else { return }
        var heights: [Int: CGFloat] = [:]
        for (row, height) in format.rowHeights {
            if let moved = transform(row) { heights[moved] = height }
        }
        setRowFormatting(heights: heights,
                         collapsed: Set(format.collapsedSections.compactMap(transform)))
    }

    /// Re-keys per-column `.tss` state (widths, data types) so it stays with
    /// its content when columns are inserted or deleted to its left. State on a
    /// deleted column is dropped.
    private func shiftColumnFormatting(_ transform: (Int) -> Int?) {
        guard let format = formatProvider?(),
              !format.columnWidths.isEmpty || !format.columnTypes.isEmpty
                || !format.selectSources.isEmpty || !format.sourceSpecs.isEmpty
                || !format.hiddenColumns.isEmpty
                || !format.flagDuplicateColumns.isEmpty else { return }
        var widths: [Int: CGFloat] = [:]
        for (column, width) in format.columnWidths {
            if let moved = transform(column) { widths[moved] = width }
        }
        var types: [Int: ColumnType] = [:]
        for (column, type) in format.columnTypes {
            if let moved = transform(column) { types[moved] = type }
        }
        var sources: [Int: SelectSource] = [:]
        for (column, source) in format.selectSources {
            if let moved = transform(column) { sources[moved] = source }
        }
        var specs: [Int: SourceSpec] = [:]
        for (column, spec) in format.sourceSpecs {
            if let moved = transform(column) { specs[moved] = spec }
        }
        setColumnFormatting(widths: widths, types: types, sources: sources, specs: specs,
                            hidden: Set(format.hiddenColumns.compactMap(transform)),
                            flagged: Set(format.flagDuplicateColumns.compactMap(transform)))
    }

    /// The per-column counterpart of `setRowFormatting`.
    private func setColumnFormatting(widths: [Int: CGFloat], types: [Int: ColumnType],
                                     sources: [Int: SelectSource], specs: [Int: SourceSpec],
                                     hidden: Set<Int>, flagged: Set<Int>) {
        guard let format = formatProvider?() else { return }
        let previousWidths = format.columnWidths
        let previousTypes = format.columnTypes
        let previousSources = format.selectSources
        let previousSpecs = format.sourceSpecs
        let previousHidden = format.hiddenColumns
        let previousFlagged = format.flagDuplicateColumns
        guard widths != previousWidths || types != previousTypes
            || sources != previousSources || specs != previousSpecs
            || hidden != previousHidden || flagged != previousFlagged else { return }
        onFormatChange? {
            $0.columnWidths = widths
            $0.columnTypes = types
            $0.selectSources = sources
            $0.sourceSpecs = specs
            $0.hiddenColumns = hidden
            $0.flagDuplicateColumns = flagged
        }
        undoManager?.registerUndo(withTarget: self) { view in
            view.setColumnFormatting(widths: previousWidths, types: previousTypes,
                                     sources: previousSources, specs: previousSpecs,
                                     hidden: previousHidden, flagged: previousFlagged)
        }
        modelDidChange()
    }

    /// Replaces the per-row `.tss` state wholesale, registering the exact
    /// inverse so it rides along in the same undo group as the row
    /// insert/delete that prompted it.
    private func setRowFormatting(heights: [Int: CGFloat], collapsed: Set<Int>) {
        guard let format = formatProvider?() else { return }
        let previousHeights = format.rowHeights
        let previousCollapsed = format.collapsedSections
        guard heights != previousHeights || collapsed != previousCollapsed else { return }
        onFormatChange? {
            $0.rowHeights = heights
            $0.collapsedSections = collapsed
        }
        undoManager?.registerUndo(withTarget: self) { view in
            view.setRowFormatting(heights: previousHeights, collapsed: previousCollapsed)
        }
        modelDidChange()
    }

    @objc func insertColumnLeft(_ sender: Any?) {
        guard let model else { return }
        insertColumns(at: max(selectedCols.lowerBound, 1), model: model)
    }

    @objc func insertColumnRight(_ sender: Any?) {
        guard let model else { return }
        insertColumns(at: min(selectedCols.upperBound + 1, model.columnCount), model: model)
    }

    private func insertColumns(at index: Int, model: SpreadsheetModel) {
        // Clamp exactly as the model does (a selection can reach into the
        // phantom columns), so the formatting shift agrees with the insert.
        let at = min(max(index, 1), model.columnCount)
        let count = insertColumnCount
        shiftColumnFormatting { SpreadsheetModel.shiftedIndex($0, afterInsertAt: at, count: count) }
        model.insertColumn(at: at, count: count)
    }

    @objc func deleteSelectedColumns(_ sender: Any?) {
        guard let model else { return }
        let indexes = IndexSet(selectedCols.filter { $0 >= 1 && $0 < model.columnCount })
        // Mirror removeColumns' own guard so the formatting shift can't run
        // ahead of a rejected deletion.
        guard !indexes.isEmpty else { return }
        shiftColumnFormatting { SpreadsheetModel.shiftedIndex($0, afterRemoving: indexes) }
        model.removeColumns(indexes)
    }

    @objc func jumpToNextDuplicateID(_ sender: Any?) {
        guard let model, !model.duplicateIDRows.isEmpty else { return }
        let sorted = model.duplicateIDRows.sorted()
        let next = sorted.first(where: { $0 > focus.row }) ?? sorted[0]
        expandToReveal(row: next)
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
                // None of these types links to another sheet; picking one
                // retires whatever a select or source column had configured.
                format.selectSources.removeValue(forKey: c)
                format.sourceSpecs.removeValue(forKey: c)
            }
        }
        modelDidChange()
    }

    /// "Select…" / "Multi-Select…": these types carry an options source, so
    /// they're set through a dialog — where the options come from (an ad-hoc
    /// list, or another sheet's IDs) — instead of a bare menu pick. Re-picking
    /// the type re-opens the dialog prefilled, to edit the source.
    @objc private func configureSelectColumns(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = ColumnType(rawValue: raw), let model else { return }
        let columns = selectedCols.filter { $0 < model.columnCount }
        guard let anchorColumn = columns.first else { return }

        guard let source = SelectSourcePanel.run(
            columnName: describe(columns: columns, anchoredAt: anchorColumn),
            typeTitle: type == .multiselect ? "Multi-Select" : "Select",
            existing: cachedSelectSources[anchorColumn],
            suggested: valuesInUse(columns: columns),
            tsvURL: documentURLProvider?()) else { return }

        onFormatChange? { format in
            for c in columns {
                format.columnTypes[c] = type
                format.selectSources[c] = source
                format.sourceSpecs.removeValue(forKey: c)
            }
        }
        modelDidChange()
    }

    /// "Source…": which sheet to mirror, and which of its fields. Like the
    /// select types this one carries a configuration, so re-picking it
    /// re-opens the dialog prefilled instead of doing nothing.
    @objc private func configureSourceColumns(_ sender: NSMenuItem) {
        guard let model else { return }
        let columns = selectedCols.filter { $0 < model.columnCount }
        guard let anchorColumn = columns.first else { return }

        guard let spec = SourceColumnPanel.run(
            columnName: describe(columns: columns, anchoredAt: anchorColumn),
            existing: cachedSourceSpecs[anchorColumn],
            tsvURL: documentURLProvider?(),
            resolver: sourceResolver) else { return }

        onFormatChange? { format in
            for c in columns {
                format.columnTypes[c] = .source
                format.sourceSpecs[c] = spec
                format.selectSources.removeValue(forKey: c)
            }
        }
        modelDidChange()
    }

    // MARK: - Flag Duplicates

    /// The selected columns the option can speak for: real data columns, never
    /// the ID column (whose IDs are checked whatever anyone asks for) and never
    /// the phantom space past the data.
    private var flaggableSelectedColumns: [Int] {
        guard let model else { return [] }
        return selectedCols.filter { $0 >= 1 && $0 < model.columnCount }
    }

    /// "Flag Duplicates": tint a column's repeated values red the way
    /// colliding IDs are tinted. Like a mixed-state checkbox, a selection
    /// where only some columns have it on turns it on for all of them.
    @objc private func toggleFlagDuplicates(_ sender: Any?) {
        let columns = flaggableSelectedColumns
        guard !columns.isEmpty else { return }
        let turnOn = !columns.allSatisfy { duplicateFlagColumns.contains($0) }
        onFormatChange? { format in
            if turnOn {
                format.flagDuplicateColumns.formUnion(columns)
            } else {
                format.flagDuplicateColumns.subtract(columns)
            }
        }
        modelDidChange()
    }

    /// How the column-type dialogs name what they're about to configure: by
    /// field name where there is one, else by letter, plus a count of the rest
    /// of the selection.
    private func describe(columns: [Int], anchoredAt anchorColumn: Int) -> String {
        var name = "Column " + Self.columnLetters(anchorColumn)
        if let model, model.hasFieldNameRow {
            let fieldName = model.value(row: 0, column: anchorColumn)
            if !fieldName.isEmpty { name = "“\(fieldName)”" }
        }
        return columns.count > 1 ? name + " (and \(columns.count - 1) more)" : name
    }

    /// The distinct values the given columns already hold, in sheet order —
    /// what the select dialog offers as a ready-made ad-hoc list. Only cells a
    /// select column would govern count (rows with an ID, no headers or field
    /// names), and values are split on commas the way a multi-select cell is.
    ///
    /// A column with more distinct values than any list could plausibly want
    /// isn't an options column at all — free-form text that happens to be
    /// getting retyped — so it suggests nothing rather than a wall of text.
    private func valuesInUse(columns: [Int]) -> [String] {
        guard let model else { return [] }
        let limit = 100
        var seen = Set<String>()
        var values: [String] = []
        for r in 0..<model.rowCount
        where model.headerLevel(ofRow: r) == 0 && !model.isFieldNameRow(r)
            && !model.value(row: r, column: 0).isEmpty {
            for c in columns where c < model.columnCount {
                for token in SelectCell.tokens(model.value(row: r, column: c))
                where !token.isEmpty && seen.insert(token).inserted {
                    if values.count == limit { return [] }
                    values.append(token)
                }
            }
        }
        return values
    }

    @objc private func autoSizeColumns(_ sender: Any?) {
        guard let model else { return }
        let cols = selectedCols.filter { $0 < model.columnCount }
        guard !cols.isEmpty else { return }
        onFormatChange? { format in
            for c in cols {
                // A checkbox is a fixed size, so the text in the file (TRUE /
                // FALSE) says nothing about how wide the column needs to be.
                if format.columnTypes[c] == .boolean {
                    format.columnWidths[c] = Metrics.minColWidth
                    continue
                }
                // Pre-filter by character count so huge sheets only measure a
                // handful of candidate strings.
                var candidates: [(row: Int, count: Int)] = []
                for r in 0..<model.rowCount {
                    // A multi-line cell is only as wide as its longest line.
                    let value = model.value(row: r, column: c)
                    let n = value.contains("\n")
                        ? (value.components(separatedBy: "\n").map(\.count).max() ?? 0)
                        : value.count
                    if n > 0 { candidates.append((r, n)) }
                }
                candidates.sort { $0.count > $1.count }
                var maxWidth = Metrics.minColWidth
                for (r, _) in candidates.prefix(24) {
                    let font = cellFont(forRow: r, column: c)
                    for line in model.value(row: r, column: c).components(separatedBy: "\n") {
                        let w = (line as NSString).size(withAttributes: [.font: font]).width
                        maxWidth = max(maxWidth, w + 14)
                    }
                }
                // Select cells clip their text short of the dropdown chevron.
                if let type = format.columnTypes[c], type == .select || type == .multiselect {
                    maxWidth += Metrics.chevronHitWidth
                }
                format.columnWidths[c] = min(maxWidth.rounded(.up), 800)
            }
        }
        modelDidChange()
    }

    // MARK: - Cross-file ID navigation

    /// Every open sheet, ordered the way the tab bar reads: this window's own
    /// tab group left to right, then any sheet living in another window (in
    /// whatever order the app has them). `NSDocumentController` hands them
    /// over in the sequence they were opened in, which is nobody's mental
    /// model of where a sheet is once the tabs have been dragged around.
    private func openSheetsInTabOrder() -> [TSVDocument] {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? TSVDocument }
        guard let tabs = window?.tabbedWindows, tabs.count > 1 else { return documents }

        var rank: [ObjectIdentifier: Int] = [:]
        for (index, tab) in tabs.enumerated() { rank[ObjectIdentifier(tab)] = index }
        return Self.orderedByTabPosition(documents) { document in
            // A document showing in more than one window sits where its
            // leftmost tab does.
            document.windowControllers
                .compactMap { $0.window.map(ObjectIdentifier.init).flatMap { rank[$0] } }
                .min()
        }
    }

    /// Orders items by tab position, leaving those with none — a sheet in some
    /// other window — in the order they arrived in, after the rest. Split out
    /// from the window lookup so the rule can be tested without windows.
    static func orderedByTabPosition<T>(_ items: [T], position: (T) -> Int?) -> [T] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, rank: position($0.element)) }
            .sorted { ($0.rank ?? Int.max, $0.offset) < ($1.rank ?? Int.max, $1.offset) }
            .map(\.item)
    }

    @objc private func jumpToDocument(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CrossFileTarget,
              let document = target.document else { return }
        document.showWindows()
        (document.windowControllers.first as? DocumentWindowController)?.reveal(row: target.row)
    }

    /// The focused cell — where a find starts searching from.
    var focusedCell: GridPos { focus }

    /// False over a cell the sheet fills in for you, which the formula bar
    /// shows read-only rather than inviting an edit that would be discarded.
    var focusedCellIsEditable: Bool { !isMirroredCell(focus) }

    /// Selects a single cell and scrolls it into view (find & replace lands
    /// matches here).
    func selectCellAndReveal(row: Int, column: Int) {
        guard row < gridRows else { return }
        expandToReveal(row: row)
        let pos = GridPos(row: row, col: min(column, gridCols - 1))
        anchor = pos
        focus = pos
        scrollCellToVisible(pos)
        selectionDidChange()
    }

    /// Selects a row (full width), scrolls it into view. Used when arriving
    /// from another sheet.
    func selectRowAndReveal(_ row: Int) {
        guard row < gridRows else { return }
        expandToReveal(row: row)
        anchor = GridPos(row: row, col: 0)
        focus = GridPos(row: row, col: gridCols - 1)
        scrollCellToVisible(GridPos(row: row, col: 0))
        selectionDidChange()
    }

    // MARK: - Spelling

    /// True for a cell that holds prose: a `text` column in a plain data row
    /// (headers and the field-name row ignore column types).
    private func isTextCell(_ pos: GridPos) -> Bool {
        guard let model, cachedTypes[pos.col] == .text else { return false }
        return model.headerLevel(ofRow: pos.row) == 0 && !model.isFieldNameRow(pos.row)
    }

    /// Where a cell's text is actually drawn, frozen panes included.
    private func textAreaScreenRect(_ pos: GridPos) -> NSRect {
        cellScreenRect(pos).insetBy(dx: 6, dy: 4)
    }

    /// The misspelled word under a click, if the click landed on one.
    private func misspelling(at p: NSPoint, in pos: GridPos) -> SpellingFix? {
        guard let model, isTextCell(pos),
              pos.row < model.rowCount, pos.col < model.columnCount else { return nil }
        let text = model.value(row: pos.row, column: pos.col)
        let misspellings = spellIndex.misspellings(in: text)
        guard !misspellings.isEmpty else { return nil }
        guard let index = textRenderer.characterIndex(
            in: text, font: cellFont(forRow: pos.row, column: pos.col),
            rect: textAreaScreenRect(pos), at: p) else { return nil }
        guard let range = misspellings.first(where: { NSLocationInRange(index, $0) }) else { return nil }
        return SpellingFix(pos: pos, range: range,
                           word: (text as NSString).substring(with: range),
                           replacement: nil)
    }

    /// Guesses + Learn / Ignore for the right-clicked misspelling, mirroring the
    /// spelling section of a text view's context menu.
    private func addSpellingItems(for hit: SpellingFix, to menu: NSMenu) {
        guard let model else { return }
        let text = model.value(row: hit.pos.row, column: hit.pos.col)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: hit.range, in: text, language: nil,
            inSpellDocumentWithTag: spellIndex.documentTag) ?? []

        if guesses.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for guess in guesses {
            let item = NSMenuItem(title: guess, action: #selector(correctSpelling(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingFix(pos: hit.pos, range: hit.range,
                                                 word: hit.word, replacement: guess)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("Ignore Spelling", #selector(ignoreSpelling(_:))),
                                ("Learn Spelling", #selector(learnSpelling(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = hit
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func correctSpelling(_ sender: NSMenuItem) {
        guard let fix = sender.representedObject as? SpellingFix,
              let replacement = fix.replacement, let model else { return }
        let text = model.value(row: fix.pos.row, column: fix.pos.col) as NSString
        // The cell may have been edited between the right-click and the pick.
        guard fix.range.upperBound <= text.length,
              text.substring(with: fix.range) == fix.word else { return }
        model.setValue(text.replacingCharacters(in: fix.range, with: replacement),
                       row: fix.pos.row, column: fix.pos.col)
        needsDisplay = true
    }

    @objc private func ignoreSpelling(_ sender: NSMenuItem) {
        guard let fix = sender.representedObject as? SpellingFix else { return }
        NSSpellChecker.shared.ignoreWord(fix.word, inSpellDocumentWithTag: spellIndex.documentTag)
        spellIndex.invalidateAll()
    }

    @objc private func learnSpelling(_ sender: NSMenuItem) {
        guard let fix = sender.representedObject as? SpellingFix else { return }
        NSSpellChecker.shared.learnWord(fix.word)
        spellIndex.invalidateAll()
    }

    // MARK: - Context menu & validation

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        var contextRow: Int?
        var spellingHit: SpellingFix?
        switch hitArea(at: p) {
        case .cell(let pos):
            if !(selectedRows.contains(pos.row) && selectedCols.contains(pos.col)) {
                anchor = pos
                focus = pos
                selectionDidChange()
            }
            contextRow = pos.row
            spellingHit = misspelling(at: p, in: pos)
        case .rowHeader(let r), .sectionToggle(let r):
            if !(isFullRowSelection && selectedRows.contains(r)) {
                selectRow(r, extend: false)
            }
            contextRow = r
        case .columnHeader(let c, _):
            if !(isFullColumnSelection && selectedCols.contains(c)) {
                selectColumn(c, extend: false)
            }
        case .hiddenColumnsMarker(let run):
            // Right-clicking the marker selects the gap, so the menu's show
            // items act on exactly the run that was clicked.
            anchor = GridPos(row: 0, col: run.lowerBound)
            focus = GridPos(row: gridRows - 1, col: run.upperBound)
            selectionDidChange()
        case .corner:
            return nil
        }

        let menu = NSMenu()

        // Spelling first, where the click was on a misspelled word — that's
        // where a text view puts it, and it's what the click was aimed at.
        if let spellingHit {
            addSpellingItems(for: spellingHit, to: menu)
        }

        // "Go to <ID> in <other sheet>" — same ID in other open files.
        if let model, let row = contextRow, row < model.rowCount {
            let id = model.value(row: row, column: 0)
            if !id.isEmpty, !id.hasPrefix("#"), !model.isFieldNameRow(row) {
                let submenu = NSMenu()
                for document in openSheetsInTabOrder() where document.model !== model {
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

        // Section folding — only where there's a section to fold.
        if let header = focusedSectionHeader, let model {
            let name = model.value(row: header, column: 0)
            let shown = name.count > 30 ? name.prefix(30) + "…" : name
            let collapsed = collapsedRows.contains(header)
            let item = NSMenuItem(
                title: collapsed ? "Expand “\(shown)”" : "Collapse “\(shown)”",
                action: collapsed ? #selector(expandSection(_:)) : #selector(collapseSection(_:)),
                keyEquivalent: "")
            menu.addItem(item)
            menu.addItem(withTitle: "Collapse All Sections",
                         action: #selector(collapseAllSections(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Expand All Sections",
                         action: #selector(expandAllSections(_:)), keyEquivalent: "")
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")

        // Arithmetic over the selection — offered only where there's a number
        // in it to change, since it would do nothing at all otherwise.
        let numericCells = adjustableNumericCells
        if !numericCells.isEmpty {
            menu.addItem(.separator())
            let adjustMenu = NSMenu()
            for operation in CellArithmetic.Operation.allCases {
                let item = NSMenuItem(title: operation.menuTitle,
                                      action: #selector(adjustSelectedValues(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = operation.rawValue
                adjustMenu.addItem(item)
            }
            let adjustItem = NSMenuItem(
                title: numericCells.count == 1 ? "Adjust Value" : "Adjust \(numericCells.count) Values",
                action: nil, keyEquivalent: "")
            adjustItem.submenu = adjustMenu
            menu.addItem(adjustItem)
        }

        // Selecting whole columns is a statement about columns: row commands
        // there would act on the entire sheet, so they don't belong in the
        // menu at all (and vice versa).
        if !isFullColumnSelection {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Insert Row Above", action: #selector(insertRowAbove(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Insert Row Below", action: #selector(insertRowBelow(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Delete Rows", action: #selector(deleteSelectedRows(_:)), keyEquivalent: "")
        }
        if !isFullRowSelection {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Insert Column Left", action: #selector(insertColumnLeft(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Insert Column Right", action: #selector(insertColumnRight(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Delete Columns", action: #selector(deleteSelectedColumns(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Hide Columns", action: #selector(hideSelectedColumns(_:)), keyEquivalent: "")
            // Only offered where there's something to bring back: over a gap
            // the selection reaches, or anywhere at all once one exists.
            if !hiddenColumnsInSelection.isEmpty {
                menu.addItem(withTitle: "Show Hidden Columns",
                             action: #selector(showHiddenColumns(_:)), keyEquivalent: "")
            }
            if !hiddenColumns.isEmpty {
                menu.addItem(withTitle: "Show All Hidden Columns",
                             action: #selector(showAllHiddenColumns(_:)), keyEquivalent: "")
            }
        }

        // Column formatting — hidden for whole-row selections, where "the
        // selected columns" would mean every column in the sheet.
        if !isFullRowSelection, let model {
            menu.addItem(.separator())

            let typeMenu = NSMenu()
            let selectedTypes = Set(selectedCols
                .filter { $0 < model.columnCount }
                .map { cachedTypes[$0] ?? .raw })
            for (title, type) in [("Raw", ColumnType.raw), ("Integer", .integer),
                                  ("Float", .float), ("Text", .text), ("Boolean", .boolean)] {
                let item = NSMenuItem(title: title, action: #selector(setColumnType(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = type.rawValue
                if selectedTypes == [type] { item.state = .on }
                else if selectedTypes.contains(type) { item.state = .mixed }
                typeMenu.addItem(item)
            }
            // Select types need an options source, so they run through a
            // configuration dialog (re-picking one edits its source).
            typeMenu.addItem(.separator())
            for (title, type) in [("Select…", ColumnType.select),
                                  ("Multi-Select…", .multiselect)] {
                let item = NSMenuItem(title: title, action: #selector(configureSelectColumns(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = type.rawValue
                if selectedTypes == [type] { item.state = .on }
                else if selectedTypes.contains(type) { item.state = .mixed }
                typeMenu.addItem(item)
            }
            // Likewise Source, which names a sheet and one of its fields.
            let sourceItem = NSMenuItem(title: "Source…",
                                        action: #selector(configureSourceColumns(_:)),
                                        keyEquivalent: "")
            sourceItem.target = self
            if selectedTypes == [.source] { sourceItem.state = .on }
            else if selectedTypes.contains(.source) { sourceItem.state = .mixed }
            typeMenu.addItem(sourceItem)

            let plural = selectedCols.count > 1
            let typeItem = NSMenuItem(title: plural ? "Column Data Types" : "Column Data Type",
                                      action: nil, keyEquivalent: "")
            typeItem.submenu = typeMenu
            menu.addItem(typeItem)

            if !flaggableSelectedColumns.isEmpty {
                menu.addItem(withTitle: "Flag Duplicates",
                             action: #selector(toggleFlagDuplicates(_:)), keyEquivalent: "")
            }

            menu.addItem(.separator())

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
        case #selector(setSheetAccent(_:)):
            let format = formatProvider?() ?? TSSFormat()
            menuItem.state = Self.accent(of: menuItem) == format.accent ? .on : .off
            return true
        // Insert titles count what they'll actually do, in both menus. Row
        // commands stay out of the way of a whole-column selection (where they
        // would act on the entire sheet), and vice versa — the context menu
        // drops them outright, the Sheet menu greys them out.
        case #selector(insertRowAbove(_:)):
            menuItem.title = insertRowCount == 1
                ? "Insert Row Above" : "Insert \(insertRowCount) Rows Above"
            return !isFullColumnSelection
        case #selector(insertRowBelow(_:)):
            menuItem.title = insertRowCount == 1
                ? "Insert Row Below" : "Insert \(insertRowCount) Rows Below"
            return !isFullColumnSelection
        case #selector(insertColumnLeft(_:)):
            menuItem.title = insertColumnCount == 1
                ? "Insert Column Left" : "Insert \(insertColumnCount) Columns Left"
            return !isFullRowSelection
        case #selector(insertColumnRight(_:)):
            menuItem.title = insertColumnCount == 1
                ? "Insert Column Right" : "Insert \(insertColumnCount) Columns Right"
            return !isFullRowSelection
        case #selector(deleteSelectedColumns(_:)):
            guard let model, !isFullRowSelection else { return false }
            return selectedCols.contains(where: { $0 >= 1 && $0 < model.columnCount })
        case #selector(hideSelectedColumns(_:)):
            let count = hideableSelectedColumns.count
            menuItem.title = count == 1 ? "Hide Column" : "Hide \(count) Columns"
            return !isFullRowSelection && count > 0
        case #selector(showHiddenColumns(_:)):
            let count = hiddenColumnsInSelection.count
            menuItem.title = count == 1 ? "Show Hidden Column" : "Show \(count) Hidden Columns"
            return !isFullRowSelection && count > 0
        case #selector(showAllHiddenColumns(_:)):
            return !hiddenColumns.isEmpty
        case #selector(toggleFlagDuplicates(_:)):
            let columns = flaggableSelectedColumns
            let flagged = columns.filter { duplicateFlagColumns.contains($0) }
            menuItem.state = flagged.isEmpty ? .off
                : (flagged.count == columns.count ? .on : .mixed)
            return !isFullRowSelection && !columns.isEmpty
        case #selector(deleteSelectedRows(_:)):
            guard let model, !isFullColumnSelection else { return false }
            return selectedRows.lowerBound < model.rowCount && model.rowCount > 1
        case #selector(jumpToNextDuplicateID(_:)):
            return !(model?.duplicateIDRows.isEmpty ?? true)
        case #selector(collapseSection(_:)):
            guard let header = focusedSectionHeader else { return false }
            return !collapsedRows.contains(header)
        case #selector(expandSection(_:)):
            guard let header = focusedSectionHeader else { return false }
            return collapsedRows.contains(header)
        case #selector(collapseAllSections(_:)):
            guard let model else { return false }
            return model.sectionHeaderRows().contains { !collapsedRows.contains($0) }
        case #selector(expandAllSections(_:)):
            return !collapsedRows.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }
}

/// Payload for a select dropdown's menu items. A nil option is the
/// single-select "None" (clear the cell).
private final class SelectPick: NSObject {
    let pos: GridPos
    let option: String?
    let multi: Bool

    init(pos: GridPos, option: String?, multi: Bool) {
        self.pos = pos
        self.option = option
        self.multi = multi
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
