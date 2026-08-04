# TSVee

A native, sleek macOS spreadsheet editor for raw **TSV** files — built for game
data tables. No cell types, no formulas, no surprises in your diffs: the file
on disk is always plain tab-separated text.

![TSVee](docs/screenshot.png)

## Build & run

```sh
make run        # builds a release TSVee.app into dist/ and opens it
swift test      # unit tests for the model and TSS parsing
```

Requires Xcode command-line tools. You can also `open Package.swift` in Xcode
and run the `TSVee` target from there (note: file-type association and the
document-based niceties come from `Support/Info.plist`, which only the `make
bundle` app carries).

## The rules

1. **Column A is always `ID`**, and IDs must be unique per row. TSVee never
   blocks your typing — duplicate IDs are tinted red (cell + row number), a
   `⚠ N duplicate IDs` badge appears in the formula bar, and clicking it (or
   Sheet → Jump to Next Duplicate ID, ⇧⌘D) cycles through the offenders.
2. **`#` IDs are section headers.** `#` is a top-level header, `##` a
   subheader, `###` (or more) the lowest tier. Header rows get graduated
   accent tints, bolder/larger type, and taller rows — and are exempt from the
   uniqueness rule, so two `## Stats` sections under different headers are
   fine.
3. If row 1's ID cell is literally `ID`, it's treated as the **field-name
   row**: styled bold and exempt from uniqueness.
4. Empty IDs are allowed (and exempt from uniqueness).

## Google-Sheets-isms

- Column letters / row numbers, accent-colored range selection, a formula bar
  with an `A1` name box that edits the raw cell value.
- **Frozen panes**: the field-name row and the ID column stay pinned while you
  scroll (both on by default; toggle in the View menu, persisted via `.tss`).
- **Fill handle**: drag the circle at the selection's bottom-right corner to
  autofill. A single cell copies; numeric runs continue the series (`1, 2 →
  3, 4`); IDs with trailing numbers increment and keep their zero-padding
  (`slime_01, slime_02 → slime_03`); anything else repeats the pattern.
- **Drag to reorder**: select whole rows/columns via their headers, then grab
  the selected header (cursor becomes a hand) and drag to move the block —
  multi-row/column selections move together, and `.tss` widths/heights follow
  their columns/rows. The ID column stays put.
- Type into a selected cell to start editing; **Enter** commits and moves
  down (⇧Enter up), **Tab** right (⇧Tab left), **Esc** cancels. Double-click
  or Enter to edit in place. Arrow keys navigate; ⇧-arrows extend the
  selection.
- Copy/cut/paste whole rectangular blocks as TSV — round-trips cleanly with
  Google Sheets, Excel, and Numbers.
- Click row numbers / column letters to select whole rows/columns; drag a
  column edge in the letter band to resize.
- The grid extends past your data with phantom rows/columns; editing one
  grows the file (trailing empty rows/columns are trimmed on save).
- Right-click for insert/delete row & column operations (also in the Sheet
  menu). The ID column can't be deleted or displaced.
- Full undo/redo.

## Column data types

Right-click a column (header or any cell) → **Column Data Type**:

- **Raw** (default) — plain left-aligned strings, exactly as on disk.
- **Integer** / **Float** — right-aligned; values that don't parse are shown
  in red so bad data is obvious at a glance. Nothing is ever rewritten.
- **Text** — word-wrapped display with spell-checking while editing; rows
  grow automatically to fit the tallest text cell.

Types are per-column formatting, stored in the `.tss` sidecar, and they
follow their column when you drag-reorder. Header (`#`) rows and the
field-name row ignore column types. **Auto-Size Column** in the same menu
fits the width to the longest cell (field name included).

## Cross-file ID navigation

The same ID often lives in several files (stats in one, dialogue in
another). Right-click a row — its header or any cell — and **Go to "id" In**
lists every other open sheet containing that ID, with its row number.
Choosing one brings that sheet's window/tab forward and selects the row.

## Saving & tabs (Sublime-style)

Traditional save paradigm — no autosave-in-place, no Duplicate/Rename
titlebar model. Sheets keep a dirty flag and prompt on close/quit.

- **⌘S** Save · **⌥⇧⌘S** Save As… · **⇧⌘S** Save All (every sheet with
  pending changes)
- Sheets open as **tabs** of the frontmost window (**⇧⌘[** / **⇧⌘]** to
  switch). Drag a tab out — or use Window → Move Tab to New Window — to get
  an independent window with its own tab group; **⇧⌘N** opens a fresh
  standalone window. Window → Merge All Windows collects everything back
  into one.

## `.tss` — Tab Separated Support (stubbed)

Formatting never pollutes the TSV. A sibling sidecar carries it instead:
`data.tsv` + `data.tss` in the same folder. If the sidecar exists it's loaded
with the document; it's written on save **only** if there's formatting worth
persisting (a plain TSV never grows a stray `.tss`).

v0 wire format — one tab-separated record per line:

```
tss	0
colwidth	<columnIndex>	<points>
rowheight	<rowIndex>	<points>
freeze	fieldrow|idcol	0|1
```

The UI writes column widths (drag-resize a column) and the freeze toggles
today; freeze records are only written when a pane is un-frozen, since frozen
is the default. Unknown record types are preserved verbatim on rewrite, so future
fields — cell styles, merged headers, calculated columns — can be added in
`TSSFormat.swift` without breaking older files. That's the extension point:
add a record type to `parse`/`serialize` and consume it in
`SpreadsheetView`.

## Layout

```
Sources/TSVee/
  SpreadsheetModel.swift        the TSV grid: parsing, mutations, undo, unique-ID checks
  TSSFormat.swift               the .tss sidecar (stub v0)
  TSVDocument.swift             NSDocument glue: read/write TSV + sidecar
  SpreadsheetView.swift         custom-drawn grid (only visible cells render — big files stay fast)
  FormulaBarView.swift          name box + raw value editor + duplicate-ID badge
  DocumentWindowController.swift
  MainMenu.swift / AppDelegate.swift / main.swift
Support/Info.plist              app bundle metadata + .tsv file association
Tests/TSVeeTests/               model + TSS unit tests
```

## Roadmap

- Row-height drag-resize (the model + `.tss` already support it)
- Find & replace, sort-within-section
- `.tss`: cell styles, column types, calculated columns
