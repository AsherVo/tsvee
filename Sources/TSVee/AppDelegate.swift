import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - File menu actions

    /// Saves every open sheet with pending changes (untitled ones prompt for
    /// a location on their own window).
    @objc func saveAllDocuments(_ sender: Any?) {
        for document in NSDocumentController.shared.documents where document.isDocumentEdited {
            document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        }
    }

    /// Opens an untitled sheet in a standalone window instead of a tab.
    @objc func newUntitledWindow(_ sender: Any?) {
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) else { return }
        document.makeWindowControllers()
        let window = document.windowControllers.first?.window
        window?.tabbingMode = .disallowed
        document.showWindows()
        // Restore tabbing so future documents can join this window's group.
        DispatchQueue.main.async { window?.tabbingMode = .preferred }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveAllDocuments(_:)) {
            return NSDocumentController.shared.documents.contains { $0.isDocumentEdited }
        }
        return true
    }
}
