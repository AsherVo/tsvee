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

    /// Header level of a row: 0 = plain data, 1–3 = "#"/"##"/"###" headers.
    func headerLevel(ofRow row: Int) -> Int {
        guard row < rows.count else { return 0 }
        let id = rows[row][0]
        guard id.hasPrefix("#") else { return 0 }
        let hashes = id.prefix(while: { $0 == "#" }).count
        return min(hashes, 3)
    }

    func isFieldNameRow(_ row: Int) -> Bool { row == 0 && hasFieldNameRow }

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

    func insertRow(at index: Int) {
        let clamped = min(max(index, 0), rows.count)
        rows.insert(Array(repeating: "", count: columnCount), at: clamped)
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeRows(IndexSet(integer: clamped))
        }
        undoManager?.setActionName("Insert Row")
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

    func insertColumn(at index: Int) {
        let clamped = min(max(index, 1), columnCount)  // never before the ID column
        columnCount += 1
        for i in rows.indices { rows[i].insert("", at: clamped) }
        undoManager?.registerUndo(withTarget: self) { model in
            model.removeColumns(IndexSet(integer: clamped))
        }
        undoManager?.setActionName("Insert Column")
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
