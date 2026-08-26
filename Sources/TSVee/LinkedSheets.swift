import AppKit

/// Paths to another sheet, as they travel in the `.tss` sidecar.
///
/// Relative wherever possible, so two sheets that reference each other can be
/// moved (or checked out) together; absolute only when this sheet has never
/// been saved and there's nothing to be relative to.
enum SheetPath {

    static func resolve(_ path: String, relativeTo tsvURL: URL?) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base = tsvURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    static func storable(to target: URL, from tsvURL: URL?) -> String {
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
}

/// Reads a sheet this one links to — a `select` column's option sheet, a
/// `source` column's donor.
///
/// If the named sheet is open, its live (possibly unsaved) model is used —
/// including the sheet asking, which is how a self-referential column stays
/// current — otherwise the file is read from disk and cached until its
/// modification date changes.
final class LinkedSheetLoader {

    private var diskCache: [String: (modified: Date, model: SpreadsheetModel)] = [:]

    func model(at url: URL) -> SpreadsheetModel? {
        if let document = Self.openDocument(at: url) { return document.model }

        let modified = Self.modificationDate(of: url)
        if let cached = diskCache[url.path], cached.modified == modified {
            return cached.model
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            diskCache[url.path] = nil
            return nil
        }
        let model = SpreadsheetModel()
        model.load(tsv: text)
        diskCache[url.path] = (modified, model)
        return model
    }

    private static func modificationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private static func openDocument(at url: URL) -> TSVDocument? {
        for case let document as TSVDocument in NSDocumentController.shared.documents
        where document.fileURL?.standardizedFileURL == url {
            return document
        }
        return nil
    }
}

/// A pop-up listing every open sheet that has a file, then "Other…" for
/// navigating to one on disk. Shared by the dialogs behind the `select` and
/// `source` column types, which both need to name another sheet.
final class SheetPopUpButton: NSPopUpButton {

    /// Fired when the chosen sheet changes — including via "Other…".
    var onSheetChanged: (() -> Void)?

    /// The sheet this document lives in, which relative paths resolve against.
    private var tsvURL: URL?

    var selectedSheet: URL? { selectedItem?.representedObject as? URL }

    /// Fills the menu. `preselecting` is a stored (possibly relative) path;
    /// one naming a sheet that isn't open gets its own entry so re-opening the
    /// dialog shows — and keeps — the current choice.
    func populate(tsvURL: URL?, preselecting path: String?) {
        self.tsvURL = tsvURL
        removeAllItems()
        target = self
        action = #selector(selectionChanged)

        let current = tsvURL?.standardizedFileURL
        for case let document as TSVDocument in NSDocumentController.shared.documents {
            guard let url = document.fileURL?.standardizedFileURL else { continue }
            let name = document.displayName ?? url.lastPathComponent
            let item = NSMenuItem(title: url == current ? "\(name) — this sheet" : name,
                                  action: nil, keyEquivalent: "")
            item.representedObject = url
            menu?.addItem(item)
        }

        if let path, let resolved = SheetPath.resolve(path, relativeTo: tsvURL) {
            if let index = itemArray.firstIndex(where: { ($0.representedObject as? URL) == resolved }) {
                selectItem(at: index)
            } else {
                insert(sheet: resolved, titled: path)
            }
        }

        if numberOfItems > 0 { menu?.addItem(.separator()) }
        let other = NSMenuItem(title: "Other…", action: #selector(chooseFile), keyEquivalent: "")
        other.target = self
        menu?.addItem(other)
    }

    private func insert(sheet url: URL, titled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = url
        menu?.insertItem(item, at: 0)
        selectItem(at: 0)
    }

    @objc private func selectionChanged() {
        onSheetChanged?()
    }

    /// The "Other…" item: navigate to a sheet anywhere on disk.
    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = tsvURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else {
            // Cancelled: put the selection back on a real sheet instead of
            // leaving it sitting on "Other…".
            if let index = itemArray.firstIndex(where: { $0.representedObject is URL }) {
                selectItem(at: index)
            }
            return
        }
        let standardized = url.standardizedFileURL
        if let index = itemArray.firstIndex(where: {
            ($0.representedObject as? URL) == standardized
        }) {
            selectItem(at: index)
        } else {
            insert(sheet: standardized, titled: standardized.lastPathComponent)
        }
        onSheetChanged?()
    }
}
