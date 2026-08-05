import AppKit

/// Adds folder support to the standard document machinery: picking a folder
/// in the Open panel (or dropping one on the app) opens every .tsv directly
/// inside it, each as its own tab.
final class TSVDocumentController: NSDocumentController {

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
