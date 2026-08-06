import Foundation

/// TSS ("Tab Separated Support") — the optional formatting sidecar.
///
/// A file named `data.tsv` may have a sibling `data.tss` carrying presentation
/// data so the TSV itself stays pure. This is a v0 STUB: it round-trips column
/// widths and row heights, and preserves any record types it doesn't
/// understand so future versions (cell styles, calculations) stay compatible.
///
/// v0 wire format — one tab-separated record per line:
///
///     tss	0
///     colwidth	<columnIndex>	<points>
///     rowheight	<rowIndex>	<points>
///     collapsed	<headerRowIndex>	1
///     selectlist	<columnIndex>	<option>	<option>	…
///     selectfile	<columnIndex>	<relative path to .tsv>
///
/// TODO(tss): cell styles (font/color/alignment), merged headers, calculated
/// columns. Add new record types here; unknown records are preserved verbatim.
/// Per-column data type. `raw` is the default and is never persisted.
enum ColumnType: String {
    case raw
    case integer
    case float
    case text
    case boolean
    case select
    case multiselect
}

/// Where a `select` / `multiselect` column's allowed options come from: an
/// ad-hoc list defined right in the sidecar, or another sheet's IDs — named by
/// a path relative to this file, so the sheets can move around together.
enum SelectSource: Equatable {
    case list([String])
    case file(String)
}

/// What a `boolean` cell holds. The file only ever carries `TRUE`/`FALSE` —
/// an empty cell reads as false, and anything else is data the column type
/// doesn't describe, which TSVee flags rather than rewrites.
enum BooleanCell {
    case on
    case off
    case invalid

    init(_ raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "TRUE": self = .on
        case "", "FALSE": self = .off
        default: self = .invalid
        }
    }

    /// What clicking a checkbox writes.
    static func literal(_ on: Bool) -> String { on ? "TRUE" : "FALSE" }
}

/// What a `select` / `multiselect` cell holds: one option, or a
/// comma-separated list of them. Empty is always allowed. Anything else is
/// data the column type doesn't describe — flagged, never rewritten.
enum SelectCell {

    /// The comma-separated entries of a cell, whitespace-trimmed. A
    /// single-select cell is just the one-entry case.
    static func tokens(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isValid(_ raw: String, options: Set<String>, multi: Bool) -> Bool {
        let entries = tokens(raw)
        if entries.isEmpty { return true }
        if !multi && entries.count > 1 { return false }
        return entries.allSatisfy { !$0.isEmpty && options.contains($0) }
    }
}

struct TSSFormat {

    var columnWidths: [Int: CGFloat] = [:]
    var rowHeights: [Int: CGFloat] = [:]
    var columnTypes: [Int: ColumnType] = [:]

    /// Option sources for `select` / `multiselect` columns.
    var selectSources: [Int: SelectSource] = [:]

    /// Header rows whose sections are collapsed. Entries for rows that are no
    /// longer headers are inert (and pruned on the next toggle), so an edited-
    /// away "#" can never strand its rows out of sight.
    var collapsedSections: Set<Int> = []

    /// Frozen panes. Both default to true; only deviations are persisted.
    var freezeFieldRow = true
    var freezeIDColumn = true

    /// Records from a newer/unknown TSS version, preserved on rewrite.
    private var unknownRecords: [String] = []

    var hasCustomFormatting: Bool {
        !columnWidths.isEmpty || !rowHeights.isEmpty || !columnTypes.isEmpty
            || !selectSources.isEmpty || !collapsedSections.isEmpty
            || !unknownRecords.isEmpty || !freezeFieldRow || !freezeIDColumn
    }

    /// The half of the sidecar that says what the data *is*: column types and
    /// where their options come from. Records from a version of TSS we don't
    /// know are counted here too — we can't rule out that they matter.
    ///
    /// Everything else — widths, heights, collapsed sections, frozen panes —
    /// is decoration: how one person happens to be looking at the sheet. A
    /// difference there is never worth interrupting anyone over.
    struct SubstantiveContent: Equatable {
        var columnTypes: [Int: ColumnType]
        var selectSources: [Int: SelectSource]
        var unknownRecords: [String]
    }

    var substantiveContent: SubstantiveContent {
        SubstantiveContent(columnTypes: columnTypes,
                           selectSources: selectSources,
                           unknownRecords: unknownRecords)
    }

    // MARK: - Sidecar location

    static func sidecarURL(for tsvURL: URL) -> URL {
        tsvURL.deletingPathExtension().appendingPathExtension("tss")
    }

    // MARK: - Loading

    /// Loads the sidecar next to the given TSV file, if one exists.
    static func load(for tsvURL: URL) -> TSSFormat? {
        let url = sidecarURL(for: tsvURL)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> TSSFormat {
        var format = TSSFormat()
        for line in text.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\t")
            switch fields[0] {
            case "", "tss":
                continue
            case "colwidth" where fields.count >= 3:
                if let index = Int(fields[1]), let width = Double(fields[2]), width > 0 {
                    format.columnWidths[index] = CGFloat(width)
                }
            case "rowheight" where fields.count >= 3:
                if let index = Int(fields[1]), let height = Double(fields[2]), height > 0 {
                    format.rowHeights[index] = CGFloat(height)
                }
            case "coltype" where fields.count >= 3:
                if let index = Int(fields[1]), let type = ColumnType(rawValue: fields[2]), type != .raw {
                    format.columnTypes[index] = type
                }
            // Options are tab-separated: cell values can never contain a tab,
            // so any option is representable, commas included.
            case "selectlist" where fields.count >= 2:
                if let index = Int(fields[1]) {
                    format.selectSources[index] = .list(fields.dropFirst(2).filter { !$0.isEmpty })
                }
            case "selectfile" where fields.count >= 3:
                if let index = Int(fields[1]), !fields[2].isEmpty {
                    format.selectSources[index] = .file(fields[2])
                }
            case "collapsed" where fields.count >= 3:
                if let index = Int(fields[1]), index >= 0, fields[2] != "0" {
                    format.collapsedSections.insert(index)
                }
            case "freeze" where fields.count >= 3:
                switch fields[1] {
                case "fieldrow": format.freezeFieldRow = fields[2] != "0"
                case "idcol": format.freezeIDColumn = fields[2] != "0"
                default: format.unknownRecords.append(line)
                }
            default:
                format.unknownRecords.append(line)
            }
        }
        return format
    }

    // MARK: - Saving

    func serialize() -> String {
        var lines = ["tss\t0"]
        for (index, width) in columnWidths.sorted(by: { $0.key < $1.key }) {
            lines.append("colwidth\t\(index)\t\(Int(width.rounded()))")
        }
        for (index, height) in rowHeights.sorted(by: { $0.key < $1.key }) {
            lines.append("rowheight\t\(index)\t\(Int(height.rounded()))")
        }
        for (index, type) in columnTypes.sorted(by: { $0.key < $1.key }) where type != .raw {
            lines.append("coltype\t\(index)\t\(type.rawValue)")
        }
        for (index, source) in selectSources.sorted(by: { $0.key < $1.key }) {
            switch source {
            case .list(let options):
                lines.append((["selectlist", String(index)] + options).joined(separator: "\t"))
            case .file(let path):
                lines.append("selectfile\t\(index)\t\(path)")
            }
        }
        for index in collapsedSections.sorted() {
            lines.append("collapsed\t\(index)\t1")
        }
        if !freezeFieldRow { lines.append("freeze\tfieldrow\t0") }
        if !freezeIDColumn { lines.append("freeze\tidcol\t0") }
        lines.append(contentsOf: unknownRecords)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the sidecar next to the TSV, but only when there is something
    /// worth persisting (or an existing sidecar to update). A plain TSV with
    /// default formatting never grows a stray .tss file.
    func writeSidecarIfNeeded(for tsvURL: URL) {
        let url = TSSFormat.sidecarURL(for: tsvURL)
        let sidecarExists = FileManager.default.fileExists(atPath: url.path)
        guard hasCustomFormatting || sidecarExists else { return }
        try? serialize().data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
