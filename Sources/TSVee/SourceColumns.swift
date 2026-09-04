import AppKit

/// Resolves what a `source` column shows: one named field of another sheet,
/// matched to this sheet's rows by ID.
final class SourceColumnResolver {

    private let loader: LinkedSheetLoader
    private let optionsResolver: SelectOptionsResolver

    init(loader: LinkedSheetLoader = LinkedSheetLoader()) {
        self.loader = loader
        self.optionsResolver = SelectOptionsResolver(loader: loader)
    }

    /// The spec'd field's value for every entry of the source sheet, keyed by
    /// ID. Where two rows over there share an ID, the first wins — the same
    /// rule `entryIDs` uses.
    ///
    /// nil when there's nothing to mirror right now: the sheet can't be
    /// resolved or read, or it has no field by that name. That's a different
    /// answer from "no row over there has this ID" (an empty cell), and the
    /// caller leans on the difference — a source sheet that's been renamed or
    /// is mid-write must not blank a column of saved data.
    func values(for spec: SourceSpec, tsvURL: URL?) -> [String: String]? {
        guard let target = SheetPath.resolve(spec.path, relativeTo: tsvURL),
              let model = loader.model(at: target),
              let column = Self.column(named: spec.field, in: model) else { return nil }

        var values: [String: String] = [:]
        for row in 0..<model.rowCount {
            guard model.headerLevel(ofRow: row) == 0, !model.isFieldNameRow(row) else { continue }
            let id = model.value(row: row, column: 0)
            guard !id.isEmpty, values[id] == nil else { continue }
            values[id] = model.value(row: row, column: column)
        }
        return values
    }

    /// How the mirrored field is typed in the sheet it comes from, so a
    /// `source` column can present its values the way that sheet does — a
    /// mirrored boolean field draws checkboxes, a mirrored number right-aligns.
    ///
    /// nil when there's nothing to inherit: the sheet can't be resolved, has no
    /// such field, or types it as plain `raw`.
    func inheritedType(for spec: SourceSpec, tsvURL: URL?) -> InheritedType? {
        var spec = spec
        var base = tsvURL
        // A donor that is itself a `source` column has no type of its own to
        // give — it passes along whatever it mirrors, so the chain is followed
        // to whatever typed it. `visited` stops a cycle from spinning.
        var visited: Set<String> = []
        while true {
            guard let target = SheetPath.resolve(spec.path, relativeTo: base),
                  visited.insert("\(target.path)\t\(spec.field)").inserted,
                  let model = loader.model(at: target),
                  let column = Self.column(named: spec.field, in: model),
                  let format = loader.format(at: target) else { return nil }

            let type = format.columnTypes[column] ?? .raw
            if type == .source {
                guard let next = format.sourceSpecs[column] else { return nil }
                spec = next
                base = target
                continue
            }
            guard type != .raw else { return nil }

            // Options belong to the sheet that defines them: a `selectfile`
            // path over there is relative to that sheet, not to this one.
            var options: [String] = []
            if type == .select || type == .multiselect, let source = format.selectSources[column] {
                options = optionsResolver.options(for: source, tsvURL: target)
            }
            return InheritedType(type: type, options: options)
        }
    }

    /// The field names another sheet offers, in column order. The ID column is
    /// left out: mirroring it into a column already matched by ID would just
    /// copy the IDs back. A sheet with no field-name row names nothing, so it
    /// has nothing to offer.
    func fieldNames(at url: URL) -> [String] {
        guard let model = loader.model(at: url), model.hasFieldNameRow else { return [] }
        var seen = Set<String>()
        return (1..<model.columnCount).compactMap { column in
            let name = model.value(row: 0, column: column)
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
    }

    /// What a `source` column takes on from the column it mirrors: that
    /// column's data type, plus the options behind it when it is a select.
    struct InheritedType: Equatable {
        var type: ColumnType
        var options: [String]
    }

    private static func column(named field: String, in model: SpreadsheetModel) -> Int? {
        guard model.hasFieldNameRow else { return nil }
        return (1..<model.columnCount).first { model.value(row: 0, column: $0) == field }
    }
}

/// The configuration dialog behind "Source…" in the Column Data Type menu:
/// which sheet to mirror, and which of its fields.
enum SourceColumnPanel {

    /// Runs the modal dialog. nil means the user cancelled, or picked a sheet
    /// with no fields to offer.
    static func run(columnName: String, existing: SourceSpec?,
                    tsvURL: URL?, resolver: SourceColumnResolver) -> SourceSpec? {
        let controller = Controller(existing: existing, tsvURL: tsvURL, resolver: resolver)

        let alert = NSAlert()
        alert.messageText = "Source for \(columnName)"
        alert.informativeText = "Every row with an ID shows that ID's value of the chosen "
            + "field. Rows the source sheet doesn't have come up empty. The column is "
            + "filled in for you and can't be edited here, but its values are saved to "
            + "this file like any others."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = controller.accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return controller.chosenSpec()
    }

    /// Owns the accessory view for the duration of the modal run: the sheet to
    /// mirror, and the field of it to show. Changing the sheet re-reads its
    /// field names into the second pop-up.
    private final class Controller: NSObject {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        private let sheetPopUp = SheetPopUpButton(frame: .zero, pullsDown: false)
        private let fieldPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        private let tsvURL: URL?
        private let resolver: SourceColumnResolver

        init(existing: SourceSpec?, tsvURL: URL?, resolver: SourceColumnResolver) {
            self.tsvURL = tsvURL
            self.resolver = resolver
            super.init()

            sheetPopUp.populate(tsvURL: tsvURL, preselecting: existing?.path)
            sheetPopUp.onSheetChanged = { [weak self] in self?.reloadFields(selecting: nil) }
            reloadFields(selecting: existing?.field)

            let sheetLabel = Self.label("Sheet:")
            let fieldLabel = Self.label("Field:")
            sheetLabel.frame = NSRect(x: 0, y: 84, width: 420, height: 16)
            sheetPopUp.frame = NSRect(x: 18, y: 54, width: 402, height: 26)
            fieldLabel.frame = NSRect(x: 0, y: 30, width: 420, height: 16)
            fieldPopUp.frame = NSRect(x: 18, y: 0, width: 402, height: 26)
            for view in [sheetLabel, sheetPopUp, fieldLabel, fieldPopUp] as [NSView] {
                accessory.addSubview(view)
            }
        }

        private static func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 12)
            return field
        }

        /// Re-reads the chosen sheet's field names. `selecting` re-picks a
        /// field by name when that sheet still has one — how re-opening the
        /// dialog comes up on the configured field.
        private func reloadFields(selecting field: String?) {
            fieldPopUp.removeAllItems()
            let names = sheetPopUp.selectedSheet.map(resolver.fieldNames(at:)) ?? []
            guard !names.isEmpty else {
                fieldPopUp.addItem(withTitle: "No fields — that sheet has no field-name row")
                fieldPopUp.isEnabled = false
                return
            }
            fieldPopUp.isEnabled = true
            fieldPopUp.addItems(withTitles: names)
            if let field, let index = names.firstIndex(of: field) {
                fieldPopUp.selectItem(at: index)
            }
        }

        /// nil when there's nothing usable to store: no sheet was ever picked,
        /// or the one that was names no fields.
        func chosenSpec() -> SourceSpec? {
            guard let url = sheetPopUp.selectedSheet, fieldPopUp.isEnabled,
                  let field = fieldPopUp.titleOfSelectedItem else { return nil }
            return SourceSpec(path: SheetPath.storable(to: url, from: tsvURL), field: field)
        }
    }
}
