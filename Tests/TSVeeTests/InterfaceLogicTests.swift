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

final class CellArithmeticTests: XCTestCase {

    private func apply(_ op: CellArithmetic.Operation, _ operand: String, _ value: String) -> String? {
        CellArithmetic.apply(op, operand: Decimal(string: operand, locale: Locale(identifier: "en_US_POSIX"))!,
                             to: value)
    }

    func testOnlyCleanNumbersCount() {
        XCTAssertEqual(CellArithmetic.number("12"), 12)
        XCTAssertEqual(CellArithmetic.number("-0.5"), Decimal(string: "-0.5"))
        XCTAssertEqual(CellArithmetic.number(".5"), Decimal(string: "0.5"))
        for text in ["", " ", "12 hp", "1,000", "$3", "1e5", "--1", "1.2.3", "TRUE", "#Boss"] {
            XCTAssertNil(CellArithmetic.number(text), "\(text) should not read as a number")
        }
    }

    func testFourOperations() {
        XCTAssertEqual(apply(.add, "5", "10"), "15")
        XCTAssertEqual(apply(.subtract, "5", "10"), "5")
        XCTAssertEqual(apply(.multiply, "3", "10"), "30")
        XCTAssertEqual(apply(.divide, "4", "10"), "2.5")
        XCTAssertEqual(apply(.add, "-2", "10"), "8")
    }

    func testNonNumericCellsAreLeftAlone() {
        XCTAssertNil(apply(.multiply, "2", "Red Slime"))
        XCTAssertNil(apply(.multiply, "2", ""))
        XCTAssertNil(apply(.divide, "0", "10"))
    }

    func testDecimalMathsIsExact() {
        // 0.1 + 0.2 in binary floating point would land on 0.30000000000000004.
        XCTAssertEqual(apply(.add, "0.2", "0.1"), "0.3")
        XCTAssertEqual(apply(.multiply, "1.1", "19.99"), "21.989")
    }

    func testResultKeepsTheCellsShape() {
        XCTAssertEqual(apply(.add, "1", "007"), "008")
        XCTAssertEqual(apply(.add, "1", "099"), "100")
        XCTAssertEqual(apply(.multiply, "2", "1.50"), "3.00")
        XCTAssertEqual(apply(.multiply, "2", "1.5"), "3.0")
        // Padding can't survive a negative result, so the sign wins.
        XCTAssertEqual(apply(.subtract, "10", "007"), "-3")
    }

    func testRepeatingDivisionIsRounded() {
        XCTAssertEqual(apply(.divide, "3", "10"), "3.3333333333")
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

final class SheetAccentTests: XCTestCase {

    func testSystemAccentIsTheDefaultAndIsNeverWritten() {
        let format = TSSFormat()
        XCTAssertEqual(format.accent, .system)
        XCTAssertFalse(format.hasCustomFormatting)
        XCTAssertFalse(format.serialize().contains("accent"))
    }

    func testNamedAccentRoundTrips() {
        var format = TSSFormat()
        format.accent = .purple
        XCTAssertTrue(format.hasCustomFormatting)
        let out = format.serialize()
        XCTAssertTrue(out.contains("accent\tpurple"))
        XCTAssertEqual(TSSFormat.parse(out).accent, .purple)
    }

    // A color TSVee can't draw is no reason to refuse the sheet: it falls
    // back to the system accent, the same as a sheet that never named one.
    func testUnknownAccentFallsBackToSystem() {
        XCTAssertEqual(TSSFormat.parse("accent\tchartreuse\n").accent, .system)
        XCTAssertEqual(TSSFormat.parse("accent\n").accent, .system)
    }

    // Accent is decoration, like column widths — two people picking different
    // colors for the same sheet is never worth a "changed on disk" dialog.
    func testAccentIsNotSubstantive() {
        var blue = TSSFormat()
        blue.accent = .blue
        var green = TSSFormat()
        green.accent = .green
        XCTAssertEqual(blue.substantiveContent, green.substantiveContent)
    }

    func testEveryAccentHasADistinctTitleAndSwatch() {
        let titles = SheetAccent.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, SheetAccent.allCases.count)
        XCTAssertEqual(SheetAccent.system.title, "Automatic")
        XCTAssertEqual(SheetAccent.graphite.title, "Graphite")
        XCTAssertTrue(SheetAccent.allCases.allSatisfy { $0.swatch.size.width > 0 })
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

final class BlankSheetReplacementTests: XCTestCase {

    /// A stand-in for the documents on screen: (untitled?, edited?).
    private struct Sheet {
        var untitled: Bool
        var edited: Bool
    }

    private func replaced(_ sheets: [Sheet], openingFile: Bool = true) -> Bool {
        TSVDocumentController.replaceableBlankSheet(
            among: sheets, openingFile: openingFile,
            isUntitled: { $0.untitled }, isEdited: { $0.edited }) != nil
    }

    func testLoneUntouchedBlankSheetIsReplaced() {
        XCTAssertTrue(replaced([Sheet(untitled: true, edited: false)]))
    }

    func testATouchedOrSavedSheetStays() {
        XCTAssertFalse(replaced([Sheet(untitled: true, edited: true)]))
        XCTAssertFalse(replaced([Sheet(untitled: false, edited: false)]))
    }

    func testNothingIsReplacedWhenOtherSheetsAreOpen() {
        // Two sheets is a workspace; opening a third doesn't tidy it up.
        XCTAssertFalse(replaced([Sheet(untitled: true, edited: false),
                                 Sheet(untitled: false, edited: false)]))
        XCTAssertFalse(replaced([]))
    }

    func testANewUntitledSheetReplacesNothing() {
        XCTAssertFalse(replaced([Sheet(untitled: true, edited: false)], openingFile: false))
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

        // Re-pointing a source column changes what the sheet's data means as
        // surely as re-listing a select column's options does.
        let mirroring = format {
            $0.columnTypes[2] = .source
            $0.sourceSpecs[2] = SourceSpec(path: "enemies.tsv", field: "HP")
        }
        let remirrored = format {
            $0.columnTypes[2] = .source
            $0.sourceSpecs[2] = SourceSpec(path: "enemies.tsv", field: "Attack")
        }
        XCTAssertNotEqual(mirroring.substantiveContent, remirrored.substantiveContent)
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

final class FollowStateTests: XCTestCase {

    private func scratchState() -> FollowState {
        let name = "tsvee-follow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return FollowState(defaults: defaults)
    }

    func testFollowingIsOnUntilTurnedOff() {
        let state = scratchState()
        XCTAssertTrue(state.isEnabled)
        state.isEnabled = false
        XCTAssertFalse(state.isEnabled)
        state.isEnabled = true
        XCTAssertTrue(state.isEnabled)
    }

    /// The toggle is a preference, not session state: a later launch reading
    /// the same defaults has to see the choice, including "off" — which is
    /// indistinguishable from "unset" unless it's really been written.
    func testTheToggleOutlivesTheObject() {
        let name = "tsvee-follow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }

        FollowState(defaults: defaults).isEnabled = false
        XCTAssertFalse(FollowState(defaults: defaults).isEnabled)
    }
}

final class TabOrderTests: XCTestCase {

    private func order(_ positions: [Int?]) -> [Int] {
        // Items are their own index, so the result reads as the new ordering.
        SpreadsheetView.orderedByTabPosition(Array(positions.indices)) { positions[$0] }
    }

    func testSortsByTabPosition() {
        XCTAssertEqual(order([2, 0, 1]), [1, 2, 0])
    }

    /// Sheets in another window have no tab position here; they go last,
    /// keeping the order they came in (Swift's sort isn't stable on its own).
    func testUnplacedItemsKeepTheirOrderAtTheEnd() {
        XCTAssertEqual(order([nil, 1, nil, 0]), [3, 1, 0, 2])
        XCTAssertEqual(order([nil, nil, nil]), [0, 1, 2])
    }

    func testEmptyAndSingleAreLeftAlone() {
        XCTAssertEqual(order([]), [])
        XCTAssertEqual(order([5]), [0])
    }
}

final class HiddenColumnTests: XCTestCase {

    func testHiddenColumnsRoundTrip() {
        var format = TSSFormat()
        format.hiddenColumns = [3, 1]
        let out = format.serialize()
        XCTAssertTrue(out.contains("hiddencol\t1\t1"))
        XCTAssertTrue(out.contains("hiddencol\t3\t1"))
        XCTAssertEqual(TSSFormat.parse(out).hiddenColumns, [1, 3])
    }

    func testIDColumnIsNeverHidden() {
        // Nothing in the app can write this, but a hand-edited sidecar can.
        XCTAssertTrue(TSSFormat.parse("hiddencol\t0\t1\n").hiddenColumns.isEmpty)
        XCTAssertTrue(TSSFormat.parse("hiddencol\t2\t0\n").hiddenColumns.isEmpty)
    }

    func testHidingIsDecorative() {
        // Someone else folding a column away is not a conflict worth a dialog.
        var hidden = TSSFormat()
        hidden.hiddenColumns = [2]
        XCTAssertEqual(TSSFormat().substantiveContent, hidden.substantiveContent)
        XCTAssertTrue(hidden.hasCustomFormatting)
    }
}

final class FlagDuplicateColumnTests: XCTestCase {

    func testFlaggedColumnsRoundTrip() {
        var format = TSSFormat()
        format.flagDuplicateColumns = [3, 1]
        let out = format.serialize()
        XCTAssertTrue(out.contains("flagdupes\t1\t1"))
        XCTAssertTrue(out.contains("flagdupes\t3\t1"))
        XCTAssertEqual(TSSFormat.parse(out).flagDuplicateColumns, [1, 3])
    }

    func testIDColumnIsNeverFlagged() {
        // Its IDs are checked anyway, so a sidecar saying so says nothing.
        XCTAssertTrue(TSSFormat.parse("flagdupes\t0\t1\n").flagDuplicateColumns.isEmpty)
        XCTAssertTrue(TSSFormat.parse("flagdupes\t2\t0\n").flagDuplicateColumns.isEmpty)
    }

    func testFlaggingIsSubstantive() {
        // A rule about what the data may contain, not how it's displayed.
        var flagged = TSSFormat()
        flagged.flagDuplicateColumns = [2]
        XCTAssertNotEqual(TSSFormat().substantiveContent, flagged.substantiveContent)
        XCTAssertTrue(flagged.hasCustomFormatting)
    }
}
