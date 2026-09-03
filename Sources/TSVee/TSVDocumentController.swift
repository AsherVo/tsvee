import AppKit

/// Adds folder support to the standard document machinery: picking a folder
/// in the Open panel (or dropping one on the app) opens every .tsv directly
/// inside it, each as its own tab. Also retires the blank sheet the app
/// launches with once a real file arrives to take its place.
final class TSVDocumentController: NSDocumentController {

    // MARK: - Replacing the blank launch sheet

    /// The blank sheet an incoming document should replace, if there is one:
    /// opening a file when the only thing on screen is an untouched,
    /// never-saved sheet takes its place instead of piling up next to it.
    /// A new untitled sheet (⌘N) never displaces one — two blank sheets is
    /// something you asked for.
    ///
    /// Generic over the document type so the rule can be tested on its own.
    static func replaceableBlankSheet<Document>(
        among documents: [Document], openingFile: Bool,
        isUntitled: (Document) -> Bool, isEdited: (Document) -> Bool) -> Document? {
        guard openingFile, documents.count == 1, let only = documents.first,
              isUntitled(only), !isEdited(only) else { return nil }
        return only
    }

    override func addDocument(_ document: NSDocument) {
        // `documents` doesn't include the incoming one yet, which is exactly
        // the "what's on screen right now" the rule is about.
        let blank = Self.replaceableBlankSheet(
            among: documents, openingFile: document.fileURL != nil,
            isUntitled: { $0.fileURL == nil }, isEdited: { $0.isDocumentEdited })
        super.addDocument(document)
        guard let blank else { return }
        // Closed on the next turn of the run loop, once the incoming document
        // has claimed its tab in the blank sheet's window: the file lands
        // where the blank sheet was rather than in a window of its own.
        DispatchQueue.main.async { [weak blank] in
            // It was untouched when the file arrived; it still has to be one
            // keystroke later, since the document opened asynchronously.
            guard let blank, blank.fileURL == nil, !blank.isDocumentEdited else { return }
            blank.close()
        }
    }

    // MARK: - Opening folders

    /// The .tsv files sitting directly in a folder, in Finder order.
    static func tsvFiles(inFolder url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "tsv" }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel,
                                 forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.canChooseDirectories = true
        return super.runModalOpenPanel(openPanel, forTypes: types)
    }

    override func openDocument(withContentsOf url: URL,
                               display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            super.openDocument(withContentsOf: url, display: displayDocument,
                               completionHandler: completionHandler)
            return
        }

        let files = Self.tsvFiles(inFolder: url)
        guard !files.isEmpty else {
            completionHandler(nil, false, NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
                    NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” contains no .tsv files.",
                ]))
            return
        }
        noteNewRecentDocumentURL(url)
        openSequentially(files, index: 0, display: displayDocument,
                         firstOpened: nil, firstError: nil,
                         completionHandler: completionHandler)
    }

    /// Opens one file at a time, chaining through each completion, so the
    /// tabs always land in name order. The folder-level completion reports
    /// the first document that opened, or the first error if none did.
    private func openSequentially(_ files: [URL], index: Int, display: Bool,
                                  firstOpened: NSDocument?, firstError: Error?,
                                  completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard index < files.count else {
            completionHandler(firstOpened, false, firstOpened == nil ? firstError : nil)
            return
        }
        super.openDocument(withContentsOf: files[index], display: display) { document, _, error in
            self.openSequentially(files, index: index + 1, display: display,
                                  firstOpened: firstOpened ?? document,
                                  firstError: firstError ?? error,
                                  completionHandler: completionHandler)
        }
    }
}
