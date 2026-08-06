import XCTest
@testable import TSVee

final class AutofillSeriesTests: XCTestCase {

    func testSingleValueCopies() {
        XCTAssertEqual(AutofillSeries.extend(["sword"], count: 3), ["sword", "sword", "sword"])
        XCTAssertEqual(AutofillSeries.extend(["7"], count: 2), ["7", "7"])
    }

    func testIntegerSeriesContinues() {
        XCTAssertEqual(AutofillSeries.extend(["1", "2"], count: 3), ["3", "4", "5"])
        XCTAssertEqual(AutofillSeries.extend(["10", "20", "30"], count: 2), ["40", "50"])
        XCTAssertEqual(AutofillSeries.extend(["5", "3"], count: 3), ["1", "-1", "-3"])
    }

    func testPaddedIntegersKeepWidth() {
        XCTAssertEqual(AutofillSeries.extend(["007", "008"], count: 3), ["009", "010", "011"])
        XCTAssertEqual(AutofillSeries.extend(["098", "099"], count: 2), ["100", "101"])
    }

    func testDecimalSeriesContinues() {
        XCTAssertEqual(AutofillSeries.extend(["0.5", "1.0"], count: 3), ["1.5", "2", "2.5"])
        XCTAssertEqual(AutofillSeries.extend(["1.1", "1.2"], count: 2), ["1.3", "1.4"])
    }

    func testTrailingIntegerIDsContinue() {
        XCTAssertEqual(AutofillSeries.extend(["slime_01", "slime_02"], count: 3),
                       ["slime_03", "slime_04", "slime_05"])
        XCTAssertEqual(AutofillSeries.extend(["wave5", "wave10"], count: 2), ["wave15", "wave20"])
    }

    func testMixedPrefixesCycle() {
        XCTAssertEqual(AutofillSeries.extend(["a1", "b2"], count: 3), ["a1", "b2", "a1"])
    }

    func testPlainTextCycles() {
        XCTAssertEqual(AutofillSeries.extend(["red", "blue"], count: 3), ["red", "blue", "red"])
    }

    func testNonConstantStepCycles() {
        XCTAssertEqual(AutofillSeries.extend(["1", "2", "4"], count: 3), ["1", "2", "4"])
    }
}

final class MoveTests: XCTestCase {

    private func makeModel(_ tsv: String) -> SpreadsheetModel {
        let model = SpreadsheetModel()
        model.load(tsv: tsv)
        return model
    }

    private func ids(_ model: SpreadsheetModel) -> [String] {
        (0..<model.rowCount).map { model.value(row: $0, column: 0) }
    }

    func testMoveRowsDownAndUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("a\nb\nc\nd\ne")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.moveRows(1...2, to: 5)     // b,c to the end
        undo.endUndoGrouping()
        XCTAssertEqual(ids(model), ["a", "d", "e", "b", "c"])

        undo.undo()
        XCTAssertEqual(ids(model), ["a", "b", "c", "d", "e"])
        undo.redo()
        XCTAssertEqual(ids(model), ["a", "d", "e", "b", "c"])
    }

    func testMoveRowsUp() {
        let model = makeModel("a\nb\nc\nd")
        model.moveRows(3...3, to: 1)
        XCTAssertEqual(ids(model), ["a", "d", "b", "c"])
    }

    func testMoveRowsToAdjacentBoundaryIsNoOp() {
        let model = makeModel("a\nb\nc")
        model.moveRows(1...1, to: 1)
        model.moveRows(1...1, to: 2)
        XCTAssertEqual(ids(model), ["a", "b", "c"])
    }

    func testMoveColumnsAndUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("id\tw\tx\ty\nid2\t1\t2\t3")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.moveColumns(3...3, to: 1)   // y next to the ID column
        undo.endUndoGrouping()
        XCTAssertEqual(model.value(row: 0, column: 1), "y")
        XCTAssertEqual(model.value(row: 1, column: 1), "3")
        XCTAssertEqual(model.value(row: 0, column: 3), "x")

        undo.undo()
        XCTAssertEqual(model.value(row: 0, column: 1), "w")
        XCTAssertEqual(model.value(row: 0, column: 3), "y")
    }

    func testIDColumnCannotMoveOrBeDisplaced() {
        let model = makeModel("id\ta\tb")
        model.moveColumns(0...0, to: 2)   // moving the ID column: rejected
        XCTAssertEqual(model.value(row: 0, column: 0), "id")
        model.moveColumns(1...1, to: 0)   // dropping before the ID column: rejected
        XCTAssertEqual(model.value(row: 0, column: 1), "a")
    }

    func testMoveMapping() {
        // [0 1 2 3 4], move 1...2 after index 4 (to boundary 5)
        var mapping = SpreadsheetModel.moveMapping(range: 1...2, to: 5)
        XCTAssertEqual(mapping, [1: 3, 2: 4, 3: 1, 4: 2])

        // move 3...3 to boundary 1
        mapping = SpreadsheetModel.moveMapping(range: 3...3, to: 1)
        XCTAssertEqual(mapping, [3: 1, 1: 2, 2: 3])

        // no-op boundaries produce empty mappings
        XCTAssertTrue(SpreadsheetModel.moveMapping(range: 1...2, to: 1).isEmpty)
        XCTAssertTrue(SpreadsheetModel.moveMapping(range: 1...2, to: 3).isEmpty)
    }
}

final class ColumnTypeTests: XCTestCase {

    func testColumnTypeRoundTrip() {
        var format = TSSFormat()
        format.columnTypes[2] = .integer
        format.columnTypes[4] = .text
        let out = format.serialize()
        XCTAssertTrue(out.contains("coltype\t2\tinteger"))
        XCTAssertTrue(out.contains("coltype\t4\ttext"))

        let parsed = TSSFormat.parse(out)
        XCTAssertEqual(parsed.columnTypes[2], .integer)
        XCTAssertEqual(parsed.columnTypes[4], .text)
        XCTAssertNil(parsed.columnTypes[0])
    }

    func testBooleanRoundTrip() {
        var format = TSSFormat()
        format.columnTypes[3] = .boolean
        XCTAssertTrue(format.serialize().contains("coltype\t3\tboolean"))
        XCTAssertEqual(TSSFormat.parse(format.serialize()).columnTypes[3], .boolean)
    }

    func testBooleanCellParsing() {
        XCTAssertEqual(BooleanCell("TRUE"), .on)
        XCTAssertEqual(BooleanCell("true"), .on)
        XCTAssertEqual(BooleanCell(" TRUE "), .on)
        XCTAssertEqual(BooleanCell("FALSE"), .off)
        XCTAssertEqual(BooleanCell(""), .off)
        // Anything else is data the type doesn't describe — flagged, not coerced.
        XCTAssertEqual(BooleanCell("1"), .invalid)
        XCTAssertEqual(BooleanCell("yes"), .invalid)
        XCTAssertEqual(BooleanCell("TRUE!"), .invalid)
        XCTAssertEqual(BooleanCell.literal(true), "TRUE")
        XCTAssertEqual(BooleanCell.literal(false), "FALSE")
    }

    func testRawIsNeverPersisted() {
        var format = TSSFormat()
        format.columnTypes[1] = .raw
        XCTAssertFalse(format.serialize().contains("coltype"))
        let parsed = TSSFormat.parse("coltype\t1\traw\n")
        XCTAssertTrue(parsed.columnTypes.isEmpty)
    }
}

final class CrossFileLookupTests: XCTestCase {

    func testFirstRowWithID() {
        let model = SpreadsheetModel()
        model.load(tsv: "ID\tName\n# Header\t\nslime_red\tRed\nslime_blue\tBlue\nslime_red\tAgain")
        XCTAssertEqual(model.firstRow(withID: "slime_red"), 2)
        XCTAssertEqual(model.firstRow(withID: "slime_blue"), 3)
        XCTAssertNil(model.firstRow(withID: "missing"))
        // The field-name row never matches, even for the literal "ID".
        XCTAssertNil(model.firstRow(withID: "ID"))
        // Header rows can be found (useful for section navigation).
        XCTAssertEqual(model.firstRow(withID: "# Header"), 1)
    }
}

final class TSSCollapseTests: XCTestCase {

    func testCollapsedSectionsRoundTrip() {
        var format = TSSFormat()
        format.collapsedSections = [7, 2]
        let out = format.serialize()
        // Written in row order, so sidecar diffs stay stable.
        XCTAssertTrue(out.contains("collapsed\t2\t1\ncollapsed\t7\t1"))

        let parsed = TSSFormat.parse(out)
        XCTAssertEqual(parsed.collapsedSections, [2, 7])
    }

    func testNoCollapsedSectionsMeansNoRecordsAndNoSidecar() {
        let format = TSSFormat()
        XCTAssertTrue(format.collapsedSections.isEmpty)
        XCTAssertFalse(format.serialize().contains("collapsed"))
        XCTAssertFalse(format.hasCustomFormatting)
    }

    func testCollapsedSectionsCountAsFormattingWorthSaving() {
        var format = TSSFormat()
        format.collapsedSections = [3]
        XCTAssertTrue(format.hasCustomFormatting)
    }

    func testMalformedAndClearedCollapseRecordsAreIgnored() {
        let format = TSSFormat.parse("collapsed\tnot-a-number\t1\ncollapsed\t4\t0\ncollapsed\t5\n")
        XCTAssertTrue(format.collapsedSections.isEmpty)
    }
}

final class TSSFreezeTests: XCTestCase {

    func testFreezeDefaultsOnAndOnlyDeviationsPersist() {
        let format = TSSFormat()
        XCTAssertTrue(format.freezeFieldRow)
        XCTAssertTrue(format.freezeIDColumn)
        XCTAssertFalse(format.serialize().contains("freeze"))
    }

    func testFreezeRoundTrip() {
        var format = TSSFormat()
        format.freezeFieldRow = false
        let out = format.serialize()
        XCTAssertTrue(out.contains("freeze\tfieldrow\t0"))
        XCTAssertFalse(out.contains("idcol"))

        let parsed = TSSFormat.parse(out)
        XCTAssertFalse(parsed.freezeFieldRow)
        XCTAssertTrue(parsed.freezeIDColumn)
    }
}

final class FolderOpenTests: XCTestCase {

    func testTSVFilesListsOnlyTopLevelTSVsInFinderOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsvee-folder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["b.tsv", "a10.tsv", "a2.tsv", "Z.TSV", "notes.txt", "data.tss"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("inner.tsv"))

        let names = TSVDocumentController.tsvFiles(inFolder: dir).map(\.lastPathComponent)
        // Finder-style ordering: numeric-aware, case-insensitive; extension
        // matching is case-insensitive; subfolders and other types skipped.
        XCTAssertEqual(names, ["a2.tsv", "a10.tsv", "b.tsv", "Z.TSV"])
    }

    func testTSVFilesOnMissingFolderIsEmpty() {
        let missing = URL(fileURLWithPath: "/tmp/tsvee-does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(TSVDocumentController.tsvFiles(inFolder: missing).isEmpty)
    }
}

final class TabTitleTests: XCTestCase {

    func testDirtyMarkerLeadsAndExtensionDrops() {
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "enemies.tsv", edited: false),
                       "enemies")
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "enemies.tsv", edited: true),
                       "*enemies")
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "ENEMIES.TSV", edited: false),
                       "ENEMIES")
    }

    func testOnlyTheTSVExtensionIsDropped() {
        // Untitled sheets and odd names keep their full display name.
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "Untitled", edited: true),
                       "*Untitled")
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "notes.txt", edited: false),
                       "notes.txt")
        XCTAssertEqual(DocumentWindowController.tabTitle(for: "v1.2.tsv", edited: false),
                       "v1.2")
    }
}

/// What counts as a conflict when the sidecar changes underneath an open
/// sheet: data meaning, never how someone happens to be viewing it.
final class SidecarSubstanceTests: XCTestCase {

    private func format(_ mutate: (inout TSSFormat) -> Void) -> TSSFormat {
        var format = TSSFormat()
        mutate(&format)
        return format
    }

    func testDecorationIsNotSubstantive() {
        let plain = TSSFormat()
        let decorated = format {
            $0.columnWidths[1] = 220
            $0.rowHeights[4] = 60
            $0.collapsedSections.insert(7)
            $0.freezeFieldRow = false
            $0.freezeIDColumn = false
        }
        XCTAssertEqual(plain.substantiveContent, decorated.substantiveContent)
    }

    func testColumnTypesAndOptionsAreSubstantive() {
        let typed = format { $0.columnTypes[2] = .boolean }
        XCTAssertNotEqual(TSSFormat().substantiveContent, typed.substantiveContent)

        let listed = format {
            $0.columnTypes[2] = .select
            $0.selectSources[2] = .list(["red", "green"])
        }
        let relisted = format {
            $0.columnTypes[2] = .select
            $0.selectSources[2] = .list(["red", "blue"])
        }
        XCTAssertNotEqual(listed.substantiveContent, relisted.substantiveContent)
        XCTAssertEqual(listed.substantiveContent, listed.substantiveContent)
    }

    func testUnknownRecordsCountAsSubstantive() {
        // A record from a newer TSS can't be assumed decorative.
        let future = TSSFormat.parse("tss\t0\nsomethingnew\t1\tvalue\n")
        XCTAssertNotEqual(TSSFormat().substantiveContent, future.substantiveContent)
    }

    func testDecorationDifferenceSurvivesRoundTrip() {
        let wide = format { $0.columnWidths[0] = 300 }
        let narrow = format { $0.columnWidths[0] = 80 }
        XCTAssertEqual(TSSFormat.parse(wide.serialize()).substantiveContent,
                       TSSFormat.parse(narrow.serialize()).substantiveContent)
    }
}
