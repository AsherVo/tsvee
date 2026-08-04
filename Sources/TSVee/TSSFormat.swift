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
///
/// TODO(tss): cell styles (font/color/alignment), merged headers, calculated
/// columns. Add new record types here; unknown records are preserved verbatim.
/// Per-column data type. `raw` is the default and is never persisted.
enum ColumnType: String {
    case raw
    case integer
    case float
    case text
}

struct TSSFormat {

    var columnWidths: [Int: CGFloat] = [:]
    var rowHeights: [Int: CGFloat] = [:]
    var columnTypes: [Int: ColumnType] = [:]

    /// Frozen panes. Both default to true; only deviations are persisted.
    var freezeFieldRow = true
    var freezeIDColumn = true

    /// Records from a newer/unknown TSS version, preserved on rewrite.
    private var unknownRecords: [String] = []

    var hasCustomFormatting: Bool {
        !columnWidths.isEmpty || !rowHeights.isEmpty || !columnTypes.isEmpty
            || !unknownRecords.isEmpty || !freezeFieldRow || !freezeIDColumn
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
