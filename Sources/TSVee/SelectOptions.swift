import AppKit

/// Resolves the option list of a `select` / `multiselect` column.
///
/// `.list` sources carry their options inline. `.file` sources name another
/// TSV by a path relative to this sheet; that sheet's row IDs are the options.
final class SelectOptionsResolver {

    private let loader: LinkedSheetLoader

    init(loader: LinkedSheetLoader = LinkedSheetLoader()) {
        self.loader = loader
    }

    func options(for source: SelectSource, tsvURL: URL?) -> [String] {
        switch source {
        case .list(let options):
            return options
        case .file(let path):
            guard let target = SheetPath.resolve(path, relativeTo: tsvURL),
                  let model = loader.model(at: target) else { return [] }
            return model.entryIDs()
        }
    }
}

/// The configuration dialog behind "Select…" / "Multi-Select…" in the Column
/// Data Type menu: choose where the column's options come from — an ad-hoc
/// list, or the IDs of another sheet (any open sheet, this one included, or a
/// file picked from disk).
enum SelectSourcePanel {

    /// Runs the modal dialog. nil means the user cancelled.
    ///
    /// `suggested` seeds the ad-hoc list for a column that isn't already
    /// configured as one — normally the values the column already holds.
    static func run(columnName: String, typeTitle: String,
                    existing: SelectSource?, suggested: [String] = [],
                    tsvURL: URL?) -> SelectSource? {
        let controller = Controller(existing: existing, suggested: suggested, tsvURL: tsvURL)

        let alert = NSAlert()
        alert.messageText = "\(typeTitle) Options for \(columnName)"
        alert.informativeText = "Cells in rows with IDs must be empty or hold "
            + (typeTitle == "Multi-Select"
                ? "a comma-separated list of these options."
                : "one of these options.")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = controller.accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return controller.chosenSource()
    }

    /// Owns the accessory view for the duration of the modal run: two radio
    /// rows (ad-hoc list / IDs from a sheet) with their inputs.
    private final class Controller: NSObject {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 118))
        private let listRadio = NSButton(radioButtonWithTitle: "Ad-hoc list of options:",
                                         target: nil, action: nil)
        private let fileRadio = NSButton(radioButtonWithTitle: "IDs from another sheet:",
                                         target: nil, action: nil)
        private let listField = NSTextField(string: "")
        private let sheetPopUp = SheetPopUpButton(frame: .zero, pullsDown: false)
        private let tsvURL: URL?

        init(existing: SelectSource?, suggested: [String], tsvURL: URL?) {
            self.tsvURL = tsvURL
            super.init()

            listRadio.target = self
            listRadio.action = #selector(radioChanged(_:))
            fileRadio.target = self
            fileRadio.action = #selector(radioChanged(_:))

            listField.placeholderString = "red, green, blue"
            listField.font = .systemFont(ofSize: 12)

            var configuredPath: String?
            if case .file(let path) = existing { configuredPath = path }
            sheetPopUp.populate(tsvURL: tsvURL, preselecting: configuredPath)

            if case .list(let options) = existing {
                listField.stringValue = options.joined(separator: ", ")
            } else {
                // Nothing configured (or options come from a sheet): start the
                // list off with what the column already contains, so turning a
                // column of hand-typed values into a select needs no retyping.
                listField.stringValue = suggested.joined(separator: ", ")
            }
            let useFile = configuredPath != nil
            listRadio.state = useFile ? .off : .on
            fileRadio.state = useFile ? .on : .off

            listRadio.frame = NSRect(x: 0, y: 96, width: 420, height: 18)
            listField.frame = NSRect(x: 20, y: 64, width: 400, height: 24)
            fileRadio.frame = NSRect(x: 0, y: 34, width: 420, height: 18)
            sheetPopUp.frame = NSRect(x: 18, y: 2, width: 402, height: 26)
            for view in [listRadio, listField, fileRadio, sheetPopUp] {
                accessory.addSubview(view)
            }
            syncEnabledStates()
        }

        @objc private func radioChanged(_ sender: NSButton) {
            listRadio.state = sender === listRadio ? .on : .off
            fileRadio.state = sender === fileRadio ? .on : .off
            syncEnabledStates()
        }

        private func syncEnabledStates() {
            listField.isEnabled = listRadio.state == .on
            sheetPopUp.isEnabled = fileRadio.state == .on
        }

        /// What OK means, given the dialog's state. nil when the file radio is
        /// on but no sheet was ever picked — nothing usable to store.
        func chosenSource() -> SelectSource? {
            if listRadio.state == .on {
                var seen = Set<String>()
                let options = listField.stringValue
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                return .list(options)
            }
            guard let url = sheetPopUp.selectedSheet else { return nil }
            return .file(SheetPath.storable(to: url, from: tsvURL))
        }
    }
}
