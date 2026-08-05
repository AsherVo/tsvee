import Foundation

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

        var parsed = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        if parsed.isEmpty { parsed = [[""]] }

        let width = max(parsed.map(\.count).max() ?? 1, 1)
        for i in parsed.indices where parsed[i].count < width {
            parsed[i].append(contentsOf: Array(repeating: "", count: width - parsed[i].count))
        }
        rows = parsed
        columnCount = width
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
            .map { $0[0...lastCol].joined(separator: "\t") }
            .joined(separator: "\n") + "\n"
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
        undoManager?.registerUndo(withTarget: self) { model in
            model.setValue(old, row: row, column: column)
        }
        undoManager?.setActionName("Edit Cell")
        recomputeDuplicates()
        onChange?()
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

    // MARK: - Unique-ID enforcement

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
