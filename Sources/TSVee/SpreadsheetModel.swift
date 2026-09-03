import Foundation

/// How a find (or replace) query matches cell content.
struct FindOptions: Equatable {
    var caseSensitive = false
    /// Match only cells whose entire content equals the query, instead of
    /// any cell containing it.
    var wholeCell = false
    /// Restrict matching to one column — nil searches every column. A column
    /// scope also spares that column's field-name cell, since the name is a
    /// label for the search, not something to search in.
    var column: Int?
}

/// The raw TSV data: a rectangular grid of strings.
///
/// Rules enforced/understood by the model:
///  - Column 0 is always the ID column.
///  - IDs must be unique per row. Violations are surfaced via `duplicateIDRows`
///    (the UI flags them; edits are never blocked).
///  - An ID beginning with "#" marks the row as a section header:
///    "#" = level 1, "##" = level 2, "###" (or more) = level 3.
///    Header rows are exempt from the uniqueness rule.
///  - If the very first row's ID cell is exactly "ID", that row is treated as
///    the field-name row (styled bold, exempt from uniqueness).
///  - A line break inside a cell is stored as the two characters `\n`, since a
///    file line is a row. See `decodeCell` / `encodeCell`.
final class SpreadsheetModel {

    private(set) var rows: [[String]] = [["ID"]]
    private(set) var columnCount: Int = 1

    /// Rows whose ID collides with another row's ID.
    private(set) var duplicateIDRows: Set<Int> = []

    /// Set by the document so all mutations are undoable.
    weak var undoManager: UndoManager?

    /// Fired after any mutation (including undo/redo).
    var onChange: (() -> Void)?

    var rowCount: Int { rows.count }

    /// True when row 0 is the field-name row ("ID" in the first cell).
    var hasFieldNameRow: Bool { rows.first?.first == "ID" }

    // MARK: - Reading / writing TSV

    func load(tsv: String) {
        // Normalize CRLF/CR first — a trailing "\r\n" is a single Character
        // in Swift, which makes suffix trimming on the raw string treacherous.
        var text = tsv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }

        var parsed = text.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "\t").map(Self.decodeCell) }
        if parsed.isEmpty { parsed = [[""]] }

        let width = max(parsed.map(\.count).max() ?? 1, 1)
        for i in parsed.indices where parsed[i].count < width {
            parsed[i].append(contentsOf: Array(repeating: "", count: width - parsed[i].count))
        }
        rows = parsed
        columnCount = width
        recomputeLineBreakColumns()
        recomputeDuplicates()
        onChange?()
    }

    /// Serialized TSV. Trailing all-empty rows and columns are trimmed so
    /// scratch space in the editor never pollutes the file.
    func tsvString() -> String {
        var lastRow = rows.count - 1
        while lastRow > 0 && rows[lastRow].allSatisfy(\.isEmpty) { lastRow -= 1 }

        var lastCol = columnCount - 1
        while lastCol > 0 && rows[0...lastRow].allSatisfy({ $0[lastCol].isEmpty }) { lastCol -= 1 }

        return rows[0...lastRow]
            .map { $0[0...lastCol].map(Self.encodeCell).joined(separator: "\t") }
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Line breaks inside a cell

    /// A file line is a row, so a line break inside a cell travels as the two
    /// characters `\n`. Backslashes are otherwise left exactly as they were
    /// written — nothing else in the file is rewritten on save, which is worth
    /// more than being able to store a cell whose text is literally `\n`
    /// (that one reads back as a line break).
    static func decodeCell(_ cell: String) -> String {
        cell.contains("\\n") ? cell.replacingOccurrences(of: "\\n", with: "\n") : cell
    }

    static func encodeCell(_ cell: String) -> String {
        cell.contains("\n") ? cell.replacingOccurrences(of: "\n", with: "\\n") : cell
    }

    /// Columns that hold (or held, this session) a cell with a line break — the
    /// only ones whose rows can need more than one line of height. A superset
    /// is harmless: the row-height pass still checks each cell for a break, so
    /// a stale entry costs a string scan and nothing else.
    private(set) var columnsWithLineBreaks: Set<Int> = []

    private func recomputeLineBreakColumns() {
        var columns: Set<Int> = []
        for row in rows {
            for (column, value) in row.enumerated() where value.contains("\n") {
                columns.insert(column)
            }
        }
        columnsWithLineBreaks = columns
    }

    // MARK: - Cell access

    func value(row: Int, column: Int) -> String {
        guard row < rows.count, column < columnCount else { return "" }
        return rows[row][column]
    }

    /// Populated / empty tally over a rectangle of cells, for the selection
    /// readout in the formula bar.
    ///
    /// Only real entries count: a row has to have an ID to be one, so `#`
    /// header and comment rows, the field-name row (selecting a whole column
    /// shouldn't count the column name), ID-less rows, and everything past the
    /// end of the data are all skipped. A column in `booleanColumns` holds
    /// checkboxes, where only a checked box counts as populated — FALSE is an
    /// answer, but it isn't content.
    func tally(rows rowRange: ClosedRange<Int>, columns columnRange: ClosedRange<Int>,
               booleanColumns: Set<Int>) -> (populated: Int, empty: Int) {
        var populated = 0, empty = 0
        for row in rowRange where row < rowCount {
            guard headerLevel(ofRow: row) == 0, !isFieldNameRow(row),
                  !rows[row][0].isEmpty else { continue }
            for column in columnRange where column < columnCount {
                let value = rows[row][column]
                let counts = booleanColumns.contains(column)
                    ? BooleanCell(value) == .on
                    : !value.isEmpty
                if counts { populated += 1 } else { empty += 1 }
            }
        }
        return (populated, empty)
    }

    /// Header level of a row: 0 = plain data, 1–3 = "#"/"##"/"###" headers.
    func headerLevel(ofRow row: Int) -> Int {
        guard row < rows.count else { return 0 }
        let id = rows[row][0]
        guard id.hasPrefix("#") else { return 0 }
        let hashes = id.prefix(while: { $0 == "#" }).count
        return min(hashes, 3)
    }

    func isFieldNameRow(_ row: Int) -> Bool { row == 0 && hasFieldNameRow }

    // MARK: - Sections

    /// Header levels that open a collapsible section. "###" (or more) is a
    /// comment row, not a section: it neither collapses nor closes the section
    /// it sits in.
    static let sectionHeaderLevels = 1...2

    /// The rows belonging to the section a header row opens: everything below
    /// it up to (but not including) the next header of the same or higher
    /// level — so a "#" section swallows its "##" subsections, and a "##"
    /// section ends at the next "##" or "#". "###" comment rows are carried
    /// along as ordinary content.
    ///
    /// nil when the row doesn't open a section, or opens nothing (the next row
    /// is already a sibling/parent header, or the header is the last row).
    func sectionBody(ofRow row: Int) -> ClosedRange<Int>? {
        let level = headerLevel(ofRow: row)
        guard Self.sectionHeaderLevels.contains(level) else { return nil }
        var end = row
        var next = row + 1
        while next < rows.count {
            let nextLevel = headerLevel(ofRow: next)
            if nextLevel > 0 && nextLevel <= level { break }
            end = next
            next += 1
        }
        return end > row ? (row + 1)...end : nil
    }

    /// The innermost section header that owns a row — the row itself when it
    /// opens a section, otherwise the nearest one above it. "###" comment rows
    /// are skipped over, since they don't open sections.
    func enclosingSectionHeader(ofRow row: Int) -> Int? {
        guard row < rows.count else { return nil }
        for candidate in stride(from: min(row, rows.count - 1), through: 0, by: -1)
        where Self.sectionHeaderLevels.contains(headerLevel(ofRow: candidate)) {
            // The nearest section header above always owns the row: nothing
            // between them can have closed the section.
            return sectionBody(ofRow: candidate) != nil ? candidate : nil
        }
        return nil
    }

    /// Every row that opens a non-empty section, in order.
    func sectionHeaderRows() -> [Int] {
        (0..<rows.count).filter { sectionBody(ofRow: $0) != nil }
    }

    /// The ID of every entry, in sheet order, deduplicated — what a select
    /// column pointed at this sheet offers as its options. Headers, comments,
    /// the field-name row and ID-less rows aren't entries.
    func entryIDs() -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for (index, row) in rows.enumerated() {
            let id = row[0]
            guard !id.isEmpty, !id.hasPrefix("#"), !isFieldNameRow(index),
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// How many of the given rows are entries — the same rule the tally and
    /// `entryIDs` use: a row needs an ID to be one, so `#` headers and
    /// comments, the field-name row, and blank rows don't count. (Duplicates
    /// do: two rows are two entries even when they collide.)
    func entryCount(in rowRange: ClosedRange<Int>) -> Int {
        rowRange.filter { row in
            row < rowCount && headerLevel(ofRow: row) == 0
                && !isFieldNameRow(row) && !rows[row][0].isEmpty
        }.count
    }

    /// First row whose ID matches exactly (used for cross-file navigation).
    /// The field-name row doesn't count.
    func firstRow(withID id: String) -> Int? {
        for (index, row) in rows.enumerated() where row[0] == id {
            if isFieldNameRow(index) { continue }
            return index
        }
        return nil
    }

    // MARK: - Mutations (all undoable)

    func setValue(_ newValue: String, row: Int, column: Int) {
        ensureSize(rows: row + 1, columns: column + 1)
        let old = rows[row][column]
        guard old != newValue else { return }
        rows[row][column] = newValue
        if newValue.contains("\n") { columnsWithLineBreaks.insert(column) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.setValue(old, row: row, column: column)
        }
        undoManager?.setActionName("Edit Cell")
        recomputeDuplicates()
        onChange?()
    }

    /// Writes computed values into one column, without touching the undo
    /// stack: a `source` column mirrors another sheet, so there is no earlier
    /// state of it worth stepping back to — and an undo that put stale values
    /// back would only be overwritten by the next refresh anyway. Returns
    /// whether anything actually changed, so a sheet only goes dirty when the
    /// mirror moved.
    ///
    /// Rows outside the grid, and columns past its width, are ignored: this
    /// fills a column in, it doesn't grow the sheet to make room for one.
    @discardableResult
    func applyDerivedValues(_ values: [Int: String], column: Int) -> Bool {
        guard column >= 0, column < columnCount else { return false }
        var changed = false
        for (row, value) in values where row >= 0 && row < rows.count {
            guard rows[row][column] != value else { continue }
            rows[row][column] = value
            if value.contains("\n") { columnsWithLineBreaks.insert(column) }
            changed = true
        }
        guard changed else { return false }
        onChange?()
        return true
    }

    /// Writes `FALSE` into the empty cells of `boolean` columns, so the file
    /// says what the sheet already shows — an empty cell there draws as an
    /// unchecked box, and saving is when that reading becomes the data.
    ///
    /// Only rows that can own a value are filled: plain data rows with an ID,
    /// never headers, the field-name row, or the ID-less lines between
    /// sections. Cells holding anything other than TRUE/FALSE are left alone —
    /// that's data the column type doesn't describe, and TSVee flags it rather
    /// than rewriting it. One undo step; returns whether anything changed.
    @discardableResult
    func fillEmptyBooleanCells(inColumns columns: Set<Int>) -> Bool {
        var changes: [(row: Int, column: Int, value: String)] = []
        for row in rows.indices {
            guard headerLevel(ofRow: row) == 0, !isFieldNameRow(row),
                  !rows[row][0].isEmpty else { continue }
            for column in columns.sorted()
            where column >= 0 && column < columnCount && rows[row][column].isEmpty {
                changes.append((row, column, BooleanCell.literal(false)))
            }
        }
        guard !changes.isEmpty else { return false }
        setCells(changes)
        undoManager?.setActionName(columns.count == 1 ? "Fill Boolean Column"
                                                      : "Fill Boolean Columns")
        return true
    }

    /// Grows the grid to contain the given size (used when editing the
    /// phantom cells past the end of the data). Undoable.
    func ensureSize(rows neededRows: Int, columns neededColumns: Int) {
        let oldRows = rows.count
        let oldCols = columnCount
        guard neededRows > oldRows || neededColumns > oldCols else { return }

        if neededColumns > oldCols {
            columnCount = neededColumns
            for i in rows.indices {
                rows[i].append(contentsOf: Array(repeating: "", count: neededColumns - rows[i].count))
            }
        }
        if neededRows > oldRows {
            rows.append(contentsOf: Array(
                repeating: Array(repeating: "", count: columnCount),
                count: neededRows - oldRows))
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.shrink(toRows: oldRows, columns: oldCols)
        }
        onChange?()
    }

    private func shrink(toRows rowTarget: Int, columns colTarget: Int) {
        let oldRows = rows.count
        let oldCols = columnCount
        if rows.count > rowTarget { rows.removeLast(rows.count - rowTarget) }
        if columnCount > colTarget {
            columnCount = colTarget
            for i in rows.indices { rows[i].removeLast(rows[i].count - colTarget) }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.ensureSize(rows: oldRows, columns: oldCols)
        }
        recomputeDuplicates()
        onChange?()
    }

    /// Inserts `count` blank rows — one insert, one undo step, however many
    /// rows the selection asked for.
    func insertRow(at index: Int, count: Int = 1) {
        guard count > 0 else { return }
        let clamped = min(max(index, 0), rows.count)
        let blank = Array(repeating: "", count: columnCount)
        rows.insert(contentsOf: Array(repeating: blank, count: count), at: clamped)
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeRows(IndexSet(integersIn: clamped..<(clamped + count)))
        }
        undoManager?.setActionName(count == 1 ? "Insert Row" : "Insert Rows")
        recomputeDuplicates()
        onChange?()
    }

    func removeRows(_ indexes: IndexSet) {
        let valid = IndexSet(indexes.filter { $0 < rows.count })
        guard !valid.isEmpty, valid.count < rows.count else { return }
        let removed = valid.map { (index: $0, content: rows[$0]) }
        for index in valid.reversed() { rows.remove(at: index) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreRows(removed)
        }
        undoManager?.setActionName("Delete Row")
        recomputeDuplicates()
        onChange?()
    }

    private func restoreRows(_ removed: [(index: Int, content: [String])]) {
        for item in removed { rows.insert(item.content, at: min(item.index, rows.count)) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeRows(IndexSet(removed.map(\.index)))
        }
        recomputeDuplicates()
        onChange?()
    }

    func insertColumn(at index: Int, count: Int = 1) {
        guard count > 0 else { return }
        let clamped = min(max(index, 1), columnCount)  // never before the ID column
        columnCount += count
        for i in rows.indices {
            rows[i].insert(contentsOf: Array(repeating: "", count: count), at: clamped)
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeColumns(IndexSet(integersIn: clamped..<(clamped + count)))
        }
        undoManager?.setActionName(count == 1 ? "Insert Column" : "Insert Columns")
        onChange?()
    }

    func removeColumns(_ indexes: IndexSet) {
        let valid = IndexSet(indexes.filter { $0 >= 1 && $0 < columnCount })  // ID column is always kept
        guard !valid.isEmpty else { return }
        var removed: [(index: Int, content: [String])] = []
        for index in valid { removed.append((index, rows.map { $0[index] })) }
        for index in valid.reversed() {
            columnCount -= 1
            for i in rows.indices { rows[i].remove(at: index) }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreColumns(removed)
        }
        undoManager?.setActionName("Delete Column")
        onChange?()
    }

    private func restoreColumns(_ removed: [(index: Int, content: [String])]) {
        for item in removed {
            let at = min(item.index, columnCount)
            columnCount += 1
            for i in rows.indices { rows[i].insert(item.content[i], at: at) }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeColumns(IndexSet(removed.map(\.index)))
        }
        onChange?()
    }

    // MARK: - Reordering

    /// Moves a contiguous block of rows so it starts at the given insertion
    /// boundary (expressed in pre-move indices, outside the block).
    func moveRows(_ range: ClosedRange<Int>, to destination: Int) {
        guard range.lowerBound >= 0, range.upperBound < rows.count,
              destination >= 0, destination <= rows.count,
              destination < range.lowerBound || destination > range.upperBound + 1 else { return }
        let block = Array(rows[range])
        rows.removeSubrange(range)
        let adjusted = destination > range.upperBound ? destination - block.count : destination
        rows.insert(contentsOf: block, at: adjusted)

        let newRange = adjusted...(adjusted + block.count - 1)
        let inverseDestination = destination > range.upperBound ? range.lowerBound : range.upperBound + 1
        undoManager?.registerUndo(withTarget: self) { model in
            model.moveRows(newRange, to: inverseDestination)
        }
        undoManager?.setActionName("Move Rows")
        recomputeDuplicates()
        onChange?()
    }

    /// Moves a contiguous block of columns. The ID column (0) can neither
    /// move nor be displaced.
    func moveColumns(_ range: ClosedRange<Int>, to destination: Int) {
        guard range.lowerBound >= 1, range.upperBound < columnCount,
              destination >= 1, destination <= columnCount,
              destination < range.lowerBound || destination > range.upperBound + 1 else { return }
        let adjusted = destination > range.upperBound ? destination - range.count : destination
        for i in rows.indices {
            let block = Array(rows[i][range])
            rows[i].removeSubrange(range)
            rows[i].insert(contentsOf: block, at: adjusted)
        }

        let newRange = adjusted...(adjusted + range.count - 1)
        let inverseDestination = destination > range.upperBound ? range.lowerBound : range.upperBound + 1
        undoManager?.registerUndo(withTarget: self) { model in
            model.moveColumns(newRange, to: inverseDestination)
        }
        undoManager?.setActionName("Move Columns")
        onChange?()
    }

    /// old index → new index for every index a move displaces. Used to keep
    /// per-index formatting (.tss widths/heights) attached to its content.
    static func moveMapping(range: ClosedRange<Int>, to destination: Int) -> [Int: Int] {
        var mapping: [Int: Int] = [:]
        let count = range.count
        if destination > range.upperBound + 1 {
            for i in range { mapping[i] = i + (destination - range.upperBound - 1) }
            for i in (range.upperBound + 1)..<destination { mapping[i] = i - count }
        } else if destination < range.lowerBound {
            for i in range { mapping[i] = i - (range.lowerBound - destination) }
            for i in destination..<range.lowerBound { mapping[i] = i + count }
        }
        return mapping
    }

    /// Where per-row or per-column `.tss` state (a height, a width, a data
    /// type, a collapsed section) lands after `count` rows/columns are
    /// inserted at `insertion`. The arithmetic is the same on both axes.
    static func shiftedIndex(_ index: Int, afterInsertAt insertion: Int, count: Int = 1) -> Int {
        index >= insertion ? index + count : index
    }

    /// Where that state lands after `removed` rows/columns are deleted — nil
    /// when the one it was attached to is among them.
    static func shiftedIndex(_ index: Int, afterRemoving removed: IndexSet) -> Int? {
        guard !removed.contains(index) else { return nil }
        return index - removed.count(in: 0..<index)
    }

    // MARK: - Find & replace

    static func value(_ value: String, matches query: String, options: FindOptions) -> Bool {
        guard !query.isEmpty else { return false }
        let compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        if options.wholeCell {
            return value.compare(query, options: compareOptions) == .orderedSame
        }
        return value.range(of: query, options: compareOptions) != nil
    }

    /// The cell's content with every match replaced — nil when it doesn't
    /// match at all, so callers can tell "replaced" from "left alone".
    static func replacing(_ value: String, query: String, with replacement: String,
                          options: FindOptions) -> String? {
        guard Self.value(value, matches: query, options: options) else { return nil }
        if options.wholeCell { return replacement }
        let compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        return value.replacingOccurrences(of: query, with: replacement, options: compareOptions)
    }

    /// The cells the options let a search touch: the whole grid, or — when the
    /// options name a column — that column without its field-name cell.
    private func searchArea(_ options: FindOptions) -> (rows: Range<Int>, columns: Range<Int>) {
        guard let column = options.column else { return (rows.indices, 0..<columnCount) }
        guard column >= 0, column < columnCount else { return (0..<0, 0..<0) }
        let firstRow = hasFieldNameRow ? 1 : 0
        return (min(firstRow, rowCount)..<rowCount, column..<(column + 1))
    }

    /// Every matching cell, in reading order (row-major).
    func findMatches(_ query: String, options: FindOptions) -> [(row: Int, column: Int)] {
        guard !query.isEmpty else { return [] }
        let area = searchArea(options)
        var matches: [(row: Int, column: Int)] = []
        for r in area.rows {
            for c in area.columns where Self.value(rows[r][c], matches: query, options: options) {
                matches.append((r, c))
            }
        }
        return matches
    }

    /// Replaces every match the options reach as a single undo step. Returns
    /// the number of cells that changed.
    @discardableResult
    func replaceAll(_ query: String, with replacement: String, options: FindOptions) -> Int {
        let area = searchArea(options)
        var changes: [(row: Int, column: Int, value: String)] = []
        for r in area.rows {
            for c in area.columns {
                if let updated = Self.replacing(rows[r][c], query: query, with: replacement,
                                                options: options),
                   updated != rows[r][c] {
                    changes.append((r, c, updated))
                }
            }
        }
        guard !changes.isEmpty else { return 0 }
        setCells(changes)
        undoManager?.setActionName("Replace All")
        return changes.count
    }

    /// Batch cell write: one undo step no matter how many cells change.
    private func setCells(_ changes: [(row: Int, column: Int, value: String)]) {
        let old = changes.map { (row: $0.row, column: $0.column, value: rows[$0.row][$0.column]) }
        for change in changes { rows[change.row][change.column] = change.value }
        undoManager?.registerUndo(withTarget: self) { model in
            model.setCells(old)
        }
        recomputeDuplicates()
        onChange?()
    }

    // MARK: - Unique-ID enforcement

    /// Rows whose value in the given column collides with another row's — what
    /// a column with the "Flag Duplicates" option turns red. The ID column's
    /// rule, one column over: only entries are compared (`#` header and
    /// comment rows, the field-name row and ID-less rows are exempt), and an
    /// empty cell is never a collision. For column 0 this is `duplicateIDRows`.
    func duplicateRows(inColumn column: Int) -> Set<Int> {
        guard column >= 0, column < columnCount else { return [] }
        var firstSeen: [String: Int] = [:]
        var duplicates: Set<Int> = []
        for (index, row) in rows.enumerated() {
            guard headerLevel(ofRow: index) == 0, !isFieldNameRow(index),
                  !row[0].isEmpty else { continue }
            let value = row[column]
            if value.isEmpty { continue }
            if let earlier = firstSeen[value] {
                duplicates.insert(earlier)
                duplicates.insert(index)
            } else {
                firstSeen[value] = index
            }
        }
        return duplicates
    }

    private func recomputeDuplicates() {
        var firstSeen: [String: Int] = [:]
        var duplicates: Set<Int> = []
        for (index, row) in rows.enumerated() {
            let id = row[0]
            if id.isEmpty || id.hasPrefix("#") || isFieldNameRow(index) { continue }
            if let earlier = firstSeen[id] {
                duplicates.insert(earlier)
                duplicates.insert(index)
            } else {
                firstSeen[id] = index
            }
        }
        duplicateIDRows = duplicates
    }
}
