import AppKit

final class DocumentWindowController: NSWindowController {

    private let spreadsheetView = SpreadsheetView()
    private let formulaBar = FormulaBarView()

    convenience init(document: TSVDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true)
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.setFrameAutosaveName("TSVeeDocumentWindow")

        self.init(window: window)

        // Format hooks must be in place before the model is attached — the
        // model's didSet does the first geometry pass using the .tss widths.
        spreadsheetView.formatProvider = { [weak document] in document?.format ?? TSSFormat() }
        spreadsheetView.onFormatChange = { [weak document] mutate in
            guard let document else { return }
            mutate(&document.format)
            document.noteFormatChanged()
        }
        spreadsheetView.model = document.model

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.documentView = spreadsheetView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        formulaBar.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(formulaBar)
        content.addSubview(divider)
        content.addSubview(scrollView)
        window.contentView = content

        NSLayoutConstraint.activate([
            formulaBar.topAnchor.constraint(equalTo: content.topAnchor),
            formulaBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formulaBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formulaBar.heightAnchor.constraint(equalToConstant: 34),

            divider.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        wireUp(document: document)
        window.makeFirstResponder(spreadsheetView)
    }

    private func wireUp(document: TSVDocument) {
        let model = document.model

        model.onChange = { [weak self] in
            guard let self else { return }
            self.spreadsheetView.modelDidChange()
            self.refreshFormulaBar()
        }

        spreadsheetView.onSelectionChange = { [weak self] in
            self?.refreshFormulaBar()
        }

        formulaBar.onCommit = { [weak self] text in
            self?.spreadsheetView.applyToFocusedCell(text)
        }
        formulaBar.onJumpToDuplicate = { [weak self] in
            self?.spreadsheetView.jumpToNextDuplicateID(nil)
        }

        // The document was read before this controller existed, so push the
        // initial state through by hand.
        refreshFormulaBar()
    }

    private func refreshFormulaBar() {
        guard let model = spreadsheetView.model else { return }
        formulaBar.update(
            cellName: spreadsheetView.focusedCellName(),
            content: spreadsheetView.focusedCellValue(),
            duplicateCount: model.duplicateIDRows.count)
    }
}
