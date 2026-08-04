import AppKit

@objc(TSVDocument)
final class TSVDocument: NSDocument {

    let model = SpreadsheetModel()
    var format = TSSFormat()

    override init() {
        super.init()
        model.undoManager = undoManager
    }

    override class var autosavesInPlace: Bool { true }

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
            }
            completionHandler(error)
        }
    }

    /// Called by the UI when formatting (column widths etc.) changes, so the
    /// document knows a save is warranted even though the TSV text is clean.
    func noteFormatChanged() {
        updateChangeCount(.changeDone)
    }
}
