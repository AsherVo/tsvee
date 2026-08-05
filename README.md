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
2. **`#` IDs are section headers.** `#` is a top-level header and `##` a
   subheader — both get accent-tinted rows with bolder/larger type, and both
   open a **collapsible section**. `###` (or more) renders as a **greyed-out
   italic comment row**: it's ordinary content, so it neither collapses nor
   closes the section it sits in. All are exempt from the uniqueness rule, so
   two `## Stats` sections under different headers are fine.
3. If row 1's ID cell is literally `ID`, it's treated as the **field-name
   row**: bold on a grey band and exempt from uniqueness. IDs in data rows
   are drawn in monospace.
4. Empty IDs are allowed (and exempt from uniqueness).

## Google-Sheets-isms

- Column letters / row numbers, accent-colored range selection, a formula bar
  with an `A1` name box that edits the raw cell value.
- **Selection tally**: select more than one cell and the right of the formula
  bar reads `Count: 12/16` — populated cells out of cells counted. Select the
  ID column and it reads `12 entries` instead, since every counted row has an
  ID. Only entries are counted: a row needs an ID to be one, so `#` header and
  comment rows, the field-name row (selecting a column doesn't count its
  name), rows with no ID, and everything past the end of the data are all
  skipped. In a Boolean column only checked boxes count as populated.
  Selecting a collapsed header counts everything folded under it, so you can
  tally a section without unfolding it.
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
  menu). Insert works in units of the selection — three selected rows insert
  three, and the menu says so (**Insert 3 Rows Above**) — in one undo step.
  Selecting whole columns shows only the column commands (and vice versa),
  since the other axis would be acting on the entire sheet. The ID column
  can't be deleted or displaced.
- Full undo/redo.

## Collapsing sections

A `#` or `##` header owns every row beneath it up to the next header of the
same or higher level — so collapsing `# Enemies` folds its `## Forest` and
`## Caves` subsections away with it, while collapsing `## Forest` leaves
`## Caves` alone. `###` comment rows fold along with the content around them.

- Click the **disclosure triangle** at the left of a header's row number.
  ⌥-click folds the subsections nested inside it too.
- Sheet menu: **Collapse / Expand Section** (⌥⌘← / ⌥⌘→) act on the section
  the cursor is in; **Collapse / Expand All Sections** (⌥⇧⌘← / ⌥⇧⌘→) act on
  the whole sheet. Both pairs are also on the right-click menu.
- Folded rows are hidden, not changed — **the TSV on disk is untouched**.
  The skipped row numbers and a firm line under the header mark the seam, and
  a **“12 rows” badge** in the header's ID cell says how much is folded away.
- Arrow keys step over a folded section in one press, and the cursor is never
  left inside one. A selection that ends on a collapsed header still covers
  everything folded under it — the same way a fold in the middle of a
  selection is already inside it — so Select All doesn't miss a collapsed last
  section, and copy/clear/delete treat the fold as part of the selection. Autofill drags stop at a fold rather than writing into
  cells you can't see. Cross-file ID jumps and ⇧⌘D unfold whatever is hiding
  the row they land on.
- Collapse state lives in the `.tss` sidecar, so it survives reopening and
  follows its header when you drag-reorder rows. Editing the `#` off a header
  always brings its rows back.

## Column data types

Right-click a column (header or any cell) → **Column Data Type**:

- **Raw** (default) — plain left-aligned strings, exactly as on disk.
- **Integer** / **Float** — right-aligned; values that don't parse are shown
  in red so bad data is obvious at a glance. Nothing is ever rewritten.
- **Text** — word-wrapped display; rows grow automatically to fit the tallest
  text cell. Misspellings get a red squiggle in the grid (not just while
  editing), and right-clicking one offers corrections plus **Ignore
  Spelling** / **Learn Spelling**.
- **Boolean** — a checkbox on every line that has an ID; the file holds
  `TRUE` or `FALSE` (empty reads as false). Click the box or hit **space** to
  toggle — space toggles the whole selection at once. Values that aren't
  `TRUE`/`FALSE` are shown in red rather than coerced, and lines with no ID
  get no checkbox.
- **Select / Multi-Select** — the cell must be empty or hold a pre-defined
  option (Multi-Select allows a comma-separated list of them). Picking the
  type opens a dialog for where the options come from: an **ad-hoc list** you
  type in, or **the IDs of another sheet** — any open sheet (including this
  one) or a file you navigate to, stored as a relative path so the sheets can
  move together. If the option sheet is open its live IDs are used; otherwise
  it's read from disk. Like Boolean, the type only governs rows with IDs:
  every such cell gets a **dropdown chevron** (click to pick; on a
  multi-select, picks toggle membership), typing gets **inline autocomplete**
  (the suggested completion appears selected ahead of the cursor — keep
  typing to narrow it, ⌫ to reject it, commit to accept it), and on a
  multi-select **comma confirms the suggestion** and starts the next option.
  Values the options don't cover are shown in red, never rewritten.

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
titlebar model. Sheets keep a dirty flag (a `*` after the name in the
window/tab title, plus the close-button dot) and prompt on close/quit.

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
coltype	<columnIndex>	raw|integer|float|text|boolean|select|multiselect
collapsed	<headerRowIndex>	1
freeze	fieldrow|idcol	0|1
selectlist	<columnIndex>	<option>	<option>	…
selectfile	<columnIndex>	<relative path to .tsv>
```

`select`/`multiselect` columns carry one extra record naming their options
source: `selectlist` holds an ad-hoc option list (tab-separated, so any cell
value is representable), `selectfile` points at the sheet whose IDs are the
options, by a path relative to this file.

The UI writes column widths (drag-resize a column), column types, collapsed
sections and the freeze toggles today; freeze records are only written when a
pane is un-frozen, since frozen is the default, and `raw` column types are
never written. Per-row records (`rowheight`, `collapsed`) and per-column ones
(`colwidth`, `coltype`) are re-keyed when rows/columns are inserted, deleted or
reordered, so they stay attached to their content, and state on something
deleted is dropped rather than relocated. Unknown record types are preserved verbatim on rewrite, so future
fields — cell styles, merged headers, calculated columns — can be added in
`TSSFormat.swift` without breaking older files. That's the extension point:
add a record type to `parse`/`serialize` and consume it in
`SpreadsheetView`.

## Layout

```
Sources/TSVee/
  SpreadsheetModel.swift        the TSV grid: parsing, mutations, undo, unique-ID checks, section ranges
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
- `.tss`: cell styles, calculated columns
