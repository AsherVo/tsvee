import AppKit

/// Resolves the option list of a `select` / `multiselect` column.
///
/// `.list` sources carry their options inline. `.file` sources name another
/// TSV by a path relative to this sheet; that sheet's row IDs are the options.
/// If the named sheet is open, its live (possibly unsaved) model is used —
/// including the sheet asking, which is how a self-referential column stays
/// current — otherwise the file is read from disk and cached until its
/// modification date changes.
final class SelectOptionsResolver {

    private var diskCache: [String: (modified: Date, ids: [String])] = [:]

    func options(for source: SelectSource, tsvURL: URL?) -> [String] {
        switch source {
        case .list(let options):
            return options
        case .file(let path):
            guard let target = Self.resolve(path, relativeTo: tsvURL) else { return [] }
            if let document = openDocument(at: target) {
                return document.model.entryIDs()
            }
            return idsOnDisk(at: target)
        }
    }

    static func resolve(_ path: String, relativeTo tsvURL: URL?) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base = tsvURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    /// The path stored in the sidecar: relative wherever possible, so the two
    /// sheets can move around together; absolute only when this sheet has
    /// never been saved and there's nothing to be relative to.
    static func storablePath(to target: URL, from tsvURL: URL?) -> String {
        let targetParts = target.standardizedFileURL.pathComponents
        guard let baseDir = tsvURL?.deletingLastPathComponent() else {
            return target.standardizedFileURL.path
        }
        let baseParts = baseDir.standardizedFileURL.pathComponents
        var common = 0
        while common < min(targetParts.count, baseParts.count),
              targetParts[common] == baseParts[common] { common += 1 }
        let parts = Array(repeating: "..", count: baseParts.count - common) + targetParts[common...]
        return parts.isEmpty ? target.lastPathComponent : parts.joined(separator: "/")
    }

    private func openDocument(at url: URL) -> TSVDocument? {
        for case let document as TSVDocument in NSDocumentController.shared.documents
        where document.fileURL?.standardizedFileURL == url {
            return document
        }
        return nil
    }

    private func idsOnDisk(at url: URL) -> [String] {
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = diskCache[url.path], cached.modified == modified {
            return cached.ids
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            diskCache[url.path] = nil
            return []
        }
        let model = SpreadsheetModel()
        model.load(tsv: text)
        let ids = model.entryIDs()
        diskCache[url.path] = (modified, ids)
        return ids
    }
}

/// The configuration dialog behind "Select…" / "Multi-Select…" in the Column
/// Data Type menu: choose where the column's options come from — an ad-hoc
/// list, or the IDs of another sheet (any open sheet, this one included, or a
/// file picked from disk).
enum SelectSourcePanel {

    /// Runs the modal dialog. nil means the user cancelled.
    static func run(columnName: String, typeTitle: String,
                    existing: SelectSource?, tsvURL: URL?) -> SelectSource? {
        let controller = Controller(existing: existing, tsvURL: tsvURL)

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
        private let sheetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        private let tsvURL: URL?

        init(existing: SelectSource?, tsvURL: URL?) {
            self.tsvURL = tsvURL
            super.init()

            listRadio.target = self
            listRadio.action = #selector(radioChanged(_:))
            fileRadio.target = self
            fileRadio.action = #selector(radioChanged(_:))

            listField.placeholderString = "red, green, blue"
            listField.font = .systemFont(ofSize: 12)

            populatePopUp(existing: existing)

            if case .list(let options) = existing {
                listField.stringValue = options.joined(separator: ", ")
            }
            var useFile = false
            if case .file = existing { useFile = true }
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

        /// Every open sheet that has a file (self included, so a column can
        /// reference its own IDs), then "Other…" for navigating to one.
        private func populatePopUp(existing: SelectSource?) {
            let current = tsvURL?.standardizedFileURL
            for case let document as TSVDocument in NSDocumentController.shared.documents {
                guard let url = document.fileURL?.standardizedFileURL else { continue }
                let name = document.displayName ?? url.lastPathComponent
                let item = NSMenuItem(
                    title: url == current ? "\(name) — this sheet" : name,
                    action: nil, keyEquivalent: "")
                item.representedObject = url
                sheetPopUp.menu?.addItem(item)
            }

            // A configured file that isn't open gets its own entry, selected,
            // so re-running the dialog shows (and keeps) the current source.
            if case .file(let path) = existing {
                let resolved = SelectOptionsResolver.resolve(path, relativeTo: tsvURL)
                if let index = sheetPopUp.itemArray.firstIndex(where: {
                    ($0.representedObject as? URL) == resolved
                }) {
                    sheetPopUp.selectItem(at: index)
                } else if let resolved {
                    let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
                    item.representedObject = resolved
                    sheetPopUp.menu?.insertItem(item, at: 0)
                    sheetPopUp.selectItem(at: 0)
                }
            }

            if sheetPopUp.numberOfItems > 0 { sheetPopUp.menu?.addItem(.separator()) }
            let other = NSMenuItem(title: "Other…", action: #selector(chooseFile(_:)),
                                   keyEquivalent: "")
            other.target = self
            sheetPopUp.menu?.addItem(other)
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

        /// The "Other…" pop-up item: navigate to a sheet anywhere on disk.
        @objc private func chooseFile(_ sender: NSMenuItem) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = tsvURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else {
                // Cancelled: put the selection back on a real sheet instead of
                // leaving it sitting on "Other…".
                if let index = sheetPopUp.itemArray.firstIndex(where: {
                    $0.representedObject is URL
                }) {
                    sheetPopUp.selectItem(at: index)
                }
                return
            }
            let standardized = url.standardizedFileURL
            if let index = sheetPopUp.itemArray.firstIndex(where: {
                ($0.representedObject as? URL) == standardized
            }) {
                sheetPopUp.selectItem(at: index)
            } else {
                let item = NSMenuItem(title: standardized.lastPathComponent,
                                      action: nil, keyEquivalent: "")
                item.representedObject = standardized
                sheetPopUp.menu?.insertItem(item, at: 0)
                sheetPopUp.selectItem(at: 0)
            }
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
            guard let url = sheetPopUp.selectedItem?.representedObject as? URL else { return nil }
            return .file(SelectOptionsResolver.storablePath(to: url, from: tsvURL))
        }
    }
}
