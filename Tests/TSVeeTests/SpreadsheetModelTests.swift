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

    // MARK: - Sections

    /// Mirrors Samples/enemies.tsv: nested "#" / "##" / "###" sections.
    private func makeSectionedModel() -> SpreadsheetModel {
        makeModel("""
        ID\tName
        # Enemies\t
        ## Forest\t
        slime_green\tGreen Slime
        slime_red\tRed Slime
        ### Boss\t
        forest_guardian\tForest Guardian
        ## Caves\t
        bat_cave\tCave Bat
        crimson\tCrimson Slime
        # Items\t
        potion_small\tSmall Potion
        """)
    }

    func testSectionBodyStopsAtSameOrHigherLevel() {
        let model = makeSectionedModel()
        // "#" swallows its subsections, and runs to the next "#".
        XCTAssertEqual(model.sectionBody(ofRow: 1), 2...9)
        // "## Forest" ends at "## Caves", carrying its "### Boss" comment.
        XCTAssertEqual(model.sectionBody(ofRow: 2), 3...6)
        XCTAssertEqual(model.sectionBody(ofRow: 7), 8...9)
        // A trailing section runs to the last row.
        XCTAssertEqual(model.sectionBody(ofRow: 10), 11...11)
        // The field-name row and data rows open nothing.
        XCTAssertNil(model.sectionBody(ofRow: 0))
        XCTAssertNil(model.sectionBody(ofRow: 3))
    }

    func testCommentRowsAreNotSections() {
        let model = makeSectionedModel()
        // "### Boss" is a comment row: it opens no section of its own...
        XCTAssertEqual(model.headerLevel(ofRow: 5), 3)
        XCTAssertNil(model.sectionBody(ofRow: 5))
        // ...and doesn't close the "##" section it sits in (row 6 is inside it).
        XCTAssertEqual(model.sectionBody(ofRow: 2), 3...6)
        // "####" and deeper clamp to level 3, so they're comments too.
        let deep = makeModel("# One\n#### Deep\nx")
        XCTAssertNil(deep.sectionBody(ofRow: 1))
        XCTAssertEqual(deep.sectionBody(ofRow: 0), 1...2)
    }

    func testEmptySectionsHaveNoBody() {
        // Back-to-back headers, and a header as the very last row.
        let model = makeModel("# A\n# B\nx\n# Trailing")
        XCTAssertNil(model.sectionBody(ofRow: 0))
        XCTAssertEqual(model.sectionBody(ofRow: 1), 2...2)
        XCTAssertNil(model.sectionBody(ofRow: 3))
        XCTAssertEqual(model.sectionHeaderRows(), [1])
    }

    func testSectionHeaderRows() {
        // Row 5 ("### Boss") is a comment, so it isn't listed.
        XCTAssertEqual(makeSectionedModel().sectionHeaderRows(), [1, 2, 7, 10])
    }

    func testEnclosingSectionHeaderIsTheInnermostOne() {
        let model = makeSectionedModel()
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 4), 2)     // in "## Forest"
        // Below a "###" comment: skips it for the real section header above.
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 6), 2)
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 5), 2)
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 9), 7)     // in "## Caves"
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 11), 10)
        // A header row owns itself.
        XCTAssertEqual(model.enclosingSectionHeader(ofRow: 2), 2)
        // Nothing above the first header.
        XCTAssertNil(model.enclosingSectionHeader(ofRow: 0))
    }

    // MARK: - Per-row state follows its content

    func testShiftedRowIndexAfterInsert() {
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(2, afterInsertAt: 3), 2)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(3, afterInsertAt: 3), 4)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(5, afterInsertAt: 3), 6)
    }

    func testShiftedRowIndexAfterRemoval() {
        let removed = IndexSet([1, 3])
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(0, afterRemoving: removed), 0)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(2, afterRemoving: removed), 1)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(4, afterRemoving: removed), 2)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(5, afterRemoving: removed), 3)
        // State on a deleted row is dropped, not relocated.
        XCTAssertNil(SpreadsheetModel.shiftedIndex(1, afterRemoving: removed))
        XCTAssertNil(SpreadsheetModel.shiftedIndex(3, afterRemoving: removed))
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

    func testInsertingSeveralRowsIsOneUndoStep() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("ID\na\nb")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.insertRow(at: 1, count: 3)
        undo.endUndoGrouping()
        XCTAssertEqual(model.rowCount, 6)
        XCTAssertEqual(model.value(row: 1, column: 0), "")
        XCTAssertEqual(model.value(row: 4, column: 0), "a")

        undo.undo()
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.value(row: 1, column: 0), "a")
    }

    func testInsertingSeveralColumnsIsOneUndoStep() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("ID\tName\na\tAlpha")
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.insertColumn(at: 1, count: 2)
        undo.endUndoGrouping()
        XCTAssertEqual(model.columnCount, 4)
        XCTAssertEqual(model.value(row: 1, column: 0), "a")
        XCTAssertEqual(model.value(row: 1, column: 3), "Alpha")

        undo.undo()
        XCTAssertEqual(model.columnCount, 2)
        XCTAssertEqual(model.value(row: 1, column: 1), "Alpha")
    }

    func testRowFormattingShiftsByTheNumberInserted() {
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(5, afterInsertAt: 2, count: 3), 8)
        XCTAssertEqual(SpreadsheetModel.shiftedIndex(1, afterInsertAt: 2, count: 3), 1)
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

    // MARK: - Entry IDs (select-column options)

    func testEntryIDsSkipNonEntriesAndDeduplicate() {
        let model = makeModel("""
        ID\tName
        # Section\t
        fire\tFire
        water\tWater
        ### comment\t
        \tno id
        fire\tFire again
        """)
        XCTAssertEqual(model.entryIDs(), ["fire", "water"])
    }

    // MARK: - Selection tally

    /// Row 0 is the field-name row, row 2 a header, row 5 a "###" comment and
    /// row 6 has no ID — none of them are entries, so none are counted.
    private func tallyModel() -> SpreadsheetModel {
        makeModel("""
        ID\tName\tFlag
        a\tAlpha\tTRUE
        # Section\t\t
        b\t\tFALSE
        c\tGamma\t
        ### note\tignored\tTRUE
        \tstray\tTRUE
        """)
    }

    func testTallySkipsHeaderCommentFieldNameAndIDLessRows() {
        let model = tallyModel()
        let tally = model.tally(rows: 0...6, columns: 0...1, booleanColumns: [])
        // Three data rows × two columns; only b's empty Name is unpopulated.
        XCTAssertEqual(tally.populated, 5)
        XCTAssertEqual(tally.empty, 1)
    }

    func testTallyCountsOnlyCheckedBooleans() {
        let model = tallyModel()
        // FALSE and empty are both "not populated" in a boolean column.
        XCTAssertEqual(model.tally(rows: 0...6, columns: 2...2, booleanColumns: [2]).populated, 1)
        XCTAssertEqual(model.tally(rows: 0...6, columns: 2...2, booleanColumns: [2]).empty, 2)
        // Without the column type it's just text, so FALSE counts as content.
        XCTAssertEqual(model.tally(rows: 0...6, columns: 2...2, booleanColumns: []).populated, 2)
    }

    func testTallyIgnoresRowsAndColumnsPastTheData() {
        let model = tallyModel()
        let tally = model.tally(rows: 0...400, columns: 0...30, booleanColumns: [])
        XCTAssertEqual(tally.populated + tally.empty, 9)   // 3 data rows × 3 columns
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

    func testSelectRecordsRoundTrip() {
        let text = "coltype\t2\tselect\nselectlist\t2\tred fox\tgreen\tblue, dotted\n"
            + "coltype\t3\tmultiselect\nselectfile\t3\t../shared/enemies.tsv\n"
        let format = TSSFormat.parse(text)
        XCTAssertEqual(format.columnTypes[2], .select)
        XCTAssertEqual(format.columnTypes[3], .multiselect)
        // Options are tab-separated, so spaces and commas survive.
        XCTAssertEqual(format.selectSources[2], .list(["red fox", "green", "blue, dotted"]))
        XCTAssertEqual(format.selectSources[3], .file("../shared/enemies.tsv"))

        let out = format.serialize()
        XCTAssertTrue(out.contains("coltype\t2\tselect\n"))
        XCTAssertTrue(out.contains("selectlist\t2\tred fox\tgreen\tblue, dotted"))
        XCTAssertTrue(out.contains("selectfile\t3\t../shared/enemies.tsv"))
        XCTAssertTrue(format.hasCustomFormatting)
    }
}

final class SelectCellTests: XCTestCase {

    private let options: Set<String> = ["fire", "water", "earth"]

    func testTokensSplitOnCommasAndTrim() {
        XCTAssertEqual(SelectCell.tokens(""), [])
        XCTAssertEqual(SelectCell.tokens("fire"), ["fire"])
        XCTAssertEqual(SelectCell.tokens("fire, water"), ["fire", "water"])
        XCTAssertEqual(SelectCell.tokens("a,,b"), ["a", "", "b"])
    }

    func testSingleSelectValidation() {
        XCTAssertTrue(SelectCell.isValid("", options: options, multi: false))
        XCTAssertTrue(SelectCell.isValid("fire", options: options, multi: false))
        XCTAssertTrue(SelectCell.isValid(" fire ", options: options, multi: false))
        XCTAssertFalse(SelectCell.isValid("lava", options: options, multi: false))
        // A comma-separated list is multi-select data, not a single option.
        XCTAssertFalse(SelectCell.isValid("fire,water", options: options, multi: false))
        XCTAssertFalse(SelectCell.isValid("Fire", options: options, multi: false))
    }

    func testMultiSelectValidation() {
        XCTAssertTrue(SelectCell.isValid("", options: options, multi: true))
        XCTAssertTrue(SelectCell.isValid("fire", options: options, multi: true))
        XCTAssertTrue(SelectCell.isValid("fire,water", options: options, multi: true))
        XCTAssertTrue(SelectCell.isValid("fire, water", options: options, multi: true))
        XCTAssertFalse(SelectCell.isValid("fire,lava", options: options, multi: true))
        // Dangling and doubled commas are empty tokens — flagged, not hidden.
        XCTAssertFalse(SelectCell.isValid("fire,", options: options, multi: true))
        XCTAssertFalse(SelectCell.isValid("fire,,water", options: options, multi: true))
    }
}

final class SelectOptionsResolverTests: XCTestCase {

    func testResolveRelativeAndAbsolutePaths() {
        let base = URL(fileURLWithPath: "/data/sheets/heroes.tsv")
        XCTAssertEqual(SelectOptionsResolver.resolve("enemies.tsv", relativeTo: base)?.path,
                       "/data/sheets/enemies.tsv")
        XCTAssertEqual(SelectOptionsResolver.resolve("../shared/items.tsv", relativeTo: base)?.path,
                       "/data/shared/items.tsv")
        XCTAssertEqual(SelectOptionsResolver.resolve("/abs/items.tsv", relativeTo: base)?.path,
                       "/abs/items.tsv")
        // A never-saved sheet has no base to resolve a relative path against.
        XCTAssertNil(SelectOptionsResolver.resolve("enemies.tsv", relativeTo: nil))
        XCTAssertEqual(SelectOptionsResolver.resolve("/abs/items.tsv", relativeTo: nil)?.path,
                       "/abs/items.tsv")
    }

    func testStorablePathPrefersRelative() {
        let base = URL(fileURLWithPath: "/data/sheets/heroes.tsv")
        XCTAssertEqual(SelectOptionsResolver.storablePath(
            to: URL(fileURLWithPath: "/data/sheets/enemies.tsv"), from: base),
            "enemies.tsv")
        XCTAssertEqual(SelectOptionsResolver.storablePath(
            to: URL(fileURLWithPath: "/data/shared/items.tsv"), from: base),
            "../shared/items.tsv")
        // Self-reference: the sheet using its own IDs stores its own name.
        XCTAssertEqual(SelectOptionsResolver.storablePath(
            to: URL(fileURLWithPath: "/data/sheets/heroes.tsv"), from: base),
            "heroes.tsv")
        XCTAssertEqual(SelectOptionsResolver.storablePath(
            to: URL(fileURLWithPath: "/data/sheets/items.tsv"), from: nil),
            "/data/sheets/items.tsv")
    }

    func testFileSourceReadsIDsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsvee-select-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let enemies = dir.appendingPathComponent("enemies.tsv")
        try "ID\tName\n# Bosses\t\nslime\tSlime\nbat\tBat\n\tno id\n"
            .write(to: enemies, atomically: true, encoding: .utf8)
        let heroes = dir.appendingPathComponent("heroes.tsv")

        let resolver = SelectOptionsResolver()
        XCTAssertEqual(resolver.options(for: .file("enemies.tsv"), tsvURL: heroes),
                       ["slime", "bat"])
        XCTAssertEqual(resolver.options(for: .file("missing.tsv"), tsvURL: heroes), [])
        XCTAssertEqual(resolver.options(for: .list(["a", "b"]), tsvURL: nil), ["a", "b"])
    }
}

final class FindReplaceTests: XCTestCase {

    private func makeModel(_ tsv: String) -> SpreadsheetModel {
        let model = SpreadsheetModel()
        model.load(tsv: tsv)
        return model
    }

    func testMatchingRules() {
        let options = FindOptions()
        XCTAssertTrue(SpreadsheetModel.value("Red Slime", matches: "slime", options: options))
        XCTAssertFalse(SpreadsheetModel.value("Red Slime", matches: "slime",
                                              options: FindOptions(caseSensitive: true)))
        XCTAssertTrue(SpreadsheetModel.value("Slime", matches: "SLIME",
                                             options: FindOptions(wholeCell: true)))
        XCTAssertFalse(SpreadsheetModel.value("Red Slime", matches: "Slime",
                                              options: FindOptions(wholeCell: true)))
        // The empty query matches nothing (not everything).
        XCTAssertFalse(SpreadsheetModel.value("anything", matches: "", options: options))
    }

    func testFindMatchesInReadingOrder() {
        let model = makeModel("ID\tName\nslime_red\tRed Slime\nbat\tBat\nslime_blue\tBlue Slime")
        let matches = model.findMatches("slime", options: FindOptions())
        XCTAssertEqual(matches.map { [$0.row, $0.column] }, [[1, 0], [1, 1], [3, 0], [3, 1]])

        let caseSensitive = model.findMatches("Slime", options: FindOptions(caseSensitive: true))
        XCTAssertEqual(caseSensitive.map { [$0.row, $0.column] }, [[1, 1], [3, 1]])

        XCTAssertTrue(model.findMatches("", options: FindOptions()).isEmpty)
    }

    func testReplacingHelper() {
        XCTAssertEqual(SpreadsheetModel.replacing("Red Slime", query: "slime", with: "Goblin",
                                                  options: FindOptions()), "Red Goblin")
        XCTAssertNil(SpreadsheetModel.replacing("Red Slime", query: "goblin", with: "x",
                                                options: FindOptions()))
        // Whole-cell replaces the entire content, whatever the query's case.
        XCTAssertEqual(SpreadsheetModel.replacing("SLIME", query: "slime", with: "goblin",
                                                  options: FindOptions(wholeCell: true)), "goblin")
        XCTAssertNil(SpreadsheetModel.replacing("Red Slime", query: "Slime", with: "goblin",
                                                options: FindOptions(wholeCell: true)))
    }

    func testReplaceAllIsOneUndoStep() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = makeModel("ID\tName\nslime_red\tRed Slime\nslime_blue\tBlue Slime")
        model.undoManager = undo

        undo.beginUndoGrouping()
        let count = model.replaceAll("slime", with: "goblin", options: FindOptions())
        undo.endUndoGrouping()

        XCTAssertEqual(count, 4)
        XCTAssertEqual(model.value(row: 1, column: 0), "goblin_red")
        XCTAssertEqual(model.value(row: 1, column: 1), "Red goblin")
        XCTAssertEqual(model.value(row: 2, column: 0), "goblin_blue")

        undo.undo()
        XCTAssertEqual(model.value(row: 1, column: 0), "slime_red")
        XCTAssertEqual(model.value(row: 1, column: 1), "Red Slime")
        undo.redo()
        XCTAssertEqual(model.value(row: 1, column: 0), "goblin_red")
    }

    func testReplaceAllReplacesEveryOccurrenceInACell() {
        let model = makeModel("a\tslime slime slime")
        XCTAssertEqual(model.replaceAll("slime", with: "bat", options: FindOptions()), 1)
        XCTAssertEqual(model.value(row: 0, column: 1), "bat bat bat")
    }

    func testReplaceAllUpdatesDuplicateTracking() {
        let model = makeModel("slime\ta\nslime2\tb")
        model.replaceAll("slime2", with: "slime", options: FindOptions())
        XCTAssertEqual(model.duplicateIDRows, [0, 1])
    }

    func testReplaceAllWithNoMatchesChangesNothing() {
        let model = makeModel("a\tb")
        XCTAssertEqual(model.replaceAll("zzz", with: "x", options: FindOptions()), 0)
        XCTAssertEqual(model.value(row: 0, column: 0), "a")
    }
}
