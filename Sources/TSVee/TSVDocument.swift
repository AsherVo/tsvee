import AppKit

@objc(TSVDocument)
final class TSVDocument: NSDocument {

    let model = SpreadsheetModel()
    var format = TSSFormat()

    override init() {
        super.init()
        model.undoManager = undoManager
    }

    // Traditional save paradigm: dirty flag, explicit ⌘S, prompt on close —
    // no autosave-in-place and none of the Duplicate/Rename titlebar model.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: - Reading

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedDescriptionKey: "This file is not text TSVee can read.",
            ])
        }
        model.load(tsv: text)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        try super.read(from: url, ofType: typeName)
        // Optional formatting sidecar: data.tsv -> data.tss (stub, v0).
        format = TSSFormat.load(for: url) ?? TSSFormat()
        sidecarModificationDate = Self.modificationDate(of: TSSFormat.sidecarURL(for: url))
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        Data(model.tsvString().utf8)
    }

    override func save(to url: URL,
                       ofType typeName: String,
                       for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            // Sidecars only accompany real saves, never autosave copies.
            if error == nil,
               saveOperation == .saveOperation || saveOperation == .saveAsOperation {
                self?.format.writeSidecarIfNeeded(for: url)
                // What's on disk is now ours, so nothing is left to reconcile
                // (including a difference the user previously chose to keep).
                self?.sidecarModificationDate =
                    Self.modificationDate(of: TSSFormat.sidecarURL(for: url))
                self?.declinedDiskState = nil
            }
            completionHandler(error)
        }
    }

    /// Called by the UI when formatting (column widths etc.) changes, so the
    /// document knows a save is warranted even though the TSV text is clean.
    func noteFormatChanged() {
        updateChangeCount(.changeDone)
    }

    // MARK: - Keeping up with the file on disk

    /// When the file (or its sidecar) was last written, as far as this document
    /// knows. The TSV half is `fileModificationDate`, which AppKit maintains
    /// across reads and saves; the sidecar's is ours to track.
    private struct DiskState: Equatable {
        var tsv: Date?
        var tss: Date?
    }

    private var sidecarModificationDate: Date?

    /// Disk state the user was offered and declined, so a sheet they chose to
    /// keep isn't re-offered every time its window comes forward. Cleared when
    /// the file changes again, or when a save makes the question moot.
    private var declinedDiskState: DiskState?

    /// Guards against a second check running while the confirmation sheet from
    /// the first is still up — dismissing it makes the window key again.
    private var isReconcilingWithDisk = false

    private var knownDiskState: DiskState {
        DiskState(tsv: fileModificationDate, tss: sidecarModificationDate)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// nil when there's nothing readable there — a file that has been deleted
    /// or renamed out from under us is left alone rather than emptied.
    private static func diskState(for tsvURL: URL) -> DiskState? {
        guard let tsv = modificationDate(of: tsvURL) else { return nil }
        return DiskState(tsv: tsv, tss: modificationDate(of: TSSFormat.sidecarURL(for: tsvURL)))
    }

    /// Something edited this sheet in another app? Show that version. Called
    /// whenever one of this document's windows comes to the front, which is
    /// when a stale sheet would start misleading someone.
    ///
    /// Silent when there's nothing of the user's to lose. When there is —
    /// unsaved edits, or a half-typed cell — reloading is destructive, so it
    /// becomes a question, asked on `window` when there is one.
    func reconcileWithDiskIfNeeded(confirmingIn window: NSWindow?) {
        guard !isReconcilingWithDisk, let url = fileURL,
              let disk = Self.diskState(for: url),
              disk != knownDiskState, disk != declinedDiskState else { return }

        guard hasWorkToLose else {
            reloadFromDisk()
            return
        }
        // Someone resizing a column or folding a section elsewhere is not a
        // conflict worth a dialog. Leave this sheet as it is; the user's own
        // save will settle it.
        guard changeOnDiskIsSubstantive(at: url, disk: disk) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = displayName ?? url.lastPathComponent
        alert.messageText = "“\(name)” has changed on disk."
        alert.informativeText = "This sheet has changes of your own that aren't saved. "
            + "Reloading replaces them with the version on disk."
        // Keeping is the default: losing unsaved work to an absent-minded
        // Return is worse than looking at a stale sheet for another moment.
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload from Disk")

        isReconcilingWithDisk = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isReconcilingWithDisk = false
            if response == .alertFirstButtonReturn {
                self.declinedDiskState = disk
            } else {
                self.reloadFromDisk()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Whether what changed on disk is worth asking about: any change to the
    /// TSV is, but a sidecar-only change counts only when it touches what the
    /// data means (column types, select options) rather than how it's laid out.
    private func changeOnDiskIsSubstantive(at url: URL, disk: DiskState) -> Bool {
        if disk.tsv != fileModificationDate { return true }
        let onDisk = TSSFormat.load(for: url) ?? TSSFormat()
        return onDisk.substantiveContent != format.substantiveContent
    }

    /// Unsaved edits, or an open cell editor whose text hasn't been committed
    /// yet — either way, reloading would throw away something the user typed.
    private var hasWorkToLose: Bool {
        if isDocumentEdited { return true }
        return windowControllers.contains {
            ($0 as? DocumentWindowController)?.isEditingCell == true
        }
    }

    /// Replaces the document's contents — data and formatting both — with
    /// what's in the file, discarding anything unsaved.
    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        for case let controller as DocumentWindowController in windowControllers {
            controller.prepareForReload()
        }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "public.tab-separated-values")
        } catch {
            // Unreadable right now (a partial write, say): keep what we have
            // and let the next focus try again.
            return
        }
        fileModificationDate = Self.modificationDate(of: url)
        declinedDiskState = nil
        // The old undo stack describes rows that no longer exist.
        undoManager?.removeAllActions()
        // `read` loads the model before the sidecar, so the views' first look
        // at the new rows used the old formatting. Nudge them again now that
        // both halves are in place.
        model.onChange?()
    }
}
