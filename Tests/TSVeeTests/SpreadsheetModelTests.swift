import XCTest
@testable import TSVee

final class SpreadsheetModelTests: XCTestCase {

    private func makeModel(_ tsv: String) -> SpreadsheetModel {
        let model = SpreadsheetModel()
        model.load(tsv: tsv)
        return model
    }

    // MARK: - Parsing

    func testLoadPadsRaggedRows() {
        let model = makeModel("ID\tName\tHP\na\tAlpha\nb")
        XCTAssertEqual(model.columnCount, 3)
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.value(row: 1, column: 2), "")
        XCTAssertEqual(model.value(row: 2, column: 1), "")
    }

    func testLoadHandlesCRLFAndTrailingNewline() {
        let model = makeModel("ID\tName\r\na\tAlpha\r\n")
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.value(row: 1, column: 0), "a")
        XCTAssertEqual(model.value(row: 1, column: 1), "Alpha")
    }

    func testRoundTrip() {
        let text = "ID\tName\ta1\tAlpha\n#Header\t\t\t\nb2\tBeta\tx\ty\n"
        let model = makeModel(text)
        XCTAssertEqual(model.tsvString(), text)
    }

    func testSaveTrimsTrailingEmptyRowsAndColumns() {
        let model = makeModel("ID\tName\na\tAlpha")
        model.ensureSize(rows: 10, columns: 8)   // simulate scratch-space edits
        XCTAssertEqual(model.tsvString(), "ID\tName\na\tAlpha\n")
    }

    // MARK: - Unique IDs

    func testDuplicateIDDetection() {
        let model = makeModel("ID\tName\na\tAlpha\nb\tBeta\na\tAgain")
        XCTAssertEqual(model.duplicateIDRows, [1, 3])
    }

    func testFieldNameRowAndHeadersAndEmptyIDsAreExempt() {
        let model = makeModel("ID\tName\n# Section\t\n# Section\t\n\tno id\n\talso no id\nID\tliteral-in-data")
        // Two identical "# Section" headers, two empty IDs: allowed.
        // "ID" in row 5 vs field-name row 0: row 0 is exempt, so no pair.
        XCTAssertTrue(model.duplicateIDRows.isEmpty)
    }

    func testDuplicatesUpdateOnEdit() {
        let model = makeModel("ID\tName\na\tAlpha\nb\tBeta")
        model.setValue("a", row: 2, column: 0)
        XCTAssertEqual(model.duplicateIDRows, [1, 2])
        model.setValue("c", row: 2, column: 0)
        XCTAssertTrue(model.duplicateIDRows.isEmpty)
    }

    // MARK: - Header rows

    func testHeaderLevels() {
        let model = makeModel("ID\n# One\n## Two\n### Three\n#### Clamped\nplain")
        XCTAssertEqual(model.headerLevel(ofRow: 0), 0)
        XCTAssertEqual(model.headerLevel(ofRow: 1), 1)
        XCTAssertEqual(model.headerLevel(ofRow: 2), 2)
        XCTAssertEqual(model.headerLevel(ofRow: 3), 3)
        XCTAssertEqual(model.headerLevel(ofRow: 4), 3)
        XCTAssertEqual(model.headerLevel(ofRow: 5), 0)
    }

    // MARK: - Undo

    func testUndoRedoOfCellEdit() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("ID\tName\na\tAlpha")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.setValue("Omega", row: 1, column: 1)
        undo.endUndoGrouping()
        XCTAssertEqual(model.value(row: 1, column: 1), "Omega")

        undo.undo()
        XCTAssertEqual(model.value(row: 1, column: 1), "Alpha")
        undo.redo()
        XCTAssertEqual(model.value(row: 1, column: 1), "Omega")
    }

    func testUndoOfRowRemoval() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("ID\na\nb\nc")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.removeRows(IndexSet([1, 3]))
        undo.endUndoGrouping()
        XCTAssertEqual(model.rowCount, 2)
        XCTAssertEqual(model.value(row: 1, column: 0), "b")

        undo.undo()
        XCTAssertEqual(model.rowCount, 4)
        XCTAssertEqual(model.value(row: 1, column: 0), "a")
        XCTAssertEqual(model.value(row: 3, column: 0), "c")
    }

    // MARK: - Column rules

    func testIDColumnCannotBeRemovedOrDisplaced() {
        let model = makeModel("ID\tName\ta\tAlpha")
        model.removeColumns(IndexSet(integer: 0))
        XCTAssertEqual(model.columnCount, 4)     // unchanged
        model.insertColumn(at: 0)                // clamped to index 1
        XCTAssertEqual(model.value(row: 0, column: 0), "ID")
        XCTAssertEqual(model.value(row: 0, column: 1), "")
    }
}

final class TSSFormatTests: XCTestCase {

    func testParseAndSerializeRoundTrip() {
        let format = TSSFormat.parse("tss\t0\ncolwidth\t2\t140\nrowheight\t5\t40\nfuture-record\tstuff\n")
        XCTAssertEqual(format.columnWidths[2], 140)
        XCTAssertEqual(format.rowHeights[5], 40)

        let out = format.serialize()
        XCTAssertTrue(out.hasPrefix("tss\t0\n"))
        XCTAssertTrue(out.contains("colwidth\t2\t140"))
        XCTAssertTrue(out.contains("rowheight\t5\t40"))
        // Unknown records survive a round trip so future TSS versions are safe.
        XCTAssertTrue(out.contains("future-record\tstuff"))
    }

    func testSidecarURL() {
        let url = TSSFormat.sidecarURL(for: URL(fileURLWithPath: "/tmp/data.tsv"))
        XCTAssertEqual(url.path, "/tmp/data.tss")
    }

    func testMalformedRecordsAreTolerated() {
        let format = TSSFormat.parse("colwidth\tnot-a-number\t99\ncolwidth\t1\t-5\ncolwidth\t1\n")
        XCTAssertTrue(format.columnWidths.isEmpty)
    }
}
